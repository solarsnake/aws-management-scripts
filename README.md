# AWS Management Scripts

![CI](https://github.com/solarsnake/aws-management-scripts/actions/workflows/ci.yml/badge.svg)

Small, safe AWS CLI scripts for EBS, AMI, snapshot, Backup and S3 housekeeping. Every destructive script has a dry run and asks before it changes anything.

## Requirements

- bash 3.2 or newer (the macOS default works)
- [AWS CLI v2](https://aws.amazon.com/cli/)
- [jq](https://jqlang.org/download/)
- AWS credentials from the usual CLI configuration; pick a profile per run with `--profile`

## Common options

| Option | Meaning |
| --- | --- |
| `--profile NAME` | AWS CLI profile to use |
| `--region NAME` | AWS region to use |
| `--dry-run` | Show what would change and change nothing. Read-only calls still run, and no confirmation is asked |
| `--yes` | Skip the confirmation prompt |
| `-h`, `--help` | Show usage |

Messages and prompts go to stderr, and data (vault names, the bucket table or JSON) goes to stdout. Exit codes are 0 on success (including "Nothing to do."), 1 on a runtime or AWS error or when you answer no, and 2 on a usage error. A batch keeps going when one item fails: it prints `Failed: <id>: <reason>`, finishes the rest, prints `Done: N succeeded, M failed` and exits 1.

The encrypt scripts need a KMS key (ID, ARN or alias) that the caller is allowed to use. They copy tags except those starting with `aws:`, and the copy scripts need a region from `--region` or the profile. Long copies are waited on for up to about 2 hours, and `WAIT_ROUNDS` can be set in the environment to change that (12 rounds by default).

## Scripts
| Script | What it does | Changes resources |
| --- | --- | --- |
| [aws-backup/delete-aws-backup-recovery-points.sh](#aws-backupdelete-aws-backup-recovery-pointssh) | Lists backup vaults, or deletes recovery points older than a date | yes |
| [ec2/delete-list-of-amis.sh](#ec2delete-list-of-amissh) | Deregisters the AMIs in a list, optionally deleting their snapshots | yes |
| [ec2/delete-list-of-snapshots.sh](#ec2delete-list-of-snapshotssh) | Deletes the snapshots in a list | yes |
| [ec2/encrypt-all-amis.sh](#ec2encrypt-all-amissh) | Copies unencrypted AMIs into encrypted ones | yes |
| [ec2/encrypt-all-snapshots.sh](#ec2encrypt-all-snapshotssh) | Copies unencrypted snapshots into encrypted ones | yes |
| [ec2/encrypt-unattached-ebs-volume.sh](#ec2encrypt-unattached-ebs-volumesh) | Replaces an unattached volume with an encrypted copy | yes |
| [ec2/modify-ebs-volumes-gp2-to-gp3.sh](#ec2modify-ebs-volumes-gp2-to-gp3sh) | Converts gp2 volumes to gp3 | yes |
| [s3/list-encryption-for-s3-buckets.sh](#s3list-encryption-for-s3-bucketssh) | Reports the default encryption of each bucket | no |

Each script also calls `sts:GetCallerIdentity` at startup. The `IAM actions` block in each section lists what the script calls, so you can build a least-privilege policy. `test/iam-docs.bats` checks these blocks against the calls the scripts really make.

### aws-backup/delete-aws-backup-recovery-points.sh

Without `--vault` it prints the vault names. With `--vault` it deletes every recovery point in that vault created before the given date. Its own flags are `--vault NAME` and `--before DATE` (`YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS[Z]`, required with `--vault`).  
IAM actions:
```
sts:GetCallerIdentity
backup:ListBackupVaults
backup:ListRecoveryPointsByBackupVault
backup:DeleteRecoveryPoint
```
### ec2/delete-list-of-amis.sh

Deregisters every AMI in a file, one ID per line. With `--delete-snapshots` it also deletes the snapshots behind each AMI; without it, it prints the snapshots left behind. Blank lines and `#` comments are ignored, and the whole list is validated before any AWS call. Its own flags are `--file FILE|-` (required; `-` reads stdin and then needs `--yes` or `--dry-run`) and `--delete-snapshots`.  
IAM actions:
```
sts:GetCallerIdentity
ec2:DescribeImages
ec2:DeregisterImage
ec2:DeleteSnapshot
```
### ec2/delete-list-of-snapshots.sh

Deletes every snapshot in a file, one ID per line, with the same list rules as above. Its own flag is `--file FILE|-` (required; `-` reads stdin and then needs `--yes` or `--dry-run`).  
IAM actions:
```
sts:GetCallerIdentity
ec2:DeleteSnapshot
```
### ec2/encrypt-all-amis.sh

Copies every AMI you own that has unencrypted snapshots into an encrypted AMI named `<name>-encrypted`. AMIs created by AWS Backup are skipped. Its own flags are `--kms-key KEY` (required), `--delete-source` (deregisters each original and deletes its snapshots once the copy is available and tagged) and `--report FILE` (one `<old-id> <new-id>` line per copy).

```
$ ec2/encrypt-all-amis.sh --kms-key alias/ebs-key --dry-run
Account: 123456789012  Region: us-east-1  Profile: default
  ami-0a1b2c3d4e5f60001  web
About to create 1 encrypted copies.
[dry-run] aws ec2 copy-image --name web-encrypted --source-region us-east-1 --source-image-id ami-0a1b2c3d4e5f60001 --encrypted --kms-key-id alias/ebs-key
Dry run: 1 AMI(s) would be copied.
```  
IAM actions:
```
sts:GetCallerIdentity
ec2:DescribeImages
ec2:CopyImage
ec2:CreateTags
ec2:DeregisterImage
ec2:DeleteSnapshot
```
### ec2/encrypt-all-snapshots.sh

Copies every unencrypted snapshot you own into an encrypted snapshot. Snapshots created by AWS Backup and snapshots that back an AMI, including disabled AMIs, are skipped; use `encrypt-all-amis.sh` for those. Its own flags are `--kms-key KEY` (required), `--delete-source` (deletes each original once its copy is complete and tagged) and `--report FILE`.  
IAM actions:
```
sts:GetCallerIdentity
ec2:DescribeSnapshots
ec2:DescribeImages
ec2:CopySnapshot
ec2:CreateTags
ec2:DeleteSnapshot
```
### ec2/encrypt-unattached-ebs-volume.sh

Encrypts an unattached volume by snapshotting it and creating an encrypted volume from the snapshot in the same availability zone. The temporary snapshot is deleted afterwards, and if a step fails the original volume is left alone. Its own flags are `--volume-id ID` and `--kms-key KEY` (both required), `--type TYPE` (defaults to the source type; gp3 throughput follows the same size rule as the gp2 to gp3 script) and `--delete-source`.  
IAM actions:
```
sts:GetCallerIdentity
ec2:DescribeVolumes
ec2:CreateSnapshot
ec2:DescribeSnapshots
ec2:CreateVolume
ec2:CreateTags
ec2:DeleteSnapshot
ec2:DeleteVolume
```
### ec2/modify-ebs-volumes-gp2-to-gp3.sh

Converts every gp2 volume in the region to gp3, keeping each volume's IOPS when that is above the minimum (capped at 16000) and skipping volumes with a modification in progress. Throughput is 125 MiB/s up to 170 GiB and 250 MiB/s above. Its own flags are `--min-iops N` (3000 to 16000) and `--throughput N` (125 to 1000, at most `min-iops / 4`), which only raises the default.

```
$ ec2/modify-ebs-volumes-gp2-to-gp3.sh --dry-run
Account: 123456789012  Region: us-east-1  Profile: default
VOLUME                 SIZE GiB  GP2 IOPS  GP3 IOPS  THROUGHPUT
vol-0a1b2c3d4e5f60001       100       300      3000         125
vol-0a1b2c3d4e5f60002       500      1500      3000         250
About to convert 2 volume(s) to gp3.
[dry-run] aws ec2 modify-volume --volume-id vol-0a1b2c3d4e5f60001 --volume-type gp3 --iops 3000 --throughput 125
[dry-run] aws ec2 modify-volume --volume-id vol-0a1b2c3d4e5f60002 --volume-type gp3 --iops 3000 --throughput 250
Dry run: 2 volume(s) would be modified.
```  
IAM actions:
```
sts:GetCallerIdentity
ec2:DescribeVolumes
ec2:DescribeVolumesModifications
ec2:ModifyVolume
```
### s3/list-encryption-for-s3-buckets.sh

Prints the default encryption of each bucket as a table, and only reads. A bucket that cannot be queried shows algorithm `error` with the reason, and a bucket with no default encryption shows `none`. Its own flag is `--json`, which prints a JSON array instead.

```
$ s3/list-encryption-for-s3-buckets.sh
BUCKET        ALGORITHM  KMS KEY                                     BUCKET KEY  ERROR
logs-archive  aws:kms    arn:aws:kms:us-east-1:123456789012:key/abc  true        -
app-assets    AES256     -                                           false       -
scratch       none       -                                           -           -
locked        error      -                                           -           AccessDenied
```  
IAM actions:
```
sts:GetCallerIdentity
s3:ListAllMyBuckets
s3:GetEncryptionConfiguration
```

## Safety notes

- Run with `--dry-run` first. It prints the commands that would run and changes nothing.
- The `--delete-*` options and the delete scripts are irreversible. Check the copies or the `--report` file first.

## Running the tests

```
bats test
shellcheck -x lib/*.sh */*.sh test/bin/aws
```

## License

GPLv3 (GPL-3.0-or-later). See [LICENSE](LICENSE).
