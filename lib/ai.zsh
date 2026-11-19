_zshard_json_string() {
  emulate -L zsh
  local value=$1 char
  integer i n
  print -rn -- '"'
  for (( i=1; i<=${#value}; ++i )); do
    char=$value[i]
    case $char in
      '"') print -rn -- '\"';;
      '\') print -rn -- '\\';;
      $'\n') print -rn -- '\n';;
      $'\r') print -rn -- '\r';;
      $'\t') print -rn -- '\t';;
      *)
        printf -v n '%d' "'$char"
        if (( n < 32 )); then printf '\\u%04x' "$n"
        else print -rn -- "$char"
        fi;;
    esac
  done
  print -rn -- '"'
}

zai() {
  emulate -L zsh
  local action=${1:-help}; (( $# )) && shift
  case $action in
    context)
      (( $# == 0 )) || { _zshard_error 'zai context takes no arguments'; return 2; }
      print -rn -- '{"schema":"zshard.context.v1","cwd":'
      _zshard_json_string "$PWD"
      print -rn -- ',"shell":"zsh","shell_version":'
      _zshard_json_string "$ZSH_VERSION"
      print -r -- ',"last_exit":'"${_ZSHARD_LAST_EXIT:-0}"',"capabilities":["context","stage-command","ssmcp"],"history_included":false,"environment_included":false}'
      ;;
    connect)
      (( $+commands[ssmcp] )) || { _zshard_error 'ssmcp is not installed; install the Project Z companion first'; return 127; }
      command ssmcp "$@"
      ;;
    ask)
      (( $# )) || { _zshard_error 'zai ask requires a request'; return 2; }
      (( ${+ZSHARD_AI_COMMAND} && ${#ZSHARD_AI_COMMAND} )) ||
        { _zshard_error 'configure ZSHARD_AI_COMMAND=(provider-cli arguments...) to opt into a provider'; return 2; }
      [[ ${(t)ZSHARD_AI_COMMAND} == *array* ]] || { _zshard_error 'ZSHARD_AI_COMMAND must be an array, never an evaluated command string'; return 2; }
      { zai context; print -r -- "$*"; } | command "${ZSHARD_AI_COMMAND[@]}"
      ;;
    propose)
      (( $# == 1 )) || { _zshard_error 'zai propose requires one quoted command'; return 2; }
      [[ -o interactive && -t 0 ]] || { _zshard_error 'proposals need an interactive terminal'; return 2; }
      [[ -n $1 && $1 != *[[:cntrl:]]* ]] && (( ${#1} <= 8192 )) ||
        { _zshard_error 'proposal must be one printable line (up to 8192 characters)'; return 2; }
      print -z -- "$1"
      print -r -- 'Command staged. Review it, then press Enter to run.'
      ;;
    help|--help|-h)
      print -r -- 'zai context              Print explicit, local JSON context (no history or environment)
zai connect [SSMCP_ARGS]  Start ssmcp in this working directory
zai ask REQUEST          Send context and request to your opt-in provider argv
zai propose COMMAND      Put one command in the editing buffer; never execute it'
      ;;
    *) _zshard_error "unknown AI command: $action"; return 2;;
  esac
}
