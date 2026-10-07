#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
# "learning" には作業用IAMユーザーの認証情報を設定している。
PROFILE="learning"
REGION="ap-northeast-1"

# ALB作成で参照するリソース名。
VPC_NAME="sample-vpc"
PUB01_NAME="sample-subnet-public01"
PUB02_NAME="sample-subnet-public02"
WEB01_NAME="sample-ec2-web01"
WEB02_NAME="sample-ec2-web02"
ELB_SG_NAME="sample-sg-elb"

# 作成するALB関連リソース名。
TARGET_GROUP_NAME="sample-tg"
ALB_NAME="sample-elb"
APP_PORT="3000"

# LocalStack用のaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

# ID取得に失敗した場合に、分かりやすいメッセージで止めるための関数。
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

# ALBは課金対象なので、作成前に操作先アカウントを確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get Resource IDs ==="

# ALBとTarget Groupを作成するVPCを取得する。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)
VPC_ID=$(get_required_id "VPC" "$VPC_ID")

# ALBを配置するPublic Subnetを2つ取得する。
# Application Load Balancerは、少なくとも2つのAZにまたがるSubnet指定が基本。
PUB01_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUB01_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PUB01_ID=$(get_required_id "Public Subnet 01" "$PUB01_ID")

PUB02_ID=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$PUB02_NAME" \
  --query 'Subnets[0].SubnetId' \
  --output text)
PUB02_ID=$(get_required_id "Public Subnet 02" "$PUB02_ID")

# Target Groupに登録するWebサーバー2台を取得する。
# running状態のインスタンスだけを対象にする。
WEB01_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$WEB01_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
WEB01_ID=$(get_required_id "Web01 Instance" "$WEB01_ID")

WEB02_ID=$(aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$WEB02_NAME" Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
WEB02_ID=$(get_required_id "Web02 Instance" "$WEB02_ID")

# ALBに関連付けるSecurity Groupを取得する。
# このSGは、前の手順でインターネットからのHTTP/HTTPSを許可している。
SG_ELB_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$ELB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
SG_ELB_ID=$(get_required_id "ELB Security Group" "$SG_ELB_ID")

echo "VPC: $VPC_ID"
echo "Public Subnets: $PUB01_ID, $PUB02_ID"
echo "Web Instances: $WEB01_ID, $WEB02_ID"
echo "ELB Security Group: $SG_ELB_ID"

echo "=== Create Target Group ==="

# ALBから転送された通信を受けるTarget Groupを作成する。
# 今回はWebサーバーの3000番ポートへHTTPで転送する。
TG_ARN=$(aws elbv2 create-target-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --name "$TARGET_GROUP_NAME" \
  --protocol HTTP \
  --port "$APP_PORT" \
  --target-type instance \
  --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-path / \
  --tags Key=Name,Value="$TARGET_GROUP_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)


echo "Target Group Created: $TG_ARN"

echo "=== Register Web Servers to Target Group ==="

# Webサーバー2台をTarget Groupへ登録する。
# ALBはこのTarget Groupに登録されたインスタンスへ通信を振り分ける。
aws elbv2 register-targets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --target-group-arn "$TG_ARN" \
  --targets Id="$WEB01_ID",Port="$APP_PORT" Id="$WEB02_ID",Port="$APP_PORT"

echo "Web01 and Web02 registered to Target Group."

echo "=== Create Application Load Balancer ==="

# Internet-facingなApplication Load Balancerを作成する。
# Public Subnet 2つに配置し、外部からHTTPアクセスを受ける入口にする。
LB_ARN=$(aws elbv2 create-load-balancer \
  --profile "$PROFILE" \
  --region "$REGION" \
  --name "$ALB_NAME" \
  --subnets "$PUB01_ID" "$PUB02_ID" \
  --security-groups "$SG_ELB_ID" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags Key=Name,Value="$ALB_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

echo "Load Balancer Created: $LB_ARN"

echo "=== Wait for Load Balancer to become available ==="

# ALBが利用可能になるまで待つ。
aws elbv2 wait load-balancer-available \
  --profile "$PROFILE" \
  --region "$REGION" \
  --load-balancer-arns "$LB_ARN"

echo "Load Balancer is available."

echo "=== Create Listener ==="

# ALBの80番ポートでHTTPを受けるListenerを作成する。
# 受けた通信はTarget Groupへforwardする。
LISTENER_ARN=$(aws elbv2 create-listener \
  --profile "$PROFILE" \
  --region "$REGION" \
  --load-balancer-arn "$LB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text)

echo "Listener Created: $LISTENER_ARN"

echo "=== Get Load Balancer DNS Name ==="

# ALBのDNS名を取得する。
# 実AWSではLocalStack用URLではなく、このDNS名でアクセスする。
LB_DNS_NAME=$(aws elbv2 describe-load-balancers \
  --profile "$PROFILE" \
  --region "$REGION" \
  --load-balancer-arns "$LB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "------------------------------------------------"
echo "Setup Complete!"
echo "Access URL:"
echo "http://$LB_DNS_NAME"
echo "------------------------------------------------"

echo "=== Describe Target Health ==="

# Target Groupに登録されたWebサーバーのヘルスチェック状態を確認する。
# Webサーバー側で3000番ポートのアプリが起動していない場合、unhealthyになる。
aws elbv2 describe-target-health \
  --profile "$PROFILE" \
  --region "$REGION" \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
  --output table

echo "=== Describe Load Balancer ==="

# 作成したALBの状態を確認する。
aws elbv2 describe-load-balancers \
  --profile "$PROFILE" \
  --region "$REGION" \
  --load-balancer-arns "$LB_ARN" \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,DNSName:DNSName,State:State.Code,Scheme:Scheme,Type:Type,VpcId:VpcId}' \
  --output table

