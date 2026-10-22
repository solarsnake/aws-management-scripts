#!/usr/bin/env bash
# Shared helpers for the AWS management scripts. Source this file; do not run it.

PROFILE=""
REGION=""
DRY_RUN=0
ASSUME_YES=0
COMMON_SHIFT=0
_COMMON_TEMP_FILES=()

log() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  local msg=$1 code=${2-1}
  printf 'error: %s\n' "$msg" >&2
  exit "$code"
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf "Try '%s --help'.\n" "$(basename "$0")" >&2
  exit 2
}

# Handle --profile, --region, --dry-run and --yes. Sets COMMON_SHIFT to the
# number of arguments consumed (0 when ARG is not a common flag).
# shellcheck disable=SC2034 # COMMON_SHIFT is read by the scripts that source this file
common_flag() {
  COMMON_SHIFT=0
  case "${1-}" in
    --profile | --region)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then usage_error "$1 requires a value"; fi
      if [ "$1" = "--profile" ]; then PROFILE=$2; else REGION=$2; fi
      COMMON_SHIFT=2
      ;;
    --dry-run) DRY_RUN=1; COMMON_SHIFT=1 ;;
    --yes) ASSUME_YES=1; COMMON_SHIFT=1 ;;
  esac
  return 0
}

# Run aws with the selected profile and region, always as JSON.
aws_ro() {
  local extra=()
  if [ -n "$PROFILE" ]; then extra+=(--profile "$PROFILE"); fi
  if [ -n "$REGION" ]; then extra+=(--region "$REGION"); fi
  aws "$@" ${extra[@]+"${extra[@]}"} --output json
}

# Like aws_ro, but with DRY_RUN=1 only logs the command.
aws_rw() {
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] aws $*"
    return 0
  fi
  aws_ro "$@"
}

# Ask PROMPT on stderr; succeed only for y/yes. Skipped by --yes and --dry-run.
confirm() {
  local answer=""
  if [ "$ASSUME_YES" = 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r answer || true
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
  esac
  return 1
}

# Print the region in effect: --region, else the configured one, else nothing.
effective_region() {
  if [ -n "$REGION" ]; then
    printf '%s\n' "$REGION"
    return 0
  fi
  local extra=()
  if [ -n "$PROFILE" ]; then extra+=(--profile "$PROFILE"); fi
  aws configure get region ${extra[@]+"${extra[@]}"} 2>/dev/null || true
}

require_region() {
  local r
  r=$(effective_region)
  if [ -z "$r" ]; then die "no region set; pass --region or configure one for the profile"; fi
  printf '%s\n' "$r"
}

# Check tools and credentials, then log the account in use.
preflight() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found; install it from https://aws.amazon.com/cli/"
  command -v jq >/dev/null 2>&1 || die "jq not found; install it from https://jqlang.org/download/"
  local ident account region
  ident=$(aws_ro sts get-caller-identity) || die "could not get AWS caller identity; check your credentials"
  account=$(printf '%s' "$ident" | jq -r '.Account')
  region=$(effective_region)
  log "Account: $account  Region: ${region:-(not set)}  Profile: ${PROFILE:-default}"
}

# make_temp VAR: create a temp file, assign its path to VAR, remove it on exit.
make_temp() {
  local f
  f=$(mktemp) || die "could not create a temp file"
  _COMMON_TEMP_FILES+=("$f")
  printf -v "$1" '%s' "$f"
}

_common_cleanup() {
  local f
  for f in ${_COMMON_TEMP_FILES[@]+"${_COMMON_TEMP_FILES[@]}"}; do
    rm -f "$f"
  done
}
# Sourcing scripts must not set their own EXIT trap; it would replace this one
# and leak the temp files.
trap _common_cleanup EXIT

# read_id_list FILE PATTERN: print the IDs in FILE (or stdin for -), one per
# line. Ignores CR, blank lines and # comments; rejects IDs not matching PATTERN.
# Callers must capture the output first (ids=$(read_id_list ...)) so that a bad
# line exits 2 before any AWS call is made.
read_id_list() {
  local file=$1 pattern=$2 line n=0
  if [ "$file" = "-" ]; then
    file=/dev/stdin
  elif [ ! -r "$file" ]; then
    usage_error "cannot read file: $file"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line//$'\r'/}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in "" | "#"*) continue ;; esac
    if ! [[ $line =~ $pattern ]]; then usage_error "invalid ID on line $n: $line"; fi
    printf '%s\n' "$line"
  done < "$file"
}

# gp3_iops SOURCE_IOPS MIN_IOPS: min(16000, max(MIN_IOPS, SOURCE_IOPS)).
gp3_iops() {
  local v=$1
  case "$v" in '' | *[!0-9]*) v=0 ;; esac
  if [ "$v" -lt "$2" ]; then v=$2; fi
  if [ "$v" -gt 16000 ]; then v=16000; fi
  printf '%s\n' "$v"
}

# Read a JSON tag array on stdin; print it compact without aws:* keys.
copyable_tags_json() {
  local input
  input=$(cat)
  if [ -z "$input" ]; then input=null; fi
  printf '%s' "$input" | jq -c '(. // []) | map(select(.Key | startswith("aws:") | not))'
}
