setup() {
  load test_helper
  setup_stub
  fixture ec2_describe-images '{"Images":[{"ImageId":"ami-00000001","Name":"web","Tags":[{"Key":"team","Value":"core"},{"Key":"aws:cloudformation:stack-name","Value":"x"}],"BlockDeviceMappings":[{"DeviceName":"/dev/sda1","Ebs":{"SnapshotId":"snap-0000000a"}},{"DeviceName":"/dev/sdb","Ebs":{"SnapshotId":"snap-0000000b"}},{"DeviceName":"/dev/sdc","VirtualName":"ephemeral0"}]}]}'
  fixture ec2_copy-image '{"ImageId":"ami-0000ffff"}'
}

S="$BATS_TEST_DIRNAME/../ec2/encrypt-all-amis.sh"

@test "missing --kms-key is usage error" {
  run "$S" --yes
  [ "$status" -eq 2 ]
  refute_called ec2 copy-image
}

@test "missing region fails before copying" {
  fixture_script configure_get 'exit 0'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error: no region set; pass --region or configure one for the profile"* ]]
  refute_called ec2 copy-image
}

@test "copy uses a -encrypted name" {
  run "$S" --yes --kms-key alias/k --region us-west-2
  [ "$status" -eq 0 ]
  assert_called ec2 copy-image --name\ web-encrypted --source-region\ us-west-2 --source-image-id\ ami-00000001 --encrypted --kms-key-id\ alias/k
  assert_called ec2 wait image-available --image-ids\ ami-0000ffff
  local line
  line=$(grep '^ec2 create-tags' "$AWS_STUB_LOG")
  [[ "$line" == *"--resources ami-0000ffff"* ]]
  [[ "$line" == *'"Key":"team"'* ]]
  [[ "$line" != *"aws:cloudformation"* ]]
  refute_called ec2 deregister-image
  [[ "$output" == *"  ami-00000001  web"* ]]
  [[ "$output" == *"Done: 1 succeeded, 0 failed"* ]]
}

@test "excludes backup-created AMIs" {
  fixture ec2_describe-images '{"Images":[{"ImageId":"ami-00000001","Name":"a"},{"ImageId":"ami-00000002","Name":"b","Tags":[{"Key":"aws:backup:source-resource","Value":"arn"}]}]}'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 copy-image)" -eq 1 ]
  refute_called ec2 copy-image --source-image-id\ ami-00000002
}

@test "long names are truncated to 128 characters" {
  local long
  long=$(printf 'n%.0s' $(seq 1 128))
  fixture ec2_describe-images "{\"Images\":[{\"ImageId\":\"ami-00000001\",\"Name\":\"$long\"}]}"
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 0 ]
  local line name
  line=$(grep '^ec2 copy-image' "$AWS_STUB_LOG")
  name=${line#*--name }
  name=${name%% --source-region*}
  [ "${#name}" -eq 128 ]
  [[ "$name" == *-encrypted ]]
}

@test "tags and names with spaces and quotes are preserved" {
  fixture ec2_describe-images '{"Images":[{"ImageId":"ami-00000001","Name":"My \"web\" image","Tags":[{"Key":"note","Value":"a b $c"}]}]}'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 copy-image '--name My "web" image-encrypted --source-region'
  assert_called ec2 create-tags '--tags [{"Key":"note","Value":"a b $c"}]'
}

@test "--delete-source deregisters then deletes source snapshots" {
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 deregister-image --image-id\ ami-00000001
  [ "$(call_count ec2 delete-snapshot)" -eq 2 ]
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000a
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000b
  local d s
  d=$(grep -n '^ec2 deregister-image' "$AWS_STUB_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n '^ec2 delete-snapshot' "$AWS_STUB_LOG" | head -1 | cut -d: -f1)
  [ "$d" -lt "$s" ]
}

@test "--delete-source deletes nothing when the copy fails" {
  fixture_script ec2_copy-image 'echo "An error occurred (CopyFailed)" >&2; exit 1'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 deregister-image
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Done: 0 succeeded, 1 failed"* ]]
}

@test "--delete-source deletes nothing when the wait fails" {
  fixture_script ec2_wait 'echo "Waiter ImageAvailable failed" >&2; exit 255'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 deregister-image
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Failed: ami-00000001: "*"Waiter ImageAvailable failed"* ]]
}

@test "--delete-source deletes nothing when tagging fails" {
  fixture_script ec2_create-tags 'echo "tag error" >&2; exit 1'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 deregister-image
  refute_called ec2 delete-snapshot
}

@test "failed deregister skips snapshot deletes" {
  fixture_script ec2_deregister-image 'echo "denied" >&2; exit 1'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-snapshot
  [[ "$output" == *"Done: 0 succeeded, 1 failed"* ]]
}

@test "failed candidate list exits 1 before any copy" {
  fixture_script ec2_describe-images 'echo "An error occurred (UnauthorizedOperation)" >&2; exit 1'
  run "$S" --yes --delete-source --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 copy-image
}

@test "unparseable candidate list exits 1 before any copy" {
  fixture_script ec2_describe-images 'echo "not json"'
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 copy-image
}

@test "--report writes old and new ids" {
  run "$S" --yes --kms-key alias/k --report "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/report.txt")" = "ami-00000001 ami-0000ffff" ]
}

@test "--dry-run makes no copy calls" {
  run "$S" --dry-run --delete-source --kms-key alias/k --report "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]
  refute_called ec2 copy-image
  refute_called ec2 wait
  refute_called ec2 create-tags
  refute_called ec2 deregister-image
  refute_called ec2 delete-snapshot
  [ ! -s "$BATS_TEST_TMPDIR/report.txt" ]
}

@test "answering no exits 1 with no copies" {
  run bash -c "echo n | '$S' --kms-key alias/k"
  [ "$status" -eq 1 ]
  refute_called ec2 copy-image
}

@test "nothing to do" {
  fixture ec2_describe-images '{"Images":[]}'
  run "$S" --delete-source --kms-key alias/k
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  refute_called ec2 copy-image
}
