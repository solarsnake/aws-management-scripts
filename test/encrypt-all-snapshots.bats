setup() {
  load test_helper
  setup_stub
  fixture ec2_describe-snapshots '{"Snapshots":[{"SnapshotId":"snap-0000000a","Description":"first","Tags":[{"Key":"team","Value":"core"},{"Key":"aws:cloudformation:stack-name","Value":"x"}]},{"SnapshotId":"snap-0000000b","Description":"second"}]}'
  fixture ec2_describe-images '{"Images":[]}'
  fixture ec2_copy-snapshot '{"SnapshotId":"snap-0000ffff"}'
}

S="$BATS_TEST_DIRNAME/../ec2/encrypt-all-snapshots.sh"

@test "missing --kms-key is usage error" {
  run "$S" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"--kms-key"* ]]
  refute_called ec2 copy-snapshot
}

@test "missing region fails before copying" {
  fixture_script configure_get 'exit 0'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error: no region set; pass --region or configure one for the profile"* ]]
  refute_called ec2 copy-snapshot
}

@test "excludes backup-created and AMI-backed snapshots" {
  fixture ec2_describe-snapshots '{"Snapshots":[{"SnapshotId":"snap-00000001","Description":"plain"},{"SnapshotId":"snap-00000002","Description":"bk","Tags":[{"Key":"aws:backup:source-resource","Value":"arn"}]},{"SnapshotId":"snap-00000003","Description":"ami"}]}'
  fixture ec2_describe-images '{"Images":[{"BlockDeviceMappings":[{"DeviceName":"/dev/sda1","Ebs":{"SnapshotId":"snap-00000003"}},{"DeviceName":"/dev/sdb","VirtualName":"ephemeral0"}]}]}'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 copy-snapshot)" -eq 1 ]
  assert_called ec2 copy-snapshot --source-snapshot-id\ snap-00000001
  [[ "$output" == *"Skipped 1 snapshot(s) that back AMIs; use encrypt-all-amis.sh for those."* ]]
  [[ "$output" == *"About to create 1 encrypted copies."* ]]
}

@test "copies, waits and copies tags without aws: keys" {
  run "$S" --yes --kms-key alias/k --region us-west-2
  [ "$status" -eq 0 ]
  assert_called ec2 copy-snapshot --source-region\ us-west-2 --source-snapshot-id\ snap-0000000a --encrypted --kms-key-id\ alias/k "--description Encrypted copy of snap-0000000a"
  assert_called ec2 wait snapshot-completed --snapshot-ids\ snap-0000ffff
  [ "$(call_count ec2 create-tags)" -eq 1 ]
  local line
  line=$(grep '^ec2 create-tags' "$AWS_STUB_LOG")
  [[ "$line" == *"--resources snap-0000ffff"* ]]
  [[ "$line" == *'"Key":"team"'* ]]
  [[ "$line" != *"aws:cloudformation"* ]]
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Done: 2 succeeded, 0 failed"* ]]
  [[ "$output" == *"  snap-0000000a  first"* ]]
}

@test "--delete-source deletes only after a successful copy" {
  fixture_script ec2_copy-snapshot 'case "$*" in *snap-0000000b*) echo "An error occurred (CopyFailed)" >&2; exit 1 ;; esac; echo "{\"SnapshotId\":\"snap-0000ffff\"}"'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000a
  refute_called ec2 delete-snapshot --snapshot-id\ snap-0000000b
  [ "$(call_count ec2 delete-snapshot)" -eq 1 ]
  [[ "$output" == *"Failed: snap-0000000b: "*CopyFailed* ]]
  [[ "$output" == *"Done: 1 succeeded, 1 failed"* ]]
  [[ "$output" == *"Source resources will be deleted afterwards."* ]]
}

@test "--delete-source does not delete when the wait fails" {
  fixture_script ec2_wait 'echo "Waiter SnapshotCompleted failed" >&2; exit 255'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Failed: snap-0000000a: "*"Waiter SnapshotCompleted failed"* ]]
  [[ "$output" == *"Done: 0 succeeded, 2 failed"* ]]
}

@test "--delete-source does not delete when tagging fails" {
  fixture ec2_describe-snapshots '{"Snapshots":[{"SnapshotId":"snap-0000000a","Tags":[{"Key":"team","Value":"core"}]}]}'
  fixture_script ec2_create-tags 'echo "tag error" >&2; exit 1'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Done: 0 succeeded, 1 failed"* ]]
}

@test "failed candidate list exits 1 before any copy" {
  fixture_script ec2_describe-snapshots 'echo "An error occurred (UnauthorizedOperation)" >&2; exit 1'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 copy-snapshot
  refute_called ec2 delete-snapshot
}

@test "unparseable candidate list exits 1 before any copy" {
  fixture_script ec2_describe-snapshots 'echo "not json"'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 copy-snapshot
}

@test "failed AMI lookup exits 1 before any copy" {
  fixture_script ec2_describe-images 'echo "denied" >&2; exit 1'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 copy-snapshot
}

@test "stderr noise does not corrupt the candidate list" {
  fixture_script ec2_describe-snapshots 'echo "warning: odd" >&2; echo "{\"Snapshots\":[{\"SnapshotId\":\"snap-0000000a\"}]}"'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 copy-snapshot)" -eq 1 ]
}

@test "--report writes old and new ids" {
  run "$S" --yes --kms-key alias/k --report "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/report.txt")" = "snap-0000000a snap-0000ffff
snap-0000000b snap-0000ffff" ]
}

@test "--dry-run makes no copy, tag or delete calls" {
  run "$S" --dry-run --delete-source --kms-key alias/k --report "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]
  refute_called ec2 copy-snapshot
  refute_called ec2 wait
  refute_called ec2 create-tags
  refute_called ec2 delete-snapshot
  [[ "$output" == *"[dry-run] aws ec2 copy-snapshot"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/report.txt" ]
}

@test "answering no exits 1 with no copies" {
  run bash -c "echo n | '$S' --kms-key alias/k"
  [ "$status" -eq 1 ]
  refute_called ec2 copy-snapshot
}

@test "nothing to do" {
  fixture ec2_describe-snapshots '{"Snapshots":[]}'
  run "$S" --delete-source --kms-key alias/k
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  refute_called ec2 copy-snapshot
}

@test "AMI lookup includes disabled AMIs" {
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 describe-images --owners\ self --include-disabled
}

@test "malformed describe-images output fails closed" {
  fixture ec2_describe-images '{}'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 copy-snapshot
}
