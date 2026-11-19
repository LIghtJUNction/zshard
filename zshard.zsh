# zshard: the shell owns the hot path.
[[ -n ${ZSH_VERSION-} ]] || return 1
[[ -n ${_ZSHARD_LOADED-} ]] && return 0
typeset -g ZSHARD_HOME=${ZSHARD_HOME:-${${(%):-%N}:A:h}}
typeset -g ZSHARD_VERSION=0.1.3
typeset -g _ZSHARD_LOADED=1
source "$ZSHARD_HOME/lib/core.zsh" || { unset _ZSHARD_LOADED; return 1; }
_zshard_ensure_plugins() {
  [[ -n ${_ZSHARD_PLUGIN_RUNTIME_LOADED-} ]] && return 0
  source "$ZSHARD_HOME/lib/plugins.zsh" || return
  typeset -g _ZSHARD_PLUGIN_RUNTIME_LOADED=1
}
zai() {
  source "$ZSHARD_HOME/lib/ai.zsh" || return
  zai "$@"
}
if [[ -o interactive ]]; then
  source "$ZSHARD_HOME/lib/interactive.zsh" || { unset _ZSHARD_LOADED; return 1; }
  _zshard_interactive_init
fi
