#!/bin/bash
#
# This script is used to remove aws backup recovery points that are older than a certain date. 
# It may come in handy if you have accidentally created a large number of backups that need to be cleaned,
# or that have retained an incorrect retention date.
#
#

read -e -p "Give me the cli profile: " profile
profile=${profile:-default}
read -e -p "Created before date? (e.g.2022-06-01T22:00:00) " created_before
created_before=${created_before:-2022-06-01T22:00:00}

read -e -p "Do you want to see your backup vaults? (y/n) " see_vault
if [ "${see_vault}" == "y" ] || [ "${see_vault}" == "Y" ]; then 
  aws --profile ${profile} backup list-backup-vaults |jq -r '.[][].BackupVaultName'
elif [ "${see_vault}" == "n" ] || "${see_vault}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Give me your vault name: " vault_name

read -e -p "Want to see the recovery points to be deleted? (y/n) " see_points
if [ "${see_points}" == "y" ] || [ "${see_points}" == "Y" ]; then 
  aws --profile ${profile} backup list-recovery-points-by-backup-vault --backup-vault-name ${vault_name} --by-created-before ${created_before} |jq -r '.[][].RecoveryPointArn'
elif [ "${see_points}" == "n" ] || "${see_points}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Do you want to remove all backups created before ${created_before}? (y/n) " remove_all
if [ "${remove_all}" == "y" ] || [ "${remove_all}" == "Y" ]; then 
  recover_points=$(aws --profile ${profile} backup list-recovery-points-by-backup-vault --backup-vault-name ${vault_name} --by-created-before ${created_before} |jq -r '.[][].RecoveryPointArn')
  for p in $recover_points; do
    aws --profile ${profile} backup delete-recovery-point --backup-vault-name ${vault_name} --recovery-point-arn "$p"
  done
elif [ "${remove_all}" == "n" ] || "${remove_all}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi
