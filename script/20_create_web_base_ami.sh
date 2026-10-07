#!/bin/bash

# エラー発生時に処理を止める。
# -e: コマンドが失敗したら終了
# -u: 未定義の変数を使ったら終了
# -o pipefail: パイプ途中のコマンド失敗も検知
set -euo pipefail

# AWS CLIで使用するプロファイルとリージョン。
PROFILE="learning"
REGION="ap-northeast-1"

# AMI作成元にするEC2インスタンス名。
# このスクリプトでは、AnsibleでRubyなどを導入済みのweb01を元にする。
SOURCE_INSTANCE_NAME="sample-ec2-web01"

# 作成するAMI名のプレフィックス。
# 実際のAMI名には日時を付け、世代を区別できるようにする。
AMI_NAME_PREFIX="web-base-ruby336-rails72"

echo "================================================"
echo "Create Web Base AMI"
echo "This script creates a custom AMI from web01."
echo "It assumes Ruby, Bundler, nginx, and deploy user"
echo "are already installed by Ansible."
echo "================================================"

# 誤ったAWSアカウントやプロファイルで実行していないか確認する。
echo "=== Caller Identity ==="
aws sts get-caller-identity \
  --profile "${PROFILE}" \
  --output table

# AMI作成元となるweb01のInstance IDを取得する。
# Nameタグが sample-ec2-web01 で、running状態のインスタンスを対象にする。
echo "=== Get source EC2 instance ID ==="
INSTANCE_ID=$(aws ec2 describe-instances \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --filters \
    "Name=tag:Name,Values=${SOURCE_INSTANCE_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

# 対象インスタンスが見つからない場合は、AMIを作成できないため終了する。
if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" = "None" ]; then
  echo "ERROR: Running instance not found: ${SOURCE_INSTANCE_NAME}"
  exit 1
fi

echo "Source Instance: ${SOURCE_INSTANCE_NAME}"
echo "Instance ID    : ${INSTANCE_ID}"

# AMI名を作成する。
# 日時を含めることで、いつ作ったAMIか分かるようにする。
AMI_NAME="${AMI_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)"

echo "=== Create AMI ==="
echo "AMI Name: ${AMI_NAME}"

# EC2インスタンスからAMIを作成する。
# --no-reboot:
#   インスタンスを再起動せずにAMIを作成する。
#   今回はアプリやDB書き込みがないベースAMIなので、学習用途ではこの指定で進める。
#   より厳密にディスク整合性を取りたい場合は、このオプションを外す。
AMI_ID=$(aws ec2 create-image \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --instance-id "${INSTANCE_ID}" \
  --name "${AMI_NAME}" \
  --description "Amazon Linux 2023 with nginx, deploy user, rbenv, Ruby 3.3.6 and Bundler for Rails 7.2 lab" \
  --no-reboot \
  --query "ImageId" \
  --output text)

echo "AMI ID: ${AMI_ID}"

# AMI作成は非同期処理のため、availableになるまで待機する。
echo "=== Wait for AMI to become available ==="
aws ec2 wait image-available \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --image-ids "${AMI_ID}"

# 作成されたAMIの情報を確認する。
echo "=== AMI created ==="
aws ec2 describe-images \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --image-ids "${AMI_ID}" \
  --query "Images[].{Name:Name,ImageId:ImageId,State:State,CreationDate:CreationDate}" \
  --output table

echo "================================================"
echo "AMI creation completed."
echo "AMI ID:"
echo "  ${AMI_ID}"
echo
echo "Next step:"
echo "  Use this AMI ID in 08_Web_server_setup.sh"
echo "  when creating web01 and web02."
echo "================================================"

