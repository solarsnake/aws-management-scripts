setup() {
  load test_helper
  setup_stub
  fixture ec2_describe-images '{"Images":[{"BlockDeviceMappings":[{"DeviceName":"/dev/sda1","Ebs":{"SnapshotId":"snap-0000000a"}},{"DeviceName":"/dev/sdb","Ebs":{"SnapshotId":"snap-0000000b"}},{"DeviceName":"/dev/sdc","VirtualName":"ephemeral0"}]}]}'
  printf 'ami-00000001\n' > "$BATS_TEST_TMPDIR/ids.txt"
}

S="$BATS_TEST_DIRNAME/../ec2/delete-list-of-amis.sh"

@test "deregisters and reports leftover snapshots" {
  run "$S" --yes --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  assert_called ec2 deregister-image --image-id\ ami-00000001
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Left snapshot(s) for ami-00000001: snap-0000000a snap-0000000b"* ]]
}

@test "--delete-snapshots deletes backing snapshots after deregister" {
  run "$S" --yes --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 2 ]
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000a
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000b
  local d s
  d=$(grep -n '^ec2 deregister-image' "$AWS_STUB_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n '^ec2 delete-snapshot' "$AWS_STUB_LOG" | head -1 | cut -d: -f1)
  [ "$d" -lt "$s" ]
}

@test "failed deregister skips its snapshot deletes" {
  fixture_script ec2_deregister-image 'echo "An error occurred (InvalidAMIID.Unavailable)" >&2; exit 1'
  run "$S" --yes --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 1 ]
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Done: 0 succeeded, 1 failed"* ]]
}

@test "nothing to do" {
  printf '# nothing\n' > "$BATS_TEST_TMPDIR/ids.txt"
  run "$S" --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  refute_called ec2 deregister-image
}

@test "describe-images stderr noise does not hide snapshots" {
  fixture_script ec2_describe-images 'echo "warning: something odd" >&2; echo "{\"Images\":[{\"BlockDeviceMappings\":[{\"Ebs\":{\"SnapshotId\":\"snap-0000000a\"}}]}]}"'
  run "$S" --yes --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  assert_called ec2 deregister-image --image-id\ ami-00000001
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000a
}

@test "failed describe-images skips deregister and exits 1" {
  fixture_script ec2_describe-images 'echo "An error occurred (InvalidAMIID.NotFound)" >&2; exit 1'
  run "$S" --yes --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 1 ]
  refute_called ec2 deregister-image
  [[ "$output" == *"Failed: ami-00000001: "*InvalidAMIID.NotFound* ]]
}

@test "unparseable describe-images output skips deregister and exits 1" {
  fixture_script ec2_describe-images 'echo "not json"'
  run "$S" --yes --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 1 ]
  refute_called ec2 deregister-image
}

@test "--dry-run deregisters nothing" {
  run "$S" --dry-run --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  refute_called ec2 deregister-image
  refute_called ec2 delete-snapshot
}

@test "answering no deregisters nothing and exits 1" {
  run bash -c "echo n | '$S' --file '$BATS_TEST_TMPDIR/ids.txt'"
  [ "$status" -eq 1 ]
  refute_called ec2 deregister-image
}
