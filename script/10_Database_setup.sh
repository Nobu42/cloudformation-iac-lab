#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# RDSを作成するVPCとPrivate Subnet。
# DBは外部公開しないため、Private Subnetに配置する。
VPC_NAME="sample-vpc"
PRIVATE_SUBNET_01_NAME="sample-subnet-private01"
PRIVATE_SUBNET_02_NAME="sample-subnet-private02"

# Webサーバー用Security Group。
# DBはWebサーバーからのMySQL接続だけを許可する。
WEB_SG_NAME="sample-sg-web"
DB_SG_NAME="sample-sg-db"

# RDS関連リソース名。
DB_PARAMETER_GROUP_NAME="sample-db-pg"
DB_OPTION_GROUP_NAME="sample-db-og"
DB_SUBNET_GROUP_NAME="sample-db-subnet"
DB_INSTANCE_IDENTIFIER="sample-db"

# MySQL設定。
DB_ENGINE="mysql"
DB_ENGINE_VERSION="8.0"
DB_PARAMETER_GROUP_FAMILY="mysql8.0"
DB_MAJOR_ENGINE_VERSION="8.0"
DB_PORT="3306"

# RDSインスタンス設定。
# 学習用の小さい構成。利用できるクラスはアカウントやリージョンで確認する。
DB_INSTANCE_CLASS="db.t3.micro"
DB_ALLOCATED_STORAGE="20"
DB_MASTER_USERNAME="adminuser"

# DBパスワードはスクリプトに直書きしない。
# 実行前に以下のように設定する。
# export DB_MASTER_PASSWORD='任意の強いパスワード'
if [ -z "${DB_MASTER_PASSWORD:-}" ]; then
  echo "Error: DB_MASTER_PASSWORD is not set."
  echo "Please run: export DB_MASTER_PASSWORD='your-strong-password'"
  exit 1
fi

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

# RDSは課金対象なので、作成前に操作先アカウントを必ず確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get Resource IDs ==="

# VPC IDを取得する。
# DB Subnet GroupやSecurity Group作成で使う。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)
VPC_ID=$(get_required_id "VPC" "$VPC_ID")

# DBを配置するPrivate Subnet 2つを取得する。
# RDSのDB Subnet Groupには、複数AZのSubnetを指定する。
SUBNET_PRIV01=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PRIVATE_SUBNET_01_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
SUBNET_PRIV01=$(get_required_id "Private Subnet 01" "$SUBNET_PRIV01")

SUBNET_PRIV02=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PRIVATE_SUBNET_02_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
SUBNET_PRIV02=$(get_required_id "Private Subnet 02" "$SUBNET_PRIV02")

# Webサーバー用Security Groupを取得する。
# DB用Security Groupでは、このSGからの3306番だけを許可する。
WEB_SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$WEB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
WEB_SG_ID=$(get_required_id "Web Security Group" "$WEB_SG_ID")

echo "VPC: $VPC_ID"
echo "Private Subnets: $SUBNET_PRIV01, $SUBNET_PRIV02"
echo "Web Security Group: $WEB_SG_ID"

echo "=== Create DB Security Group ==="

# DB用Security Groupを作成する。
# RDSにはこのSGを関連付け、WebサーバーからのDB接続だけを許可する。
DB_SG_ID=$(aws ec2 create-security-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-name "$DB_SG_NAME" \
  --description "for RDS database" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
  --query 'GroupId' \
  --output text)

# Webサーバー用SGからDB用SGへのMySQL接続を許可する。
# 送信元にCIDRではなくSecurity Groupを指定している。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$DB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$DB_PORT,ToPort=$DB_PORT,UserIdGroupPairs=[{GroupId=$WEB_SG_ID,Description='MySQL access from web servers'}]"

echo "DB Security Group: $DB_SG_ID"

echo "=== Create DB Parameter Group ==="

# DB Parameter Groupを作成する。
# MySQLの設定値を管理するためのグループ。
aws rds create-db-parameter-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-parameter-group-name "$DB_PARAMETER_GROUP_NAME" \
  --db-parameter-group-family "$DB_PARAMETER_GROUP_FAMILY" \
  --description "sample parameter group" \
  --tags Key=Name,Value="$DB_PARAMETER_GROUP_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning

echo "=== Create DB Option Group ==="

# DB Option Groupを作成する。
# MySQLの追加オプションを管理するためのグループ。
aws rds create-option-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --option-group-name "$DB_OPTION_GROUP_NAME" \
  --engine-name "$DB_ENGINE" \
  --major-engine-version "$DB_MAJOR_ENGINE_VERSION" \
  --option-group-description "sample option group" \
  --tags Key=Name,Value="$DB_OPTION_GROUP_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning

echo "=== Create DB Subnet Group ==="

# DB Subnet Groupを作成する。
# RDSをどのSubnet群に配置できるかを定義する。
# 今回はPrivate Subnet 2つを指定し、DBを外部公開しない構成にする。
aws rds create-db-subnet-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
  --db-subnet-group-description "sample db subnet group" \
  --subnet-ids "$SUBNET_PRIV01" "$SUBNET_PRIV02" \
  --tags Key=Name,Value="$DB_SUBNET_GROUP_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning

echo "=== Create RDS Instance ==="

# RDS MySQLインスタンスを作成する。
# --no-publicly-accessible により、インターネットから直接接続できないDBにする。
# 接続元はSecurity GroupでWebサーバーに限定する。
aws rds create-db-instance \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --engine "$DB_ENGINE" \
  --engine-version "$DB_ENGINE_VERSION" \
  --db-instance-class "$DB_INSTANCE_CLASS" \
  --allocated-storage "$DB_ALLOCATED_STORAGE" \
  --storage-type gp2 \
  --master-username "$DB_MASTER_USERNAME" \
  --master-user-password "$DB_MASTER_PASSWORD" \
  --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --db-parameter-group-name "$DB_PARAMETER_GROUP_NAME" \
  --option-group-name "$DB_OPTION_GROUP_NAME" \
  --no-publicly-accessible \
  --backup-retention-period 0 \
  --no-multi-az \
  --no-deletion-protection \
  --tags Key=Name,Value="$DB_INSTANCE_IDENTIFIER" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning

echo "Waiting for RDS instance to be available..."

# RDS作成には時間がかかる。
# availableになるまで待ってから確認する。
aws rds wait db-instance-available \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"

echo "RDS Instance created successfully."

echo "=== Describe RDS Instance ==="

# 作成したRDSの状態、エンドポイント、公開設定を確認する。
aws rds describe-db-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Class:DBInstanceClass,Endpoint:Endpoint.Address,Port:Endpoint.Port,PubliclyAccessible:PubliclyAccessible,MultiAZ:MultiAZ}' \
  --output table

