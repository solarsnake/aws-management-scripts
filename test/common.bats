#!/usr/bin/env bats

load test_helper

setup() {
  setup_stub
  LIB="$SCRIPT_DIR/lib/common.sh"
  export LIB
}

@test "common_flag sets profile and shift 2" {
  run bash -c '. "$LIB"; common_flag --profile dev x; echo "$PROFILE $COMMON_SHIFT"'
  [ "$status" -eq 0 ]
  [ "$output" = "dev 2" ]
}

@test "common_flag missing value is usage error" {
  run bash -c '. "$LIB"; common_flag --profile ""'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--profile requires a value"* ]]
}

@test "common_flag unknown arg leaves shift 0" {
  run bash -c '. "$LIB"; common_flag --bogus x; echo "$COMMON_SHIFT"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "aws_rw in dry-run makes no call" {
  run bash -c '. "$LIB"; DRY_RUN=1; aws_rw ec2 delete-snapshot --snapshot-id snap-1 2>&1 >/dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] aws ec2 delete-snapshot"* ]]
  [ ! -s "$AWS_STUB_LOG" ]
}

@test "aws_ro passes profile and region" {
  run bash -c '. "$LIB"; PROFILE=p; REGION=r; aws_ro ec2 describe-volumes'
  [ "$status" -eq 0 ]
  assert_called ec2 describe-volumes "--profile p --region r --output json"
}

@test "confirm accepts y and yes" {
  run bash -c '. "$LIB"; echo y | confirm "Go?"'
  [ "$status" -eq 0 ]
  run bash -c '. "$LIB"; echo YES | confirm "Go?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Go? [y/N] "* ]]
}

@test "confirm rejects n, empty and EOF" {
  run bash -c '. "$LIB"; echo n | confirm "Go?"'
  [ "$status" -eq 1 ]
  run bash -c '. "$LIB"; echo "" | confirm "Go?"'
  [ "$status" -eq 1 ]
  run bash -c '. "$LIB"; confirm "Go?" < /dev/null'
  [ "$status" -eq 1 ]
}

@test "confirm skipped with --yes" {
  run bash -c '. "$LIB"; common_flag --yes; confirm "Go?" < /dev/null'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "preflight prints account and region" {
  run bash -c '. "$LIB"; preflight'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Account: 123456789012  Region: us-east-1  Profile: default"* ]]
}

# Build a PATH dir holding only the named tools (plus the stub aws if wanted).
make_tool_dir() {
  local with_aws=$1 t src
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS"
  for t in bash env basename mktemp rm cat jq; do
    src=$(command -v "$t") || continue
    ln -sf "$src" "$TOOLS/$t"
  done
  if [ "$with_aws" = 1 ]; then ln -sf "$BATS_TEST_DIRNAME/bin/aws" "$TOOLS/aws"; fi
}

@test "preflight fails without jq" {
  make_tool_dir 1
  rm_jq="$TOOLS/jq"
  unlink "$rm_jq"
  run env PATH="$TOOLS" "$TOOLS/bash" -c '. "$LIB"; preflight'
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq not found"* ]]
  [[ "$output" == *"https://jqlang.org/download/"* ]]
}

@test "preflight fails without aws" {
  make_tool_dir 0
  run env PATH="$TOOLS" "$TOOLS/bash" -c '. "$LIB"; preflight'
  [ "$status" -eq 1 ]
  [[ "$output" == *"aws CLI not found"* ]]
  [[ "$output" == *"https://aws.amazon.com/cli/"* ]]
}

@test "library works under set -euo pipefail with empty profile and region" {
  run bash -c 'set -euo pipefail; . "$LIB"; aws_ro sts get-caller-identity >/dev/null; make_temp T; [ -f "$T" ]; echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  assert_called sts get-caller-identity "--output json"
}

@test "assert_called matches the operation exactly" {
  printf 'ec2 create-tags --resources x\n' > "$AWS_STUB_LOG"
  run refute_called ec2 create-tag
  [ "$status" -eq 0 ]
  assert_called ec2 create-tags
}

@test "require_region dies when unset" {
  fixture_script configure_get ''
  run bash -c '. "$LIB"; require_region'
  [ "$status" -eq 1 ]
  [[ "$output" == *"error: no region set; pass --region or configure one for the profile"* ]]
}

@test "read_id_list strips CR, comments and blanks" {
  printf 'snap-1\r\n\r\n# comment\r\n  snap-2  \n\nsnap-3' > "$BATS_TEST_TMPDIR/ids"
  run bash -c '. "$LIB"; read_id_list "$1" "^snap-[0-9]+$"' _ "$BATS_TEST_TMPDIR/ids"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'snap-1\nsnap-2\nsnap-3')" ]
}

@test "read_id_list rejects bad id with exit 2" {
  printf 'snap-1\nbogus\n' > "$BATS_TEST_TMPDIR/ids"
  run bash -c '. "$LIB"; read_id_list "$1" "^snap-[0-9]+$"' _ "$BATS_TEST_TMPDIR/ids"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid ID on line 2: bogus"* ]]
}

@test "gp3_iops floors at min and caps at 16000" {
  run bash -c '. "$LIB"; gp3_iops 100 3000; gp3_iops 4500 3000; gp3_iops 3000 6000; gp3_iops 20000 3000; gp3_iops null 3000; gp3_iops "" 3000'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3000\n4500\n6000\n16000\n3000\n3000')" ]
}

@test "copyable_tags_json drops aws: keys and handles null" {
  run bash -c '. "$LIB"; echo "[{\"Key\":\"aws:x\",\"Value\":\"1\"},{\"Key\":\"Name\",\"Value\":\"a b\"}]" | copyable_tags_json'
  [ "$output" = '[{"Key":"Name","Value":"a b"}]' ]
  run bash -c '. "$LIB"; echo null | copyable_tags_json'
  [ "$output" = '[]' ]
  run bash -c '. "$LIB"; copyable_tags_json < /dev/null'
  [ "$output" = '[]' ]
}

@test "temp files are removed on exit" {
  run bash -c '. "$LIB"; make_temp T; [ -f "$T" ]; echo "$T"'
  [ "$status" -eq 0 ]
  [ ! -e "$output" ]
}

# A wait fixture that reports "Max attempts exceeded" for the first $1 calls.
timeout_wait_fixture() {
  fixture_script ec2_wait "n=\$(cat '$BATS_TEST_TMPDIR/n' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$BATS_TEST_TMPDIR/n'
if [ \$n -le $1 ]; then echo 'Waiter SnapshotCompleted failed: Max attempts exceeded' >&2; exit 255; fi"
}

@test "aws_wait retries after Max attempts exceeded" {
  timeout_wait_fixture 1
  run bash -c '. "$LIB"; aws_wait snapshot-completed --snapshot-ids snap-1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Still waiting..."* ]]
  [ "$(call_count ec2 wait)" -eq 2 ]
}

@test "aws_wait gives up after WAIT_ROUNDS rounds" {
  timeout_wait_fixture 100
  run bash -c '. "$LIB"; WAIT_ROUNDS=3 aws_wait snapshot-completed --snapshot-ids snap-1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Max attempts exceeded"* ]]
  [ "$(call_count ec2 wait)" -eq 3 ]
}

@test "aws_wait fails at once on any other error" {
  fixture_script ec2_wait 'echo "Waiter SnapshotCompleted failed: Waiter encountered a terminal failure state" >&2; exit 255'
  run bash -c '. "$LIB"; aws_wait snapshot-completed --snapshot-ids snap-1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal failure state"* ]]
  [ "$(call_count ec2 wait)" -eq 1 ]
}

@test "gp3_default_throughput is 125 up to 170 GiB and 250 above" {
  run bash -c '. "$LIB"; gp3_default_throughput 1; gp3_default_throughput 170; gp3_default_throughput 171; gp3_default_throughput ""'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '125\n125\n250\n125')" ]
}
