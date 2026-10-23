setup() {
  load test_helper
  setup_stub
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"gp2","Size":100,"Iops":300,"AvailabilityZone":"us-east-1a","Tags":[{"Key":"Name","Value":"my vol"},{"Key":"aws:cloudformation:stack-name","Value":"x"}]}]}'
  fixture ec2_create-snapshot '{"SnapshotId":"snap-0000beef"}'
  fixture ec2_create-volume '{"VolumeId":"vol-0000ffff"}'
}

S="$BATS_TEST_DIRNAME/../ec2/encrypt-unattached-ebs-volume.sh"
V=vol-0000000a

create_line() { grep '^ec2 create-volume' "$AWS_STUB_LOG"; }

@test "missing --volume-id is usage error" {
  run "$S" --yes --kms-key alias/k
  [ "$status" -eq 2 ]
  [[ "$output" == *"--volume-id"* ]]
  refute_called ec2 create-snapshot
}

@test "missing --kms-key is usage error" {
  run "$S" --yes --volume-id $V
  [ "$status" -eq 2 ]
  [[ "$output" == *"--kms-key"* ]]
  refute_called ec2 create-snapshot
}

@test "invalid --type is usage error" {
  run "$S" --yes --volume-id $V --kms-key alias/k --type gp9
  [ "$status" -eq 2 ]
  [[ "$output" == *"--type"* ]]
  refute_called ec2 create-snapshot
}

@test "attached volume is refused" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"in-use","Encrypted":false,"VolumeType":"gp2","AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error: $V is attached (state: in-use); detach it first"* ]]
  refute_called ec2 create-snapshot
}

@test "already encrypted is a no-op" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":true,"VolumeType":"gp2","AvailabilityZone":"us-east-1a"}]}'
  run "$S" --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  [[ "$output" == *"$V is already encrypted. Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  refute_called ec2 create-snapshot
}

@test "failed describe exits 1 before any mutation" {
  fixture_script ec2_describe-volumes 'echo "An error occurred (InvalidVolume.NotFound)" >&2; exit 1'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"*InvalidVolume.NotFound* ]]
  refute_called ec2 create-snapshot
}

@test "unparseable describe exits 1 before any mutation" {
  fixture_script ec2_describe-volumes 'echo "not json"'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 create-snapshot
}

@test "stderr noise does not corrupt the describe output" {
  fixture_script ec2_describe-volumes 'echo "warning: odd" >&2; echo "{\"Volumes\":[{\"VolumeId\":\"vol-0000000a\",\"State\":\"available\",\"Encrypted\":false,\"VolumeType\":\"gp2\",\"AvailabilityZone\":\"us-east-1a\"}]}"'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 create-volume)" -eq 1 ]
}

@test "keeps source type when --type is omitted" {
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 create-snapshot --volume-id\ $V "--description Temporary snapshot for encrypting $V"
  assert_called ec2 wait snapshot-completed
  assert_called ec2 create-volume --availability-zone\ us-east-1a --snapshot-id\ snap-0000beef --encrypted --kms-key-id\ alias/k --volume-type\ gp2
  local line
  line=$(create_line)
  [[ "$line" != *"--iops"* ]]
  [[ "$line" != *"--throughput"* ]]
  assert_called ec2 wait volume-available
  [[ "$output" == *"Created encrypted volume vol-0000ffff from $V."* ]]
}

@test "gp3 source keeps iops and throughput" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"gp3","Iops":6000,"Throughput":250,"AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 create-volume --volume-type\ gp3 --iops\ 6000 --throughput\ 250
}

@test "--type gp3 from gp2 uses floor iops and 125 throughput" {
  run "$S" --yes --volume-id $V --kms-key alias/k --type gp3
  [ "$status" -eq 0 ]
  assert_called ec2 create-volume --volume-type\ gp3 --iops\ 3000 --throughput\ 125
}

@test "io2 keeps provisioned iops" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"io2","Iops":9000,"AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 create-volume --volume-type\ io2 --iops\ 9000
  [[ "$(create_line)" != *"--throughput"* ]]
}

@test "tags copied plus encrypted-copy-of" {
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  local line
  line=$(create_line)
  [[ "$line" == *'"ResourceType":"volume"'* ]]
  [[ "$line" == *'{"Key":"Name","Value":"my vol"}'* ]]
  [[ "$line" == *'{"Key":"encrypted-copy-of","Value":"vol-0000000a"}'* ]]
  [[ "$line" != *"aws:cloudformation"* ]]
}

@test "temporary snapshot is deleted" {
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000beef
  refute_called ec2 delete-volume
}

@test "--delete-source deletes original last" {
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  assert_called ec2 delete-volume --volume-id\ $V
  local ops
  ops=$(grep -E '^ec2 (create-volume|wait volume-available|delete-snapshot|delete-volume)' "$AWS_STUB_LOG" | cut -d' ' -f1-3 | tr '\n' '|')
  [ "$ops" = "ec2 create-volume --availability-zone|ec2 wait volume-available|ec2 delete-snapshot --snapshot-id|ec2 delete-volume --volume-id|" ]
  [ "$(tail -n 1 "$AWS_STUB_LOG" | cut -d' ' -f1-2)" = "ec2 delete-volume" ]
}

@test "failed create-volume leaves the source and deletes the snapshot" {
  fixture_script ec2_create-volume 'echo "An error occurred (VolumeLimitExceeded)" >&2; exit 1'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-volume
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000beef
  [[ "$output" == *"error:"*VolumeLimitExceeded* ]]
  [[ "$output" == *"temporary snapshot snap-0000beef deleted"* ]]
}

@test "failed volume wait leaves the source and deletes the snapshot" {
  fixture_script ec2_wait 'case "$*" in *volume-available*) echo "Waiter VolumeAvailable failed" >&2; exit 255 ;; esac'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-volume
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000beef
  [[ "$output" == *"Waiter VolumeAvailable failed"* ]]
  [[ "$output" == *"temporary snapshot snap-0000beef deleted"* ]]
}

@test "failed snapshot wait skips create-volume and deletes the snapshot" {
  fixture_script ec2_wait 'echo "Waiter SnapshotCompleted failed" >&2; exit 255'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 create-volume
  refute_called ec2 delete-volume
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000beef
  [[ "$output" == *"Waiter SnapshotCompleted failed"* ]]
}

@test "failed create-snapshot stops with no further calls" {
  fixture_script ec2_create-snapshot 'echo "snapshot denied" >&2; exit 1'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"*"snapshot denied"* ]]
  refute_called ec2 create-volume
  refute_called ec2 delete-snapshot
  refute_called ec2 delete-volume
}

@test "failed temporary snapshot delete keeps the source and exits 1" {
  fixture_script ec2_delete-snapshot 'echo "ds denied" >&2; exit 1'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-volume
  [[ "$output" == *"ds denied"* ]]
}

@test "failed source delete exits 1" {
  fixture_script ec2_delete-volume 'echo "dv denied" >&2; exit 1'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"dv denied"* ]]
}

@test "--dry-run makes no create or delete calls" {
  run "$S" --dry-run --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 0 ]
  refute_called ec2 create-snapshot
  refute_called ec2 create-volume
  refute_called ec2 delete-snapshot
  refute_called ec2 delete-volume
  refute_called ec2 wait
  [[ "$output" == *"[dry-run] aws ec2 create-snapshot"* ]]
  [[ "$output" == *"[dry-run] aws ec2 delete-volume"* ]]
}

@test "answering no exits 1" {
  run bash -c "echo n | '$S' --volume-id $V --kms-key alias/k"
  [ "$status" -eq 1 ]
  refute_called ec2 create-snapshot
}

@test "--type gp3 warns when source iops exceed 16000" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"io2","Iops":20000,"AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k --type gp3
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: $V has 20000 IOPS; gp3 supports at most 16000"* ]]
  assert_called ec2 create-volume --volume-type\ gp3 --iops\ 16000
}

@test "create-snapshot output without SnapshotId exits 1" {
  fixture ec2_create-snapshot '{}'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 create-volume
  refute_called ec2 delete-volume
}

@test "create-volume output without VolumeId cleans up and warns" {
  fixture ec2_create-volume '{}'
  run "$S" --yes --delete-source --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  refute_called ec2 delete-volume
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000beef
  [[ "$output" == *"a volume may have been created"* ]]
  [[ "$output" == *"encrypted-copy-of=$V"* ]]
}

@test "describe with no volumes exits 1" {
  fixture ec2_describe-volumes '{"Volumes":[]}'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error: $V was not found"* ]]
  refute_called ec2 create-snapshot
}

@test "io1 source without Iops is refused before any mutation" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"io1","AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"*"no provisioned IOPS"* ]]
  refute_called ec2 create-snapshot
}

@test "--type gp3 from a 500 GiB source gets 250 throughput" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"gp2","Size":500,"AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k --type gp3
  [ "$status" -eq 0 ]
  assert_called ec2 create-volume --volume-type\ gp3 --iops\ 3000 --throughput\ 250
}

@test "--type gp3 from a 100 GiB source gets 125 throughput" {
  run "$S" --yes --volume-id $V --kms-key alias/k --type gp3
  [ "$status" -eq 0 ]
  assert_called ec2 create-volume --volume-type\ gp3 --throughput\ 125
}

@test "--type gp3 from io1 warns about the throughput" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"io1","Size":500,"Iops":9000,"AvailabilityZone":"us-east-1a"}]}'
  run "$S" --yes --volume-id $V --kms-key alias/k --type gp3
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: $V is io1; gp3 throughput will be 250 MiB/s"* ]]
  assert_called ec2 create-volume --volume-type\ gp3 --iops\ 9000 --throughput\ 250
}
