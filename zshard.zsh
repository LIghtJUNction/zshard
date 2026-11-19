# zshard: the shell owns the hot path.
[[ -n ${ZSH_VERSION-} ]] || return 1
[[ -n ${_ZSHARD_LOADED-} ]] && return 0
typeset -g ZSHARD_HOME=${ZSHARD_HOME:-${${(%):-%N}:A:h}}
typeset -g ZSHARD_VERSION=0.1.0
typeset -g _ZSHARD_LOADED=1
source "$ZSHARD_HOME/lib/core.zsh" || { unset _ZSHARD_LOADED; return 1; }
source "$ZSHARD_HOME/lib/plugins.zsh" || { unset _ZSHARD_LOADED; return 1; }
source "$ZSHARD_HOME/lib/ai.zsh" || { unset _ZSHARD_LOADED; return 1; }
if [[ -o interactive ]]; then
  source "$ZSHARD_HOME/lib/interactive.zsh"
  _zshard_interactive_init
fi
