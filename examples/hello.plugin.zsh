# A complete plugin: command, shell hook, and explicit cleanup.
hello() { print -r -- "Hello from a zshard plugin: $*"; }
_zshard_hello_precmd() { typeset -g ZSHARD_HELLO_VISITS=$(( ${ZSHARD_HELLO_VISITS:-0} + 1 )); }
zshard hook precmd _zshard_hello_precmd
zshard_plugin_hello_unload() {
  zshard unhook precmd _zshard_hello_precmd
  unfunction hello _zshard_hello_precmd zshard_plugin_hello_unload
  unset ZSHARD_HELLO_VISITS
}
