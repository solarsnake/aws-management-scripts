#!/usr/bin/env bash
# Convert gp2 EBS volumes to gp3 without lowering their IOPS.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: modify-ebs-volumes-gp2-to-gp3.sh [--min-iops N] [--throughput N] [options]

Convert every gp2 volume in the region to gp3. Each volume keeps its current
IOPS when that is above the minimum, capped at 16000. Volumes that already have
a modification in progress are skipped.

Throughput defaults to 125 MiB/s for volumes up to 170 GiB and 250 MiB/s for
larger ones, matching what gp2 can deliver. --throughput only raises it: every
volume gets the larger of N and its default.

Options:
  --min-iops N      Minimum gp3 IOPS, 3000 to 16000 (default 3000)
  --throughput N    Minimum gp3 throughput in MiB/s, 125 to 1000;
                    at most min-iops / 4
  --profile NAME    AWS CLI profile
  --region NAME     AWS region
  --dry-run         Show what would be done without changing anything
  --yes             Do not ask for confirmation
  -h, --help        Show this help
USAGE
}

int_in_range() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

MIN_IOPS=3000
THROUGHPUT=""
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --min-iops) [ $# -ge 2 ] || usage_error "--min-iops requires a value"; MIN_IOPS=$2; shift 2 ;;
    --throughput) [ $# -ge 2 ] || usage_error "--throughput requires a value"; THROUGHPUT=$2; shift 2 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
int_in_range "$MIN_IOPS" 3000 16000 || usage_error "--min-iops must be an integer from 3000 to 16000"
if [ -n "$THROUGHPUT" ]; then
  int_in_range "$THROUGHPUT" 125 1000 || usage_error "--throughput must be an integer from 125 to 1000"
  if [ $((THROUGHPUT * 4)) -gt "$MIN_IOPS" ]; then
    usage_error "--throughput $THROUGHPUT needs at least $((THROUGHPUT * 4)) IOPS; raise --min-iops"
  fi
fi

# volume_throughput SIZE_GIB: the larger of --throughput and the size-based default.
volume_throughput() {
  local t
  t=$(gp3_default_throughput "$1")
  if [ -n "$THROUGHPUT" ] && [ "$THROUGHPUT" -gt "$t" ]; then t=$THROUGHPUT; fi
  printf '%s\n' "$t"
}

preflight

errf=""
make_temp errf

if ! vols_json=$(aws_ro ec2 describe-volumes --filters Name=volume-type,Values=gp2 2>"$errf"); then
  die "could not list volumes: $(cat "$errf")"
fi
if ! mods_json=$(aws_ro ec2 describe-volumes-modifications --filters Name=modification-state,Values=modifying,optimizing 2>"$errf"); then
  die "could not list volume modifications: $(cat "$errf")"
fi
if ! busy=$(printf '%s' "$mods_json" | jq -c '[.VolumesModifications[]?.VolumeId]' 2>"$errf"); then
  die "could not parse describe-volumes-modifications output: $(cat "$errf")"
fi
if ! busy_ids=$(printf '%s' "$mods_json" | jq -r '.VolumesModifications[]?.VolumeId' 2>"$errf"); then
  die "could not parse describe-volumes-modifications output: $(cat "$errf")"
fi
if ! candidates=$(printf '%s' "$vols_json" | jq -c --argjson busy "$busy" \
  '.Volumes[]? | select(.VolumeId as $v | $busy | index($v) | not)
   | {id: .VolumeId, size: (.Size // 0), iops: (.Iops // 0)}' 2>"$errf"); then
  die "could not parse describe-volumes output: $(cat "$errf")"
fi

while IFS= read -r id <&3; do
  [ -n "$id" ] || continue
  if printf '%s' "$vols_json" | jq -e --arg id "$id" '[.Volumes[]?.VolumeId] | index($id)' >/dev/null 2>&1; then
    log "Skipping $id: modification already in progress"
  fi
done 3<<< "$busy_ids"

if [ -z "$candidates" ]; then
  log "Nothing to do."
  exit 0
fi

count=$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')
plan_row() { printf '%-21s  %8s  %8s  %8s  %10s\n' "$@"; }
plan_row "VOLUME" "SIZE GiB" "GP2 IOPS" "GP3 IOPS" "THROUGHPUT"
while IFS= read -r item <&3; do
  id=$(printf '%s' "$item" | jq -r '.id')
  size=$(printf '%s' "$item" | jq -r '.size')
  iops=$(printf '%s' "$item" | jq -r '.iops')
  plan_row "$id" "$size" "$iops" "$(gp3_iops "$iops" "$MIN_IOPS")" "$(volume_throughput "$size")"
done 3<<< "$candidates"
log "About to convert $count volume(s) to gp3."
confirm "Continue?" || die "Aborted. Nothing was changed."

ok=0
failed=0
while IFS= read -r item <&3; do
  id=$(printf '%s' "$item" | jq -r '.id')
  iops=$(printf '%s' "$item" | jq -r '.iops')
  size=$(printf '%s' "$item" | jq -r '.size')
  if ! aws_rw ec2 modify-volume --volume-id "$id" --volume-type gp3 \
    --iops "$(gp3_iops "$iops" "$MIN_IOPS")" --throughput "$(volume_throughput "$size")" >/dev/null 2>"$errf"; then
    failed=$((failed + 1))
    log "Failed: $id: $(cat "$errf")"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    cat "$errf" >&2
    continue
  fi
  ok=$((ok + 1))
done 3<<< "$candidates"

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run: $count volume(s) would be modified."
  exit 0
fi
log "Done: $ok succeeded, $failed failed"
[ "$failed" -eq 0 ] || exit 1
