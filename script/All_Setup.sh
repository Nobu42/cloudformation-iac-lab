#!/bin/bash
set -euo pipefail

# ============================================================
# All_Setup.sh
#
# AWS CLI編の主要セットアップスクリプトを順番に実行する。
#
# このスクリプトは「何も残っていない状態」からの新規構築を前提とする。
# 既存の sample-vpc が残っている状態で実行すると、
# Subnet CIDRの衝突や、古いVPCを誤って参照する問題が起きる。
#
# そのため、冒頭で sample-vpc の残存確認を行い、
# 1つでも残っていた場合は安全のため処理を停止する。
#
# 残っている場合は、先に以下を実行する。
#
#   ./cleanup_all.sh
#   ./check_cleanup.sh
#
# ============================================================

PROFILE="learning"
REGION="ap-northeast-1"
VPC_NAME="sample-vpc"

# LocalStack向けのaliasや環境変数が残っていると、
# 実AWSではなくLocalStackへ接続してしまう。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "================================================"
echo "All setup started."
echo "This script creates daily lab resources."
echo "================================================"

echo "=== Caller Identity ==="
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Check existing VPC ==="

# sample-vpc がすでに存在するか確認する。
# 既存VPCが残っている状態でセットアップを開始すると、
# 02_subnet_setup.sh が古いVPCを拾ったり、
# Subnet CIDRが衝突したりする可能性がある。
EXISTING_VPCS=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[*].VpcId' \
  --output text)

if [ -n "$EXISTING_VPCS" ]; then
  echo "Error: Existing VPC found."
  echo "VPC Name: $VPC_NAME"
  echo "VPC IDs : $EXISTING_VPCS"
  echo ""
  echo "This script must start from a clean state."
  echo "Please delete remaining daily lab resources first:"
  echo ""
  echo "  ./cleanup_all.sh"
  echo "  ./check_cleanup.sh"
  echo ""
  echo "After cleanup, run this script again."
  exit 1
fi

echo "No existing $VPC_NAME found. Continue setup."

echo "=== Input RDS master password ==="
echo "This password is used by 10_Database_setup.sh."
echo "Input is hidden and will not be displayed."

# RDSのマスターパスワードを入力する。
# 環境変数としてexportすることで、10_Database_setup.sh から参照できる。
# スクリプト内にパスワードを直接書かないことで、Gitへの混入を防ぐ。
read -r -s -p "DB master password: " DB_MASTER_PASSWORD
echo

if [ -z "$DB_MASTER_PASSWORD" ]; then
  echo "Error: DB master password is empty."
  exit 1
fi

export DB_MASTER_PASSWORD

echo "=== Run setup scripts ==="

# ネットワーク基盤
./01_vpc_setup.sh
./02_subnet_setup.sh
./03_internetgateway_setup.sh
./04_nat_gateway_setup.sh
./05_route_table_setup.sh

# セキュリティグループ
./06_security_group_setup.sh

# EC2
./07_bastion_server_setup.sh
./08_Web_server_setup.sh

# ALB
./09_LoadBalancer_setup.sh

# RDS
./10_Database_setup.sh

# S3とWeb EC2用IAM Role
./11_s3_setup.sh

# Public DNS
./12_public_dns_setup.sh

# Private DNS
./14_private_dns_setup.sh

# ACM証明書とHTTPS Listener
./15_acm_certificate_setup.sh

# SES送信用のDomain Identity / DKIM / SPF / DMARCは初回設定済みのため、
# 毎日のセットアップでは実行しない。
#
# ./16_ses_setup.sh

# SES受信設定は、メール受信を検証する日だけ実行する。
# 実行するとMXレコード、Receipt Rule、受信用S3バケットを作成する。
#
# ./18_ses_receiving_setup.sh

# ElastiCache Redis
./19_elasticache_setup.sh

# DBパスワードを現在のシェル環境から削除する。
unset DB_MASTER_PASSWORD

echo "================================================"
echo "All setup completed."
echo ""
echo "Next checks:"
echo "  ./check_setup.sh"
echo ""
echo "Manual checks:"
echo "  ssh bastion"
echo "  ssh web01"
echo "  ssh web02"
echo "  https://www.nobu-iac-lab.com"
echo ""
echo "Notes:"
echo "  - Run ./18_ses_receiving_setup.sh only when testing email receiving."
echo "  - Run cleanup_all.sh after learning to delete chargeable resources."
echo "================================================"

