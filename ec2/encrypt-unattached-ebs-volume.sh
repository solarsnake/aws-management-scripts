#!/bin/bash
#
# This script will encrypt an unattached volume in your account.
#

read -e -p "Give me your AWS CLI profile name: " profile_name

read -e -p "Do you want to see your unencrypted, unattached volumes? (y/n) " wanna_see
if [ "${wanna_see}" == "y" ] || [ "${wanna_see}" == "Y" ]; then 
  aws --profile "${profile_name}" ec2 describe-volumes --filters Name=status,Values=available Name=encrypted,Values=false --query "Volumes[*].{ID:VolumeId,AZ:AvailabilityZone,Tag:Tags}" --output yaml
elif [ "${wanna_see}" == "n" ] || "${wanna_see}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Give me your VolumeID: " volume_id
read -e -p "Give me your volume's AZ: " availability_zone
read -e -p "Give me a KMS key alias (alias/SOME_VALUE): " kms_key
read -e -p "Do you need to encrypt this volume (this may take some time)? (y/n) " encrypt_vol

if [ "${encrypt_vol}" == "y" ] || [ "${encrypt_vol}" == "Y" ]; then
  snapshot_id=$(aws --profile "${profile_name}" ec2 create-snapshot --volume-id "${volume_id}" | jq -r '.SnapshotId')
  aws --profile "${profile_name}" ec2 wait snapshot-completed --snapshot-ids "${snapshot_id}"
  new_volume_id=$(aws --profile "${profile_name}" ec2 create-volume --availability-zone "${availability_zone}" --volume-type gp3 --snapshot-id "${snapshot_id}" --encrypted --kms-key-id "${kms_key}" --tag-specifications "ResourceType=volume,Tags=[{Key=encrypted-copy,Value=${volume_id}}]"| jq -r '.VolumeId')
  aws --profile "${profile_name}" ec2 wait volume-available --volume-ids "${new_volume_id}"
  aws --profile "${profile_name}" ec2 delete-snapshot --snapshot-id "${snapshot_id}"
  aws --profile "${profile_name}" ec2 describe-tags --filters "Name=resource-id,Values=${volume_id}"| sed '/Resource/d' > tags.json
  aws --profile "${profile_name}" ec2 create-tags --resources "${new_volume_id}" --cli-input-json file://tags.json
  rm tags.json
elif [ "${encrypt_vol}" == "n" ] || "${encrypt_vol}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Want to delete the original volume? (y/n) " delete_vol

if [ "${delete_vol}" == "y" ] || [ "${delete_vol}" == "Y" ]; then
  aws --profile "${profile_name}" ec2 delete-volume --volume-id "${volume_id}"
elif [ "${delete_vol}" == "n" ] || "${delete_vol}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

echo "You have created an encrypted volume ${new_volume_id} from the unencrypted volume ${volume_id}"