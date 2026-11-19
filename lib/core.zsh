typeset -ga _ZSHARD_LOADED_FILES=() _ZSHARD_DEFERRED=()
typeset -gA _ZSHARD_LAZY_FILES=()
typeset -g ZSHARD_PLUGIN_DIR=${ZSHARD_PLUGIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zshard/plugins}

_zshard_error() { print -ru2 -- "zshard: $*"; return 1; }

_zshard_source() {
  emulate -L zsh
  local file=${1:A}
  [[ -f $file && -r $file ]] || { _zshard_error "cannot read plugin: $1"; return 1; }
  (( ${_ZSHARD_LOADED_FILES[(Ie)$file]} )) && return 0
  source "$file" || return
  _ZSHARD_LOADED_FILES+=("$file")
}

_zshard_lazy_dispatch() {
  local name=$1 file=${_ZSHARD_LAZY_FILES[$1]}
  shift
  unfunction "$name"
  unset "_ZSHARD_LAZY_FILES[$name]"
  _zshard_source "$file" || return
  if (( $+functions[$name] )); then "$name" "$@"
  elif (( $+commands[$name] )); then command "$name" "$@"
  else _zshard_error "plugin did not provide command: $name"
  fi
}

_zshard_run_deferred() {
  local file
  local -a files=("${_ZSHARD_DEFERRED[@]}")
  _ZSHARD_DEFERRED=()
  for file in "${files[@]}"; do _zshard_source "$file" || return; done
}

zshard() {
  emulate -L zsh
  setopt extendedglob
  local action=${1:-help} name file
  (( $# )) && shift
  case $action in
    help|--help|-h)
      print -r -- 'zshard — small, explicit zsh framework
  load FILE                    Source a local plugin once
  defer FILE                   Source when the first editing line opens
  lazy COMMAND FILE            Source on the first command invocation
  use NAME                     Load an explicitly installed plugin
  plugin add NAME URL SHA FILE  Install a pinned Git commit; does not load it
  plugin list|verify|remove NAME
  plugin export|restore FILE   Export or restore reviewed exact pins
  hook|unhook EVENT FUNCTION    Register or remove one owned shell hook
  completions DIR              Register completion files before first Tab
  theme FUNCTION               Set a prompt callback (status, seconds)
  unload NAME                  Run an installed plugin cleanup function
  ai ACTION                    Run a zai action from the standalone CLI
  complete                     Initialize audited completion now
  doctor                       Show runtime dependencies and modes
  version                      Print version
  zai context|connect|ask|propose (separate shell function)'
      ;;
    version|--version) print -r -- "zshard $ZSHARD_VERSION";;
    load) (( $# == 1 )) || { _zshard_error 'load requires FILE'; return 2; }; _zshard_source "$1";;
    defer)
      (( $# == 1 )) || { _zshard_error 'defer requires FILE'; return 2; }
      file=${1:A}; [[ -f $file ]] || { _zshard_error "missing plugin: $1"; return 1; }
      (( ${_ZSHARD_DEFERRED[(Ie)$file]} )) || _ZSHARD_DEFERRED+=("$file")
      ;;
    lazy)
      (( $# == 2 )) || { _zshard_error 'lazy requires COMMAND FILE'; return 2; }
      name=$1; file=${2:A}
      [[ $name == [A-Za-z_][A-Za-z0-9_:-]# ]] || { _zshard_error 'invalid command name'; return 2; }
      [[ -f $file ]] || { _zshard_error "missing plugin: $2"; return 1; }
      (( $+functions[$name] )) && { _zshard_error "function already exists: $name"; return 1; }
      _ZSHARD_LAZY_FILES[$name]=$file
      functions[$name]="_zshard_lazy_dispatch ${(q)name} \"\$@\""
      ;;
    use)
      (( $# == 1 )) || { _zshard_error 'use requires NAME'; return 2; }
      _zshard_plugin_entry "$1" || return
      _zshard_source "$REPLY"
      ;;
    ai) zai "$@";;
    hook|unhook)
      (( $# == 2 )) || { _zshard_error "$action requires EVENT FUNCTION"; return 2; }
      [[ $1 == (chpwd|precmd|preexec|periodic|zshaddhistory|zshexit|zsh_directory_name) ]] ||
        { _zshard_error 'unsupported shell hook'; return 2; }
      [[ $2 == [A-Za-z_][A-Za-z0-9_:-]# ]] || { _zshard_error 'invalid hook function'; return 2; }
      autoload -Uz add-zsh-hook
      if [[ $action == hook ]]; then
        (( $+functions[$2] )) || { _zshard_error "missing hook function: $2"; return 1; }
        add-zsh-hook "$1" "$2"
      else add-zsh-hook -d "$1" "$2"
      fi
      ;;
    completions)
      (( $# == 1 )) && [[ -d $1 ]] || { _zshard_error 'completions requires a directory'; return 2; }
      (( ${_ZSHARD_COMPLETION_READY:-0} )) && { _zshard_error 'register completion directories before the first Tab or zshard complete'; return 1; }
      typeset -gU fpath
      fpath=("${1:A}" "${fpath[@]}")
      ;;
    theme)
      (( $# == 1 )) && (( $+functions[$1] )) || { _zshard_error 'theme requires a defined function'; return 2; }
      typeset -g ZSHARD_PROMPT_FUNCTION=$1
      ;;
    unload)
      (( $# == 1 )) || { _zshard_error 'unload requires an installed plugin NAME'; return 2; }
      name=$1
      _zshard_plugin_entry "$name" || return
      file=$REPLY
      local cleanup=zshard_plugin_${name//-/_}_unload
      (( $+functions[$cleanup] )) || { _zshard_error "plugin has no unload function: $cleanup"; return 1; }
      "$cleanup" || return
      integer index=${_ZSHARD_LOADED_FILES[(Ie)$file]}
      (( index )) && _ZSHARD_LOADED_FILES[index]=()
      return 0
      ;;
    plugin) _zshard_plugin "$@";;
    complete)
      (( $+functions[_zshard_completion_init] )) || { _zshard_error 'completion requires an interactive shell'; return 1; }
      _zshard_completion_init
      ;;
    doctor)
      print -r -- "zshard=$ZSHARD_VERSION zsh=$ZSH_VERSION"
      print -r -- "completion=${ZSHARD_COMPLETION:-lazy} prompt=${ZSHARD_PROMPT:-minimal}"
      print -r -- "git=${commands[git]:-unavailable} ssmcp=${commands[ssmcp]:-unavailable} zdot=${commands[zdot]:-unavailable}"
      print -r -- "plugin_dir=$ZSHARD_PLUGIN_DIR"
      ;;
    *) _zshard_error "unknown command: $action"; return 2;;
  esac
}
