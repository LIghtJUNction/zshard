_zshard_plugin_name() {
  emulate -L zsh
  setopt extendedglob
  [[ $1 == [A-Za-z0-9][A-Za-z0-9_-]# ]] && (( ${#1} <= 80 ))
}

_zshard_plugin_entry() {
  emulate -L zsh
  local name=$1 sha url entry extra
  _zshard_plugin_name "$name" || { _zshard_error 'invalid plugin name'; return 2; }
  local root=${ZSHARD_PLUGIN_DIR:A}
  [[ ! -L $ZSHARD_PLUGIN_DIR && -d $root && -O $root ]] || { _zshard_error 'plugin directory must be owned and not a symlink'; return 1; }
  [[ -f $root/$name.lock && ! -L $root/$name.lock ]] || { _zshard_error "plugin not installed: $name"; return 1; }
  IFS=$'\t' read -r sha url entry extra < "$root/$name.lock"
  [[ -n $sha && -n $url && -n $entry && -z $extra ]] || { _zshard_error "invalid lock: $name"; return 1; }
  local entry_file=$root/$name/$entry
  [[ -d $root/$name && ! -L $root/$name && ${entry_file:A} == $root/$name/* && -f $entry_file ]] ||
    { _zshard_error "entry escapes checkout or is missing: $name"; return 1; }
  REPLY=${entry_file:A}
}

_zshard_plugin() {
  emulate -L zsh
  setopt extendedglob no_unset
  local action=${1:-list}; (( $# )) && shift
  local root=$ZSHARD_PLUGIN_DIR name=${1-} sha url entry actual lock extra tmp
  case $action in
    list)
      [[ -d $root && ! -L $root ]] || return 0
      for lock in "$root"/*.lock(N); do
        IFS=$'\t' read -r sha url entry extra < "$lock"
        print -r -- "${lock:t:r}"$'\t'"$sha"$'\t'"$entry"
      done
      ;;
    export)
      (( $# == 0 )) || { _zshard_error 'plugin export takes no arguments'; return 2; }
      print -r -- '# zshard.plugins.v1'
      [[ -d $root && ! -L $root ]] || return 0
      for lock in "$root"/*.lock(N); do
        IFS=$'\t' read -r sha url entry extra < "$lock"
        print -r -- "${lock:t:r}"$'\t'"$sha"$'\t'"$url"$'\t'"$entry"
      done
      ;;
    restore)
      (( $# == 1 )) && [[ -f $1 ]] || { _zshard_error 'plugin restore requires a lock file'; return 2; }
      local header row name_from_file
      local -a records=()
      local -A seen=()
      {
        IFS= read -r header
        [[ $header == '# zshard.plugins.v1' ]] || { _zshard_error 'unsupported plugin lock format'; return 2; }
        while IFS= read -r row || [[ -n $row ]]; do
          [[ -z $row ]] && continue
          IFS=$'\t' read -r name_from_file sha url entry extra <<< "$row"
          _zshard_plugin_name "$name_from_file" && [[ $sha == [0-9a-f](#c40) && -n $url && -n $entry && -z $extra ]] ||
            { _zshard_error 'invalid plugin lock record'; return 2; }
          [[ -z ${seen[$name_from_file]-} ]] || { _zshard_error 'duplicate plugin lock record'; return 2; }
          seen[$name_from_file]=1
          records+=("$row")
        done
      } < "$1"
      for row in "${records[@]}"; do
        IFS=$'\t' read -r name_from_file sha url entry extra <<< "$row"
        if [[ -e $root/$name_from_file.lock ]]; then
          local saved
          IFS= read -r saved < "$root/$name_from_file.lock"
          [[ $saved == "$sha"$'\t'"$url"$'\t'"$entry" ]] ||
            { _zshard_error "installed pin differs: $name_from_file"; return 1; }
          _zshard_plugin verify "$name_from_file" || return
        else
          _zshard_plugin add "$name_from_file" "$url" "$sha" "$entry" || return
        fi
      done
      ;;
    add)
      (( $# == 4 )) || { _zshard_error 'plugin add requires NAME URL FULL_COMMIT_SHA ENTRY_FILE'; return 2; }
      name=$1; url=$2; sha=${(L)3}; entry=$4
      _zshard_plugin_name "$name" || { _zshard_error 'invalid plugin name'; return 2; }
      [[ $sha == [0-9a-f](#c40) ]] || { _zshard_error 'a full 40-character commit SHA is required'; return 2; }
      [[ $url == https://* || $url == ssh://* || $url == git@*:* ]] ||
        { _zshard_error 'use an HTTPS or SSH repository URL'; return 2; }
      [[ $url != *[$'\n\r\t']* && $entry != /* && -n $entry && $entry != *[$'\n\r\t']* &&
         /$entry/ != */../* && /$entry/ != */./* ]] ||
        { _zshard_error 'invalid URL or relative entry path'; return 2; }
      (( $+commands[git] )) || { _zshard_error 'Git is needed to install plugins'; return 127; }
      [[ ! -L $root ]] || { _zshard_error 'plugin directory cannot be a symlink'; return 1; }
      if [[ ! -d $root ]]; then
        (umask 077; command mkdir -p -- "$root") || return
      fi
      [[ -O $root ]] || { _zshard_error 'plugin directory must be owned by you'; return 1; }
      root=${root:A}
      [[ ! -e $root/$name && ! -L $root/$name && ! -e $root/$name.lock ]] ||
        { _zshard_error "plugin already exists; use remove before changing its pin: $name"; return 1; }
      tmp=$root/.install-$name-$$-$RANDOM
      (umask 077; command mkdir -- "$tmp") || return
      {
        command git -c protocol.file.allow=never -c core.hooksPath=/dev/null clone --quiet --filter=blob:none --no-checkout -- "$url" "$tmp/repo" || return
        command git -C "$tmp/repo" -c protocol.file.allow=never -c core.hooksPath=/dev/null fetch --quiet origin "$sha" || return
        actual=$(command git -C "$tmp/repo" rev-parse --verify "$sha^{commit}") || return
        [[ $actual == $sha ]] || { _zshard_error 'resolved commit does not match pin'; return 1; }
        command git -C "$tmp/repo" -c core.hooksPath=/dev/null checkout --quiet --detach "$sha" || return
        [[ -f $tmp/repo/$entry && ${${:-$tmp/repo/$entry}:A} == $tmp/repo/* ]] ||
          { _zshard_error 'entry must be a regular file within the checkout'; return 1; }
        print -r -- "$sha"$'\t'"$url"$'\t'"$entry" > "$tmp/lock"
        command mv -- "$tmp/repo" "$root/$name" || return
        command mv -- "$tmp/lock" "$root/$name.lock" || return
        print -r -- "Installed $name at $sha. Load explicitly with: zshard use $name"
      } always {
        command rm -rf -- "$tmp"
      }
      ;;
    verify)
      (( $# == 1 )) || { _zshard_error 'plugin verify requires NAME'; return 2; }
      _zshard_plugin_entry "$name" || return
      IFS=$'\t' read -r sha url entry extra < "$root/$name.lock"
      actual=$(command git -C "$root/$name" rev-parse --verify HEAD) || return
      [[ $actual == $sha ]] || { _zshard_error "HEAD differs from lock: $name"; return 1; }
      [[ -z $(command git -C "$root/$name" status --porcelain --untracked-files=all) ]] ||
        { _zshard_error "checkout has changes: $name"; return 1; }
      print -r -- "$name: pinned checkout is clean ($sha)"
      ;;
    remove)
      (( $# == 1 )) || { _zshard_error 'plugin remove requires NAME'; return 2; }
      _zshard_plugin_entry "$name" || return
      root=${root:A}
      command rm -rf -- "$root/$name" && command rm -f -- "$root/$name.lock"
      ;;
    *) _zshard_error "unknown plugin command: $action"; return 2;;
  esac
}
