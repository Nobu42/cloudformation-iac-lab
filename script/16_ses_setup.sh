#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# SESで認証するドメイン。
DOMAIN_NAME="nobu-iac-lab.com"
DOMAIN_NAME_DOT="${DOMAIN_NAME}."

# sandbox中の送信テスト先として認証するメールアドレス。
# SES sandboxでは送信元だけでなく送信先も検証済みである必要がある。
VERIFY_EMAIL_ADDRESS="nobu4071@icloud.com"

# Route 53のPublic Hosted Zoneに追加するメール認証用レコード。
DMARC_RECORD_NAME="_dmarc.${DOMAIN_NAME}"
SPF_RECORD_NAME="${DOMAIN_NAME}"

# DMARCは最初は監視寄りの弱い設定にする。
# p=none は拒否せず、まずは認証状況を見るための設定。
DMARC_VALUE="v=DMARC1; p=none; rua=mailto:${VERIFY_EMAIL_ADDRESS}"

# SESから送信するためのSPF設定。
# MXレコードは受信設定なので、このスクリプトでは作成しない。
SPF_VALUE="v=spf1 include:amazonses.com ~all"

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

# SESとRoute 53を操作するため、操作先アカウントを確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get Public Hosted Zone ID ==="

# SESのDKIM/SPF/DMARCレコードを登録するPublic Hosted Zoneを取得する。
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$DOMAIN_NAME_DOT" \
  --query "HostedZones[?Name==\`$DOMAIN_NAME_DOT\` && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text)

HOSTED_ZONE_ID=$(get_required_value "Public Hosted Zone" "$HOSTED_ZONE_ID")
HOSTED_ZONE_ID="${HOSTED_ZONE_ID#/hostedzone/}"

echo "Hosted Zone ID: $HOSTED_ZONE_ID"

echo "=== Create or Get SES Domain Identity ==="

# SES Domain Identityが存在するか確認する。
DOMAIN_IDENTITY_EXISTS="true"
aws sesv2 get-email-identity \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$DOMAIN_NAME" >/dev/null 2>&1 || DOMAIN_IDENTITY_EXISTS="false"

if [ "$DOMAIN_IDENTITY_EXISTS" = "false" ]; then
  echo "SES Domain Identity not found. Creating: $DOMAIN_NAME"

  # Domain Identityを作成する。
  # Easy DKIMの鍵長はRSA_2048_BITを指定する。
  aws sesv2 create-email-identity \
    --profile "$PROFILE" \
    --region "$REGION" \
    --email-identity "$DOMAIN_NAME" \
    --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT \
    --tags Key=Name,Value="$DOMAIN_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning >/dev/null

  echo "SES Domain Identity created: $DOMAIN_NAME"
else
  echo "SES Domain Identity already exists: $DOMAIN_NAME"
fi

echo "=== Enable DKIM Signing ==="

# DKIM署名を有効化する。
# 送信メールにDKIM署名が付くことで、受信側がドメイン認証を確認しやすくなる。
aws sesv2 put-email-identity-dkim-attributes \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$DOMAIN_NAME" \
  --signing-enabled >/dev/null

echo "DKIM signing enabled."

echo "=== Get DKIM Tokens ==="

# SESが発行したDKIMトークンを取得する。
# このトークンからRoute 53に登録するCNAMEレコードを作る。
DKIM_TOKENS=$(aws sesv2 get-email-identity \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$DOMAIN_NAME" \
  --query 'DkimAttributes.Tokens[]' \
  --output text)

DKIM_TOKENS=$(get_required_value "DKIM Tokens" "$DKIM_TOKENS")

echo "DKIM Tokens:"
for token in $DKIM_TOKENS; do
  echo "  $token"
done

echo "=== Create / Update SES DNS Records ==="

# Route 53に登録する変更セットを作る。
# DKIM CNAME 3つ、SPF TXT、DMARC TXTをまとめてUPSERTする。
# UPSERTなので、既存レコードがあれば更新、なければ作成する。
DKIM_CHANGES=""

for token in $DKIM_TOKENS; do
  DKIM_CHANGES="${DKIM_CHANGES}
    {
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${token}._domainkey.${DOMAIN_NAME}\",
        \"Type\": \"CNAME\",
        \"TTL\": 300,
        \"ResourceRecords\": [
          {
            \"Value\": \"${token}.dkim.amazonses.com\"
          }
        ]
      }
    },"
done

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Create or update SES domain authentication records",
  "Changes": [
${DKIM_CHANGES}
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${SPF_RECORD_NAME}",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "\"${SPF_VALUE}\""
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DMARC_RECORD_NAME}",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "\"${DMARC_VALUE}\""
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
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$CHANGE_BATCH" \
  --query 'ChangeInfo.Id' \
  --output text)

CHANGE_ID=$(get_required_value "Route 53 Change ID" "$CHANGE_ID")

echo "Route 53 Change ID: $CHANGE_ID"

echo "=== Wait for DNS Change to be INSYNC ==="

aws route53 wait resource-record-sets-changed \
  --profile "$PROFILE" \
  --id "$CHANGE_ID"

echo "DNS records are INSYNC."

echo "=== Create or Get SES Email Address Identity ==="

# sandbox中の送信テスト先として、個人メールアドレスをSESに認証する。
# 未作成の場合、SESから確認メールが送信される。
EMAIL_IDENTITY_EXISTS="true"
aws sesv2 get-email-identity \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$VERIFY_EMAIL_ADDRESS" >/dev/null 2>&1 || EMAIL_IDENTITY_EXISTS="false"
# sandbox中の送信テスト先として、個人メールアドレスをSESに認証する。
# SESのsandbox環境では、送信元だけでなく送信先メールアドレスも検証済みである必要がある。
# 例:
#   送信元: no-reply@nobu-iac-lab.com
#   送信先: nobu4071@icloud.com
#
# Domain Identityとして nobu-iac-lab.com を認証していても、
# sandbox中は送信先として使う個別メールアドレスの認証が必要になる。
# そのため、テスト受信用の個人メールアドレスをEmail Identityとして作成する。
EMAIL_IDENTITY_EXISTS="true"
aws sesv2 get-email-identity \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$VERIFY_EMAIL_ADDRESS" >/dev/null 2>&1 || EMAIL_IDENTITY_EXISTS="false"

if [ "$EMAIL_IDENTITY_EXISTS" = "false" ]; then
  echo "SES Email Identity not found. Creating: $VERIFY_EMAIL_ADDRESS"

  # Email Identityを作成する。
  # このコマンドを実行すると、指定したメールアドレス宛にAWSから確認メールが送信される。
  # メール本文内の確認リンクをクリックするまで、このメールアドレスはVerifiedにならない。
  aws sesv2 create-email-identity \
    --profile "$PROFILE" \
    --region "$REGION" \
    --email-identity "$VERIFY_EMAIL_ADDRESS" \
    --tags Key=Name,Value="$VERIFY_EMAIL_ADDRESS" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning >/dev/null

  echo "Verification email sent to: $VERIFY_EMAIL_ADDRESS"
  echo "Please open the email and click the verification link."
else
  # すでにEmail Identityが存在する場合は新規作成しない。
  # ただし、存在していても未検証の場合があるため、後続のget-email-identityで状態を確認する。
  echo "SES Email Identity already exists: $VERIFY_EMAIL_ADDRESS"
fi

echo "=== Describe SES Domain Identity ==="

# Domain Identityの状態を確認する。
# VerifiedForSendingStatus が True であれば、このドメインを送信元として利用できる。
# DkimStatus が SUCCESS であれば、DKIM用CNAMEレコードの検証が完了している。
# SigningEnabled が true であれば、SESが送信メールにDKIM署名を付ける。
aws sesv2 get-email-identity \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$DOMAIN_NAME" \
  --query '{
    IdentityType:IdentityType,
    VerifiedForSendingStatus:VerifiedForSendingStatus,
    DkimStatus:DkimAttributes.Status,
    SigningEnabled:DkimAttributes.SigningEnabled
  }' \
  --output table

echo "=== Describe SES Email Address Identity ==="

# Email Address Identityの状態を確認する。
# VerifiedForSendingStatus が True であれば、sandbox中の送信先として利用できる。
# False の場合は、AWSから届いた確認メールのリンクをまだクリックしていない可能性がある。
aws sesv2 get-email-identity \
  --profile "$PROFILE" \
  --region "$REGION" \
  --email-identity "$VERIFY_EMAIL_ADDRESS" \
  --query '{
    IdentityType:IdentityType,
    VerifiedForSendingStatus:VerifiedForSendingStatus
  }' \
  --output table

echo "=== Describe SES DNS Records ==="

# Route 53に登録したSES関連のDNSレコードを確認する。
# 確認対象:
#   - DKIM CNAME: SESが送信メールへDKIM署名するためのドメイン認証レコード
#   - SPF TXT: このドメインからSES経由で送信することを示すレコード
#   - DMARC TXT: SPF/DKIMの認証結果に対する扱いを受信側へ伝えるレコード
aws route53 list-resource-record-sets \
  --profile "$PROFILE" \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?contains(Name, \`_domainkey.${DOMAIN_NAME}.\`) || Name==\`${DOMAIN_NAME}.\` || Name==\`_dmarc.${DOMAIN_NAME}.\`]" \
  --output table

echo "------------------------------------------------"
echo "SES setup completed."
echo "Domain Identity:"
echo "  ${DOMAIN_NAME}"
echo "Email Address Identity:"
echo "  ${VERIFY_EMAIL_ADDRESS}"
echo "DNS records:"
echo "  DKIM CNAME records"
echo "  SPF TXT record"
echo "  DMARC TXT record"
echo "------------------------------------------------"
echo "Notes:"
echo "  - MX record is not created by this script."
echo "  - MX / receipt rules should be handled by a separate receiving setup script."
echo "  - SMTP credentials should be created separately because they contain secrets."
echo "------------------------------------------------"

