#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# Internet Gatewayを接続するVPC名と、作成するInternet Gateway名。
VPC_NAME="sample-vpc"
IGW_NAME="sample-igw"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "=== Caller Identity ==="

# いま操作しているAWSアカウントとIAMユーザーを確認する。
# 想定外のアカウントにリソースを作らないための確認。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get VPC ID ==="

# Nameタグが sample-vpc のVPCを探し、VPC IDだけを取得する。
# Internet GatewayをVPCへ接続するにはVPC IDが必要。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# VPCが見つからない場合はここで止める。
# VPC IDがないまま進むと、Internet Gatewayのアタッチで分かりにくいエラーになる。
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "Error: VPC not found. Please run 01_vpc_setup.sh first."
  exit 1
fi

echo "Target VPC ID: $VPC_ID"

echo "=== Create Internet Gateway ==="

# Internet Gatewayを作成する。
# Internet Gatewayは、VPCをインターネットへ接続するための出口になる。
# ただし、作成しただけではまだVPCに接続されていない。
IGW_ID=$(aws ec2 create-internet-gateway \
  --profile "$PROFILE" \
  --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

echo "Created IGW ID: $IGW_ID"

echo "=== Attach Internet Gateway to VPC ==="

# 作成したInternet GatewayをVPCに接続する。
# Public Subnetからインターネットへ出るには、この後のRoute Table設定も必要。
aws ec2 attach-internet-gateway \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --internet-gateway-id "$IGW_ID"

echo "Success! Attached IGW ($IGW_ID) to VPC ($VPC_ID)"

echo "=== Describe Internet Gateway ==="

# Internet GatewayがVPCに接続されているか確認する。
# Stateが available で、VPCに対象VPC IDが表示されていれば接続できている。
aws ec2 describe-internet-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[*].{ID:InternetGatewayId,Name:Tags[?Key==`Name`].Value|[0],VPC:Attachments[0].VpcId,State:Attachments[0].State}' \
  --output table

