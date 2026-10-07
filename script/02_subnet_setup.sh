#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# サブネットを作成する対象VPCのNameタグ。
# 前の手順 01_vpc_setup.sh で作成したVPCを名前で探す。
VPC_NAME="sample-vpc"

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
# サブネット作成にはVPC IDが必要。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# VPCが見つからない場合、AWS CLIは None を返すことがある。
# VPC IDがないまま進むと後続コマンドが分かりにくいエラーになるため、ここで止める。
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "Error: VPC not found. Please run 01_vpc_setup.sh first."
  exit 1
fi

echo "Target VPC ID: $VPC_ID"

echo "=== Create Public Subnet 01 ==="

# 1つ目のPublic Subnetを作成する。
# Public Subnetは、後でInternet Gatewayへのルートを設定して外部公開用に使う。
PUB01_ID=$(aws ec2 create-subnet \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.0.0/20 \
  --availability-zone ap-northeast-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sample-subnet-public01},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning},{Key=Type,Value=public}]' \
  --query 'Subnet.SubnetId' \
  --output text)

# このサブネットでEC2を起動したとき、Public IPを自動割り当てする設定。
# Public Subnetとして使うために有効化しておく。
aws ec2 modify-subnet-attribute \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PUB01_ID" \
  --map-public-ip-on-launch

echo "=== Create Public Subnet 02 ==="

# 2つ目のPublic Subnetを作成する。
# AZを分けることで、ALBなど複数AZが必要なサービスに対応できる。
PUB02_ID=$(aws ec2 create-subnet \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.16.0/20 \
  --availability-zone ap-northeast-1c \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sample-subnet-public02},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning},{Key=Type,Value=public}]' \
  --query 'Subnet.SubnetId' \
  --output text)

# 2つ目のPublic SubnetでもPublic IP自動割り当てを有効化する。
aws ec2 modify-subnet-attribute \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PUB02_ID" \
  --map-public-ip-on-launch

echo "=== Create Private Subnet 01 ==="

# 1つ目のPrivate Subnetを作成する。
# Private Subnetには、外部から直接到達させたくないWebサーバーやDBを配置する。
PRI01_ID=$(aws ec2 create-subnet \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.64.0/20 \
  --availability-zone ap-northeast-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sample-subnet-private01},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning},{Key=Type,Value=private}]' \
  --query 'Subnet.SubnetId' \
  --output text)

echo "=== Create Private Subnet 02 ==="

# 2つ目のPrivate Subnetを作成する。
# こちらもAZを分けておき、将来的に冗長構成を組めるようにする。
PRI02_ID=$(aws ec2 create-subnet \
  --profile "$PROFILE" \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.80.0/20 \
  --availability-zone ap-northeast-1c \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sample-subnet-private02},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning},{Key=Type,Value=private}]' \
  --query 'Subnet.SubnetId' \
  --output text)

# 作成されたSubnet IDを表示する。
# 後続のIGW、NAT Gateway、Route Table、EC2作成でこのIDを使う。
echo "Subnets created:"
echo "  Public : $PUB01_ID, $PUB02_ID"
echo "  Private: $PRI01_ID, $PRI02_ID"

echo "=== Describe Subnets ==="

# VPC内のサブネット一覧を確認する。
# Name、public/privateの種別、AZ、CIDR、Public IP自動割り当て設定を表形式で表示する。
aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[*].{Name:Tags[?Key==`Name`].Value|[0],Type:Tags[?Key==`Type`].Value|[0],AZ:AvailabilityZone,CIDR:CidrBlock,PublicIP:MapPublicIpOnLaunch,ID:SubnetId}' \
  --output table

