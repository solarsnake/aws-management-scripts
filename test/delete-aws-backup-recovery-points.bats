bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  setup_stub
  fixture backup_list-recovery-points-by-backup-vault '{"RecoveryPoints":[{"RecoveryPointArn":"arn:aws:ec2:us-east-1::snapshot/snap-1"},{"RecoveryPointArn":"arn:aws:ec2:us-east-1::snapshot/snap-2"}]}'
}

S="$BATS_TEST_DIRNAME/../aws-backup/delete-aws-backup-recovery-points.sh"

@test "lists vaults when --vault is omitted" {
  fixture backup_list-backup-vaults '{"BackupVaultList":[{"BackupVaultName":"alpha"},{"BackupVaultName":"beta"}]}'
  run --separate-stderr "$S"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha\nbeta')" ]
  [ "$(call_count backup delete-recovery-point)" -eq 0 ]
}

@test "--vault without --before is usage error" {
  run "$S" --vault v1
  [ "$status" -eq 2 ]
  ! grep -q '^backup' "$AWS_STUB_LOG"
}

@test "bad date is usage error" {
  run "$S" --vault v1 --before yesterday
  [ "$status" -eq 2 ]
  ! grep -q '^backup' "$AWS_STUB_LOG"
}

@test "deletes matching recovery points after yes" {
  run bash -c "echo y | '$S' --vault v1 --before 2022-06-01T22:00:00"
  [ "$status" -eq 0 ]
  [[ "$output" == *"About to delete 2 recovery point(s) in v1 created before 2022-06-01T22:00:00."* ]]
  [ "$(call_count backup delete-recovery-point)" -eq 2 ]
  assert_called backup list-recovery-points-by-backup-vault --backup-vault-name\ v1 --by-created-before\ 2022-06-01T22:00:00
  assert_called backup delete-recovery-point --backup-vault-name\ v1 --recovery-point-arn\ arn:aws:ec2:us-east-1::snapshot/snap-1
  assert_called backup delete-recovery-point --backup-vault-name\ v1 --recovery-point-arn\ arn:aws:ec2:us-east-1::snapshot/snap-2
}

@test "--dry-run deletes nothing" {
  run "$S" --dry-run --vault v1 --before 2022-06-01
  [ "$status" -eq 0 ]
  [ "$(call_count backup delete-recovery-point)" -eq 0 ]
}

@test "answering no deletes nothing and exits 1" {
  run bash -c "echo n | '$S' --vault v1 --before 2022-06-01"
  [ "$status" -eq 1 ]
  [ "$(call_count backup delete-recovery-point)" -eq 0 ]
}

@test "nothing to do" {
  fixture backup_list-recovery-points-by-backup-vault '{"RecoveryPoints":[]}'
  run "$S" --vault v1 --before 2022-06-01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  [ "$(call_count backup delete-recovery-point)" -eq 0 ]
}

@test "a failed delete continues and exits 1" {
  fixture_script backup_delete-recovery-point 'case "$*" in *snap-1*) echo "An error occurred (InvalidRequestException)" >&2; exit 1 ;; esac'
  run "$S" --yes --vault v1 --before 2022-06-01
  [ "$status" -eq 1 ]
  [ "$(call_count backup delete-recovery-point)" -eq 2 ]
  [[ "$output" == *"Done: 1 succeeded, 1 failed"* ]]
  [[ "$output" == *"Failed: arn:aws:ec2:us-east-1::snapshot/snap-1"* ]]
}

@test "a failed list exits 1 and deletes nothing" {
  fixture_script backup_list-recovery-points-by-backup-vault 'echo "An error occurred (ResourceNotFoundException)" >&2; exit 1'
  run "$S" --yes --vault v1 --before 2022-06-01
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  [ "$(call_count backup delete-recovery-point)" -eq 0 ]
}

@test "unparseable list output exits 1 and deletes nothing" {
  fixture_script backup_list-recovery-points-by-backup-vault 'echo "not json"'
  run "$S" --yes --vault v1 --before 2022-06-01
  [ "$status" -eq 1 ]
  [[ "$output" == *"error:"* ]]
  [ "$(call_count backup delete-recovery-point)" -eq 0 ]
}
