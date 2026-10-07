#!/bin/bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-learning}"
BILLING_REGION="us-east-1"

# LocalStack向け設定が残っていても実AWSを見る
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

START_DATE="$(date +%Y-%m-01)"
END_DATE="$(date -v+1d +%Y-%m-%d)" # macOS: 明日。Cost ExplorerのEndは排他的

echo "Profile: $PROFILE"
echo "Period : $START_DATE to $END_DATE"
echo

echo "=== Caller Identity ==="
command aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo
echo "=== Month-to-date total cost ==="
command aws ce get-cost-and-usage \
  --profile "$PROFILE" \
  --region "$BILLING_REGION" \
  --time-period Start="$START_DATE",End="$END_DATE" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --query 'ResultsByTime[0].Total.UnblendedCost' \
  --output table

echo
echo "=== Cost by service ==="
command aws ce get-cost-and-usage \
  --profile "$PROFILE" \
  --region "$BILLING_REGION" \
  --time-period Start="$START_DATE",End="$END_DATE" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[*].[Keys[0], Metrics.UnblendedCost.Amount, Metrics.UnblendedCost.Unit]' \
  --output table

