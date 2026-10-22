# AWS Management Scripts

![CI](https://github.com/solarsnake/aws-management-scripts/actions/workflows/ci.yml/badge.svg)

Small, safe AWS CLI scripts for EBS, AMI, snapshot, Backup and S3 housekeeping. Every destructive script has a dry run and asks before it changes anything.

## Requirements

- bash 3.2 or newer (the macOS default works)
- [AWS CLI v2](https://aws.amazon.com/cli/)
- [jq](https://jqlang.org/download/)

Credentials come from the usual AWS CLI configuration. Pick a profile per run with `--profile`.

## Common options

Every script accepts these.

| Option | Meaning |
| --- | --- |
| `--profile NAME` | AWS CLI profile to use |
| `--region NAME` | AWS region to use |
| `--dry-run` | Show what would change and change nothing. Read-only calls still run, and no confirmation is asked |
| `--yes` | Skip the confirmation prompt |
| `-h`, `--help` | Show usage |

Status messages and prompts go to stderr. Data (vault names, the bucket table or JSON) goes to stdout.

Exit codes: 0 on success (including "Nothing to do."), 1 on a runtime or AWS error or when you answer no at the confirmation, 2 on a usage error.

A batch keeps going when one item fails. It prints `Failed: <id>: <reason>` for that item, finishes the rest, prints `Done: N succeeded, M failed` and exits 1.

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

Each script also calls `sts:GetCallerIdentity` at startup and prints the account, region and profile it is using. The `IAM actions` block in each section lists what the script calls, so you can build a least-privilege policy. `test/iam-docs.bats` checks these blocks against the calls the scripts really make.

### aws-backup/delete-aws-backup-recovery-points.sh

Without `--vault` it prints the vault names, one per line. With `--vault` it deletes every recovery point in that vault created before the given date.

```
$ aws-backup/delete-aws-backup-recovery-points.sh --vault prod-daily --before 2025-01-01
Account: 123456789012  Region: us-east-1  Profile: default
About to delete 2 recovery point(s) in prod-daily created before 2025-01-01.
Delete them? [y/N] y
Done: 2 succeeded, 0 failed
```

| Option | Meaning |
| --- | --- |
| `--vault NAME` | Backup vault to clean |
| `--before DATE` | Required with `--vault`. `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS[Z]` |

**IAM actions**

```
sts:GetCallerIdentity
backup:ListBackupVaults
backup:ListRecoveryPointsByBackupVault
backup:DeleteRecoveryPoint
```

### ec2/delete-list-of-amis.sh

Deregisters every AMI in a file, one ID per line. Use `-` to read the list from stdin. Blank lines and lines starting with `#` are ignored, and the whole list is validated before any AWS call. Without `--delete-snapshots` it prints the snapshots left behind.

```
$ ec2/delete-list-of-amis.sh --file amis.txt
Account: 123456789012  Region: us-east-1  Profile: default
About to deregister 1 AMI(s).
Continue? [y/N] y
Left snapshot(s) for ami-0a1b2c3d4e5f60001: snap-0a1b2c3d4e5f60001
Done: 1 succeeded, 0 failed
```

| Option | Meaning |
| --- | --- |
| `--file FILE\|-` | File of AMI IDs (required) |
| `--delete-snapshots` | Also delete the snapshots backing each deregistered AMI |

**IAM actions**

```
sts:GetCallerIdentity
ec2:DescribeImages
ec2:DeregisterImage
ec2:DeleteSnapshot
```

### ec2/delete-list-of-snapshots.sh

Deletes every snapshot in a file, one ID per line, with the same list rules as above.

```
$ ec2/delete-list-of-snapshots.sh --file snapshots.txt
Account: 123456789012  Region: us-east-1  Profile: default
About to delete 2 snapshot(s).
Delete them? [y/N] y
Done: 2 succeeded, 0 failed
```

| Option | Meaning |
| --- | --- |
| `--file FILE\|-` | File of snapshot IDs (required) |

**IAM actions**

```
sts:GetCallerIdentity
ec2:DeleteSnapshot
```

### ec2/encrypt-all-amis.sh

Copies every AMI you own that has unencrypted snapshots into an encrypted AMI named `<name>-encrypted`. AMIs created by AWS Backup are skipped. Tags are copied except those starting with `aws:`. It needs a region, from `--region` or the profile.

```
$ ec2/encrypt-all-amis.sh --kms-key alias/ebs-key --dry-run
Account: 123456789012  Region: us-east-1  Profile: default
  ami-0a1b2c3d4e5f60001  web
About to create 1 encrypted copies.
[dry-run] aws ec2 copy-image --name web-encrypted --source-region us-east-1 --source-image-id ami-0a1b2c3d4e5f60001 --encrypted --kms-key-id alias/ebs-key
Dry run: 1 AMI(s) would be copied.
```

| Option | Meaning |
| --- | --- |
| `--kms-key KEY` | KMS key ID, ARN or alias to encrypt with (required) |
| `--delete-source` | Deregister each original AMI and delete its snapshots once the copy is available and tagged. Irreversible |
| `--report FILE` | Write one `<old-id> <new-id>` line per copied AMI |

**IAM actions**

```
sts:GetCallerIdentity
ec2:DescribeImages
ec2:CopyImage
ec2:CreateTags
ec2:DeregisterImage
ec2:DeleteSnapshot
```

The KMS key also needs to allow the caller to use it for the copy.

### ec2/encrypt-all-snapshots.sh

Copies every unencrypted snapshot you own into an encrypted snapshot. Snapshots created by AWS Backup are skipped, and so are snapshots that back an AMI (use `encrypt-all-amis.sh` for those). Tags are copied except those starting with `aws:`. It needs a region, from `--region` or the profile.

```
$ ec2/encrypt-all-snapshots.sh --kms-key alias/ebs-key --report copies.txt
Account: 123456789012  Region: us-east-1  Profile: default
  snap-0a1b2c3d4e5f60001  nightly db
  snap-0a1b2c3d4e5f60002  web root
About to create 2 encrypted copies.
Continue? [y/N] y
Done: 2 succeeded, 0 failed
```

| Option | Meaning |
| --- | --- |
| `--kms-key KEY` | KMS key ID, ARN or alias to encrypt with (required) |
| `--delete-source` | Delete each original snapshot once its copy is complete and tagged. Irreversible |
| `--report FILE` | Write one `<old-id> <new-id>` line per copied snapshot |

**IAM actions**

```
sts:GetCallerIdentity
ec2:DescribeSnapshots
ec2:DescribeImages
ec2:CopySnapshot
ec2:CreateTags
ec2:DeleteSnapshot
```

The KMS key also needs to allow the caller to use it for the copy.

### ec2/encrypt-unattached-ebs-volume.sh

Encrypts an unattached (`available`) volume by snapshotting it and creating an encrypted volume from the snapshot in the same availability zone. The temporary snapshot is deleted afterwards. Tags are copied except those starting with `aws:`, and the copy is tagged `encrypted-copy-of=<volume id>`. If a step fails after the snapshot exists, the script tries to delete the snapshot and leaves the original volume alone.

```
$ ec2/encrypt-unattached-ebs-volume.sh --volume-id vol-0a1b2c3d4e5f60001 --kms-key alias/ebs-key --type gp3
Account: 123456789012  Region: us-east-1  Profile: default
About to create an encrypted gp3 copy of vol-0a1b2c3d4e5f60001 in us-east-1a.
Continue? [y/N] y
Created encrypted volume vol-0f1e2d3c4b5a60002 from vol-0a1b2c3d4e5f60001.
```

| Option | Meaning |
| --- | --- |
| `--volume-id ID` | Volume to encrypt (required) |
| `--kms-key KEY` | KMS key ID, ARN or alias to encrypt with (required) |
| `--type TYPE` | Volume type of the copy: `gp2`, `gp3`, `io1`, `io2`, `st1`, `sc1` or `standard`. Defaults to the source type |
| `--delete-source` | Delete the original volume once the copy is available. Irreversible |

**IAM actions**

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

The KMS key also needs to allow the caller to use it for the new volume.

### ec2/modify-ebs-volumes-gp2-to-gp3.sh

Converts every gp2 volume in the region to gp3. Each volume keeps its current IOPS when that is above the minimum, capped at 16000. Volumes with a modification already in progress are skipped.

Throughput is set per volume: 125 MiB/s for volumes up to 170 GiB and 250 MiB/s for larger ones, matching what gp2 can deliver. `--throughput` only raises it, so each volume gets the larger of that value and its default.

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

| Option | Meaning |
| --- | --- |
| `--min-iops N` | Minimum gp3 IOPS, 3000 to 16000 (default 3000) |
| `--throughput N` | Minimum gp3 throughput in MiB/s, 125 to 1000, at most `min-iops / 4` |

**IAM actions**

```
sts:GetCallerIdentity
ec2:DescribeVolumes
ec2:DescribeVolumesModifications
ec2:ModifyVolume
```

### s3/list-encryption-for-s3-buckets.sh

Prints the default encryption of each bucket as a table on stdout, or as a JSON array with `--json`. It only reads. `--dry-run` and `--yes` are accepted and ignored. A bucket that cannot be queried is reported with algorithm `error` and the reason in the ERROR column, and the exit status stays 0. A bucket with no default encryption shows `none`.

```
$ s3/list-encryption-for-s3-buckets.sh
BUCKET        ALGORITHM  KMS KEY                                     BUCKET KEY  ERROR
logs-archive  aws:kms    arn:aws:kms:us-east-1:123456789012:key/abc  true        -
app-assets    AES256     -                                           false       -
scratch       none       -                                           -           -
locked        error      -                                           -           AccessDenied
```

| Option | Meaning |
| --- | --- |
| `--json` | Print JSON instead of a table |

**IAM actions**

```
sts:GetCallerIdentity
s3:ListAllMyBuckets
s3:GetEncryptionConfiguration
```

## Safety notes

- Run with `--dry-run` first. It prints the commands that would run and changes nothing.
- Use `--yes` only in automation. Without it every script shows what it is about to do and asks `[y/N]`.
- `--delete-source` and `--delete-snapshots` are irreversible. Check the copies (or the `--report` file) before you rely on them.
- Deleting recovery points, snapshots and AMIs cannot be undone either.

## Running the tests

The tests run every script against a stub `aws`, so they need no credentials and make no AWS calls.

```
brew install bats-core shellcheck
bats test
shellcheck -x lib/*.sh */*.sh test/bin/aws
```

To run the suite under the macOS bash 3.2:

```
d=$(mktemp -d) && ln -s /bin/bash "$d/bash" && PATH="$d:$PATH" bats test
```

## License

GPLv3 (GPL-3.0-or-later). See [LICENSE](LICENSE).
