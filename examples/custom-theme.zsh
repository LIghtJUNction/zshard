# This callback receives last exit status and elapsed whole seconds.
my_compact_prompt() {
  local exit_code=$1 seconds=$2
  PROMPT="%F{$ZSHARD_COLOR_PATH}%1~%f %F{$ZSHARD_COLOR_ACCENT}%#%f "
  (( exit_code )) && PROMPT="%F{$ZSHARD_COLOR_ERROR}!$exit_code%f $PROMPT"
  RPROMPT=''
}
zshard theme my_compact_prompt
