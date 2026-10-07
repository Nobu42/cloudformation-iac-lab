#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# Bastionを作成するために参照するリソース名。
# BastionはPublic Subnetに配置し、SSHの入口として使う。
VPC_NAME="sample-vpc"
PUBLIC_SUBNET_NAME="sample-subnet-public01"
BASTION_SG_NAME="sample-sg-bastion"

# EC2に設定するKey Pair名と秘密鍵ファイル名。
# この秘密鍵を使って、あとでSSH接続する。
KEY_NAME="nobu"
KEY_FILE="${KEY_NAME}.pem"

# 作成するBastion EC2のNameタグとインスタンスタイプ。
# t3.microは今回の無料枠対象として確認したため使用している。
INSTANCE_NAME="sample-ec2-bastion"
INSTANCE_TYPE="t3.micro"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# Amazon Linux 2023の最新AMI IDをSSM Parameter Storeから取得する。
# AMI IDはリージョンや時期で変わるため、固定値ではなくAWS管理のパラメータから取得する。
AMI_ID=$(aws ssm get-parameter \
  --profile "$PROFILE" \
  --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' \
  --output text)

# 取得したIDが空、または None の場合にスクリプトを止めるための関数。
# 必要なリソースが見つからないままEC2作成へ進むのを防ぐ。
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
# EC2は課金対象なので、作成前に操作先アカウントを必ず確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get Resource IDs ==="

# VPC IDを取得する。
# SubnetやSecurity Groupが想定したVPCにあるか確認するためにも使う。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)
VPC_ID=$(get_required_id "VPC" "$VPC_ID")

# Bastionを配置するPublic SubnetのIDを取得する。
# Public Subnetに配置し、Public IPを付与してSSH接続できるようにする。
PUB01_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUBLIC_SUBNET_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PUB01_ID=$(get_required_id "Public Subnet 01" "$PUB01_ID")

# Bastion用Security GroupのIDを取得する。
# SSH接続を許可するルールが入っているSecurity GroupをEC2に関連付ける。
SG_BASTION_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$BASTION_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
SG_BASTION_ID=$(get_required_id "Bastion Security Group" "$SG_BASTION_ID")

# 取得した値を表示し、想定したリソースを使うことを確認する。
echo "VPC: $VPC_ID"
echo "Public Subnet: $PUB01_ID"
echo "Bastion Security Group: $SG_BASTION_ID"
echo "AMI: $AMI_ID"

echo "=== Recreate Key Pair ==="

# 既存の同名Key Pairがあれば削除する。
# 学習用に毎回作り直すための処理。
# 既存EC2で同じKey Pairを使っている場合、作り直すと古い秘密鍵では接続できなくなる点に注意。
aws ec2 delete-key-pair \
  --profile "$PROFILE" \
  --region "$REGION" \
  --key-name "$KEY_NAME" >/dev/null 2>&1 || true

# ローカルに残っている古い秘密鍵ファイルを削除する。
rm -f "$KEY_FILE"

# 新しいKey Pairを作成し、秘密鍵の中身をpemファイルとして保存する。
# KeyMaterialは作成時にしか取得できないため、ここで必ず保存する。
aws ec2 create-key-pair \
  --profile "$PROFILE" \
  --region "$REGION" \
  --key-name "$KEY_NAME" \
  --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$KEY_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'KeyMaterial' \
  --output text > "$KEY_FILE"

# 秘密鍵の権限をSSHが受け入れる安全な権限にする。
# 権限が広すぎると、SSH接続時にエラーになる。
chmod 400 "$KEY_FILE"

echo "Key pair created: $KEY_NAME"
echo "Private key saved: $KEY_FILE"

echo "=== Launch Bastion Instance ==="

# Bastion用EC2を起動する。
# Public Subnetに配置し、Public IPを自動割り当てしてSSHできるようにする。
BASTION_ID=$(aws ec2 run-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_BASTION_ID" \
  --subnet-id "$PUB01_ID" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Waiting for Bastion ($BASTION_ID) to be running..."

# EC2の状態が running になるまで待つ。
# 起動完了前にPublic IPを取得したりSSHしようとすると失敗することがある。
aws ec2 wait instance-running \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$BASTION_ID"

# BastionのPublic IPを取得する。
# ローカルPCからSSH接続するために使う。
PUBLIC_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# BastionのPrivate IPを取得する。
# VPC内での通信確認や、構成把握のために表示する。
PRIVATE_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo "Bastion is running."
echo "Instance ID: $BASTION_ID"
echo "Public IP: $PUBLIC_IP"
echo "Private IP: $PRIVATE_IP"

echo "=== SSH Command ==="

# Bastionへ接続するためのSSHコマンドを表示する。
# Amazon Linux 2023の標準ユーザーは ec2-user。
echo "ssh -i $KEY_FILE ec2-user@$PUBLIC_IP"

echo "=== Describe Bastion Instance ==="

# 作成したBastion EC2の状態を確認する。
# running、PublicIP、PrivateIP、Subnetが期待通りか見る。
aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`].Value|[0],ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,Subnet:SubnetId}' \
  --output table

