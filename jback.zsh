#!/usr/bin/env zsh
set -euo pipefail

# ZSH script that provides incremental backups via rsync. Simple but effective. Must have GUM.

umask 077
zmodload zsh/system 2>/dev/null || true

PROG_NAME="${0:t}"
LOCK_FD=9
: "${BACKUP_KEEP:=30}"

HAVE_GUM=0
if command -v gum >/dev/null 2>&1; then
  HAVE_GUM=1
fi

usage() {
  cat <<'EOF'
Usage:
  jback.zsh -s SOURCE -d DESTINATION [-e EXCLUDES] [-k KEEP] [-n] [-v]

Required:
  -s SOURCE         Source directory to back up
  -d DESTINATION    Backup destination
                    Local example: /mnt/backup/laptop
                    Remote example: backup@server:/srv/backups/laptop

Optional:
  -e EXCLUDES       Path to rsync exclude file
  -k KEEP           Number of snapshots to keep (default: 30)
  -n                Dry run
  -v                Verbose
  -h                Show help
EOF
}

banner() {
  if (( HAVE_GUM )); then
    gum style \
      --border rounded \
      --margin "1 0" \
      --padding "1 2" \
      --border-foreground 212 \
      --foreground 231 \
      --background 57 \
      "JBackup - Incremental Backup" \
      "rsync snapshot backup for Linux + macOS"
  else
    print
    print "=================================="
    print "  JBackup Incremental Backup"
    print "  rsync snapshot backup"
    print "=================================="
    print
  fi
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

err() {
  if (( HAVE_GUM )); then
    gum style --foreground 196 "✖ $*"
  else
    print -u2 -r -- "ERROR: $*"
  fi
}

die() {
  err "$*"
  exit 1
}

kv() {
  local k="$1"
  local v="$2"
  if (( HAVE_GUM )); then
    gum style --foreground 244 "${k}: " | tr -d '\n'
    gum style --bold "$v"
  else
    print -r -- "${k}: ${v}"
  fi
}

run_with_spinner() {
  local title="$1"
  shift
  if (( HAVE_GUM )); then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    "$@"
  fi
}

is_remote_path() {
  [[ "$1" == *:* ]]
}

remote_host_from_path() {
  local p="$1"
  print -r -- "${p%%:*}"
}

remote_dir_from_path() {
  local p="$1"
  print -r -- "${p#*:}"
}

ensure_source_exists() {
  [[ -d "$SOURCE" ]] || die "Source directory does not exist: $SOURCE"
}

ensure_local_tools() {
  command -v rsync >/dev/null 2>&1 || die "rsync not found"
  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v find >/dev/null 2>&1 || die "find not found"
  command -v sort >/dev/null 2>&1 || die "sort not found"
  command -v awk >/dev/null 2>&1 || die "awk not found"
  command -v sed >/dev/null 2>&1 || die "sed not found"
  command -v du >/dev/null 2>&1 || die "du not found"
}

ensure_remote_tools() {
  local host="$1"
  ssh "$host" "command -v rsync >/dev/null 2>&1 && command -v mkdir >/dev/null 2>&1 && command -v ln >/dev/null 2>&1 && command -v find >/dev/null 2>&1" \
    || die "Remote host missing required tools: $host"
}

list_snapshots_local() {
  local dest_root="$1"
  [[ -d "$dest_root" ]] || return 0
  find "$dest_root" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??????' -print | sort
}

list_snapshots_remote() {
  local host="$1"
  local dest_root="$2"
  ssh "$host" "find '$dest_root' -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??????' -print 2>/dev/null | sort"
}

get_latest_snapshot_name_local() {
  local dest_root="$1"
  local last=""
  last="$(list_snapshots_local "$dest_root" | tail -n 1 || true)"
  [[ -n "$last" ]] && basename "$last"
}

get_latest_snapshot_name_remote() {
  local host="$1"
  local dest_root="$2"
  local last=""
  last="$(list_snapshots_remote "$host" "$dest_root" | tail -n 1 || true)"
  [[ -n "$last" ]] && basename "$last"
}

count_snapshots_local() {
  local dest_root="$1"
  list_snapshots_local "$dest_root" | wc -l | tr -d ' '
}

count_snapshots_remote() {
  local host="$1"
  local dest_root="$2"
  list_snapshots_remote "$host" "$dest_root" | wc -l | tr -d ' '
}

prune_old_local() {
  local dest_root="$1"
  local keep="$2"
  local -a snaps
  snaps=("${(@f)$(list_snapshots_local "$dest_root")}")
  local count="${#snaps[@]}"

  (( count > keep )) || return 0
  local to_delete=$(( count - keep ))
  warn "Pruning $to_delete old local snapshot(s)"

  local i
  for (( i=1; i<=to_delete; i++ )); do
    info "Removing ${snaps[i]}"
    rm -rf -- "${snaps[i]}"
  done
}

prune_old_remote() {
  local host="$1"
  local dest_root="$2"
  local keep="$3"
  local -a snaps
  snaps=("${(@f)$(list_snapshots_remote "$host" "$dest_root")}")
  local count="${#snaps[@]}"

  (( count > keep )) || return 0
  local to_delete=$(( count - keep ))
  warn "Pruning $to_delete old remote snapshot(s)"

  local i
  for (( i=1; i<=to_delete; i++ )); do
    info "Removing ${snaps[i]}"
    ssh "$host" "rm -rf -- '${snaps[i]}'"
  done
}

create_lock_local() {
  local dest_root="$1"
  mkdir -p "$dest_root"
  exec {LOCK_FD}> "$dest_root/.backup.lock"
  if ! zsystem flock -f "$LOCK_FD"; then
    die "Could not acquire local backup lock"
  fi
}

human_size_local() {
  local p="$1"
  du -sh "$p" 2>/dev/null | awk '{print $1}'
}

human_size_remote() {
  local host="$1"
  local p="$2"
  ssh "$host" "du -sh '$p' 2>/dev/null | awk '{print \$1}'" 2>/dev/null
}

print_summary() {
  local mode="$1"
  local snapshot="$2"
  local snap_path="$3"
  local source="$4"
  local dest="$5"
  local previous="$6"
  local count="$7"
  local size="$8"
  local duration="$9"

  print
  if (( HAVE_GUM )); then
    gum style --border rounded --padding "0 1" --foreground 212 "Backup Summary"
    gum table \
      --border rounded \
      --widths 18,70 \
      "Field" "Value" \
      "Mode" "$mode" \
      "Source" "$source" \
      "Destination" "$dest" \
      "Snapshot" "$snapshot" \
      "Snapshot Path" "$snap_path" \
      "Previous" "${previous:-<none>}" \
      "Snapshots Total" "$count" \
      "Snapshot Size" "${size:-unknown}" \
      "Duration" "${duration}s"
  else
    printf "\n%-18s %s\n" "Field" "Value"
    printf "%-18s %s\n" "-----" "-----"
    printf "%-18s %s\n" "Mode" "$mode"
    printf "%-18s %s\n" "Source" "$source"
    printf "%-18s %s\n" "Destination" "$dest"
    printf "%-18s %s\n" "Snapshot" "$snapshot"
    printf "%-18s %s\n" "Snapshot Path" "$snap_path"
    printf "%-18s %s\n" "Previous" "${previous:-<none>}"
    printf "%-18s %s\n" "Snapshots Total" "$count"
    printf "%-18s %s\n" "Snapshot Size" "${size:-unknown}"
    printf "%-18s %ss\n" "Duration" "$duration"
  fi
  print
}

main() {
  typeset SOURCE=""
  typeset DEST=""
  typeset EXCLUDES=""
  typeset KEEP="$BACKUP_KEEP"
  typeset DRY_RUN=0
  typeset VERBOSE=0

  while getopts ":s:d:e:k:nvh" opt; do
    case "$opt" in
      s) SOURCE="$OPTARG" ;;
      d) DEST="$OPTARG" ;;
      e) EXCLUDES="$OPTARG" ;;
      k) KEEP="$OPTARG" ;;
      n) DRY_RUN=1 ;;
      v) VERBOSE=1 ;;
      h) usage; exit 0 ;;
      :) die "Option -$OPTARG requires an argument" ;;
      \?) die "Unknown option: -$OPTARG" ;;
    esac
  done

  [[ -n "$SOURCE" ]] || die "Missing -s SOURCE"
  [[ -n "$DEST" ]] || die "Missing -d DEST"
  [[ "$KEEP" == <-> ]] || die "KEEP must be an integer"

  ensure_local_tools
  ensure_source_exists
  [[ -n "$EXCLUDES" && ! -f "$EXCLUDES" ]] && die "Exclude file not found: $EXCLUDES"

  SOURCE="${SOURCE:A}"

  local timestamp snapshot_name start_epoch end_epoch duration
  timestamp="$(date '+%Y-%m-%d_%H%M%S')"
  snapshot_name="$timestamp"
  start_epoch="$(date +%s)"

  banner
  kv "Source" "$SOURCE"
  kv "Destination" "$DEST"
  kv "Keep" "$KEEP snapshots"
  [[ -n "$EXCLUDES" ]] && kv "Exclude file" "$EXCLUDES"
  (( DRY_RUN )) && kv "Mode" "dry-run"

  if (( HAVE_GUM )) && (( ! DRY_RUN )); then
    gum confirm "Start backup?" || {
      warn "Backup cancelled"
      exit 0
    }
  fi

  local -a rsync_opts
  rsync_opts=(
    -aH
    --delete
    --delete-excluded
    --numeric-ids
    --partial
    --human-readable
    --stats
  )

  rsync --version | grep -qi 'xattrs' && rsync_opts+=( -X )
  rsync --version | grep -qi 'ACLs' && rsync_opts+=( -A )
  (( VERBOSE )) && rsync_opts+=( -v )
  (( DRY_RUN )) && rsync_opts+=( --dry-run --itemize-changes )
  [[ -n "$EXCLUDES" ]] && rsync_opts+=( --exclude-from="$EXCLUDES" )

  local src="${SOURCE%/}/"
  local summary_mode previous_snapshot="" summary_snap_path="" summary_count="" summary_size=""

  if is_remote_path "$DEST"; then
    local host dest_root latest prev_linkdest snap_path log_path
    host="$(remote_host_from_path "$DEST")"
    dest_root="$(remote_dir_from_path "$DEST")"

    summary_mode="remote"

    info "Checking remote tools on $host"
    run_with_spinner "Connecting to $host..." ensure_remote_tools "$host"

    info "Preparing remote destination"
    run_with_spinner "Creating remote destination..." ssh "$host" "mkdir -p '$dest_root'"

    latest="$(get_latest_snapshot_name_remote "$host" "$dest_root")"
    snap_path="$dest_root/$snapshot_name"
    log_path="$dest_root/backup.log"

    summary_snap_path="$host:$snap_path"
    previous_snapshot="$latest"

    local -a remote_rsync_opts
    remote_rsync_opts=("${rsync_opts[@]}")

    if [[ -n "$latest" ]]; then
      prev_linkdest="../$latest"
      remote_rsync_opts+=( "--link-dest=$prev_linkdest" )
      kv "Previous snapshot" "$latest"
    else
      warn "No previous snapshot found; first full snapshot"
    fi

    info "Running rsync to remote snapshot"
    rsync "${remote_rsync_opts[@]}" \
      --rsync-path="mkdir -p '$snap_path' && rsync" \
      "$src" "$host:$snap_path/" | tee >(ssh "$host" "cat >> '$log_path'")

    if (( ! DRY_RUN )); then
      info "Updating latest symlink"
      ssh "$host" "cd '$dest_root' && ln -sfn '$snapshot_name' latest"
      prune_old_remote "$host" "$dest_root" "$KEEP"
    fi

    summary_count="$(count_snapshots_remote "$host" "$dest_root")"
    summary_size="$(human_size_remote "$host" "$snap_path")"
  else
    local dest_root latest snap_path log_path prev_linkdest
    dest_root="${DEST:A}"

    summary_mode="local"

    create_lock_local "$dest_root"

    info "Preparing local destination"
    mkdir -p "$dest_root"

    latest="$(get_latest_snapshot_name_local "$dest_root")"
    snap_path="$dest_root/$snapshot_name"
    log_path="$dest_root/backup.log"

    summary_snap_path="$snap_path"
    previous_snapshot="$latest"

    mkdir -p "$snap_path"

    if [[ -n "$latest" ]]; then
      prev_linkdest="../$latest"
      rsync_opts+=( "--link-dest=$prev_linkdest" )
      kv "Previous snapshot" "$latest"
    else
      warn "No previous snapshot found; first full snapshot"
    fi

    info "Running rsync to local snapshot"
    rsync "${rsync_opts[@]}" "$src" "$snap_path/" | tee -a "$log_path"

    if (( ! DRY_RUN )); then
      info "Updating latest symlink"
      ln -sfn "$snapshot_name" "$dest_root/latest"
      prune_old_local "$dest_root" "$KEEP"
    fi

    summary_count="$(count_snapshots_local "$dest_root")"
    summary_size="$(human_size_local "$snap_path")"
  fi

  end_epoch="$(date +%s)"
  duration="$(( end_epoch - start_epoch ))"

  print_summary \
    "$summary_mode" \
    "$snapshot_name" \
    "$summary_snap_path" \
    "$SOURCE" \
    "$DEST" \
    "$previous_snapshot" \
    "$summary_count" \
    "$summary_size" \
    "$duration"

  success "Backup complete: $snapshot_name"
}

main "$@"
