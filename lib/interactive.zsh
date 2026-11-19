typeset -gi _ZSHARD_LAST_EXIT=0 _ZSHARD_STARTED=0 _ZSHARD_COMPLETION_READY=0
typeset -g _ZSHARD_GIT_DIR='' _ZSHARD_BRANCH='' _ZSHARD_POSTDISPLAY='' _ZSHARD_SUGGESTION=''

_zshard_git_location() {
  emulate -L zsh
  local dir=$PWD line target
  _ZSHARD_GIT_DIR=''
  while [[ $dir != / ]]; do
    if [[ -d $dir/.git ]]; then _ZSHARD_GIT_DIR=$dir/.git; break; fi
    if [[ -f $dir/.git ]]; then
      IFS= read -r line < "$dir/.git"
      if [[ $line == 'gitdir: '* ]]; then
        target=${line#gitdir: }
        [[ $target == /* ]] || target=$dir/$target
        [[ -d $target ]] && _ZSHARD_GIT_DIR=${target:A}
      fi
      break
    fi
    dir=${dir:h}
  done
}

_zshard_git_branch() {
  emulate -L zsh
  local head
  _ZSHARD_BRANCH=''
  [[ -n $_ZSHARD_GIT_DIR && -f $_ZSHARD_GIT_DIR/HEAD ]] || return 0
  IFS= read -r head < "$_ZSHARD_GIT_DIR/HEAD"
  case $head in
    'ref: refs/heads/'*) _ZSHARD_BRANCH=${head#ref: refs/heads/};;
    [0-9a-f]*) _ZSHARD_BRANCH=@${head[1,8]};;
  esac
  _ZSHARD_BRANCH=${_ZSHARD_BRANCH//[[:cntrl:]]/}
  _ZSHARD_BRANCH=${_ZSHARD_BRANCH//\%/%%}
  _ZSHARD_BRANCH=${_ZSHARD_BRANCH[1,80]}
}

_zshard_uri_path() {
  emulate -L zsh
  local LC_ALL=C char out='' hex
  integer i
  for (( i=1; i<=${#PWD}; ++i )); do
    char=$PWD[i]
    case $char in
      [a-zA-Z0-9/._~-]) out+=$char;;
      *) printf -v hex '%%%02X' "'$char"; out+=$hex;;
    esac
  done
  REPLY=$out
}

_zshard_preexec() {
  _ZSHARD_STARTED=$EPOCHSECONDS
  [[ ${ZSHARD_SHELL_INTEGRATION:-0} == 1 && -t 1 ]] && print -rn -- $'\e]133;C\a'
  return 0
}

_zshard_precmd() {
  local last=$?
  _ZSHARD_LAST_EXIT=$last
  local branch='' result='' elapsed='' marker=''
  integer seconds=0
  (( _ZSHARD_STARTED )) && seconds=$(( EPOCHSECONDS - _ZSHARD_STARTED ))
  _ZSHARD_STARTED=0
  if [[ ${ZSHARD_PROMPT:-minimal} != off ]]; then
    _zshard_git_branch
    [[ -n $_ZSHARD_BRANCH ]] && branch=" %F{242}$_ZSHARD_BRANCH%f"
    (( last )) && result=" %F{red}!$last%f"
    (( seconds >= 2 )) && elapsed=" %F{242}${seconds}s%f"
    if [[ ${ZSHARD_SHELL_INTEGRATION:-0} == 1 && -t 1 ]]; then
      print -rn -- $'\e]133;D;'"$last"$'\a'
      _zshard_uri_path
      print -rn -- $'\e]7;file://localhost'"$REPLY"$'\a'
      marker=$'%{\e]133;A\a%}'
      PROMPT="$marker%F{blue}%1~%f$branch$result$elapsed"$'\n'"%F{green}%#%f "$'%{\e]133;B\a%}'
    else
      PROMPT="%F{blue}%1~%f$branch$result$elapsed"$'\n''%F{green}%#%f '
    fi
    RPROMPT=''
  fi
  if [[ -n ${ZSHARD_PROMPT_FUNCTION-} ]] && (( $+functions[$ZSHARD_PROMPT_FUNCTION] )); then
    "$ZSHARD_PROMPT_FUNCTION" "$last" "$seconds"
  fi
  return 0
}

_zshard_cache_usable() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat || return 1
  local candidate
  local -A metadata
  for candidate in "$@"; do
    [[ -L $candidate ]] && return 1
    [[ -e $candidate ]] || continue
    [[ -O $candidate ]] || return 1
    zstat -H metadata -- "$candidate" 2>/dev/null || return 1
    (( (metadata[mode] & 8#22) == 0 )) || return 1
  done
  return 0
}

_zshard_completion_init() {
  emulate -L zsh
  (( _ZSHARD_COMPLETION_READY )) && return 0
  local cache=${ZSHARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zshard}
  autoload -Uz compinit
  if [[ ! -L $cache ]] && { [[ -d $cache && -O $cache ]] || zf_mkdir -p -m 700 -- "$cache"; }; then
    if _zshard_cache_usable "$cache" "$cache/zcompdump-$ZSH_VERSION" "$cache/zcompdump-$ZSH_VERSION.zwc"; then
      zf_chmod 700 "$cache" || return
      # A new audit runs for each shell, including when a dump already exists.
      compinit -i -d "$cache/zcompdump-$ZSH_VERSION" || return
    else
      compinit -i -D -d /dev/null || return
    fi
  else
    compinit -i -D -d /dev/null || return
  fi
  _ZSHARD_COMPLETION_READY=1
}

_zshard_complete() {
  _zshard_completion_init || return
  zle expand-or-complete
}

_zshard_redraw() {
  emulate -L zsh
  setopt extendedglob
  region_highlight=("${(@)region_highlight:#*memo=zshard}")
  [[ $POSTDISPLAY == $_ZSHARD_POSTDISPLAY ]] && POSTDISPLAY=''
  _ZSHARD_POSTDISPLAY='' _ZSHARD_SUGGESTION=''
  local command_word prefix candidate color
  integer start end event tries=0
  if [[ ${ZSHARD_HIGHLIGHT:-1} == 1 && ${#BUFFER} -le 2048 &&
        $BUFFER =~ '^[[:space:]]*([^[:space:];|&]+)' ]]; then
    command_word=$match[1]
    start=$(( ${#MATCH} - ${#command_word} ))
    end=$(( start + ${#command_word} ))
    if (( $+commands[$command_word] || $+builtins[$command_word] || $+functions[$command_word] )) ||
      [[ -x $command_word && ! -d $command_word ]]; then color=green
    elif [[ $command_word == (if|then|else|elif|fi|for|while|until|do|done|case|esac|function|select|repeat|time|coproc|foreach|end) ]]; then color=magenta
    elif [[ $command_word == *[\$\`\\\"\'=]* ]]; then color=default
    else color=red
    fi
    region_highlight+=("$start $end fg=$color memo=zshard")
  fi
  if [[ ${ZSHARD_SUGGESTIONS:-1} != 1 || -z $BUFFER || -n $POSTDISPLAY ||
        ${#BUFFER} -gt 400 || $CURSOR -ne ${#BUFFER} || $BUFFER == *$'\n'* ]]; then return 0; fi
  event=$HISTCMD
  while (( event > 0 && tries < ${ZSHARD_HISTORY_SCAN:-200} )); do
    (( --event, ++tries ))
    candidate=${history[$event]-}
    if [[ $candidate == "$BUFFER"* && $candidate != "$BUFFER" && $candidate != *$'\n'* ]]; then
      _ZSHARD_SUGGESTION=${candidate[${#BUFFER}+1,-1]}
      POSTDISPLAY=$_ZSHARD_SUGGESTION
      _ZSHARD_POSTDISPLAY=$POSTDISPLAY
      region_highlight+=("${#BUFFER} $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=242 memo=zshard")
      break
    fi
  done
  return 0
}

_zshard_forward() {
  if [[ $CURSOR -eq ${#BUFFER} && -n $_ZSHARD_SUGGESTION ]]; then
    BUFFER+=$_ZSHARD_SUGGESTION
    CURSOR=${#BUFFER}
    POSTDISPLAY='' _ZSHARD_POSTDISPLAY='' _ZSHARD_SUGGESTION=''
  else zle .forward-char
  fi
}

_zshard_line_finish() {
  [[ $POSTDISPLAY == $_ZSHARD_POSTDISPLAY ]] && POSTDISPLAY=''
  _ZSHARD_POSTDISPLAY='' _ZSHARD_SUGGESTION=''
  region_highlight=("${(@)region_highlight:#*memo=zshard}")
  return 0
}

_zshard_interactive_init() {
  zmodload zsh/parameter
  zmodload zsh/datetime
  zmodload -F zsh/files b:zf_mkdir b:zf_chmod
  autoload -Uz add-zsh-hook add-zle-hook-widget
  typeset -gU fpath
  fpath=("$ZSHARD_HOME/completions" "${fpath[@]}")
  setopt auto_cd auto_pushd pushd_ignore_dups interactive_comments
  setopt hist_ignore_space hist_reduce_blanks share_history extended_history hist_expire_dups_first hist_find_no_dups hist_save_no_dups
  setopt prompt_percent
  unsetopt prompt_subst
  HISTSIZE=${HISTSIZE:-10000}
  (( HISTSIZE < 1000 )) && HISTSIZE=10000
  SAVEHIST=${SAVEHIST:-10000}
  (( SAVEHIST < 1000 )) && SAVEHIST=10000
  local map
  local state=${XDG_STATE_HOME:-$HOME/.local/state}/zshard
  if [[ -z ${HISTFILE-} && ! -L $state ]]; then
    if [[ -d $state && -O $state ]] || zf_mkdir -p -m 700 -- "$state"; then
      [[ -O $state && ! -L $state ]] && HISTFILE=$state/history
    fi
  fi
  _zshard_git_location
  add-zsh-hook chpwd _zshard_git_location
  add-zsh-hook preexec _zshard_preexec
  add-zsh-hook precmd _zshard_precmd
  zstyle ':completion:*' menu select
  zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
  zstyle ':completion:*' list-colors ''
  zstyle ':completion:*' group-name ''
  zstyle ':completion:*:descriptions' format '%F{blue}%d%f'
  [[ ${ZSHARD_KEYMAP:-emacs} == vi ]] && bindkey -v || bindkey -e
  KEYTIMEOUT=${KEYTIMEOUT:-20}
  zle -N zshard-forward _zshard_forward
  for map in emacs viins; do
    bindkey -M "$map" '^[[C' zshard-forward
    bindkey -M "$map" '^F' zshard-forward
    bindkey -M "$map" '^[[A' history-beginning-search-backward
    bindkey -M "$map" '^[[B' history-beginning-search-forward
  done
  add-zle-hook-widget line-pre-redraw _zshard_redraw
  add-zle-hook-widget line-finish _zshard_line_finish
  add-zle-hook-widget line-init _zshard_run_deferred
  case ${ZSHARD_COMPLETION:-lazy} in
    lazy)
      zle -N zshard-complete _zshard_complete
      bindkey -M emacs '^I' zshard-complete
      bindkey -M viins '^I' zshard-complete
      ;;
    eager) _zshard_completion_init;;
    off) ;;
    *) _zshard_error 'ZSHARD_COMPLETION must be lazy, eager, or off'; return 2;;
  esac
  return 0
}
