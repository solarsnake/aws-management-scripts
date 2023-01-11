#!/bin/sh
# 
# This script will encrypt all AMIs in your account that are NOT created via AWS Backup. You will need to clean up snaphshots on your own.
#

read -e -p "Give me your AWS CLI profile name: " profile_name
read -e -p "What AWS Region are we in? (us-west-1, us-gov-west-1, etc) " aws_region
read -e -p "Give me your KMS key alias (alias/SOME_VALUE): " kms_key

images=$(aws --profile ${profile_name} ec2 describe-images --owner self --filters Name=block-device-mapping.encrypted,Values=false --query 'Images[?!not_null(Tags[?Key == `aws:backup:source-resource`])]' |jq -r '.[].ImageId')
count=$(echo "${images}" |wc -l)

echo "${images}" >> "${profile_name}"-amis.txt

echo "You have ${count} unencrypted AMIs in this account"

read -e -p "Do you want to see your unencrypted AMIs? (y/n) " wanna_see
if [ "${wanna_see}" == "y" ] || [ "${wanna_see}" == "Y" ]; then 
  aws --profile "${profile_name}" ec2 describe-images --owner self --filters Name=block-device-mapping.encrypted,Values=false --query 'Images[?!not_null(Tags[?Key == `aws:backup:source-resource`])].{id:ImageId,tag:Tags}' --output yaml
elif [ "${wanna_see}" == "n" ] || [ "${wanna_see}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Would you like to encrypt all unencrypted AMIs in this account (this will take some time)? (y/n) " encrypt_all
if [ "${encrypt_all}" == "y" ] || [ "${encrypt_all}" == "Y" ]; then 
    for i in $images; do
        source_image_name=$(aws --profile ${profile_name} ec2 describe-images --image-ids ${i} --query 'Images[].Name' |jq -r '.[]')
        new_image=$(aws --profile "${profile_name}" ec2 copy-image --name "${source_image_name}" --source-region "${aws_region}" --source-image-id "${i}" --encrypted --kms-key-id "${kms_key}" | jq -r '.ImageId')
        aws --profile "${profile_name}" ec2 wait image-available --image-ids "${new_image}"
        aws --profile "${profile_name}" ec2 describe-tags --filters "Name=resource-id,Values=${i}"| sed '/Resource/d' > tags.json | true
        aws --profile "${profile_name}" ec2 create-tags --resources "${new_image}" --cli-input-json file://tags.json | true
        rm tags.json | true
        echo "You have created an encrypted AMI ${new_image} from the unencrypted AMI ${i}"
    done
elif [ "${encrypt_all}" == "n" ] || [ "${encrypt_all}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Would you like to delete your source AMIs? (y/n) " delete_em

if [ "${delete_em}" == "y" ] || [ "${delete_em}" == "Y" ]; then 
    for i in $images; do
        source_snap=$(aws --profile ${profile_name} ec2 describe-images --image-ids ${i} --query 'Images[].BlockDeviceMappings[].Ebs[].SnapshotId' |jq -r '.[]')
        aws --profile "${profile_name}" ec2 deregister-image --image-id "${i}"
        echo "You will need to delete the source snapshot(s)"
        echo "${source_snap}"
    done
elif [ "${delete_em}" == "n" ] || [ "${delete_em}" == "N" ]; then
  echo "Ok"
  exit 1
else
  echo "Invalid Response"
  exit 1
fi