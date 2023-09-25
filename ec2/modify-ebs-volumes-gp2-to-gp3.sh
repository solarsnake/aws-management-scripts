#!/bin/bash
#
# This script identifies all EBS volumes in your account that use the old GP2 version and upgrades them to GP3
#

read -e -p "Give me your AWS CLI profile name: " profile

read -e -p "Want to see your gp2 volumes in this account? (y/n) " see_vols
if [ "${see_vols}" == "y" ] || [ "${see_vols}" == "Y" ]; then 
  aws --profile ${profile} ec2 describe-volumes --filters Name=volume-type,Values=gp2 | jq -r '.[][].VolumeId'
elif [ "${see_vols}" == "n" ] || "${see_vols}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

read -e -p "Set your desired IOPS for your volume (default for gp3 is 3000, max 16000 with additional cost): " iops_val
iops_val=${iops_val:-3000}

read -e -p "Would you like to modify all gp2 volumes to gp3 with IOPS value ${iops_val}? (y/n) " modify
if [ "${modify}" == "y" ] || [ "${modify}" == "Y" ]; then 
  gp2_volumes=$(aws --profile ${profile} ec2 describe-volumes --filters Name=volume-type,Values=gp2 | jq -r '.[][].VolumeId')
#   original_iops=$(aws --profile ${profile} ec2 describe-volumes --volume-ids "$v"| jq -r '.[][].Iops')
#   if [ "$original_iops" -gt 3000 ]; then
#     iops_val=$original_iops
#   fi
#   echo $iops_val
  for v in $gp2_volumes; do
    aws --profile ${profile} ec2 modify-volume --volume-id "$v" --volume-type gp3 --iops ${iops_val}
  done
elif [ "${modify}" == "n" ] || "${modify}" == "N" ]; then
  echo "Ok"
else
  echo "Invalid Response"
  exit 1
fi

echo "Done"