#!/usr/bin/env bash
# Report the default encryption settings of every S3 bucket in the account.
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: list-encryption-for-s3-buckets.sh [--json] [options]

Print the default encryption of each bucket as a table on stdout, or as a JSON
array with --json. This script only reads; --dry-run and --yes are accepted
and ignored. Buckets that cannot be queried are reported with algorithm
"error" and the exit status stays 0.

Options:
  --json            Print JSON instead of a table
  --profile NAME    AWS CLI profile
  --region NAME     AWS region
  --dry-run         Accepted and ignored
  --yes             Accepted and ignored
  -h, --help        Show this help
USAGE
}

JSON=0
while [ $# -gt 0 ]; do
  common_flag "$1" "${2-}"
  if [ "$COMMON_SHIFT" -gt 0 ]; then shift "$COMMON_SHIFT"; continue; fi
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --json) JSON=1; shift ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

preflight

buckets=$(aws_ro s3api list-buckets | jq -r '.Buckets[]?.Name') || die "could not list buckets"

rows=""
make_temp rows
errf=""
make_temp errf
for b in $buckets; do
  if out=$(aws_ro s3api get-bucket-encryption --bucket "$b" 2>"$errf"); then
    if row=$(printf '%s' "$out" | jq -r --arg b "$b" '
      .ServerSideEncryptionConfiguration.Rules[0] as $r
      | [$b, $r.ApplyServerSideEncryptionByDefault.SSEAlgorithm,
         ($r.ApplyServerSideEncryptionByDefault.KMSMasterKeyID // "-"),
         ($r.BucketKeyEnabled // false | tostring), "-"] | @tsv' 2>/dev/null); then
      printf '%s\n' "$row" >> "$rows"
    else
      printf '%s\terror\t-\t-\tunknown\n' "$b" >> "$rows"
    fi
  else
    out=$(cat "$errf")
    if [[ $out == *ServerSideEncryptionConfigurationNotFoundError* ]]; then
      printf '%s\tnone\t-\t-\t-\n' "$b" >> "$rows"
    else
      code=unknown
      err_re='\(([^)]+)\)'
      if [[ $out =~ $err_re ]]; then code=${BASH_REMATCH[1]}; fi
      printf '%s\terror\t-\t-\t%s\n' "$b" "$code" >> "$rows"
    fi
  fi
done

if [ "$JSON" = 1 ]; then
  jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t"))
    | map({bucket: .[0], algorithm: .[1],
           kms_key: (if .[2] == "-" then null else .[2] end),
           bucket_key: (if .[3] == "-" then null else (.[3] == "true") end),
           error: (if .[4] == "-" then null else .[4] end)})' "$rows"
else
  { printf 'BUCKET\tALGORITHM\tKMS KEY\tBUCKET KEY\tERROR\n'; cat "$rows"; } | column -t -s $'\t'
fi
