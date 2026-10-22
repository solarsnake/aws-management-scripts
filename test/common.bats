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

@test "preflight fails without jq" {
  if [ -x /usr/bin/jq ]; then skip "jq is in /usr/bin"; fi
  run env PATH="$BATS_TEST_DIRNAME/bin:/usr/bin:/bin" /bin/bash -c '. "$LIB"; preflight'
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://jqlang.org/download/"* ]]
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
  run bash -c '. "$LIB"; gp3_iops 100 3000; gp3_iops 4500 3000; gp3_iops 3000 6000; gp3_iops 20000 3000'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3000\n4500\n6000\n16000')" ]
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
