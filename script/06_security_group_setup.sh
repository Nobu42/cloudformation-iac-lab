#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# Security Groupを作成する対象VPCのNameタグ。
VPC_NAME="sample-vpc"

# 作成するSecurity Groupの名前。
# Bastion用はSSH接続、ELB用はHTTP/HTTPS接続を受けるために使う。
BASTION_SG_NAME="sample-sg-bastion"
ELB_SG_NAME="sample-sg-elb"

# 現在の自分のグローバルIPを取得する。
# BastionへのSSHをインターネット全体ではなく、自分のIPだけに絞るため。
MY_GLOBAL_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')

# グローバルIPが取得できなかった場合は、SSH許可ルールを作れないためここで止める。
if [ -z "$MY_GLOBAL_IP" ]; then
  echo "Error: Could not detect global IP address."
  exit 1
fi

# /32 は「このIPアドレス1つだけ」を意味する。
# 例: 203.0.113.10/32 なら、そのIPからのSSHだけを許可する。
SSH_ALLOWED_CIDR="${MY_GLOBAL_IP}/32"

# ALBは外部からHTTP/HTTPSを受ける想定なので、全体から許可する。
# 学習環境ではこの形にしているが、実運用では要件に応じて制限する。
HTTP_ALLOWED_CIDR="0.0.0.0/0"
HTTPS_ALLOWED_CIDR="0.0.0.0/0"

echo "SSH allowed CIDR: $SSH_ALLOWED_CIDR"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "=== Caller Identity ==="

# いま操作しているAWSアカウントとIAMユーザーを確認する。
# 想定外のアカウントにSecurity Groupを作らないための確認。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get VPC ID ==="

# Nameタグが sample-vpc のVPCを探し、VPC IDだけを取得する。
# Security GroupはVPCに紐づけて作成するため、VPC IDが必要。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# VPCが見つからない場合はここで止める。
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "Error: VPC not found. Please run 01_vpc_setup.sh first."
  exit 1
fi

echo "Target VPC ID: $VPC_ID"

echo "=== Create Bastion Security Group ==="

# 踏み台サーバー用のSecurity Groupを作成する。
# この時点ではルールはまだ追加されていない。
SG_BASTION_ID=$(aws ec2 create-security-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-name "$BASTION_SG_NAME" \
  --description "for bastion server" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$BASTION_SG_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'GroupId' \
  --output text)

# BastionへSSH接続できるように、22番ポートを許可する。
# 送信元は現在の自分のグローバルIP /32 に限定している。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$SG_BASTION_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SSH_ALLOWED_CIDR,Description='SSH access for learning'}]"

echo "Bastion Security Group: $SG_BASTION_ID"

echo "=== Create ELB Security Group ==="

# ロードバランサー用のSecurity Groupを作成する。
# 後続のALB作成時に、このSecurity GroupをALBへ関連付ける。
SG_ELB_ID=$(aws ec2 create-security-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-name "$ELB_SG_NAME" \
  --description "for load balancer" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$ELB_SG_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'GroupId' \
  --output text)

# ALBでHTTP通信を受けるため、80番ポートを許可する。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$SG_ELB_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$HTTP_ALLOWED_CIDR,Description='HTTP access'}]"

# ALBでHTTPS通信を受けるため、443番ポートを許可する。
# 今後HTTPS化する場合に使う想定。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$SG_ELB_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$HTTPS_ALLOWED_CIDR,Description='HTTPS access'}]"

echo "ELB Security Group: $SG_ELB_ID"

echo "Security Groups created: Bastion($SG_BASTION_ID), ELB($SG_ELB_ID)"

echo "=== Describe Security Groups ==="

# 作成したSecurity Groupとインバウンドルールを確認する。
# Bastion用はSSH、ELB用はHTTP/HTTPSが許可されているか見る。
aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-ids "$SG_BASTION_ID" "$SG_ELB_ID" \
  --query 'SecurityGroups[*].{Name:GroupName,ID:GroupId,Description:Description,Rules:IpPermissions[*].{Protocol:IpProtocol,FromPort:FromPort,ToPort:ToPort,Cidr:IpRanges[0].CidrIp,RuleDescription:IpRanges[0].Description}}' \
  --output table

