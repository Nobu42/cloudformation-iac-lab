#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# SESの受信はリージョンごとに設定するため、今回は東京リージョンを使う。
PROFILE="learning"
REGION="ap-northeast-1"

# メールを受信する独自ドメイン。
# Route 53のPublic Hosted Zoneもこのドメインで作成済み。
DOMAIN_NAME="nobu-iac-lab.com"
DOMAIN_NAME_DOT="${DOMAIN_NAME}."

# SESで受信したメールを保存するS3バケット。
# SESはメールボックスを持つサービスではないため、受信メールをS3などへ配送する。
MAIL_BUCKET_NAME="nobu-iac-lab-mailbox"

# S3バケット内でメールを保存するフォルダ相当のプレフィックス。
# 実際にはS3にフォルダはないが、キー名の先頭に inbox/ を付けて整理する。
MAIL_OBJECT_PREFIX="inbox/"

# SESの受信ルール設定。
# Rule Setは受信ルールをまとめる箱。
# Ruleは「どの宛先のメールを、どこへ配送するか」を定義する。
RULE_SET_NAME="sample-ruleset"
RULE_NAME="sample-rule-inquiry"

# 今回受信対象にするメールアドレス。
# このアドレス宛に届いたメールだけをS3へ保存する。
RECIPIENT_EMAIL="inquiry@${DOMAIN_NAME}"

# Route 53に作成するMXレコード。
# レコード名をドメイン直下にするため、Route 53画面上では名前欄は空欄に相当する。
# 値は東京リージョンのSES受信エンドポイント。
MX_RECORD_NAME="${DOMAIN_NAME}"
MX_RECORD_VALUE="10 inbound-smtp.${REGION}.amazonaws.com"

# LocalStack向けのaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
# 実AWSに対して操作するため、念のため毎回解除する。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# AWS CLIの取得結果が None や空だった場合に、分かりやすく止めるための関数。
# 途中のID取得に失敗したまま進むと、別リソースを触ったり原因が分かりづらくなる。
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

# S3、SES、Route 53を操作するため、現在どのAWSアカウントで実行しているか確認する。
# Account IDは後続のS3バケットポリシーでも利用する。
ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile "$PROFILE" \
  --query 'Account' \
  --output text)

ACCOUNT_ID=$(get_required_value "AWS Account ID" "$ACCOUNT_ID")

aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "AWS Account ID: $ACCOUNT_ID"

echo "=== Get Public Hosted Zone ID ==="

# MXレコードを追加するため、nobu-iac-lab.com のPublic Hosted Zone IDを取得する。
# Private Hosted Zoneと混ざらないように、Config.PrivateZone=false のものだけを対象にする。
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$DOMAIN_NAME_DOT" \
  --query "HostedZones[?Name==\`$DOMAIN_NAME_DOT\` && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text)

HOSTED_ZONE_ID=$(get_required_value "Public Hosted Zone" "$HOSTED_ZONE_ID")

# Route 53のHosted Zone IDは /hostedzone/XXXXXXXX の形で返ることがあるため、ID部分だけにする。
HOSTED_ZONE_ID="${HOSTED_ZONE_ID#/hostedzone/}"

echo "Hosted Zone ID: $HOSTED_ZONE_ID"

echo "=== Create S3 Bucket for Received Emails ==="

# 受信メール保存用のS3バケットを作成する。
# すでに存在してアクセスできる場合は、そのまま再利用する。
if aws s3api head-bucket \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$MAIL_BUCKET_NAME" >/dev/null 2>&1; then
  echo "S3 bucket already exists and is accessible: $MAIL_BUCKET_NAME"
else
  echo "Creating S3 bucket: $MAIL_BUCKET_NAME"

  # ap-northeast-1 のような us-east-1 以外のリージョンでは、
  # create-bucket時に LocationConstraint の指定が必要。
  aws s3api create-bucket \
    --profile "$PROFILE" \
    --region "$REGION" \
    --bucket "$MAIL_BUCKET_NAME" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null

  echo "S3 bucket created: $MAIL_BUCKET_NAME"
fi

echo "=== Block Public Access on Mail Bucket ==="

# 受信メールには個人情報や本文が含まれる可能性があるため、
# S3バケットのパブリックアクセスはすべてブロックする。
aws s3api put-public-access-block \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$MAIL_BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "=== Disable ACLs on Mail Bucket ==="

# ACLを無効化し、バケット所有者に所有権を統一する。
# 現在のS3では、ACLを使わずBucket PolicyやIAMで制御するのが基本。
aws s3api put-bucket-ownership-controls \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$MAIL_BUCKET_NAME" \
  --ownership-controls '{
    "Rules": [
      {
        "ObjectOwnership": "BucketOwnerEnforced"
      }
    ]
  }'

echo "=== Put S3 Bucket Policy for SES Receiving ==="

# SESがS3へ受信メールを書き込めるように、バケットポリシーを作成する。
# Principalに ses.amazonaws.com を指定し、SESサービスからのPutObjectを許可する。
#
# SourceAccount:
#   自分のAWSアカウントからのSES操作だけを許可する。
#
# SourceArn:
#   指定したReceipt Ruleからの書き込みだけを許可する。
#   これにより、他のSESルールや別アカウントから勝手に書き込まれるリスクを下げる。
SOURCE_ARN="arn:aws:ses:${REGION}:${ACCOUNT_ID}:receipt-rule-set/${RULE_SET_NAME}:receipt-rule/${RULE_NAME}"

BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSESPuts",
      "Effect": "Allow",
      "Principal": {
        "Service": "ses.amazonaws.com"
      },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${MAIL_BUCKET_NAME}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceAccount": "${ACCOUNT_ID}",
          "AWS:SourceArn": "${SOURCE_ARN}"
        }
      }
    }
  ]
}
EOF
)

aws s3api put-bucket-policy \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$MAIL_BUCKET_NAME" \
  --policy "$BUCKET_POLICY"

echo "Bucket policy configured for SES."
echo "SES SourceArn: $SOURCE_ARN"

echo "=== Create or Get SES Receipt Rule Set ==="

# Receipt Rule Setは、SESで受信したメールに対する処理ルールをまとめる単位。
# まずRule Setが存在するか確認し、なければ作成する。
RULE_SET_EXISTS="true"
aws ses describe-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --rule-set-name "$RULE_SET_NAME" >/dev/null 2>&1 || RULE_SET_EXISTS="false"

if [ "$RULE_SET_EXISTS" = "false" ]; then
  echo "Receipt Rule Set not found. Creating: $RULE_SET_NAME"

  aws ses create-receipt-rule-set \
    --profile "$PROFILE" \
    --region "$REGION" \
    --rule-set-name "$RULE_SET_NAME"

  echo "Receipt Rule Set created: $RULE_SET_NAME"
else
  echo "Receipt Rule Set already exists: $RULE_SET_NAME"
fi

echo "=== Create or Update SES Receipt Rule ==="

# Receipt Ruleの内容をJSONで定義する。
#
# Enabled:
#   ルールを有効化する。
#
# TlsPolicy:
#   Optionalにして、TLSを使わない送信元からも受信できるようにする。
#
# Recipients:
#   inquiry@nobu-iac-lab.com 宛だけを処理対象にする。
#
# S3Action:
#   受信したメールをS3バケットへ保存する。
#
# ScanEnabled:
#   スパム・ウイルススキャンを有効化する。
RECEIPT_RULE_JSON=$(cat <<EOF
{
  "Name": "${RULE_NAME}",
  "Enabled": true,
  "TlsPolicy": "Optional",
  "Recipients": [
    "${RECIPIENT_EMAIL}"
  ],
  "Actions": [
    {
      "S3Action": {
        "BucketName": "${MAIL_BUCKET_NAME}",
        "ObjectKeyPrefix": "${MAIL_OBJECT_PREFIX}"
      }
    }
  ],
  "ScanEnabled": true
}
EOF
)

# 同じ名前のReceipt Ruleがすでにあるか確認する。
# ない場合は作成し、ある場合は更新する。
RULE_EXISTS="true"
aws ses describe-receipt-rule \
  --profile "$PROFILE" \
  --region "$REGION" \
  --rule-set-name "$RULE_SET_NAME" \
  --rule-name "$RULE_NAME" >/dev/null 2>&1 || RULE_EXISTS="false"

if [ "$RULE_EXISTS" = "false" ]; then
  echo "Receipt Rule not found. Creating: $RULE_NAME"

  aws ses create-receipt-rule \
    --profile "$PROFILE" \
    --region "$REGION" \
    --rule-set-name "$RULE_SET_NAME" \
    --rule "$RECEIPT_RULE_JSON"

  echo "Receipt Rule created: $RULE_NAME"
else
  echo "Receipt Rule already exists. Updating: $RULE_NAME"

  aws ses update-receipt-rule \
    --profile "$PROFILE" \
    --region "$REGION" \
    --rule-set-name "$RULE_SET_NAME" \
    --rule "$RECEIPT_RULE_JSON"

  echo "Receipt Rule updated: $RULE_NAME"
fi

echo "=== Activate SES Receipt Rule Set ==="

# SESで受信処理を動かすには、Receipt Rule SetをActiveにする必要がある。
# 作成しただけでは受信処理に使われないため、ここで有効なRule Setとして設定する。
aws ses set-active-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --rule-set-name "$RULE_SET_NAME"

echo "Active Receipt Rule Set: $RULE_SET_NAME"

echo "=== Create / Update MX Record ==="

# ドメイン宛メールをSESに配送するため、Route 53にMXレコードを追加する。
# レコード名はドメイン直下なので、Route 53画面では名前欄を空欄にする設定に相当する。
#
# 値:
#   10 inbound-smtp.ap-northeast-1.amazonaws.com
#
# 注意:
#   MXレコードを設定すると、nobu-iac-lab.com 宛のメール配送先がSESになる。
#   通常のメールボックスではなく、SESのReceipt Ruleに従ってS3へ保存される。
MX_CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Create or update MX record for SES email receiving",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${MX_RECORD_NAME}",
        "Type": "MX",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "${MX_RECORD_VALUE}"
          }
        ]
      }
    }
  ]
}
EOF
)

MX_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --profile "$PROFILE" \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$MX_CHANGE_BATCH" \
  --query 'ChangeInfo.Id' \
  --output text)

MX_CHANGE_ID=$(get_required_value "Route 53 MX Change ID" "$MX_CHANGE_ID")

echo "Route 53 Change ID: $MX_CHANGE_ID"

echo "=== Wait for MX Record to be INSYNC ==="

# Route 53上でMXレコードの変更が反映されるまで待つ。
aws route53 wait resource-record-sets-changed \
  --profile "$PROFILE" \
  --id "$MX_CHANGE_ID"

echo "MX record is INSYNC."

echo "=== Describe SES Receipt Rule Set ==="

# Receipt Rule Setの中身を確認する。
# 受信対象、スキャン設定、保存先S3バケットが想定どおりかを見る。
aws ses describe-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --rule-set-name "$RULE_SET_NAME" \
  --query 'Rules[*].{Name:Name,Enabled:Enabled,Recipients:Recipients,ScanEnabled:ScanEnabled,Actions:Actions[*].S3Action.BucketName}' \
  --output table

echo "=== Describe Active Receipt Rule Set ==="

# 現在ActiveになっているReceipt Rule Setを確認する。
aws ses describe-active-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'Metadata.Name' \
  --output table

echo "=== Describe MX Record ==="

# Route 53上のMXレコードを確認する。
aws route53 list-resource-record-sets \
  --profile "$PROFILE" \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name==\`${DOMAIN_NAME}.\` && Type==\`MX\`]" \
  --output table

echo "------------------------------------------------"
echo "SES receiving setup completed."
echo "Recipient:"
echo "  ${RECIPIENT_EMAIL}"
echo "MX:"
echo "  ${MX_RECORD_VALUE}"
echo "Receipt Rule Set:"
echo "  ${RULE_SET_NAME}"
echo "Receipt Rule:"
echo "  ${RULE_NAME}"
echo "S3 Bucket:"
echo "  s3://${MAIL_BUCKET_NAME}/${MAIL_OBJECT_PREFIX}"
echo "------------------------------------------------"
echo "Test:"
echo "  Send an email to ${RECIPIENT_EMAIL}"
echo "Then check:"
echo "  aws s3 ls s3://${MAIL_BUCKET_NAME}/${MAIL_OBJECT_PREFIX} --profile ${PROFILE}"
echo "------------------------------------------------"

