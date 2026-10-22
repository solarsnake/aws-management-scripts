#!/usr/bin/env bash
# Create encrypted copies of the unencrypted AMIs you own, optionally removing the originals.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: encrypt-all-amis.sh --kms-key KEY [--delete-source] [options]

Copy every AMI you own that has unencrypted snapshots into an encrypted AMI
using KEY (a key ID, ARN or alias such as alias/my-key). The copy is named
"<name>-encrypted", shortened if needed to fit the 128 character limit.
AMIs created by AWS Backup are skipped. Tags are copied, except those starting
with aws:.

Options:
  --kms-key KEY     KMS key to encrypt with (required)
  --delete-source   Deregister each original AMI and delete its snapshots once
                    the copy is available and tagged
  --report FILE     Write one "<old-id> <new-id>" line per copied AMI to FILE
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

if ! images_json=$(aws_ro ec2 describe-images --owners self --filters Name=block-device-mapping.encrypted,Values=false 2>"$errf"); then
  die "could not list AMIs: $(cat "$errf")"
fi

# AMIs made by AWS Backup are never candidates. The new name leaves room for
# the "-encrypted" suffix within the 128 character limit.
if ! candidates=$(printf '%s' "$images_json" | jq -c '
  .Images[]
  | select(([.Tags[]?.Key] | index("aws:backup:source-resource")) | not)
  | {id: .ImageId,
     label: (.Name // ""),
     newname: ((.Name // .ImageId)[0:118] + "-encrypted"),
     tags: (.Tags // []),
     snaps: [.BlockDeviceMappings[]?.Ebs.SnapshotId? // empty]}' 2>"$errf"); then
  die "could not parse describe-images output: $(cat "$errf")"
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
  newname=$(printf '%s' "$item" | jq -r '.newname')
  tags=$(printf '%s' "$item" | jq -c '.tags' | copyable_tags_json)

  if ! out=$(aws_rw ec2 copy-image --name "$newname" --source-region "$REGION_EFF" --source-image-id "$id" \
    --encrypted --kms-key-id "$KMS_KEY" 2>"$errf"); then
    failed=$((failed + 1))
    log "Failed: $id: $(cat "$errf")"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    cat "$errf" >&2
    continue
  fi
  if ! new=$(printf '%s' "$out" | jq -r '.ImageId // empty' 2>"$errf") || [ -z "$new" ]; then
    failed=$((failed + 1))
    log "Failed: $id: no image ID in copy-image output: $(cat "$errf")"
    continue
  fi

  if ! aws_wait image-available --image-ids "$new" >/dev/null 2>"$errf"; then
    failed=$((failed + 1))
    log "Failed: $id: copy $new did not become available: $(cat "$errf")"
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

  # The source is only removed once its copy is available and tagged.
  if [ "$DELETE_SOURCE" = 1 ]; then
    if ! aws_rw ec2 deregister-image --image-id "$id" >/dev/null 2>"$errf"; then
      failed=$((failed + 1))
      log "Failed: $id: copied to $new but could not deregister the source: $(cat "$errf")"
      continue
    fi
    item_failed=0
    while IFS= read -r snap <&4; do
      [ -n "$snap" ] || continue
      if ! aws_rw ec2 delete-snapshot --snapshot-id "$snap" >/dev/null 2>"$errf"; then
        item_failed=1
        log "Failed: $snap: $(cat "$errf")"
      fi
    done 4<<< "$(printf '%s' "$item" | jq -r '.snaps[]')"
    if [ "$item_failed" = 1 ]; then
      failed=$((failed + 1))
      continue
    fi
  fi
  ok=$((ok + 1))
done 3<<< "$candidates"

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run: $count AMI(s) would be copied."
  exit 0
fi
log "Done: $ok succeeded, $failed failed"
[ "$failed" -eq 0 ] || exit 1
