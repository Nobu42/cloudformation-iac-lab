#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# Private DNSを関連付けるVPC。
VPC_NAME="sample-vpc"

# 作成するPrivate Hosted Zone名。
# VPC内だけで使う内部DNS名として利用する。
PRIVATE_ZONE_NAME="home"
PRIVATE_ZONE_NAME_DOT="${PRIVATE_ZONE_NAME}."

# DNSレコードを作成する対象リソース名。
BASTION_INSTANCE_NAME="sample-ec2-bastion"
WEB01_INSTANCE_NAME="sample-ec2-web01"
WEB02_INSTANCE_NAME="sample-ec2-web02"
DB_INSTANCE_IDENTIFIER="sample-db"

# 作成するPrivate DNSレコード名。
BASTION_RECORD_NAME="bastion"
WEB01_RECORD_NAME="web01"
WEB02_RECORD_NAME="web02"
DB_RECORD_NAME="db"

# Private DNSのTTL。
TTL="300"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# IDや値の取得に失敗した場合に、分かりやすいメッセージで止めるための関数。
get_required_value() {
  local label="$1"
  local value="$2"

  if [ "$value" = "None" ] || [ -z "$value" ]; then
    echo "Error: $label not found. Please check previous setup scripts."
    exit 1
  fi

  echo "$value"
}

echo "=== Caller Identity ==="

# DNSは名前解決に関わるため、操作先アカウントを確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get VPC ID ==="

# Private Hosted Zoneを関連付けるVPCを取得する。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

VPC_ID=$(get_required_value "VPC" "$VPC_ID")

echo "VPC ID: $VPC_ID"

echo "=== Create or Get Private Hosted Zone ==="

# Private Hosted Zoneがすでに存在するか確認する。
# Config.PrivateZone == true のものだけを対象にする。
PRIVATE_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$PRIVATE_ZONE_NAME_DOT" \
  --query "HostedZones[?Name==\`$PRIVATE_ZONE_NAME_DOT\` && Config.PrivateZone==\`true\`].Id | [0]" \
  --output text)

if [ "$PRIVATE_HOSTED_ZONE_ID" = "None" ] || [ -z "$PRIVATE_HOSTED_ZONE_ID" ]; then
  echo "Private Hosted Zone not found. Creating: $PRIVATE_ZONE_NAME"

  # Private Hosted Zoneを作成し、sample-vpcに関連付ける。
  # CallerReferenceは作成リクエストを一意にするための値。
  PRIVATE_HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
    --profile "$PROFILE" \
    --name "$PRIVATE_ZONE_NAME" \
    --vpc VPCRegion="$REGION",VPCId="$VPC_ID" \
    --caller-reference "terraform-iac-lab-${PRIVATE_ZONE_NAME}-$(date +%Y%m%d%H%M%S)" \
    --hosted-zone-config Comment="Private hosted zone for learning lab",PrivateZone=true \
    --query 'HostedZone.Id' \
    --output text)

  echo "Private Hosted Zone created: $PRIVATE_HOSTED_ZONE_ID"
else
  echo "Private Hosted Zone already exists: $PRIVATE_HOSTED_ZONE_ID"
fi

# Route 53のHosted Zone IDは "/hostedzone/XXXXXXXX" の形式で返るため、ID部分だけにする。
PRIVATE_HOSTED_ZONE_ID="${PRIVATE_HOSTED_ZONE_ID#/hostedzone/}"

echo "Private Hosted Zone ID: $PRIVATE_HOSTED_ZONE_ID"

echo "=== Get Private IP Addresses ==="

# BastionのPrivate IPを取得する。
BASTION_PRIVATE_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$BASTION_INSTANCE_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

BASTION_PRIVATE_IP=$(get_required_value "Bastion Private IP" "$BASTION_PRIVATE_IP")

# Web01のPrivate IPを取得する。
WEB01_PRIVATE_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$WEB01_INSTANCE_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

WEB01_PRIVATE_IP=$(get_required_value "Web01 Private IP" "$WEB01_PRIVATE_IP")

# Web02のPrivate IPを取得する。
WEB02_PRIVATE_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$WEB02_INSTANCE_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

WEB02_PRIVATE_IP=$(get_required_value "Web02 Private IP" "$WEB02_PRIVATE_IP")

echo "Bastion Private IP: $BASTION_PRIVATE_IP"
echo "Web01 Private IP: $WEB01_PRIVATE_IP"
echo "Web02 Private IP: $WEB02_PRIVATE_IP"

echo "=== Get RDS Endpoint ==="

# RDSのEndpointを取得する。
# db.home はこのEndpointへCNAMEで向ける。
DB_ENDPOINT=$(aws rds describe-db-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

DB_ENDPOINT=$(get_required_value "RDS Endpoint" "$DB_ENDPOINT")

echo "RDS Endpoint: $DB_ENDPOINT"

echo "=== Create / Update Private DNS Records ==="

# UPSERTを使う。
# レコードがなければ作成、すでにあれば更新する。
# EC2やRDSを作り直してIPやEndpointが変わった場合も、このスクリプトを再実行すれば更新できる。
CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Create or update private DNS records for learning lab",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${BASTION_RECORD_NAME}.${PRIVATE_ZONE_NAME}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [
          {
            "Value": "${BASTION_PRIVATE_IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${WEB01_RECORD_NAME}.${PRIVATE_ZONE_NAME}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [
          {
            "Value": "${WEB01_PRIVATE_IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${WEB02_RECORD_NAME}.${PRIVATE_ZONE_NAME}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [
          {
            "Value": "${WEB02_PRIVATE_IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DB_RECORD_NAME}.${PRIVATE_ZONE_NAME}",
        "Type": "CNAME",
        "TTL": ${TTL},
        "ResourceRecords": [
          {
            "Value": "${DB_ENDPOINT}"
          }
        ]
      }
    }
  ]
}
EOF
)

CHANGE_ID=$(aws route53 change-resource-record-sets \
  --profile "$PROFILE" \
  --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" \
  --query 'ChangeInfo.Id' \
  --output text)

CHANGE_ID=$(get_required_value "Route 53 Change ID" "$CHANGE_ID")

echo "Route 53 Change ID: $CHANGE_ID"

echo "=== Wait for DNS Change to be INSYNC ==="

# Route 53上でレコード変更が反映されるまで待つ。
aws route53 wait resource-record-sets-changed \
  --profile "$PROFILE" \
  --id "$CHANGE_ID"

echo "DNS change is INSYNC."

echo "=== Describe Created Private DNS Records ==="

# 作成したPrivate DNSレコードを確認する。
aws route53 list-resource-record-sets \
  --profile "$PROFILE" \
  --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name==\`${BASTION_RECORD_NAME}.${PRIVATE_ZONE_NAME}.\` || Name==\`${WEB01_RECORD_NAME}.${PRIVATE_ZONE_NAME}.\` || Name==\`${WEB02_RECORD_NAME}.${PRIVATE_ZONE_NAME}.\` || Name==\`${DB_RECORD_NAME}.${PRIVATE_ZONE_NAME}.\`]" \
  --output table

echo "------------------------------------------------"
echo "Route 53 private DNS setup completed."
echo "Private DNS records:"
echo "  ${BASTION_RECORD_NAME}.${PRIVATE_ZONE_NAME} -> ${BASTION_PRIVATE_IP}"
echo "  ${WEB01_RECORD_NAME}.${PRIVATE_ZONE_NAME}   -> ${WEB01_PRIVATE_IP}"
echo "  ${WEB02_RECORD_NAME}.${PRIVATE_ZONE_NAME}   -> ${WEB02_PRIVATE_IP}"
echo "  ${DB_RECORD_NAME}.${PRIVATE_ZONE_NAME}      -> ${DB_ENDPOINT}"
echo "------------------------------------------------"
echo "Check from EC2 instances in the VPC:"
echo "  dig ${WEB01_RECORD_NAME}.${PRIVATE_ZONE_NAME}"
echo "  dig ${DB_RECORD_NAME}.${PRIVATE_ZONE_NAME}"
echo "------------------------------------------------"

