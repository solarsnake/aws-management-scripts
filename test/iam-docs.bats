# Checks that every AWS call a script makes on its happy path is listed in the
# "IAM actions" block under that script's heading in README.md.

setup() {
  load test_helper
  setup_stub
  README="$BATS_TEST_DIRNAME/../README.md"
  printf 'ami-00000001\n' > "$BATS_TEST_TMPDIR/ids.txt"
  printf 'snap-0000000a\n' > "$BATS_TEST_TMPDIR/snaps.txt"
}

# readme_iam_actions SCRIPT_PATH: print the lines of the fenced block that
# follows "IAM actions" under the README heading containing SCRIPT_PATH.
readme_iam_actions() {
  awk -v path="$1" '
    /^#/ { in_section = (index($0, path) > 0); armed = 0; in_block = 0; next }
    !in_section { next }
    in_block && /^```/ { exit }
    in_block { print; next }
    /IAM actions/ { armed = 1; next }
    armed && /^```/ { in_block = 1 }
  ' "$README"
}

# aws_log_actions: map each logged call to its IAM action, one per line.
aws_log_actions() {
  local line svc op arg rest
  while IFS= read -r line; do
    read -r svc op arg _ <<< "$line"
    case "$svc" in
      configure) continue ;;
      s3api) svc=s3 ;;
    esac
    if [ "$svc" = ec2 ] && [ "$op" = wait ]; then
      case "${arg-}" in
        snapshot-completed) printf 'ec2:DescribeSnapshots\n' ;;
        image-available) printf 'ec2:DescribeImages\n' ;;
        volume-available) printf 'ec2:DescribeVolumes\n' ;;
        *) printf 'unmapped-waiter:%s\n' "${arg-}" ;;
      esac
      continue
    fi
    rest=$(printf '%s' "$op" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2) }')
    case "$svc:$rest" in
      # IAM names these two S3 permissions differently from the API operations.
      s3:ListBuckets) printf 's3:ListAllMyBuckets\n' ;;
      s3:GetBucketEncryption) printf 's3:GetEncryptionConfiguration\n' ;;
      *) printf '%s:%s\n' "$svc" "$rest" ;;
    esac
  done < "$AWS_STUB_LOG"
}

# assert_documented SCRIPT_PATH: every logged action is in the README block.
assert_documented() {
  local documented actions a missing=""
  documented=$(readme_iam_actions "$1")
  if [ -z "$documented" ]; then
    echo "no IAM actions block under a heading containing $1" >&2
    return 1
  fi
  actions=$(aws_log_actions | sort -u)
  [ -n "$actions" ]
  for a in $actions; do
    if ! printf '%s\n' "$documented" | grep -qxF "$a"; then missing="$missing $a"; fi
  done
  if [ -n "$missing" ]; then
    echo "not documented for $1:$missing" >&2
    return 1
  fi
  printf '%s\n' "$actions" | grep -qxF sts:GetCallerIdentity
}

@test "iam-docs: aws-backup/delete-aws-backup-recovery-points.sh" {
  fixture backup_list-backup-vaults '{"BackupVaultList":[{"BackupVaultName":"v1"}]}'
  fixture backup_list-recovery-points-by-backup-vault '{"RecoveryPoints":[{"RecoveryPointArn":"arn:aws:ec2:us-east-1::snapshot/snap-1"}]}'
  S="$BATS_TEST_DIRNAME/../aws-backup/delete-aws-backup-recovery-points.sh"
  run "$S"
  [ "$status" -eq 0 ]
  run "$S" --yes --vault v1 --before 2022-06-01
  [ "$status" -eq 0 ]
  assert_called backup delete-recovery-point
  assert_documented aws-backup/delete-aws-backup-recovery-points.sh
}

@test "iam-docs: ec2/delete-list-of-amis.sh" {
  fixture ec2_describe-images '{"Images":[{"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-0000000a"}}]}]}'
  run "$BATS_TEST_DIRNAME/../ec2/delete-list-of-amis.sh" --yes --delete-snapshots --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  assert_called ec2 delete-snapshot
  assert_documented ec2/delete-list-of-amis.sh
}

@test "iam-docs: ec2/delete-list-of-snapshots.sh" {
  run "$BATS_TEST_DIRNAME/../ec2/delete-list-of-snapshots.sh" --yes --file "$BATS_TEST_TMPDIR/snaps.txt"
  [ "$status" -eq 0 ]
  assert_called ec2 delete-snapshot
  assert_documented ec2/delete-list-of-snapshots.sh
}

@test "iam-docs: ec2/encrypt-all-amis.sh" {
  fixture ec2_describe-images '{"Images":[{"ImageId":"ami-00000001","Name":"web","Tags":[{"Key":"team","Value":"core"}],"BlockDeviceMappings":[{"Ebs":{"SnapshotId":"snap-0000000a"}}]}]}'
  fixture ec2_copy-image '{"ImageId":"ami-0000ffff"}'
  run "$BATS_TEST_DIRNAME/../ec2/encrypt-all-amis.sh" --yes --delete-source --kms-key alias/k --report "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 0 ]
  assert_called ec2 deregister-image
  assert_called ec2 delete-snapshot
  assert_documented ec2/encrypt-all-amis.sh
}

@test "iam-docs: ec2/encrypt-all-snapshots.sh" {
  fixture ec2_describe-snapshots '{"Snapshots":[{"SnapshotId":"snap-0000000a","Description":"first","Tags":[{"Key":"team","Value":"core"}]}]}'
  fixture ec2_describe-images '{"Images":[]}'
  fixture ec2_copy-snapshot '{"SnapshotId":"snap-0000ffff"}'
  run "$BATS_TEST_DIRNAME/../ec2/encrypt-all-snapshots.sh" --yes --delete-source --kms-key alias/k --report "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 0 ]
  assert_called ec2 delete-snapshot --snapshot-id\ snap-0000000a
  assert_documented ec2/encrypt-all-snapshots.sh
}

@test "iam-docs: ec2/encrypt-unattached-ebs-volume.sh" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","State":"available","Encrypted":false,"VolumeType":"gp2","Size":100,"Iops":300,"AvailabilityZone":"us-east-1a","Tags":[{"Key":"Name","Value":"v"}]}]}'
  fixture ec2_create-snapshot '{"SnapshotId":"snap-0000beef"}'
  fixture ec2_create-volume '{"VolumeId":"vol-0000ffff"}'
  run "$BATS_TEST_DIRNAME/../ec2/encrypt-unattached-ebs-volume.sh" --yes --delete-source --volume-id vol-0000000a --kms-key alias/k --type gp3
  [ "$status" -eq 0 ]
  assert_called ec2 delete-volume
  assert_documented ec2/encrypt-unattached-ebs-volume.sh
}

@test "iam-docs: ec2/modify-ebs-volumes-gp2-to-gp3.sh" {
  fixture ec2_describe-volumes '{"Volumes":[{"VolumeId":"vol-0000000a","Size":100,"Iops":300,"VolumeType":"gp2"}]}'
  fixture ec2_describe-volumes-modifications '{"VolumesModifications":[]}'
  run "$BATS_TEST_DIRNAME/../ec2/modify-ebs-volumes-gp2-to-gp3.sh" --yes --min-iops 4000 --throughput 200
  [ "$status" -eq 0 ]
  assert_called ec2 modify-volume
  assert_documented ec2/modify-ebs-volumes-gp2-to-gp3.sh
}

@test "iam-docs: s3/list-encryption-for-s3-buckets.sh" {
  fixture s3api_list-buckets '{"Buckets":[{"Name":"b1"}]}'
  fixture s3api_get-bucket-encryption '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
  run "$BATS_TEST_DIRNAME/../s3/list-encryption-for-s3-buckets.sh" --yes
  [ "$status" -eq 0 ]
  assert_called s3api get-bucket-encryption
  assert_documented s3/list-encryption-for-s3-buckets.sh
}
