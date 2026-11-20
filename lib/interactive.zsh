typeset -gi _ZSHARD_LAST_EXIT=0 _ZSHARD_STARTED=0 _ZSHARD_COMPLETION_READY=0
typeset -g _ZSHARD_GIT_DIR='' _ZSHARD_GIT_ROOT='' _ZSHARD_BRANCH='' _ZSHARD_POSTDISPLAY='' _ZSHARD_SUGGESTION=''
typeset -g _ZSHARD_HISTORY_BUFFER='' _ZSHARD_HISTORY_SUFFIX='' _ZSHARD_HISTORY_LIMIT=''
typeset -gi _ZSHARD_HISTORY_EVENT=-1

# Shared prompt, editor and completion colors; zsh supports names, indices and RGB.
typeset -g ZSHARD_COLOR_PATH="${ZSHARD_COLOR_PATH:-#e8ded2}"
typeset -g ZSHARD_COLOR_ACCENT="${ZSHARD_COLOR_ACCENT:-#d4a373}"
typeset -g ZSHARD_COLOR_MUTED="${ZSHARD_COLOR_MUTED:-#a3978b}"
typeset -g ZSHARD_COLOR_ERROR="${ZSHARD_COLOR_ERROR:-#e59a91}"
typeset -g ZSHARD_COLOR_COMMAND="${ZSHARD_COLOR_COMMAND:-#e8ded2}"
typeset -g ZSHARD_COLOR_KEYWORD="${ZSHARD_COLOR_KEYWORD:-#c5a4b6}"
typeset -g ZSHARD_COLOR_SUGGESTION="${ZSHARD_COLOR_SUGGESTION:-#a3978b}"
typeset -g ZSHARD_COLOR_COMPLETION="${ZSHARD_COLOR_COMPLETION:-#d4a373}"

_zshard_git_location() {
  emulate -L zsh
  local dir=$PWD line target
  _ZSHARD_GIT_DIR='' _ZSHARD_GIT_ROOT=''
  while true; do
    if [[ -d $dir/.git ]]; then _ZSHARD_GIT_DIR=$dir/.git; _ZSHARD_GIT_ROOT=$dir; break; fi
    if [[ -f $dir/.git ]]; then
      IFS= read -r line < "$dir/.git"
      if [[ $line == 'gitdir: '* ]]; then
        target=${line#gitdir: }
        [[ $target == /* ]] || target=$dir/$target
        if [[ -d $target ]]; then
          _ZSHARD_GIT_DIR=${target:A}
          _ZSHARD_GIT_ROOT=$dir
        fi
      fi
      break
    fi
    [[ $dir == / ]] && break
    dir=${dir:h}
  done
}

_zshard_git_refresh() {
  # Keep the common repository path bounded. A new .git in this directory or a
  # removed checkout invalidates the location; outside Git, look for new parents.
  if [[ -z $_ZSHARD_GIT_DIR || ! -f $_ZSHARD_GIT_DIR/HEAD ||
        ! -e $_ZSHARD_GIT_ROOT/.git ||
        ( $PWD != $_ZSHARD_GIT_ROOT && -e $PWD/.git ) ]]; then
    _zshard_git_location
  fi
  _zshard_git_branch
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
  local branch='' result='' elapsed='' begin='' end='' indicator='❯'
  integer seconds=0
  (( _ZSHARD_STARTED )) && seconds=$(( EPOCHSECONDS - _ZSHARD_STARTED ))
  _ZSHARD_STARTED=0
  if [[ ${ZSHARD_PROMPT:-minimal} != off ]]; then
    _zshard_git_refresh
    if [[ ${ZSHARD_SHELL_INTEGRATION:-0} == 1 && -t 1 ]]; then
      print -rn -- $'\e]133;D;'"$last"$'\a'
      _zshard_uri_path
      print -rn -- $'\e]7;file://localhost'"$REPLY"$'\a'
      begin=$'%{\e]133;A\a%}'
      end=$'%{\e]133;B\a%}'
    fi
    # A custom callback owns its layout. Avoid formatting a discarded prompt.
    if [[ -z ${ZSHARD_PROMPT_FUNCTION-} ]] || (( ! $+functions[$ZSHARD_PROMPT_FUNCTION] )); then
      [[ -n $_ZSHARD_BRANCH ]] && branch="  %F{${ZSHARD_COLOR_ACCENT}}$_ZSHARD_BRANCH%f"
      (( last )) && result="  %F{${ZSHARD_COLOR_ERROR}}!$last%f"
      (( seconds >= 2 )) && elapsed="  %F{${ZSHARD_COLOR_MUTED}}${seconds}s%f"
      (( EUID == 0 )) && indicator='#'
      PROMPT="${begin}%F{${ZSHARD_COLOR_PATH}}%1~%f$branch$result$elapsed"$'\n'"%F{${ZSHARD_COLOR_ACCENT}}${indicator}%f ${end}"
      RPROMPT=''
    fi
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

_zshard_cache_compdump() {
  emulate -L zsh
  # compinit dynamically shares its audited candidate list with compaudit.
  # compdump recomputes a different count for rejected paths, symlinks and
  # private groups. Preserve compinit's count so its next audit can reuse it.
  local -i candidate_count=$#_i_files created=0
  local dump=$_comp_dumpfile header content temporary
  local -A previous fresh
  zstat -H previous -- "$dump" 2>/dev/null
  _zshard_original_compdump "$@" || return
  [[ ${parameters[_i_files]-} == *array* && $dump == "$_comp_dumpfile" &&
     -f $dump && -O $dump && ! -L $dump ]] || return 0
  zstat -H fresh -- "$dump" 2>/dev/null || return
  # Native compdump atomically replaces its output; leave custom/no-op dumps.
  [[ ${previous[inode]-} == "$fresh[inode]" &&
     ${previous[device]-} == "$fresh[device]" ]] && return 0
  zf_chmod 600 "$dump" || return
  _zshard_cache_usable "$dump" || return
  IFS= read -r header < "$dump" || return
  local expected="#files: $candidate_count"$'\t'"version: $ZSH_VERSION"
  [[ $header == '#files: '*$'\tversion: '"$ZSH_VERSION" ]] || return 0
  content=$(<"$dump")
  [[ $content == *$'\n'* ]] || return 1
  temporary=$dump.zshard.$$.$RANDOM
  zmodload -F zsh/files b:zf_mv b:zf_rm || return
  {
    setopt noclobber
    { created=1; print -rl -- "$expected" "# zshard-audit: $_zshard_audit_record"
      print -r -- "${content#*$'\n'}"
    } > "$temporary" || return
    zf_chmod 600 "$temporary" || return
    zf_mv -f -- "$temporary" "$dump"
  } always {
    (( created )) && [[ -e $temporary ]] && zf_rm -f -- "$temporary"
  }
}

_zshard_cache_compaudit() {
  emulate -L zsh
  _zshard_original_compaudit "$@"
  local -i audit_status=$?
  local directory relative_base='' stored
  for directory in "$fpath[@]"; do
    [[ $directory != /* && $directory != . ]] && relative_base=$PWD
  done
  # A count alone misses renames and ownership changes with equal file totals.
  # Observe native audit inputs and exclusions; never evaluate this metadata.
  printf -v _zshard_audit_record '%q ' v1 "$ZSH_VERSION" "$relative_base" \
    "$#fpath" "$fpath[@]" "$#_i_files" "$_i_files[@]" \
    "$#_i_wdirs" "$_i_wdirs[@]" "$#_i_wfiles" "$_i_wfiles[@]"
  if [[ $_zshard_audit_record == *$'\n'* || $_zshard_audit_record == *$'\r'* ]]; then
    _comp_dumpfile=/dev/null _i_autodump=0
    return $audit_status
  fi
  if [[ -r $_zshard_cache_target ]]; then
    # zsh's $(<file) reads in blocks; read -r scans a long signature bytewise.
    stored=$(<"$_zshard_cache_target")
    stored=${${stored#*$'\n'}%%$'\n'*}
  fi
  if [[ $stored != "# zshard-audit: $_zshard_audit_record" ]]; then
    # A fresh path forces ordinary audited compinit to rebuild. The old cache
    # stays intact until its complete replacement (metadata included) is ready.
    _zshard_cache_staging=$_zshard_cache_target.zshard.$$.$RANDOM
    while [[ -e $_zshard_cache_staging || -L $_zshard_cache_staging ||
             -e $_zshard_cache_staging.zwc || -L $_zshard_cache_staging.zwc ]]; do
      _zshard_cache_staging=$_zshard_cache_target.zshard.$$.$RANDOM
    done
    _comp_dumpfile=$_zshard_cache_staging
  fi
  return $audit_status
}

_zshard_audited_compinit() {
  emulate -L zsh
  local -i completion_status=1
  local _zshard_cache_target=$1 _zshard_cache_staging='' _zshard_audit_record=''
  local cache_record
  autoload -RUz compinit compdump compaudit
  functions -c compdump _zshard_original_compdump || return
  functions -c compaudit _zshard_original_compaudit || {
    unfunction _zshard_original_compdump
    return 1
  }
  functions[compdump]=$functions[_zshard_cache_compdump]
  functions[compaudit]=$functions[_zshard_cache_compaudit]
  zmodload -F zsh/files b:zf_mv b:zf_rm
  {
    # Keep the native audit and invalidation checks on every warm load.
    compinit -i -d "$1"
    completion_status=$?
    if (( completion_status == 0 )) && [[ -n $_zshard_cache_staging ]]; then
      if [[ -f $_zshard_cache_staging ]] && _zshard_cache_usable "$_zshard_cache_staging"; then
        cache_record=$(<"$_zshard_cache_staging")
        cache_record=${${cache_record#*$'\n'}%%$'\n'*}
        if [[ $cache_record == "# zshard-audit: $_zshard_audit_record" ]]; then
          # A stale compiled dump must not override the newly audited source.
          zf_rm -f -- "$_zshard_cache_target.zwc" &&
            zf_mv -f -- "$_zshard_cache_staging" "$_zshard_cache_target"
          completion_status=$?
        else
          completion_status=1
        fi
      else
        completion_status=1
      fi
    fi
  } always {
    if [[ -n $_zshard_cache_staging && -f $_zshard_cache_staging &&
          -O $_zshard_cache_staging && ! -L $_zshard_cache_staging ]]; then
      zf_rm -f -- "$_zshard_cache_staging"
    fi
    _comp_dumpfile=$_zshard_cache_target
    unfunction compdump compaudit 2>/dev/null
    functions -c _zshard_original_compdump compdump
    functions -c _zshard_original_compaudit compaudit
    unfunction _zshard_original_compdump _zshard_original_compaudit
  }
  return $completion_status
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
      _zshard_audited_compinit "$cache/zcompdump-$ZSH_VERSION" || return
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
      [[ -x $command_word && ! -d $command_word ]]; then color=$ZSHARD_COLOR_COMMAND
    elif [[ $command_word == (if|then|else|elif|fi|for|while|until|do|done|case|esac|function|select|repeat|time|coproc|foreach|end) ]]; then color=$ZSHARD_COLOR_KEYWORD
    elif [[ $command_word == *[\$\`\\\"\'=]* ]]; then color=default
    else color=$ZSHARD_COLOR_ERROR
    fi
    region_highlight+=("$start $end fg=$color memo=zshard")
  fi
  if [[ ${ZSHARD_SUGGESTIONS:-1} != 1 || -z $BUFFER || -n $POSTDISPLAY ||
        ${#BUFFER} -gt 400 || $CURSOR -ne ${#BUFFER} || $BUFFER == *$'\n'* ]]; then return 0; fi
  # ZLE can redraw an unchanged buffer more than once. Cache both hits and
  # misses; a different input, history event or scan limit recomputes the result.
  if [[ $BUFFER == $_ZSHARD_HISTORY_BUFFER &&
        $HISTCMD == $_ZSHARD_HISTORY_EVENT &&
        ${ZSHARD_HISTORY_SCAN:-200} == $_ZSHARD_HISTORY_LIMIT ]]; then
    _ZSHARD_SUGGESTION=$_ZSHARD_HISTORY_SUFFIX
  else
    event=$HISTCMD
    while (( event > 0 && tries < ${ZSHARD_HISTORY_SCAN:-200} )); do
      (( --event, ++tries ))
      candidate=${history[$event]-}
      if [[ $candidate == "$BUFFER"* && $candidate != "$BUFFER" && $candidate != *$'\n'* ]]; then
        _ZSHARD_SUGGESTION=${candidate[${#BUFFER}+1,-1]}
        break
      fi
    done
    _ZSHARD_HISTORY_BUFFER=$BUFFER
    _ZSHARD_HISTORY_EVENT=$HISTCMD
    _ZSHARD_HISTORY_LIMIT=${ZSHARD_HISTORY_SCAN:-200}
    _ZSHARD_HISTORY_SUFFIX=$_ZSHARD_SUGGESTION
  fi
  if [[ -n $_ZSHARD_SUGGESTION ]]; then
    POSTDISPLAY=$_ZSHARD_SUGGESTION
    _ZSHARD_POSTDISPLAY=$POSTDISPLAY
    region_highlight+=("${#BUFFER} $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=$ZSHARD_COLOR_SUGGESTION memo=zshard")
  fi
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
  _ZSHARD_HISTORY_BUFFER='' _ZSHARD_HISTORY_SUFFIX='' _ZSHARD_HISTORY_EVENT=-1
  region_highlight=("${(@)region_highlight:#*memo=zshard}")
  return 0
}

_zshard_interactive_init() {
  zmodload zsh/parameter
  zmodload zsh/datetime
  zmodload -F zsh/files b:zf_mkdir b:zf_chmod
  autoload -Uz add-zsh-hook add-zle-hook-widget
  typeset -gU fpath
  # Existing fpath entries express user and suite completion precedence.
  fpath+=("$ZSHARD_HOME/completions")
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
  zstyle ':completion:*:descriptions' format "%F{$ZSHARD_COLOR_COMPLETION}%d%f"
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
