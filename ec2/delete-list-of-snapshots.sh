#!/bin/sh
#
# This script will delete a list of snapshots from your account.
#

echo "Have a list of snapshots to clean called ./snapshots.txt in the root running directory of this script"
read -e -p "What is your AWS CLI profile name? " profile_name

snapshots=$(cat snapshots.txt)

for s in $snapshots; do
    aws --profile ${profile_name} ec2 delete-snapshot --snapshot-id ${s}
done

