#!/usr/bin/env zsh
set -euo pipefail


HAVE_GUM=0
if command -v gum >/dev/null 2>&1; then
  HAVE_GUM=1
fi

usage() {
  cat <<'EOF'
Usage:
  jrestore.zsh -d DEST_ROOT -o OUTPUT_DIR [-s SNAPSHOT] [-p SUBPATH] [-n] [-v] [-l]

Required:
  -d DEST_ROOT      Backup root containing snapshots
                    Local example: /mnt/backups/laptop
                    Remote example: backup@server:/srv/backups/laptop
  -o OUTPUT_DIR     Restore destination on the local machine

Optional:
  -s SNAPSHOT       Snapshot name to restore (example: 2026-03-31_103000)
  -p SUBPATH        Restore only a subpath inside snapshot (example: Documents/project)
  -l                List snapshots and exit
  -n                Dry run
  -v                Verbose
  -h                Show help

Examples:
  jrestore.zsh -d /mnt/backups/macbook -l
  jrestore.zsh -d /mnt/backups/macbook -s 2026-03-31_103000 -o ~/restore
  jrestore.zsh -d backup@nas:/srv/backups/macbook -o ~/restore
  jrestore.zsh -d /mnt/backups/macbook -s 2026-03-31_103000 -p Documents -o ~/restore
EOF
}

info() {
  if (( HAVE_GUM )); then
    gum style --foreground 45 "▶ $*"
  else
    print -r -- "[*] $*"
  fi
}

success() {
  if (( HAVE_GUM )); then
    gum style --foreground 42 "✔ $*"
  else
    print -r -- "[+] $*"
  fi
}

warn() {
  if (( HAVE_GUM )); then
    gum style --foreground 214 "⚠ $*"
  else
    print -r -- "[!] $*"
  fi
}

die() {
  if (( HAVE_GUM )); then
    gum style --foreground 196 "✖ $*"
  else
    print -u2 -r -- "ERROR: $*"
  fi
  exit 1
}

is_remote_path() {
  [[ "$1" == *:* ]]
}

remote_host_from_path() {
  print -r -- "${1%%:*}"
}

remote_dir_from_path() {
  print -r -- "${1#*:}"
}

list_snapshots_local() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??????' -exec basename {} \; | sort
}

list_snapshots_remote() {
  local host="$1"
  local root="$2"
  ssh "$host" "find '$root' -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??????' -exec basename {} \; 2>/dev/null" | sort
}

choose_snapshot() {
  local -a snaps=("$@")
  (( ${#snaps[@]} > 0 )) || die "No snapshots found"

  if (( HAVE_GUM )); then
    printf '%s\n' "${snaps[@]}" | gum choose
  else
    print "Available snapshots:"
    local i=1
    local snap
    for snap in "${snaps[@]}"; do
      printf "  [%d] %s\n" "$i" "$snap"
      ((i++))
    done
    print -n "Select snapshot number: "
    read -r idx
    [[ "$idx" == <-> ]] || die "Invalid selection"
    (( idx >= 1 && idx <= ${#snaps[@]} )) || die "Out of range"
    print -r -- "${snaps[idx]}"
  fi
}

main() {
  local DEST_ROOT=""
  local OUTPUT_DIR=""
  local SNAPSHOT=""
  local SUBPATH=""
  local LIST_ONLY=0
  local DRY_RUN=0
  local VERBOSE=0

  while getopts ":d:o:s:p:lnvh" opt; do
    case "$opt" in
      d) DEST_ROOT="$OPTARG" ;;
      o) OUTPUT_DIR="$OPTARG" ;;
      s) SNAPSHOT="$OPTARG" ;;
      p) SUBPATH="$OPTARG" ;;
      l) LIST_ONLY=1 ;;
      n) DRY_RUN=1 ;;
      v) VERBOSE=1 ;;
      h) usage; exit 0 ;;
      :) die "Option -$OPTARG requires an argument" ;;
      \?) die "Unknown option: -$OPTARG" ;;
    esac
  done

  [[ -n "$DEST_ROOT" ]] || die "Missing -d DEST_ROOT"

  local -a snaps
  if is_remote_path "$DEST_ROOT"; then
    local host root
    host="$(remote_host_from_path "$DEST_ROOT")"
    root="$(remote_dir_from_path "$DEST_ROOT")"
    snaps=("${(@f)$(list_snapshots_remote "$host" "$root")}")
  else
    DEST_ROOT="${DEST_ROOT:A}"
    snaps=("${(@f)$(list_snapshots_local "$DEST_ROOT")}")
  fi

  if (( LIST_ONLY )); then
    (( ${#snaps[@]} > 0 )) || die "No snapshots found"
    printf '%s\n' "${snaps[@]}"
    exit 0
  fi

  [[ -n "$OUTPUT_DIR" ]] || die "Missing -o OUTPUT_DIR"

  if [[ -z "$SNAPSHOT" ]]; then
    SNAPSHOT="$(choose_snapshot "${snaps[@]}")"
  fi

  mkdir -p "$OUTPUT_DIR"
  OUTPUT_DIR="${OUTPUT_DIR:A}"

  local source_path
  if is_remote_path "$DEST_ROOT"; then
    local host root
    host="$(remote_host_from_path "$DEST_ROOT")"
    root="$(remote_dir_from_path "$DEST_ROOT")"
    source_path="$host:$root/$SNAPSHOT"
  else
    source_path="$DEST_ROOT/$SNAPSHOT"
  fi

  if [[ -n "$SUBPATH" ]]; then
    SUBPATH="${SUBPATH#/}"
    source_path="${source_path%/}/$SUBPATH"
  fi

  local -a rsync_opts
  rsync_opts=(-aH --human-readable --info=progress2)
  (( VERBOSE )) && rsync_opts+=(-v)
  (( DRY_RUN )) && rsync_opts+=(--dry-run --itemize-changes)

  info "Restoring from: $source_path"
  info "Restoring into: $OUTPUT_DIR"

  if (( HAVE_GUM )) && (( ! DRY_RUN )); then
    gum confirm "Proceed with restore?" || {
      warn "Restore cancelled"
      exit 0
    }
  fi

  rsync "${rsync_opts[@]}" "${source_path%/}/" "$OUTPUT_DIR/"

  success "Restore complete"
}

main "$@"
