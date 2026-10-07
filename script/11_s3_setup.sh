#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# 作成するS3バケット名。
# S3バケット名は全AWSアカウントでグローバルに一意である必要がある。
BUCKET_NAME="nobu-terraform-iac-lab-upload"

# IAMロール設定。
# Web EC2からS3へ画像などをアップロードするためのロール。
ROLE_NAME="sample-role-web"
ROLE_DESCRIPTION="upload images"
INSTANCE_PROFILE_NAME="$ROLE_NAME"

# 学習用にAWS管理ポリシーを使う。
#
# S3:
#   Rails Active Storageが投稿画像をS3へ保存するために利用する。
#   実運用では対象バケットだけに絞った最小権限ポリシーにする。
#
# CloudWatch Agent:
#   後続のCloudWatch編で、Web EC2上のnginx / Pumaログを
#   CloudWatch Logsへ送信するために利用する。
S3_POLICY_ARN="arn:aws:iam::aws:policy/AmazonS3FullAccess"
CLOUDWATCH_AGENT_POLICY_ARN="arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

# IAMロールを適用するWebサーバー。
WEB01_NAME="sample-ec2-web01"
WEB02_NAME="sample-ec2-web02"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSで作業するため、念のためここで無効化する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# 取得したIDが空、または None の場合にスクリプトを止めるための関数。
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

# IAMとS3を操作するため、作業先アカウントを確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Create S3 Bucket ==="

# S3バケットを作成する。
# ap-northeast-1 のようなus-east-1以外のリージョンでは LocationConstraint の指定が必要。
if aws s3api head-bucket \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
  echo "Bucket already exists and is accessible: $BUCKET_NAME"
else
  aws s3api create-bucket \
    --profile "$PROFILE" \
    --region "$REGION" \
    --bucket "$BUCKET_NAME" \
    --create-bucket-configuration LocationConstraint="$REGION"

  echo "Bucket created: $BUCKET_NAME"
fi

echo "=== Block Public Access ==="

# バケットのパブリックアクセスをすべてブロックする。
# 外部公開用ではなく、EC2からアプリ経由で利用する想定。
aws s3api put-public-access-block \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "=== Disable ACLs ==="

# ACLを無効化する。
# BucketOwnerEnforcedにすると、オブジェクト所有者はバケット所有者に統一され、ACLは使わない運用になる。
aws s3api put-bucket-ownership-controls \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" \
  --ownership-controls '{
    "Rules": [
      {
        "ObjectOwnership": "BucketOwnerEnforced"
      }
    ]
  }'

echo "=== Default Encryption ==="

# 要件では「デフォルトの暗号化: 無効」。
# ここではバケット暗号化設定を追加しない。
# なお、現在のS3では新規オブジェクトはSSE-S3で自動的に暗号化される。
echo "No bucket encryption configuration is added by this script."

echo "=== Create IAM Role for EC2 ==="

# EC2がこのロールを引き受けられるようにする信頼ポリシー。
# Principalに ec2.amazonaws.com を指定する。
TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

# IAMロールがなければ作成する。
if aws iam get-role \
  --profile "$PROFILE" \
  --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM Role already exists: $ROLE_NAME"
else
  aws iam create-role \
    --profile "$PROFILE" \
    --role-name "$ROLE_NAME" \
    --description "$ROLE_DESCRIPTION" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags Key=Name,Value="$ROLE_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning

  echo "IAM Role created: $ROLE_NAME"
fi

echo "=== Attach Policy to IAM Role ==="

# Web EC2からS3を操作できるように、学習用としてAmazonS3FullAccessを付与する。
aws iam attach-role-policy \
  --profile "$PROFILE" \
  --role-name "$ROLE_NAME" \
  --policy-arn "$S3_POLICY_ARN"

echo "Policy attached: $S3_POLICY_ARN"

# CloudWatch AgentがCloudWatch Logsへログを送信できるようにする。
# この権限がないと、AgentをインストールしてもLog Group / Log Stream作成や
# PutLogEventsに失敗し、nginx / PumaログがCloudWatch Logsへ届かない。
aws iam attach-role-policy \
  --profile "$PROFILE" \
  --role-name "$ROLE_NAME" \
  --policy-arn "$CLOUDWATCH_AGENT_POLICY_ARN"

echo "Policy attached: $CLOUDWATCH_AGENT_POLICY_ARN"

echo "=== Create Instance Profile ==="

# EC2にIAMロールを付けるには、IAM RoleをInstance Profileに入れる必要がある。
if aws iam get-instance-profile \
  --profile "$PROFILE" \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "Instance Profile already exists: $INSTANCE_PROFILE_NAME"
else
  aws iam create-instance-profile \
    --profile "$PROFILE" \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --tags Key=Name,Value="$INSTANCE_PROFILE_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning

  echo "Instance Profile created: $INSTANCE_PROFILE_NAME"
fi

# Instance ProfileにRoleを追加する。
# すでに追加済みの場合はエラーになるため、その場合は続行する。
aws iam add-role-to-instance-profile \
  --profile "$PROFILE" \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --role-name "$ROLE_NAME" 2>/dev/null || echo "Role is already added to Instance Profile."

echo "Waiting for IAM propagation..."
sleep 15

echo "=== Get Web Instance IDs ==="

# 起動中のWeb01 EC2を取得する。
WEB01_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$WEB01_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
WEB01_ID=$(get_required_id "Web01 Instance" "$WEB01_ID")

# 起動中のWeb02 EC2を取得する。
WEB02_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$WEB02_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
WEB02_ID=$(get_required_id "Web02 Instance" "$WEB02_ID")

echo "Web01: $WEB01_ID"
echo "Web02: $WEB02_ID"

attach_or_replace_instance_profile() {
  local instance_id="$1"

  # EC2にすでにIAM Instance Profileが付いているか確認する。
  local association_id
  association_id=$(aws ec2 describe-iam-instance-profile-associations \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters Name=instance-id,Values="$instance_id" \
    --query 'IamInstanceProfileAssociations[0].AssociationId' \
    --output text)

  if [ "$association_id" = "None" ] || [ -z "$association_id" ]; then
    echo "Associating Instance Profile to $instance_id"

    aws ec2 associate-iam-instance-profile \
      --profile "$PROFILE" \
      --region "$REGION" \
      --instance-id "$instance_id" \
      --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" >/dev/null
  else
    echo "Replacing Instance Profile on $instance_id"

    aws ec2 replace-iam-instance-profile-association \
      --profile "$PROFILE" \
      --region "$REGION" \
      --association-id "$association_id" \
      --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" >/dev/null
  fi
}

echo "=== Attach IAM Role to Web EC2 Instances ==="

attach_or_replace_instance_profile "$WEB01_ID"
attach_or_replace_instance_profile "$WEB02_ID"

echo "=== Describe S3 Bucket Settings ==="

# パブリックアクセスブロック設定を確認する。
aws s3api get-public-access-block \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" \
  --output table

# ACL無効化の設定を確認する。
aws s3api get-bucket-ownership-controls \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" \
  --output table

echo "=== Describe IAM Instance Profile Associations ==="

# Web EC2にInstance Profileが関連付いているか確認する。
# JMESPathのsplit関数は使えない環境があるため、ProfileArnをそのまま表示する。
aws ec2 describe-iam-instance-profile-associations \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=instance-id,Values="$WEB01_ID","$WEB02_ID" \
  --query 'IamInstanceProfileAssociations[*].{InstanceId:InstanceId,State:State,ProfileArn:IamInstanceProfile.Arn}' \
  --output table

echo "------------------------------------------------"
echo "S3 setup completed."
echo "Bucket: $BUCKET_NAME"
echo "IAM Role: $ROLE_NAME"
echo "Applied to: $WEB01_ID, $WEB02_ID"
echo "------------------------------------------------"
