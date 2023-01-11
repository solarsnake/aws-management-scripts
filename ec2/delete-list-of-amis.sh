#!/bin/sh
#
# This script will delete a list of snapshots from your account.
#

echo "Have a list of snapshots to clean called ./snapshots.txt in the root running directory of this script"
read -e -p "What is your AWS CLI profile name? " profile_name

images=$(cat amis.txt)

for i in $images; do
    source_snap=$(aws --profile ${profile_name} ec2 describe-images --image-ids ${i} --query 'Images[].BlockDeviceMappings[].Ebs[].SnapshotId' |jq -r '.[]')
    aws --profile "${profile_name}" ec2 deregister-image --image-id "${i}"
    echo "You will need to delete the source snapshot(s)"
    echo "${source_snap}"
done
