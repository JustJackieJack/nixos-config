# claude-share: general, root-owned mechanism to temporarily expose files from one configured
# account to another - e.g. game_user's files (/mnt/games) to claude. See the top of
# sharing.nix for the full design rationale (bind mount vs ACL, why root sets the ACL).
#
# This file is plain bash with NO Nix syntax. Two things are supplied by sharing.nix before
# this text runs:
#   - the functions source_info() and target_ok(), generated from the `sourceAccounts` and
#     `allowedTargets` Nix values (prepended to this file's content when building the package)
#   - the environment variables CLAUDE_SHARE_BASE / CLAUDE_SHARE_FORCLIENT / CLAUDE_SHARE_MAPPING
#     (the three paths read into base/forclient/mapping below)

base="$CLAUDE_SHARE_BASE"
forclient="$CLAUDE_SHARE_FORCLIENT"
mapping="$CLAUDE_SHARE_MAPPING"
staging="/run/claude-share-staging" # private spot to verify before moving into $base

# Creates (if needed) the given target account's subdirectory under $1, ACL'd to it only.
# Base mode is 0700 (no group/other bits at all) - access comes PURELY from named-user ACL
# entries below, never from Unix group bits. Using "-g shared" here once leaked read+traverse to
# the WHOLE "shared" group (Jacek+claude), not just the intended target - caught when secure_user
# was added as a target and claude could read what was shared to secure_user. Jacek ALSO needs his
# own named ACL entry (not just membership in "shared") so claude-revoke - which lists this
# directory as Jacek, before the actual removal happens via sudo as root - can still find what to
# remove; relying on "shared" group membership for this would re-leak access to every OTHER
# "shared" member (claude) too.
prepare_target_dir() {
  local base_dir="$1" target_user="$2" target_dir
  target_dir="$base_dir/$target_user"
  if [ ! -d "$target_dir" ]; then
    install -d -m 0700 -o root -g root -- "$target_dir"
    setfacl -m "u:Jacek:rx,u:$target_user:rx" -- "$target_dir"
    setfacl -d -m "u:Jacek:rx,u:$target_user:rx" -- "$target_dir"
  fi
  echo "$target_dir"
}

unmount_and_clear() {
  local target_path="$1" target_user="$2" mapping_file
  mapping_file="$mapping/$(basename -- "$target_path").src"
  if [ -f "$mapping_file" ]; then
    setfacl -x "u:$target_user" -- "$(cat -- "$mapping_file")" 2>/dev/null || true
    rm -f -- "$mapping_file"
  fi
  case "$target_path" in
    "$base"/*/*) ;;
    *) echo "bad path: $target_path" >&2; return 1 ;;
  esac
  umount -- "$target_path" 2>/dev/null || true
  if [ -d "$target_path" ]; then
    rmdir -- "$target_path"
  elif [ -e "$target_path" ]; then
    rm -f -- "$target_path"
  fi
}

case "${1:-}" in
  add)
    [ "$#" -ge 5 ] || {
      echo "usage: claude-share add view|edit|copy SOURCE_USER TARGET_USER PATH [DURATION]" >&2
      exit 2
    }
    mode="$2"; source_user="$3"; target_user="$4"; source_path="$5"; duration="${6:-}"
    case "$mode" in view | edit | copy) ;; *) echo "bad mode: $mode (view|edit|copy)" >&2; exit 2 ;; esac
    target_ok "$target_user" || { echo "unknown target account: $target_user" >&2; exit 2; }
    [ "$source_user" != "$target_user" ] || { echo "source and target must differ" >&2; exit 2; }
    if [ "$mode" != copy ]; then
      [ -n "$duration" ] || { echo "duration is required for mode $mode" >&2; exit 2; }
      systemd-analyze timespan "$duration" > /dev/null 2>&1 || { echo "bad duration: $duration" >&2; exit 2; }
    fi
    source_info "$source_user"

    # Resolve symlinks ONCE, up front - everything below operates on the real path
    # (protects against a symlink swapped in between this check and the mount/copy).
    p="$(realpath -e -- "$source_path")" || { echo "does not exist: $source_path" >&2; exit 1; }

    IFS=':' read -ra roots_arr <<< "$source_roots"
    in_roots=0
    for r in "${roots_arr[@]}"; do
      case "$p" in "$r" | "$r"/*) in_roots=1 ;; esac
    done
    [ "$in_roots" = 1 ] || { echo "outside the allowed directories of $source_user" >&2; exit 1; }
    [ "$(stat -c %u -- "$p")" = "$source_uid" ] || { echo "file does not belong to $source_user" >&2; exit 1; }

    if [ -n "$source_protected" ]; then
      IFS=':' read -ra protected_arr <<< "$source_protected"
      for rel in "${protected_arr[@]}"; do
        for r in "${roots_arr[@]}"; do
          c="$r/$rel"
          case "$p" in
            "$c" | "$c"/* | "$c"-*) echo "denied: $p is protected ($c)" >&2; exit 1 ;;
          esac
          case "$c" in
            "$p"/*) echo "denied: $p contains protected data ($c) - share a narrower path" >&2; exit 1 ;;
          esac
        done
      done
    fi

    install -d -m 2750 -o root -g shared -- "$base"
    install -d -m 2750 -o root -g shared -- "$forclient"
    name="$(basename -- "$p" | tr -c 'A-Za-z0-9._\n-' '_')"
    id="$(date +%Y%m%d-%H%M%S)-$$"

    if [ "$mode" = copy ]; then
      target_dir="$(prepare_target_dir "$forclient" "$target_user")"
      target_path="$target_dir/${name}_$id"
      cp -r --reflink=auto -- "$p" "$target_path"
      chmod -R u+rwX,g+rX,o-rwx -- "$target_path"
      setfacl -R -m "u:$target_user:rwX" -- "$target_path"
      echo "$target_path"
      exit 0
    fi

    if ! mountpoint -q "$staging" 2>/dev/null; then
      install -d -m 0700 "$staging"
      mount -t tmpfs -o mode=0700,size=1m tmpfs "$staging"
      mount --make-private "$staging"
    fi
    tmp="$staging/$id"
    if [ -d "$p" ]; then kind=d; mkdir -- "$tmp"; else kind=f; : > "$tmp"; fi
    opts="remount,bind,nosuid,nodev"
    [ "$mode" = view ] && opts="$opts,ro"
    mount --bind -- "$p" "$tmp"
    mount -o "$opts" -- "$tmp"

    # Verify what ACTUALLY got mounted (the path could have been swapped by e.g. a symlink
    # planted between the check above and this mount): ownership must still match.
    ok=1
    [ "$(stat -c %u -- "$tmp")" = "$source_uid" ] || ok=0
    if [ "$kind" = d ]; then [ -d "$tmp" ] || ok=0; else [ -f "$tmp" ] || ok=0; fi
    if [ "$ok" != 1 ]; then
      umount -- "$tmp"
      rm -rf -- "$tmp"
      echo "denied: the mounted object does not belong to $source_user" >&2
      exit 1
    fi

    target_dir="$(prepare_target_dir "$base" "$target_user")"
    target_path="$target_dir/${name}_$id"
    if [ "$kind" = d ]; then mkdir -- "$target_path"; else : > "$target_path"; fi
    mount --move -- "$tmp" "$target_path"
    if [ "$kind" = d ]; then rmdir -- "$tmp"; else rm -f -- "$tmp"; fi

    acl_mode="rX"; [ "$mode" = edit ] && acl_mode="rwX"
    setfacl -R -P -m "u:$target_user:$acl_mode" -- "$p"

    install -d -m 0700 "$mapping"
    echo "$p" > "$mapping/$(basename -- "$target_path").src"

    systemd-run --quiet --unit="claude-revoke-$id" --on-active="$duration" --timer-property=AccuracySec=1s \
      "$0" remove "$target_user" "$target_path"
    echo "$target_path"
    ;;
  remove)
    [ "$#" -ge 2 ] || { echo "usage: claude-share remove TARGET_USER [TARGET_PATH]" >&2; exit 2; }
    target_user="$2"
    target_ok "$target_user" || { echo "unknown target account: $target_user" >&2; exit 2; }
    if [ "$#" -ge 3 ]; then
      unmount_and_clear "$3" "$target_user"
    else
      for target_path in "$base/$target_user"/*; do
        [ -e "$target_path" ] && unmount_and_clear "$target_path" "$target_user"
      done
    fi
    ;;
  *)
    echo "usage: claude-share add view|edit|copy SOURCE_USER TARGET_USER PATH [DURATION] | remove TARGET_USER [TARGET_PATH]" >&2
    exit 2
    ;;
esac
