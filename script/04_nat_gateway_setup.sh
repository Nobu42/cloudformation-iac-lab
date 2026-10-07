#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# NAT Gatewayを配置するPublic SubnetのNameタグ。
# NAT GatewayはPrivate Subnetではなく、Public Subnetに作成する。
PUBLIC_SUBNET_01_NAME="sample-subnet-public01"
PUBLIC_SUBNET_02_NAME="sample-subnet-public02"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "=== Caller Identity ==="

# いま操作しているAWSアカウントとIAMユーザーを確認する。
# NAT Gatewayは課金対象なので、作成前に操作先アカウントを必ず確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get Public Subnet IDs ==="

# 1つ目のPublic Subnet IDを取得する。
# NAT Gateway 01はこのサブネットに配置する。
PUB01_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUBLIC_SUBNET_01_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)

# 2つ目のPublic Subnet IDを取得する。
# NAT Gateway 02はこのサブネットに配置する。
PUB02_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUBLIC_SUBNET_02_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)

# Public Subnet 01が見つからない場合はここで止める。
# NAT GatewayはSubnet IDがないと作成できない。
if [ "$PUB01_ID" = "None" ] || [ -z "$PUB01_ID" ]; then
  echo "Error: Public subnet 01 not found. Please run 02_subnet_setup.sh first."
  exit 1
fi

# Public Subnet 02が見つからない場合もここで止める。
if [ "$PUB02_ID" = "None" ] || [ -z "$PUB02_ID" ]; then
  echo "Error: Public subnet 02 not found. Please run 02_subnet_setup.sh first."
  exit 1
fi

echo "Public Subnet 01: $PUB01_ID"
echo "Public Subnet 02: $PUB02_ID"

echo "=== Allocate Elastic IP for NAT Gateway 01 ==="

# NAT Gateway 01に割り当てるElastic IPを確保する。
# Public NAT Gatewayには固定のPublic IPv4アドレスが必要。
# Elastic IPも課金対象なので、NAT Gateway削除後に解放する必要がある。
ALLOC_ID_01=$(aws ec2 allocate-address \
  --profile "$PROFILE" \
  --region "$REGION" \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=sample-eip-ngw-01},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'AllocationId' \
  --output text)

echo "Elastic IP Allocation ID 01: $ALLOC_ID_01"

echo "=== Create NAT Gateway 01 ==="

# NAT Gateway 01をPublic Subnet 01に作成する。
# 後続のRoute Table設定で、Private Subnet 01のデフォルトルートをこのNAT Gatewayへ向ける。
NGW01_ID=$(aws ec2 create-nat-gateway \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PUB01_ID" \
  --allocation-id "$ALLOC_ID_01" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=sample-ngw-01},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'NatGateway.NatGatewayId' \
  --output text)

echo "NAT Gateway 01: $NGW01_ID"

echo "=== Allocate Elastic IP for NAT Gateway 02 ==="

# NAT Gateway 02に割り当てるElastic IPを確保する。
# 2つのAZに分けてNAT Gatewayを作ることで、AZごとの経路を分けられる。
ALLOC_ID_02=$(aws ec2 allocate-address \
  --profile "$PROFILE" \
  --region "$REGION" \
  --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=sample-eip-ngw-02},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'AllocationId' \
  --output text)

echo "Elastic IP Allocation ID 02: $ALLOC_ID_02"

echo "=== Create NAT Gateway 02 ==="

# NAT Gateway 02をPublic Subnet 02に作成する。
# 後続のRoute Table設定で、Private Subnet 02のデフォルトルートをこのNAT Gatewayへ向ける。
NGW02_ID=$(aws ec2 create-nat-gateway \
  --profile "$PROFILE" \
  --region "$REGION" \
  --subnet-id "$PUB02_ID" \
  --allocation-id "$ALLOC_ID_02" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=sample-ngw-02},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]' \
  --query 'NatGateway.NatGatewayId' \
  --output text)

echo "NAT Gateway 02: $NGW02_ID"

echo "=== Wait for NAT Gateways to become available ==="

# NAT Gatewayは作成直後すぐに利用できるとは限らない。
# available になる前にRoute Tableへ設定すると失敗することがあるため、ここで待つ。
aws ec2 wait nat-gateway-available \
  --profile "$PROFILE" \
  --region "$REGION" \
  --nat-gateway-ids "$NGW01_ID" "$NGW02_ID"

echo "NAT Gateways are available."

echo "=== Describe NAT Gateways ==="

# 作成したNAT Gatewayの状態を確認する。
# Stateが available で、Public IPとAllocationIdが表示されていれば作成できている。
aws ec2 describe-nat-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --nat-gateway-ids "$NGW01_ID" "$NGW02_ID" \
  --query 'NatGateways[*].{Name:Tags[?Key==`Name`].Value|[0],ID:NatGatewayId,State:State,Subnet:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp,AllocationId:NatGatewayAddresses[0].AllocationId}' \
  --output table

