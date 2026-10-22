#!/usr/bin/env bash
# Create an encrypted copy of an unattached EBS volume, optionally deleting the original.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: encrypt-unattached-ebs-volume.sh --volume-id ID --kms-key KEY [--type TYPE] [--delete-source] [options]

Encrypt an unattached (available) volume by snapshotting it and creating an
encrypted volume from the snapshot in the same availability zone. The
temporary snapshot is deleted afterwards. Tags are copied, except those
starting with aws:, and the copy is tagged encrypted-copy-of=ID.

Options:
  --volume-id ID    Volume to encrypt (required)
  --kms-key KEY     KMS key to encrypt with: key ID, ARN or alias (required)
  --type TYPE       Volume type of the copy: gp2, gp3, io1, io2, st1, sc1 or
                    standard (default: the type of the source)
  --delete-source   Delete the original volume once the copy is available
  --profile NAME    AWS CLI profile
  --region NAME     AWS region
  --dry-run         Show what would be done without changing anything
  --yes             Do not ask for confirmation
  -h, --help        Show this help
USAGE
}

VOLUME_ID=""
KMS_KEY=""
TYPE=""
DELETE_SOURCE=0
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --volume-id) [ $# -ge 2 ] || usage_error "--volume-id requires a value"; VOLUME_ID=$2; shift 2 ;;
    --kms-key) [ $# -ge 2 ] || usage_error "--kms-key requires a value"; KMS_KEY=$2; shift 2 ;;
    --type) [ $# -ge 2 ] || usage_error "--type requires a value"; TYPE=$2; shift 2 ;;
    --delete-source) DELETE_SOURCE=1; shift ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
[ -n "$VOLUME_ID" ] || usage_error "--volume-id is required"
[ -n "$KMS_KEY" ] || usage_error "--kms-key is required"
if ! [[ $VOLUME_ID =~ ^vol-[0-9a-f]+$ ]]; then usage_error "invalid volume ID: $VOLUME_ID"; fi
case "$TYPE" in
  "" | gp2 | gp3 | io1 | io2 | st1 | sc1 | standard) ;;
  *) usage_error "--type must be one of gp2, gp3, io1, io2, st1, sc1, standard" ;;
esac

preflight

errf=""
make_temp errf

if ! vol_json=$(aws_ro ec2 describe-volumes --volume-ids "$VOLUME_ID" 2>"$errf"); then
  die "could not describe $VOLUME_ID: $(cat "$errf")"
fi
if ! info=$(printf '%s' "$vol_json" | jq -c '.Volumes[0] | select(. != null)
  | {state: .State, encrypted: (.Encrypted // false), type: .VolumeType, iops: .Iops,
     throughput: .Throughput, az: .AvailabilityZone, tags: (.Tags // [])}' 2>"$errf") || [ -z "$info" ]; then
  die "could not read $VOLUME_ID from describe-volumes output: $(cat "$errf")"
fi

field() { printf '%s' "$info" | jq -r "$1"; }
state=$(field '.state')
if [ "$state" != "available" ]; then die "$VOLUME_ID is attached (state: $state); detach it first"; fi
if [ "$(field '.encrypted')" = "true" ]; then
  log "$VOLUME_ID is already encrypted. Nothing to do."
  exit 0
fi

src_type=$(field '.type')
src_iops=$(field '.iops // empty')
src_throughput=$(field '.throughput // empty')
az=$(field '.az')
target=${TYPE:-$src_type}

extra=()
case "$target" in
  gp3)
    extra+=(--iops "$(gp3_iops "${src_iops:-3000}" 3000)")
    if [ "$src_type" = "gp3" ] && [ -n "$src_throughput" ]; then
      extra+=(--throughput "$src_throughput")
    else
      extra+=(--throughput 125)
    fi
    ;;
  io1 | io2)
    [ -n "$src_iops" ] || die "$VOLUME_ID has no provisioned IOPS to carry over to $target"
    extra+=(--iops "$src_iops")
    ;;
esac

if ! tags=$(printf '%s' "$info" | jq -c '.tags' | copyable_tags_json \
  | jq -c --arg id "$VOLUME_ID" '[{ResourceType: "volume", Tags: (. + [{Key: "encrypted-copy-of", Value: $id}])}]' 2>"$errf"); then
  die "could not build tags for the new volume: $(cat "$errf")"
fi

log "About to create an encrypted $target copy of $VOLUME_ID in $az."
if [ "$DELETE_SOURCE" = 1 ]; then log "The original volume will be deleted afterwards."; fi
confirm "Continue?" || die "Aborted. Nothing was changed."

# Report a failure after the temporary snapshot exists: try to remove the
# snapshot, leave the original volume alone, and exit 1.
snap=""
fail_after_snapshot() {
  local msg=$1 note
  if aws_rw ec2 delete-snapshot --snapshot-id "$snap" >/dev/null 2>"$errf"; then
    note="temporary snapshot $snap deleted"
  else
    note="could not delete temporary snapshot $snap: $(cat "$errf")"
  fi
  die "$msg; $note; $VOLUME_ID was not deleted"
}

if [ "$DRY_RUN" = 1 ]; then
  snap="<snapshot-id>"
  aws_rw ec2 create-snapshot --volume-id "$VOLUME_ID" --description "Temporary snapshot for encrypting $VOLUME_ID"
  aws_rw ec2 create-volume --availability-zone "$az" --snapshot-id "$snap" --encrypted --kms-key-id "$KMS_KEY" \
    --volume-type "$target" ${extra[@]+"${extra[@]}"} --tag-specifications "$tags"
  aws_rw ec2 delete-snapshot --snapshot-id "$snap"
  if [ "$DELETE_SOURCE" = 1 ]; then aws_rw ec2 delete-volume --volume-id "$VOLUME_ID"; fi
  log "Dry run: $VOLUME_ID would be copied to an encrypted volume."
  exit 0
fi

if ! out=$(aws_rw ec2 create-snapshot --volume-id "$VOLUME_ID" \
  --description "Temporary snapshot for encrypting $VOLUME_ID" 2>"$errf"); then
  die "could not snapshot $VOLUME_ID: $(cat "$errf")"
fi
if ! snap=$(printf '%s' "$out" | jq -r '.SnapshotId // empty' 2>"$errf") || [ -z "$snap" ]; then
  die "no snapshot ID in create-snapshot output: $(cat "$errf")"
fi

if ! aws_ro ec2 wait snapshot-completed --snapshot-ids "$snap" >/dev/null 2>"$errf"; then
  fail_after_snapshot "snapshot $snap did not complete: $(cat "$errf")"
fi
if ! out=$(aws_rw ec2 create-volume --availability-zone "$az" --snapshot-id "$snap" --encrypted \
  --kms-key-id "$KMS_KEY" --volume-type "$target" ${extra[@]+"${extra[@]}"} \
  --tag-specifications "$tags" 2>"$errf"); then
  fail_after_snapshot "could not create the encrypted volume: $(cat "$errf")"
fi
if ! new=$(printf '%s' "$out" | jq -r '.VolumeId // empty' 2>"$errf") || [ -z "$new" ]; then
  fail_after_snapshot "no volume ID in create-volume output: $(cat "$errf")"
fi
if ! aws_ro ec2 wait volume-available --volume-ids "$new" >/dev/null 2>"$errf"; then
  fail_after_snapshot "new volume $new did not become available: $(cat "$errf")"
fi

if ! aws_rw ec2 delete-snapshot --snapshot-id "$snap" >/dev/null 2>"$errf"; then
  die "created $new but could not delete temporary snapshot $snap: $(cat "$errf"); $VOLUME_ID was not deleted"
fi
if [ "$DELETE_SOURCE" = 1 ]; then
  if ! aws_rw ec2 delete-volume --volume-id "$VOLUME_ID" >/dev/null 2>"$errf"; then
    die "created $new but could not delete $VOLUME_ID: $(cat "$errf")"
  fi
fi
log "Created encrypted volume $new from $VOLUME_ID."
