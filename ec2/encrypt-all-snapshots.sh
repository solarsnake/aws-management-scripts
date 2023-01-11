#!/bin/sh
# 
# This script will encrypt all snapshots in your account that are NOT created via AWS Backup.
#

read -e -p "Give me your AWS CLI profile name: " profile_name
read -e -p "What AWS Region are we in? " aws_region
read -e -p "Give me your KMS key alias (alias/SOME_VALUE): " kms_key

snapshots=$(aws --profile ${profile_name} ec2 describe-snapshots --owner self --filters Name=encrypted,Values=false --query 'Snapshots[?!not_null(Tags[?Key == `aws:backup:source-resource`])].{id:SnapshotId}' |jq -r '.[].id')
count=$(echo "${snapshots}" |wc -l)

echo "${snapshots}" >> "${profile_name}"-snapshots.txt

echo "You have ${count} unencrypted snapshot in this account"

read -e -p "Do you want to see your unencrypted snapshots? (y/n) " wanna_see
if [ "${wanna_see}" == "y" ] || [ "${wanna_see}" == "Y" ]; then 
  aws --profile "${profile_name}" ec2 describe-snapshots --owner self --filters Name=encrypted,Values=false --query 'Snapshots[?!not_null(Tags[?Key == `aws:backup:source-resource`])].{id:SnapshotId,tag:Tags}'
elif [ "${wanna_see}" == "n" ] || "${wanna_see}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Would you like to encrypt all unencrypted snapshots in this account (this will take some time)? (y/n) " encrypt_all
if [ "${encrypt_all}" == "y" ] || [ "${encrypt_all}" == "Y" ]; then 
    for s in $snapshots; do
        new_snap=$(aws --profile ${profile_name} ec2 copy-snapshot --source-region ${aws_region} --source-snapshot-id ${s} --encrypted --kms-key-id ${kms_key} |jq -r '.SnapshotId')
        aws --profile ${profile_name} ec2 wait snapshot-completed --snapshot-ids ${new_snap}
        aws --profile ${profile_name} ec2 describe-tags --filters "Name=resource-id,Values=${s}"| sed '/Resource/d' > tags.json | true
        aws --profile ${profile_name} ec2 create-tags --resources ${new_snap} --cli-input-json file://tags.json | true
        rm tags.json | true
        echo "You have created an encrypted snapshot ${new_snap} from the unencrypted snapshot ${s}"
    done
elif [ "${encrypt_all}" == "n" ] || [ "${encrypt_all}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Would you like to delete your source snapshots? (y/n) " delete_em

if [ "${delete_em}" == "y" ] || [ "${delete_em}" == "Y" ]; then 
    for s in $snapshots; do
        aws --profile ${profile_name} ec2 delete-snapshot --snapshot-id ${s}
    done
elif [ "${delete_em}" == "n" ] || [ "${delete_em}" == "N" ]; then
  echo "Ok"
  exit 1
else
  echo "Invalid Response"
  exit 1
fi