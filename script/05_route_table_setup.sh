#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# Route Table設定で参照する各リソースのNameタグ。
# これまでの手順で作成したVPC、IGW、NAT Gateway、Subnetを名前で探す。
VPC_NAME="sample-vpc"
IGW_NAME="sample-igw"
NGW01_NAME="sample-ngw-01"
NGW02_NAME="sample-ngw-02"
PUB01_NAME="sample-subnet-public01"
PUB02_NAME="sample-subnet-public02"
PRI01_NAME="sample-subnet-private01"
PRI02_NAME="sample-subnet-private02"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# 取得したIDが空、または None の場合にスクリプトを止めるための関数。
# Route Tableは前段のリソースに依存するため、ID取得漏れを早めに検知する。
get_required_id() {
  local label="$1"
  local value="$2"

  if [ "$value" = "None" ] || [ -z "$value" ]; then
    echo "Error: $label not found. Please check previous setup scripts."
    exit 1
  fi

  echo "$value"
}

echo "=== Caller Identity ==="

# いま操作しているAWSアカウントとIAMユーザーを確認する。
# 想定外のアカウントにリソースを作らないための確認。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get Resource IDs ==="

# VPC IDを取得する。
# Route TableはVPCに作成するため、VPC IDが必要。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)
VPC_ID=$(get_required_id "VPC" "$VPC_ID")

# Internet Gateway IDを取得する。
# Public Subnet用Route Tableのデフォルトルートに設定する。
IGW_ID=$(aws ec2 describe-internet-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$IGW_NAME" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)
IGW_ID=$(get_required_id "Internet Gateway" "$IGW_ID")

# NAT Gateway 01のIDを取得する。
# available 状態のものだけを対象にする。
# Private Subnet 01の外向き通信に使う。
NGW01_ID=$(aws ec2 describe-nat-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filter Name=tag:Name,Values="$NGW01_NAME" Name=state,Values=available \
  --query 'NatGateways[0].NatGatewayId' \
  --output text)
NGW01_ID=$(get_required_id "NAT Gateway 01" "$NGW01_ID")

# NAT Gateway 02のIDを取得する。
# Private Subnet 02の外向き通信に使う。
NGW02_ID=$(aws ec2 describe-nat-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filter Name=tag:Name,Values="$NGW02_NAME" Name=state,Values=available \
  --query 'NatGateways[0].NatGatewayId' \
  --output text)
NGW02_ID=$(get_required_id "NAT Gateway 02" "$NGW02_ID")

# Public Subnet 01のIDを取得する。
# Public用Route Tableに関連付ける。
PUB01_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUB01_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PUB01_ID=$(get_required_id "Public Subnet 01" "$PUB01_ID")

# Public Subnet 02のIDを取得する。
# Public用Route Tableに関連付ける。
PUB02_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUB02_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PUB02_ID=$(get_required_id "Public Subnet 02" "$PUB02_ID")

# Private Subnet 01のIDを取得する。
# Private用Route Table 01に関連付ける。
PRI01_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PRI01_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PRI01_ID=$(get_required_id "Private Subnet 01" "$PRI01_ID")

# Private Subnet 02のIDを取得する。
# Private用Route Table 02に関連付ける。
PRI02_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PRI02_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PRI02_ID=$(get_required_id "Private Subnet 02" "$PRI02_ID")

# 取得したIDを一覧表示する。
# 後続処理の対象が正しいか確認しやすくするため。
echo "VPC: $VPC_ID"
echo "IGW: $IGW_ID"
echo "NGW01: $NGW01_ID"
echo "NGW02: $NGW02_ID"
echo "Public Subnets: $PUB01_ID, $PUB02_ID"
echo "Private Subnets: $PRI01_ID, $PRI02_ID"

echo "=== Create Public Route Table ==="

# Public Subnet用のRoute Tableを作成する。
# このRoute Tableには、インターネット向け通信をIGWへ流すルートを追加する。
RT_PUB_ID=$(aws ec2 create-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=sample-rt-public},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

# 0.0.0.0/0 は「VPC内ではない全ての宛先」を意味する。
# Public Subnetでは、この通信をInternet Gatewayへ向ける。
aws ec2 create-route \
  --profile "$PROFILE" \
  --region "$REGION" \
  --route-table-id "$RT_PUB_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID"

# Public Subnet 01にPublic用Route Tableを関連付ける。
aws ec2 associate-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PUB01_ID" \
  --route-table-id "$RT_PUB_ID"

# Public Subnet 02にも同じPublic用Route Tableを関連付ける。
aws ec2 associate-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PUB02_ID" \
  --route-table-id "$RT_PUB_ID"

echo "Public Route Table: $RT_PUB_ID"

echo "=== Create Private Route Table 01 ==="

# Private Subnet 01用のRoute Tableを作成する。
# Private Subnetから外へ出る通信は、NAT Gateway 01へ向ける。
RT_PRI01_ID=$(aws ec2 create-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=sample-rt-private01},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Private Subnet 01の外向き通信をNAT Gateway 01へ向ける。
# これにより、Private Subnet内のEC2はPublic IPなしでインターネットへ出られる。
aws ec2 create-route \
  --profile "$PROFILE" \
  --region "$REGION" \
  --route-table-id "$RT_PRI01_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NGW01_ID"

# Private Subnet 01にPrivate用Route Table 01を関連付ける。
aws ec2 associate-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PRI01_ID" \
  --route-table-id "$RT_PRI01_ID"

echo "Private Route Table 01: $RT_PRI01_ID"

echo "=== Create Private Route Table 02 ==="

# Private Subnet 02用のRoute Tableを作成する。
# こちらはNAT Gateway 02へ向ける。
RT_PRI02_ID=$(aws ec2 create-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=sample-rt-private02},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Private Subnet 02の外向き通信をNAT Gateway 02へ向ける。
aws ec2 create-route \
  --profile "$PROFILE" \
  --region "$REGION" \
  --route-table-id "$RT_PRI02_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NGW02_ID"

# Private Subnet 02にPrivate用Route Table 02を関連付ける。
aws ec2 associate-route-table \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PRI02_ID" \
  --route-table-id "$RT_PRI02_ID"

echo "Private Route Table 02: $RT_PRI02_ID"

echo "All Route Tables configured and associated."

echo "=== Describe Route Tables ==="

# VPC内のRoute Tableを確認する。
# Public用はIGW、Private用はNAT Gatewayへ 0.0.0.0/0 が向いているか確認する。
aws ec2 describe-route-tables \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'RouteTables[*].{Name:Tags[?Key==`Name`].Value|[0],ID:RouteTableId,AssociatedSubnets:Associations[?SubnetId!=`null`].SubnetId,IGW:Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId|[0],NGW:Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId|[0]}' \
  --output table

