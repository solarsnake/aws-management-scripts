#!/usr/bin/env bash
# Deregister the AMIs listed in a file (or on stdin), optionally with their snapshots.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: delete-list-of-amis.sh --file FILE|- [--delete-snapshots] [options]

Deregister every AMI listed in FILE, one AMI ID per line. Use - to read the
list from stdin. Blank lines and lines starting with # are ignored.

Options:
  --file FILE|-       File of AMI IDs (required)
  --delete-snapshots  Also delete the snapshots backing each deregistered AMI
  --profile NAME      AWS CLI profile
  --region NAME       AWS region
  --dry-run           Show what would be done without changing anything
  --yes               Do not ask for confirmation
  -h, --help          Show this help
USAGE
}

FILE=""
DELETE_SNAPSHOTS=0
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --file) [ $# -ge 2 ] || usage_error "--file requires a value"; FILE=$2; shift 2 ;;
    --delete-snapshots) DELETE_SNAPSHOTS=1; shift ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
[ -n "$FILE" ] || usage_error "--file is required"
if [ "$FILE" = "-" ] && [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
  usage_error "--file - reads IDs from stdin, so it needs --yes or --dry-run"
fi

# Validate the whole list before making any AWS call.
ids=$(read_id_list "$FILE" '^ami-[0-9a-f]{8,17}$')

preflight

if [ -z "$ids" ]; then
  log "Nothing to do."
  exit 0
fi

count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
if [ "$DELETE_SNAPSHOTS" = 1 ]; then
  log "About to deregister $count AMI(s) and delete their snapshots."
else
  log "About to deregister $count AMI(s)."
fi
confirm "Continue?" || die "Aborted. Nothing was changed."

errf=""
make_temp errf
ok=0
failed=0
for id in $ids; do
  if ! desc=$(aws_ro ec2 describe-images --image-ids "$id" 2>"$errf"); then
    failed=$((failed + 1))
    log "Failed: $id: $(cat "$errf")"
    continue
  fi
  if ! snaps=$(printf '%s' "$desc" | jq -r '.Images[0].BlockDeviceMappings[]?.Ebs.SnapshotId? // empty' 2>"$errf"); then
    failed=$((failed + 1))
    log "Failed: $id: could not parse describe-images output: $(cat "$errf")"
    continue
  fi

  if ! aws_rw ec2 deregister-image --image-id "$id" >/dev/null 2>"$errf"; then
    failed=$((failed + 1))
    log "Failed: $id: $(cat "$errf")"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then cat "$errf" >&2; fi

  item_failed=0
  if [ -n "$snaps" ]; then
    if [ "$DELETE_SNAPSHOTS" = 1 ]; then
      for snap in $snaps; do
        if aws_rw ec2 delete-snapshot --snapshot-id "$snap" >/dev/null 2>"$errf"; then
          if [ "$DRY_RUN" = 1 ]; then cat "$errf" >&2; fi
        else
          item_failed=1
          log "Failed: $snap: $(cat "$errf")"
        fi
      done
    else
      log "Left snapshot(s) for $id: $(printf '%s' "$snaps" | tr '\n' ' ' | sed 's/ $//')"
    fi
  fi
  if [ "$item_failed" = 1 ]; then failed=$((failed + 1)); else ok=$((ok + 1)); fi
done

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run: $count AMI(s) would be deregistered."
  exit 0
fi
log "Done: $ok succeeded, $failed failed"
[ "$failed" -eq 0 ] || exit 1
