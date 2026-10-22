#!/usr/bin/env bash
# Delete the AWS Backup recovery points in a vault created before a date.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: delete-aws-backup-recovery-points.sh [--vault NAME --before DATE] [options]

Without --vault, print the backup vault names, one per line.
With --vault, delete every recovery point in that vault created before DATE.

Options:
  --vault NAME      Backup vault to clean
  --before DATE     Delete points created before DATE (required with --vault);
                    YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS[Z]
  --profile NAME    AWS CLI profile
  --region NAME     AWS region
  --dry-run         Show what would be deleted without deleting
  --yes             Do not ask for confirmation
  -h, --help        Show this help
USAGE
}

VAULT=""
BEFORE=""
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --vault) [ $# -ge 2 ] || usage_error "--vault requires a value"; VAULT=$2; shift 2 ;;
    --before) [ $# -ge 2 ] || usage_error "--before requires a value"; BEFORE=$2; shift 2 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

if [ -n "$VAULT" ]; then
  [ -n "$BEFORE" ] || usage_error "--before is required with --vault"
  printf '%s\n' "$BEFORE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?)?$' ||
    usage_error "--before must look like 2022-06-01 or 2022-06-01T22:00:00"
elif [ -n "$BEFORE" ]; then
  usage_error "--before requires --vault"
fi

preflight
errf=""
make_temp errf

# Without --vault, just print the vault names.
if [ -z "$VAULT" ]; then
  resp=$(aws_ro backup list-backup-vaults 2>"$errf") ||
    die "could not list backup vaults: $(cat "$errf")"
  printf '%s' "$resp" | jq -r '.BackupVaultList[].BackupVaultName' ||
    die "could not parse the backup vault list"
  exit 0
fi

resp=$(aws_ro backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$VAULT" --by-created-before "$BEFORE" 2>"$errf") ||
  die "could not list recovery points in $VAULT: $(cat "$errf")"
arns=$(printf '%s' "$resp" | jq -r '.RecoveryPoints[].RecoveryPointArn') ||
  die "could not parse the recovery point list for $VAULT"

if [ -z "$arns" ]; then
  log "Nothing to do."
  exit 0
fi

count=$(printf '%s\n' "$arns" | wc -l | tr -d ' ')
log "About to delete $count recovery point(s) in $VAULT created before $BEFORE."
confirm "Delete them?" || die "Aborted. Nothing was changed."

ok=0
failed=0
for arn in $arns; do
  if out=$(aws_rw backup delete-recovery-point \
    --backup-vault-name "$VAULT" --recovery-point-arn "$arn" 2>&1); then
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    log "Failed: $arn: $out"
  fi
done

log "Done: $ok succeeded, $failed failed"
[ "$failed" -eq 0 ] || exit 1
