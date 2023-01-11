#!/bin/bash
#
# This script will list the encryption status of your s3 buckets.
#

read -e -p "Give me your AWS CLI profile name: " profile_name

read -e -p "Do you want to see your s3 buckets? (y/n) " wanna_see
if [ "${wanna_see}" == "y" ] || [ "${wanna_see}" == "Y" ]; then 
  buckets=$(aws --profile ${profile_name} s3api list-buckets --query "Buckets[].Name[]" |jq -r '.[]')
  for b in $buckets; do
    aws --profile ${profile_name} s3api get-bucket-encryption --bucket $b
  done
elif [ "${wanna_see}" == "n" ] || "${wanna_see}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi