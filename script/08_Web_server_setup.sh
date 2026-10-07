#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# Webサーバー作成で参照するリソース名。
# WebサーバーはPrivate Subnetに配置し、Bastion経由でSSHする。
VPC_NAME="sample-vpc"
PRIVATE_SUBNET_01_NAME="sample-subnet-private01"
PRIVATE_SUBNET_02_NAME="sample-subnet-private02"
BASTION_INSTANCE_NAME="sample-ec2-bastion"
BASTION_SG_NAME="sample-sg-bastion"
ELB_SG_NAME="sample-sg-elb"
WEB_SG_NAME="sample-sg-web"

# EC2で使うKey Pair名と秘密鍵ファイル。
# Bastion作成時に作ったKey PairをWebサーバーでも使う。
KEY_NAME="nobu"
KEY_FILE="${KEY_NAME}.pem"

# WebサーバーのインスタンスタイプとNameタグ。
INSTANCE_TYPE="t3.small"
WEB01_NAME="sample-ec2-web01"
WEB02_NAME="sample-ec2-web02"

# Webサーバー起動時に使用するAMIの切り替え設定。
#
# false:
#   Amazon Linux 2023の最新AMIをSSM Parameter Storeから取得して使用する。
#
# true:
#   AnsibleでRuby、Bundler、nginx、deployユーザーを導入済みの
#   カスタムAMIを使用する。毎回Rubyをソースビルドしないため、
#   日次の再構築時間を短縮できる。
USE_CUSTOM_WEB_AMI=true
CUSTOM_WEB_AMI_ID="ami-00f86224c38cc3b8c"

# ALBからWebサーバーへ転送するアプリケーション用ポート。
# 後続のALB設定でもこのポートを使う。
APP_PORT="3000"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# Webサーバー起動時に使用するAMI IDを決める。
#
# カスタムAMIを使う場合:
#   Ruby導入済みAMIを使い、AnsibleのRubyビルド時間を短縮する。
#
# カスタムAMIを使わない場合:
#   Amazon Linux 2023の最新AMI IDをSSM Parameter Storeから取得する。
#   AMI IDはリージョンや時期で変わるため、固定値ではなくAWS管理のパラメータから取得する。
if [ "$USE_CUSTOM_WEB_AMI" = "true" ]; then
  AMI_ID="$CUSTOM_WEB_AMI_ID"
  AMI_SOURCE="custom web base AMI"
else
  AMI_ID=$(aws ssm get-parameter \
    --profile "$PROFILE" \
    --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' \
    --output text)
  AMI_SOURCE="latest Amazon Linux 2023 AMI from SSM Parameter Store"
fi

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
# Security Group取得やEC2配置先確認に使う。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)
VPC_ID=$(get_required_id "VPC" "$VPC_ID")

# Web01を配置するPrivate Subnet 01のIDを取得する。
PRI01_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PRIVATE_SUBNET_01_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PRI01_ID=$(get_required_id "Private Subnet 01" "$PRI01_ID")

# Web02を配置するPrivate Subnet 02のIDを取得する。
PRI02_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PRIVATE_SUBNET_02_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PRI02_ID=$(get_required_id "Private Subnet 02" "$PRI02_ID")

# 起動中のBastion EC2を取得する。
# WebサーバーへのSSHはBastion経由で行うため、Bastionが起動している必要がある。
BASTION_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$BASTION_INSTANCE_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
BASTION_ID=$(get_required_id "Bastion Instance" "$BASTION_ID")

# BastionのPublic IPを取得する。
# SSHのProxyJump先として使う。
BASTION_PUBLIC_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
BASTION_PUBLIC_IP=$(get_required_id "Bastion Public IP" "$BASTION_PUBLIC_IP")

# Bastion用Security GroupのIDを取得する。
# Webサーバー側のSecurity Groupで、このSGからのSSHだけを許可する。
BASTION_SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$BASTION_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
BASTION_SG_ID=$(get_required_id "Bastion Security Group" "$BASTION_SG_ID")

# ELB用Security GroupのIDを取得する。
# Webサーバー側のSecurity Groupで、このSGからのアプリ通信だけを許可する。
ELB_SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$ELB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
ELB_SG_ID=$(get_required_id "ELB Security Group" "$ELB_SG_ID")

# 取得した値を表示し、想定したリソースを使うことを確認する。
echo "VPC: $VPC_ID"
echo "Private Subnet 01: $PRI01_ID"
echo "Private Subnet 02: $PRI02_ID"
echo "Bastion Instance: $BASTION_ID"
echo "Bastion Public IP: $BASTION_PUBLIC_IP"
echo "Bastion Security Group: $BASTION_SG_ID"
echo "ELB Security Group: $ELB_SG_ID"
echo "AMI: $AMI_ID"
echo "AMI Source: $AMI_SOURCE"

echo "=== Create Web Security Group ==="

# Webサーバー用のSecurity Groupを作成する。
# SSHはBastionからのみ、アプリ通信はALBからのみ許可する。
WEB_SG_ID=$(aws ec2 create-security-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-name "$WEB_SG_NAME" \
  --description "for web servers" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$WEB_SG_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'GroupId' \
  --output text)

# Bastion SGからのSSH接続だけを許可する。
# 送信元にCIDRではなくSecurity Groupを指定している点がポイント。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$WEB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$BASTION_SG_ID,Description='SSH from bastion'}]"

# ALB SGからのアプリケーション通信だけを許可する。
# 後続のALB Target Groupでは、このポートへ転送する想定。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$WEB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$APP_PORT,ToPort=$APP_PORT,UserIdGroupPairs=[{GroupId=$ELB_SG_ID,Description='Application traffic from ALB'}]"

echo "Web Security Group: $WEB_SG_ID"

echo "=== Launch Web Servers ==="

# Web01をPrivate Subnet 01に起動する。
# Public IPは付与しないため、外部から直接SSHできない。
WEB01_ID=$(aws ec2 run-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$WEB_SG_ID" \
  --subnet-id "$PRI01_ID" \
  --no-associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$WEB01_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

# Web02をPrivate Subnet 02に起動する。
# Web01とは別AZのPrivate Subnetに配置している。
WEB02_ID=$(aws ec2 run-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$WEB_SG_ID" \
  --subnet-id "$PRI02_ID" \
  --no-associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$WEB02_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Created Web01: $WEB01_ID"
echo "Created Web02: $WEB02_ID"

echo "=== Wait for Web Servers to be running ==="

# Webサーバー2台が running になるまで待つ。
# 起動完了前にPrivate IPを取得したりSSHしようとすると失敗することがある。
aws ec2 wait instance-running \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$WEB01_ID" "$WEB02_ID"

# Webサーバー2台のName、Instance ID、状態、Private IP、Subnet IDを取得する。
WEB_INFO=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$WEB01_ID" "$WEB02_ID" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],InstanceId,State.Name,PrivateIpAddress,SubnetId]' \
  --output text)

# 取得した一覧から、Web01のPrivate IPだけを取り出す。
IP01=$(echo "$WEB_INFO" | awk '$1=="sample-ec2-web01"{print $4}')

# 取得した一覧から、Web02のPrivate IPだけを取り出す。
IP02=$(echo "$WEB_INFO" | awk '$1=="sample-ec2-web02"{print $4}')

echo "Web01 Private IP: $IP01"
echo "Web02 Private IP: $IP02"

echo "=== SSH Commands via Bastion ==="

# Bastionを踏み台にしてWeb01へSSHするコマンドを表示する。
# -J は ProxyJump の指定。
echo "ssh -i $KEY_FILE -J ec2-user@$BASTION_PUBLIC_IP ec2-user@$IP01"

# Bastionを踏み台にしてWeb02へSSHするコマンドを表示する。
echo "ssh -i $KEY_FILE -J ec2-user@$BASTION_PUBLIC_IP ec2-user@$IP02"

echo "=== Describe Web Instances ==="

# 作成したWebサーバー2台の状態を確認する。
# PublicIPが None で、PrivateIPが割り当てられていればPrivate Subnet配置として期待通り。
aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --instance-ids "$WEB01_ID" "$WEB02_ID" \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`].Value|[0],ID:InstanceId,State:State.Name,Type:InstanceType,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,Subnet:SubnetId}' \
  --output table

echo "=== SSH config block ==="

# ~/.ssh/config に貼り付けるための設定例を表示する。
# 個人環境のSSH設定をスクリプトで直接変更せず、確認してから手動で反映する。
cat <<EOF
Host bastion
  HostName $BASTION_PUBLIC_IP
  User ec2-user
  IdentityFile $(pwd)/$KEY_FILE
  IdentitiesOnly yes

Host web01
  HostName $IP01
  User ec2-user
  IdentityFile $(pwd)/$KEY_FILE
  IdentitiesOnly yes
  ProxyJump bastion

Host web02
  HostName $IP02
  User ec2-user
  IdentityFile $(pwd)/$KEY_FILE
  IdentitiesOnly yes
  ProxyJump bastion
EOF
