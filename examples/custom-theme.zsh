# This callback receives last exit status and elapsed whole seconds.
my_compact_prompt() {
  local exit_code=$1 seconds=$2
  PROMPT='%F{blue}%1~%f %# '
  (( exit_code )) && PROMPT="%F{red}!$exit_code%f $PROMPT"
  RPROMPT=''
}
zshard theme my_compact_prompt
