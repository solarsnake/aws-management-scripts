#!/usr/bin/env bash
# Create encrypted copies of the unencrypted snapshots you own, optionally deleting the originals.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: encrypt-all-snapshots.sh --kms-key KEY [--delete-source] [options]

Copy every unencrypted snapshot you own into an encrypted snapshot using KEY
(a key ID, ARN or alias such as alias/my-key). Snapshots created by AWS Backup
and snapshots that back an AMI are skipped; use encrypt-all-amis.sh for AMIs.
Tags are copied, except those starting with aws:.

Options:
  --kms-key KEY     KMS key to encrypt with (required)
  --delete-source   Delete each original snapshot once its copy is complete and tagged
  --report FILE     Write one "<old-id> <new-id>" line per copied snapshot to FILE
  --profile NAME    AWS CLI profile
  --region NAME     AWS region
  --dry-run         Show what would be done without changing anything
  --yes             Do not ask for confirmation
  -h, --help        Show this help
USAGE
}

KMS_KEY=""
DELETE_SOURCE=0
REPORT=""
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --kms-key) [ $# -ge 2 ] || usage_error "--kms-key requires a value"; KMS_KEY=$2; shift 2 ;;
    --report) [ $# -ge 2 ] || usage_error "--report requires a value"; REPORT=$2; shift 2 ;;
    --delete-source) DELETE_SOURCE=1; shift ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
[ -n "$KMS_KEY" ] || usage_error "--kms-key is required"

preflight
REGION_EFF=$(require_region)

errf=""
make_temp errf

if ! snaps_json=$(aws_ro ec2 describe-snapshots --owner-ids self --filters Name=encrypted,Values=false 2>"$errf"); then
  die "could not list snapshots: $(cat "$errf")"
fi
if ! images_json=$(aws_ro ec2 describe-images --owners self 2>"$errf"); then
  die "could not list AMIs: $(cat "$errf")"
fi
if ! backed=$(printf '%s' "$images_json" | jq -c '[.Images[]?.BlockDeviceMappings[]?.Ebs.SnapshotId? // empty]' 2>"$errf"); then
  die "could not parse describe-images output: $(cat "$errf")"
fi

# Snapshots made by AWS Backup are never candidates.
base='.Snapshots[] | select(([.Tags[]?.Key] | index("aws:backup:source-resource")) | not)'
if ! skipped=$(printf '%s' "$snaps_json" | jq --argjson backed "$backed" \
  "[$base | select(.SnapshotId as \$s | \$backed | index(\$s))] | length" 2>"$errf"); then
  die "could not parse describe-snapshots output: $(cat "$errf")"
fi
if ! candidates=$(printf '%s' "$snaps_json" | jq -c --argjson backed "$backed" \
  "$base | select(.SnapshotId as \$s | \$backed | index(\$s) | not)
   | {id: .SnapshotId, label: (.Description // \"\"), tags: (.Tags // [])}" 2>"$errf"); then
  die "could not parse describe-snapshots output: $(cat "$errf")"
fi

if [ "$skipped" -gt 0 ]; then
  log "Skipped $skipped snapshot(s) that back AMIs; use encrypt-all-amis.sh for those."
fi
if [ -z "$candidates" ]; then
  log "Nothing to do."
  exit 0
fi

count=$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')
while IFS= read -r item <&3; do
  printf '  %s  %s\n' "$(printf '%s' "$item" | jq -r '.id')" "$(printf '%s' "$item" | jq -r '.label')" >&2
done 3<<< "$candidates"
log "About to create $count encrypted copies."
if [ "$DELETE_SOURCE" = 1 ]; then log "Source resources will be deleted afterwards."; fi
confirm "Continue?" || die "Aborted. Nothing was changed."

if [ -n "$REPORT" ] && [ "$DRY_RUN" != 1 ]; then
  : > "$REPORT" || die "cannot write report file: $REPORT"
fi

ok=0
failed=0
while IFS= read -r item <&3; do
  id=$(printf '%s' "$item" | jq -r '.id')
  tags=$(printf '%s' "$item" | jq -c '.tags' | copyable_tags_json)

  if ! out=$(aws_rw ec2 copy-snapshot --source-region "$REGION_EFF" --source-snapshot-id "$id" \
    --encrypted --kms-key-id "$KMS_KEY" --description "Encrypted copy of $id" 2>"$errf"); then
    failed=$((failed + 1))
    log "Failed: $id: $(cat "$errf")"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    cat "$errf" >&2
    continue
  fi
  if ! new=$(printf '%s' "$out" | jq -r '.SnapshotId // empty' 2>"$errf") || [ -z "$new" ]; then
    failed=$((failed + 1))
    log "Failed: $id: no snapshot ID in copy-snapshot output: $(cat "$errf")"
    continue
  fi

  if ! aws_ro ec2 wait snapshot-completed --snapshot-ids "$new" >/dev/null 2>"$errf"; then
    failed=$((failed + 1))
    log "Failed: $id: copy $new did not complete: $(cat "$errf")"
    continue
  fi
  if [ "$tags" != "[]" ]; then
    if ! aws_rw ec2 create-tags --resources "$new" --tags "$tags" >/dev/null 2>"$errf"; then
      failed=$((failed + 1))
      log "Failed: $id: could not tag $new: $(cat "$errf")"
      continue
    fi
  fi
  if [ -n "$REPORT" ]; then printf '%s %s\n' "$id" "$new" >> "$REPORT"; fi

  # The source is only deleted once its copy is complete and tagged.
  if [ "$DELETE_SOURCE" = 1 ]; then
    if ! aws_rw ec2 delete-snapshot --snapshot-id "$id" >/dev/null 2>"$errf"; then
      failed=$((failed + 1))
      log "Failed: $id: copied to $new but could not delete the source: $(cat "$errf")"
      continue
    fi
  fi
  ok=$((ok + 1))
done 3<<< "$candidates"

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run: $count snapshot(s) would be copied."
  exit 0
fi
log "Done: $ok succeeded, $failed failed"
[ "$failed" -eq 0 ] || exit 1
