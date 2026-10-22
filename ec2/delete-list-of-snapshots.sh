#!/usr/bin/env bash
# Delete the EBS snapshots listed in a file (or on stdin).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: delete-list-of-snapshots.sh --file FILE|- [options]

Delete every snapshot listed in FILE, one snapshot ID per line. Use - to read
the list from stdin. Blank lines and lines starting with # are ignored.

Options:
  --file FILE|-     File of snapshot IDs (required)
  --profile NAME    AWS CLI profile
  --region NAME     AWS region
  --dry-run         Show what would be deleted without deleting
  --yes             Do not ask for confirmation
  -h, --help        Show this help
USAGE
}

FILE=""
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --file) [ $# -ge 2 ] || usage_error "--file requires a value"; FILE=$2; shift 2 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
[ -n "$FILE" ] || usage_error "--file is required"

# Validate the whole list before making any AWS call.
ids=$(read_id_list "$FILE" '^snap-[0-9a-f]{8,17}$')

preflight

if [ -z "$ids" ]; then
  log "Nothing to do."
  exit 0
fi

count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
log "About to delete $count snapshot(s)."
confirm "Delete them?" || die "Aborted. Nothing was changed."

ok=0
failed=0
for id in $ids; do
  if out=$(aws_rw ec2 delete-snapshot --snapshot-id "$id" 2>&1); then
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    log "Failed: $id: $out"
  fi
done

log "Done: $ok succeeded, $failed failed"
[ "$failed" -eq 0 ] || exit 1
