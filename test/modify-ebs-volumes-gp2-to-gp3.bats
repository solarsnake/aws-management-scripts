setup() {
  load test_helper
  setup_stub
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","Size":2000,"Iops":6000,"VolumeType":"gp2"},{"VolumeId":"vol-0000000b","Size":100,"Iops":300,"VolumeType":"gp2"}]}'
  fixture ec2_describe-volumes-modifications '{"VolumesModifications":[]}'
}

S="$BATS_TEST_DIRNAME/../ec2/modify-ebs-volumes-gp2-to-gp3.sh"

@test "keeps higher gp2 iops" {
  run "$S" --yes
  [ "$status" -eq 0 ]
  assert_called ec2 describe-volumes --filters\ Name=volume-type,Values=gp2
  assert_called ec2 modify-volume --volume-id\ vol-0000000a --volume-type\ gp3 --iops\ 6000 --throughput\ 250
  assert_called ec2 modify-volume --volume-id\ vol-0000000b --volume-type\ gp3 --iops\ 3000 --throughput\ 125
  [[ "$output" == *"Done: 2 succeeded, 0 failed"* ]]
}

@test "--min-iops raises the floor" {
  run "$S" --yes --min-iops 4000
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume --volume-id\ vol-0000000a --iops\ 6000
  assert_called ec2 modify-volume --volume-id\ vol-0000000b --iops\ 4000
}

@test "--throughput is passed to modify-volume" {
  run "$S" --yes --min-iops 4000 --throughput 1000
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume --volume-id\ vol-0000000b --throughput\ 1000
}

@test "--throughput above min-iops/4 is usage error" {
  run "$S" --yes --throughput 1000
  [ "$status" -eq 2 ]
  [[ "$output" == *"--throughput 1000 needs at least 4000 IOPS; raise --min-iops"* ]]
  refute_called ec2 describe-volumes
  refute_called ec2 modify-volume
}

@test "out of range values are usage errors" {
  run "$S" --yes --min-iops 2999
  [ "$status" -eq 2 ]
  run "$S" --yes --min-iops 16001
  [ "$status" -eq 2 ]
  run "$S" --yes --min-iops abc
  [ "$status" -eq 2 ]
  run "$S" --yes --throughput 124
  [ "$status" -eq 2 ]
  run "$S" --yes --throughput 1001 --min-iops 16000
  [ "$status" -eq 2 ]
  refute_called ec2 modify-volume
}

@test "skips volumes with modification in progress" {
  fixture ec2_describe-volumes-modifications '{"VolumesModifications":[{"VolumeId":"vol-0000000a","ModificationState":"modifying"}]}'
  run "$S" --yes
  [ "$status" -eq 0 ]
  assert_called ec2 describe-volumes-modifications --filters\ Name=modification-state,Values=modifying,optimizing
  refute_called ec2 modify-volume --volume-id\ vol-0000000a
  assert_called ec2 modify-volume --volume-id\ vol-0000000b
  [[ "$output" == *"Skipping vol-0000000a: modification already in progress"* ]]
}

@test "failed modifications lookup exits 1 before any change" {
  fixture_script ec2_describe-volumes-modifications 'echo "denied" >&2; exit 1'
  run "$S" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 modify-volume
}

@test "failed volume list exits 1 before any change" {
  fixture_script ec2_describe-volumes 'echo "not json"'
  run "$S" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 modify-volume
}

@test "plan table lists before and after" {
  run bash -c "'$S' --yes 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" =~ VOLUME\ +SIZE\ GiB\ +GP2\ IOPS\ +GP3\ IOPS\ +THROUGHPUT ]]
  local row
  row=$(printf '%s\n' "$output" | grep '^vol-0000000a')
  [[ "$row" =~ ^vol-0000000a\ +2000\ +6000\ +6000\ +250$ ]]
  row=$(printf '%s\n' "$output" | grep '^vol-0000000b')
  [[ "$row" =~ ^vol-0000000b\ +100\ +300\ +3000\ +125$ ]]
}

@test "--dry-run makes no modify calls" {
  run "$S" --dry-run
  [ "$status" -eq 0 ]
  refute_called ec2 modify-volume
  [[ "$output" == *"[dry-run] aws ec2 modify-volume --volume-id vol-0000000a"* ]]
}

@test "answering no exits 1" {
  run bash -c "echo n | '$S'"
  [ "$status" -eq 1 ]
  refute_called ec2 modify-volume
}

@test "nothing to do" {
  fixture ec2_describe-volumes '{"Volumes":[]}'
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  refute_called ec2 modify-volume
}

@test "nothing to do when every volume is already modifying" {
  fixture ec2_describe-volumes-modifications '{"VolumesModifications":[{"VolumeId":"vol-0000000a"},{"VolumeId":"vol-0000000b"}]}'
  run "$S"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  refute_called ec2 modify-volume
}

@test "a failed modify continues and exits 1" {
  fixture_script ec2_modify-volume 'case "$*" in *vol-0000000a*) echo "An error occurred (VolumeModificationRateExceeded)" >&2; exit 1 ;; esac; echo "{}"'
  run "$S" --yes
  [ "$status" -eq 1 ]
  [ "$(call_count ec2 modify-volume)" -eq 2 ]
  [[ "$output" == *"Failed: vol-0000000a: "*VolumeModificationRateExceeded* ]]
  [[ "$output" == *"Done: 1 succeeded, 1 failed"* ]]
}

@test "default throughput is 125 for small volumes and 250 for large ones" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","Size":500,"Iops":1500,"VolumeType":"gp2"},{"VolumeId":"vol-0000000b","Size":100,"Iops":300,"VolumeType":"gp2"},{"VolumeId":"vol-0000000c","Size":170,"Iops":510,"VolumeType":"gp2"}]}'
  run "$S" --yes
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume --volume-id\ vol-0000000a --throughput\ 250
  assert_called ec2 modify-volume --volume-id\ vol-0000000b --throughput\ 125
  assert_called ec2 modify-volume --volume-id\ vol-0000000c --throughput\ 125
}

@test "--throughput 500 applies to every volume" {
  run "$S" --yes --min-iops 3000 --throughput 500
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume --volume-id\ vol-0000000a --throughput\ 500
  assert_called ec2 modify-volume --volume-id\ vol-0000000b --throughput\ 500
}

@test "--throughput only raises: 200 gives 200 small and 250 large" {
  run "$S" --yes --throughput 200
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume --volume-id\ vol-0000000a --throughput\ 250
  assert_called ec2 modify-volume --volume-id\ vol-0000000b --throughput\ 200
}

@test "plan table shows per-volume throughput" {
  run bash -c "'$S' --yes --throughput 200 2>/dev/null"
  [[ "$(printf '%s\n' "$output" | grep '^vol-0000000a')" =~ \ 250$ ]]
  [[ "$(printf '%s\n' "$output" | grep '^vol-0000000b')" =~ \ 200$ ]]
}

@test "gp3 iops is capped at 16000" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","Size":6000,"Iops":18000,"VolumeType":"gp2"}]}'
  run "$S" --yes
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume --volume-id\ vol-0000000a --iops\ 16000
}

@test "non-JSON modifications response exits 1 before any modify" {
  fixture_script ec2_describe-volumes-modifications 'echo "not json"'
  run "$S" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  refute_called ec2 modify-volume
}
