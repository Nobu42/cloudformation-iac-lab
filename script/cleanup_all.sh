#!/bin/bash
set -euo pipefail

#
# cleanup_all.sh
#
# AWS CLI学習環境で作成した日次リソースを削除するスクリプト。
#
# このスクリプトは、学習時だけAWSリソースを作成し、
# 学習終了後に課金対象リソースを削除する運用を前提とする。
#
# 削除する主なリソース:
# - VPC / Subnet / Route Table / Internet Gateway / NAT Gateway / Elastic IP
# - Security Group
# - EC2
# - ALB / Target Group / Listener
# - RDS
# - ElastiCache
# - S3 bucket
# - Route 53 Private Hosted Zone
# - 日次利用のPublic DNSレコード
# - SES受信用MXレコード / Receipt Rule / 受信用S3 bucket
#
# 削除せず残すリソース:
# - ドメイン登録
# - Route 53 Public Hosted Zone
# - ACM証明書
# - ACM DNS検証用CNAME
# - SES Domain Identity
# - SES DKIM / SPF / DMARC レコード
# - SES SMTP用IAMユーザー
#
# 注意:
# - このスクリプトは実AWSリソースを削除する。
# - 実行前に必ずAWSアカウントとプロファイルを確認する。
# - sample-vpc が複数残っている場合、このスクリプトは1件ずつ削除する想定。
#   その場合は cleanup_all.sh を複数回実行し、check_cleanup.sh で確認する。
#
# 実行後の確認:
#
#   ./check_cleanup.sh
#   ./check_cost.sh
#

PROFILE="learning"
REGION="ap-northeast-1"

VPC_NAME="sample-vpc"
KEY_NAME="nobu"
KEY_FILE="nobu.pem"

# Domain / DNS
DOMAIN_NAME="nobu-iac-lab.com"
DOMAIN_NAME_DOT="${DOMAIN_NAME}."
PUBLIC_DNS_RECORDS=("bastion.${DOMAIN_NAME}." "www.${DOMAIN_NAME}.")
PRIVATE_HOSTED_ZONE_NAME="home."

# ALB / Target Group
ALB_NAME="sample-elb"
TARGET_GROUP_NAME="sample-tg"

# RDS
DB_INSTANCE_IDENTIFIER="sample-db"
DB_SUBNET_GROUP_NAME="sample-db-subnet"
DB_PARAMETER_GROUP_NAME="sample-db-pg"
DB_OPTION_GROUP_NAME="sample-db-og"

# ElastiCache
ELASTICACHE_REPLICATION_GROUP_ID="sample-elasticache"
ELASTICACHE_SUBNET_GROUP_NAME="sample-elasticache-sg"
ELASTICACHE_SG_NAME="sample-sg-elasticache"

# S3 / IAM Role for Web
BUCKET_NAME="nobu-terraform-iac-lab-upload"
ROLE_NAME="sample-role-web"
INSTANCE_PROFILE_NAME="sample-role-web"
S3_POLICY_ARN="arn:aws:iam::aws:policy/AmazonS3FullAccess"
CLOUDWATCH_AGENT_POLICY_ARN="arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

# SES receiving
# 受信用のReceipt RuleとS3 mailboxは、学習終了時に削除する。
# SES Domain Identity、DKIM/SPF/DMARC、SMTPユーザー、ACM証明書は残す。
MAIL_BUCKET_NAME="nobu-iac-lab-mailbox"
RECEIPT_RULE_SET_NAME="sample-ruleset"
RECEIPT_RULE_NAME="sample-rule-inquiry"

# LocalStack向けのaliasや環境変数が残っていると、
# 実AWSではなくLocalStackへ接続してしまう。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "================================================"
echo "Cleanup started."
echo "This script deletes chargeable lab resources."
echo "It keeps domain registration, public hosted zone,"
echo "ACM certificate, and SES domain verification records."
echo "================================================"

echo "=== Caller Identity ==="
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get VPC ID ==="
# 削除対象となるVPCをNameタグから取得する。
# 何らかの理由で sample-vpc が複数残っている場合は、
# ここでは先頭1件のみを削除対象にする。
# その場合は削除後に再度 cleanup_all.sh を実行する。
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "VPC not found. VPC resources may already be deleted."
  VPC_ID=""
else
  echo "Target VPC: $VPC_ID"
fi

echo "=== Get Public Hosted Zone ID ==="
# Public Hosted Zone自体はドメイン管理に必要なため削除しない。
# ここでは日次で作成する一時レコードを削除するためにHosted Zone IDだけ取得する。
PUBLIC_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$DOMAIN_NAME_DOT" \
  --query "HostedZones[?Name==\`$DOMAIN_NAME_DOT\` && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text 2>/dev/null || true)

if [ "$PUBLIC_HOSTED_ZONE_ID" != "None" ] && [ -n "$PUBLIC_HOSTED_ZONE_ID" ]; then
  PUBLIC_HOSTED_ZONE_ID="${PUBLIC_HOSTED_ZONE_ID#/hostedzone/}"
  echo "Public Hosted Zone ID: $PUBLIC_HOSTED_ZONE_ID"
else
  PUBLIC_HOSTED_ZONE_ID=""
  echo "Public Hosted Zone not found."
fi

echo "=== Delete Public DNS Records for Daily Lab Resources ==="
# bastion と www は、EC2やALBを作り直すたびに向き先が変わる。
# 日次削除時にはレコードだけ削除し、Public Hosted Zoneは残す。
if [ -n "$PUBLIC_HOSTED_ZONE_ID" ]; then
  for record_name in "${PUBLIC_DNS_RECORDS[@]}"; do
    RECORD_JSON=$(aws route53 list-resource-record-sets \
      --profile "$PROFILE" \
      --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
      --query "ResourceRecordSets[?Name==\`${record_name}\`] | [0]" \
      --output json)

    if [ "$RECORD_JSON" != "null" ] && [ -n "$RECORD_JSON" ]; then
      echo "Deleting public DNS record: $record_name"

      CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Delete daily lab public DNS record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": ${RECORD_JSON}
    }
  ]
}
EOF
)

      aws route53 change-resource-record-sets \
        --profile "$PROFILE" \
        --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
        --change-batch "$CHANGE_BATCH" >/dev/null
    else
      echo "Public DNS record not found: $record_name"
    fi
  done

  echo "Note: Public Hosted Zone itself is kept."
  echo "Note: ACM validation CNAME, DKIM, SPF, and DMARC records are kept."
fi

echo "=== Delete SES Receiving Rule / Rule Set ==="
# 受信設定はS3保存とMX配送に関わるため、日次削除対象にする。
# SES送信用のDomain IdentityやDKIM/SPF/DMARCは残す。
RULE_SET_EXISTS="true"
aws ses describe-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --rule-set-name "$RECEIPT_RULE_SET_NAME" >/dev/null 2>&1 || RULE_SET_EXISTS="false"

if [ "$RULE_SET_EXISTS" = "true" ]; then
  echo "Deleting receipt rule: $RECEIPT_RULE_NAME"

  aws ses delete-receipt-rule \
    --profile "$PROFILE" \
    --region "$REGION" \
    --rule-set-name "$RECEIPT_RULE_SET_NAME" \
    --rule-name "$RECEIPT_RULE_NAME" 2>/dev/null || echo "Receipt rule already deleted or not found."

  echo "Disabling active receipt rule set."

  # ActiveなReceipt Rule Setは削除できない場合があるため、
  # 先にActive設定を解除してからRule Set削除を試みる。
  aws ses set-active-receipt-rule-set \
    --profile "$PROFILE" \
    --region "$REGION" 2>/dev/null || echo "Could not disable active receipt rule set."

  echo "Deleting receipt rule set: $RECEIPT_RULE_SET_NAME"

  aws ses delete-receipt-rule-set \
    --profile "$PROFILE" \
    --region "$REGION" \
    --rule-set-name "$RECEIPT_RULE_SET_NAME" 2>/dev/null || echo "Receipt rule set could not be deleted."
else
  echo "Receipt Rule Set not found."
fi

echo "=== Delete MX Record for SES Receiving ==="
# MXレコードを残すと、nobu-iac-lab.com宛メールがSES受信へ配送され続ける。
# 日次学習後は削除して、受信設定とS3保存を止める。
if [ -n "$PUBLIC_HOSTED_ZONE_ID" ]; then
  MX_RECORD_JSON=$(aws route53 list-resource-record-sets \
    --profile "$PROFILE" \
    --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name==\`${DOMAIN_NAME}.\` && Type==\`MX\`] | [0]" \
    --output json)

  if [ "$MX_RECORD_JSON" != "null" ] && [ -n "$MX_RECORD_JSON" ]; then
    echo "Deleting MX record for SES receiving."

    CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Delete MX record for SES receiving",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": ${MX_RECORD_JSON}
    }
  ]
}
EOF
)

    aws route53 change-resource-record-sets \
      --profile "$PROFILE" \
      --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
      --change-batch "$CHANGE_BATCH" >/dev/null
  else
    echo "MX record not found."
  fi
fi

echo "=== Delete ALB Listener / Load Balancer / Target Group ==="
# Target GroupはALB Listenerから参照されていると削除できない。
# そのため Listener -> Load Balancer -> Target Group の順で削除する。
LB_ARN=$(aws elbv2 describe-load-balancers \
  --profile "$PROFILE" \
  --region "$REGION" \
  --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)

if [ "$LB_ARN" != "None" ] && [ -n "$LB_ARN" ]; then
  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --profile "$PROFILE" \
    --region "$REGION" \
    --load-balancer-arn "$LB_ARN" \
    --query 'Listeners[].ListenerArn' \
    --output text 2>/dev/null || true)

  for listener_arn in $LISTENER_ARNS; do
    echo "Deleting listener: $listener_arn"
    aws elbv2 delete-listener \
      --profile "$PROFILE" \
      --region "$REGION" \
      --listener-arn "$listener_arn"
  done

  echo "Deleting load balancer: $LB_ARN"
  aws elbv2 delete-load-balancer \
    --profile "$PROFILE" \
    --region "$REGION" \
    --load-balancer-arn "$LB_ARN"

  echo "Waiting for load balancer to be deleted..."
  aws elbv2 wait load-balancers-deleted \
    --profile "$PROFILE" \
    --region "$REGION" \
    --load-balancer-arns "$LB_ARN"
else
  echo "No ALB found."
fi

TG_ARN=$(aws elbv2 describe-target-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --names "$TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || true)

if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
  echo "Deleting target group: $TG_ARN"
  aws elbv2 delete-target-group \
    --profile "$PROFILE" \
    --region "$REGION" \
    --target-group-arn "$TG_ARN"
else
  echo "No Target Group found."
fi

echo "=== Delete RDS Instance ==="
# RDSはDB Subnet GroupやSecurity Groupに依存する。
# 先にDB Instanceを削除し、削除完了を待ってから関連リソースを削除する。
DB_STATUS=$(aws rds describe-db-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || true)

if [ "$DB_STATUS" != "None" ] && [ -n "$DB_STATUS" ]; then
  echo "Deleting RDS instance: $DB_INSTANCE_IDENTIFIER"

  aws rds delete-db-instance \
    --profile "$PROFILE" \
    --region "$REGION" \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --skip-final-snapshot \
    --delete-automated-backups >/dev/null

  echo "Waiting for RDS instance to be deleted..."
  aws rds wait db-instance-deleted \
    --profile "$PROFILE" \
    --region "$REGION" \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
else
  echo "No RDS instance found."
fi

echo "=== Delete ElastiCache Replication Group / Subnet Group ==="
# ElastiCacheはPrivate SubnetとSecurity Groupに依存する。
# 先に削除しないとSubnetやSecurity Groupを削除できない。
#
# Replication Group削除後にCache Subnet Groupを削除する。
# Cache Subnet Groupが残っていると、後続のSubnet削除でDependencyViolationになることがある。
REPLICATION_GROUP_STATUS=$(aws elasticache describe-replication-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --replication-group-id "$ELASTICACHE_REPLICATION_GROUP_ID" \
  --query 'ReplicationGroups[0].Status' \
  --output text 2>/dev/null || true)

if [ "$REPLICATION_GROUP_STATUS" != "None" ] && [ -n "$REPLICATION_GROUP_STATUS" ]; then
  echo "Deleting ElastiCache replication group: $ELASTICACHE_REPLICATION_GROUP_ID"

  aws elasticache delete-replication-group \
    --profile "$PROFILE" \
    --region "$REGION" \
    --replication-group-id "$ELASTICACHE_REPLICATION_GROUP_ID" \
    --no-retain-primary-cluster >/dev/null

  echo "Waiting for ElastiCache replication group to be deleted..."
  aws elasticache wait replication-group-deleted \
    --profile "$PROFILE" \
    --region "$REGION" \
    --replication-group-id "$ELASTICACHE_REPLICATION_GROUP_ID"
else
  echo "No ElastiCache replication group found."
fi

echo "Deleting ElastiCache subnet group: $ELASTICACHE_SUBNET_GROUP_NAME"
aws elasticache delete-cache-subnet-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --cache-subnet-group-name "$ELASTICACHE_SUBNET_GROUP_NAME" 2>/dev/null || echo "ElastiCache subnet group already deleted or not found."

echo "=== Delete IAM Instance Profile Associations from EC2 ==="
# EC2にInstance Profileが付いたままだと、後続のIAM Role / Instance Profile削除で
# 依存関係が残ることがあるため、EC2削除前に関連付けを外す。
if [ -n "$VPC_ID" ]; then
  INSTANCE_IDS_FOR_PROFILE=$(aws ec2 describe-instances \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters \
      Name=vpc-id,Values="$VPC_ID" \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

  for instance_id in $INSTANCE_IDS_FOR_PROFILE; do
    ASSOC_ID=$(aws ec2 describe-iam-instance-profile-associations \
      --profile "$PROFILE" \
      --region "$REGION" \
      --filters Name=instance-id,Values="$instance_id" \
      --query 'IamInstanceProfileAssociations[0].AssociationId' \
      --output text 2>/dev/null || true)

    if [ "$ASSOC_ID" != "None" ] && [ -n "$ASSOC_ID" ]; then
      echo "Disassociating IAM Instance Profile from $instance_id: $ASSOC_ID"
      aws ec2 disassociate-iam-instance-profile \
        --profile "$PROFILE" \
        --region "$REGION" \
        --association-id "$ASSOC_ID" >/dev/null
    fi
  done
fi

echo "=== Terminate EC2 Instances ==="
# VPC内に残っているBastion / Web EC2をterminateする。
# EC2が残っているとSubnetやSecurity Groupを削除できない。
if [ -n "$VPC_ID" ]; then
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters \
      Name=vpc-id,Values="$VPC_ID" \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

  if [ -n "$INSTANCE_IDS" ]; then
    echo "Terminating: $INSTANCE_IDS"
    aws ec2 terminate-instances \
      --profile "$PROFILE" \
      --region "$REGION" \
      --instance-ids $INSTANCE_IDS >/dev/null

    aws ec2 wait instance-terminated \
      --profile "$PROFILE" \
      --region "$REGION" \
      --instance-ids $INSTANCE_IDS
  else
    echo "No EC2 instances found."
  fi
else
  echo "Skip EC2 termination because VPC was not found."
fi

echo "=== Delete custom Security Groups ==="
# Security Groupは依存関係が外れた後に削除する。
# ElastiCache、RDS、ALB、EC2が残っているとDependencyViolationになるため、
# それらの削除後に実行する。
if [ -n "$VPC_ID" ]; then
  for sg_name in sample-sg-db "$ELASTICACHE_SG_NAME" sample-sg-web sample-sg-bastion sample-sg-elb; do
    SG_ID=$(aws ec2 describe-security-groups \
      --profile "$PROFILE" \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$sg_name" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || true)

    if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
      echo "Deleting SG: $sg_name ($SG_ID)"
      aws ec2 delete-security-group \
        --profile "$PROFILE" \
        --region "$REGION" \
        --group-id "$SG_ID" || echo "Skip: could not delete $sg_name yet"
    fi
  done
fi

echo "=== Delete DB Subnet / Parameter / Option Groups ==="
# RDS Instance削除後に、RDS関連の補助リソースを削除する。
aws rds delete-db-subnet-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" 2>/dev/null || echo "DB Subnet Group already deleted or not found."

aws rds delete-db-parameter-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-parameter-group-name "$DB_PARAMETER_GROUP_NAME" 2>/dev/null || echo "DB Parameter Group already deleted or not found."

aws rds delete-option-group \
  --profile "$PROFILE" \
  --region "$REGION" \
  --option-group-name "$DB_OPTION_GROUP_NAME" 2>/dev/null || echo "DB Option Group already deleted or not found."

echo "=== Delete Private Hosted Zone ==="
# Private Hosted ZoneはVPCと一緒に日次削除する。
# 先に独自レコードを削除し、その後Hosted Zoneを削除する。
PRIVATE_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$PRIVATE_HOSTED_ZONE_NAME" \
  --query "HostedZones[?Name==\`$PRIVATE_HOSTED_ZONE_NAME\` && Config.PrivateZone==\`true\`].Id | [0]" \
  --output text 2>/dev/null || true)

if [ "$PRIVATE_HOSTED_ZONE_ID" != "None" ] && [ -n "$PRIVATE_HOSTED_ZONE_ID" ]; then
  PRIVATE_HOSTED_ZONE_ID="${PRIVATE_HOSTED_ZONE_ID#/hostedzone/}"
  echo "Private Hosted Zone ID: $PRIVATE_HOSTED_ZONE_ID"

  PRIVATE_RECORDS=$(aws route53 list-resource-record-sets \
    --profile "$PROFILE" \
    --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
    --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' \
    --output json)

  if [ "$PRIVATE_RECORDS" != "[]" ]; then
    echo "Deleting private DNS records."

    PRIVATE_CHANGES=$(echo "$PRIVATE_RECORDS" | jq -c '.[]' | sed 's/^/{ "Action": "DELETE", "ResourceRecordSet": /; s/$/ },/' | sed '$ s/,$//')

    CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Delete private DNS records",
  "Changes": [
${PRIVATE_CHANGES}
  ]
}
EOF
)

    aws route53 change-resource-record-sets \
      --profile "$PROFILE" \
      --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
      --change-batch "$CHANGE_BATCH" >/dev/null
  else
    echo "No private DNS records found."
  fi

  echo "Deleting private hosted zone: $PRIVATE_HOSTED_ZONE_ID"
  aws route53 delete-hosted-zone \
    --profile "$PROFILE" \
    --id "$PRIVATE_HOSTED_ZONE_ID" >/dev/null
else
  echo "Private Hosted Zone not found."
fi

echo "=== Delete custom Route Tables ==="
# Route TableはSubnetとの関連付けを解除してから削除する。
# Main Route Tableは削除対象外。
if [ -n "$VPC_ID" ]; then
  RT_IDS=$(aws ec2 describe-route-tables \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'RouteTables[?Tags[?Key==`Name` && (Value==`sample-rt-public` || Value==`sample-rt-private01` || Value==`sample-rt-private02`)]].RouteTableId' \
    --output text)

  for rt_id in $RT_IDS; do
    ASSOC_IDS=$(aws ec2 describe-route-tables \
      --profile "$PROFILE" \
      --region "$REGION" \
      --route-table-ids "$rt_id" \
      --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
      --output text)

    for assoc_id in $ASSOC_IDS; do
      echo "Disassociating route table association: $assoc_id"
      aws ec2 disassociate-route-table \
        --profile "$PROFILE" \
        --region "$REGION" \
        --association-id "$assoc_id"
    done

    echo "Deleting route table: $rt_id"
    aws ec2 delete-route-table \
      --profile "$PROFILE" \
      --region "$REGION" \
      --route-table-id "$rt_id"
  done
fi

echo "=== Collect Elastic IP Allocation IDs ==="
# NAT Gateway削除後にElastic IPを解放するため、先にAllocation IDを控える。
ALLOC_IDS=$(aws ec2 describe-addresses \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values=sample-eip-ngw-01,sample-eip-ngw-02 \
  --query 'Addresses[].AllocationId' \
  --output text)

echo "=== Delete NAT Gateways ==="
# NAT Gatewayは削除に時間がかかる。
# NAT Gatewayが残っている間はSubnetやEIPの削除に失敗することがある。
if [ -n "$VPC_ID" ]; then
  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filter Name=vpc-id,Values="$VPC_ID" Name=state,Values=pending,available \
    --query 'NatGateways[].NatGatewayId' \
    --output text)

  if [ -n "$NAT_IDS" ]; then
    for nat_id in $NAT_IDS; do
      echo "Deleting NAT Gateway: $nat_id"
      aws ec2 delete-nat-gateway \
        --profile "$PROFILE" \
        --region "$REGION" \
        --nat-gateway-id "$nat_id" >/dev/null
    done

    echo "Waiting for NAT Gateways to be deleted..."
    aws ec2 wait nat-gateway-deleted \
      --profile "$PROFILE" \
      --region "$REGION" \
      --nat-gateway-ids $NAT_IDS
  else
    echo "No NAT Gateways found."
  fi
fi

echo "=== Release Elastic IPs ==="
# NAT Gateway用に確保したElastic IPを解放する。
# 解放し忘れると未関連EIPとして課金対象になる場合がある。
for alloc_id in $ALLOC_IDS; do
  echo "Releasing EIP: $alloc_id"
  aws ec2 release-address \
    --profile "$PROFILE" \
    --region "$REGION" \
    --allocation-id "$alloc_id" || echo "Skip: could not release $alloc_id"
done

echo "=== Detach and Delete Internet Gateway ==="
# Internet GatewayはVPCからdetachしてからdeleteする。
if [ -n "$VPC_ID" ]; then
  IGW_ID=$(aws ec2 describe-internet-gateways \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters Name=attachment.vpc-id,Values="$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text)

  if [ "$IGW_ID" != "None" ] && [ -n "$IGW_ID" ]; then
    echo "Detaching IGW: $IGW_ID"
    aws ec2 detach-internet-gateway \
      --profile "$PROFILE" \
      --region "$REGION" \
      --internet-gateway-id "$IGW_ID" \
      --vpc-id "$VPC_ID"

    echo "Deleting IGW: $IGW_ID"
    aws ec2 delete-internet-gateway \
      --profile "$PROFILE" \
      --region "$REGION" \
      --internet-gateway-id "$IGW_ID"
  fi
fi

echo "=== Delete Subnets ==="
# Subnetは、EC2 / RDS / ElastiCache / NAT Gatewayなどの依存が残っていると削除できない。
# ここまでの削除順で依存関係を外した後に削除する。
if [ -n "$VPC_ID" ]; then
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --profile "$PROFILE" \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets[].SubnetId' \
    --output text)

  for subnet_id in $SUBNET_IDS; do
    echo "Deleting subnet: $subnet_id"
    aws ec2 delete-subnet \
      --profile "$PROFILE" \
      --region "$REGION" \
      --subnet-id "$subnet_id"
  done
fi

echo "=== Delete Key Pair ==="
# 学習用に作成したKey Pairを削除し、ローカルのpemファイルも削除する。
aws ec2 delete-key-pair \
  --profile "$PROFILE" \
  --region "$REGION" \
  --key-name "$KEY_NAME" >/dev/null 2>&1 || true

rm -f "$KEY_FILE"

echo "=== Delete VPC ==="
# すべての依存リソース削除後にVPCを削除する。
if [ -n "$VPC_ID" ]; then
  aws ec2 delete-vpc \
    --profile "$PROFILE" \
    --region "$REGION" \
    --vpc-id "$VPC_ID"
else
  echo "Skip VPC delete because VPC was not found."
fi

echo "=== Delete S3 Objects and Bucket for Web Upload ==="
# S3バケットは空でないと削除できないため、先に中身を削除する。
if aws s3api head-bucket \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" >/dev/null 2>&1; then

  echo "Deleting objects in S3 bucket: $BUCKET_NAME"
  aws s3 rm "s3://$BUCKET_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --recursive

  echo "Deleting S3 bucket: $BUCKET_NAME"
  aws s3api delete-bucket \
    --profile "$PROFILE" \
    --region "$REGION" \
    --bucket "$BUCKET_NAME"
else
  echo "Web upload S3 bucket not found or not accessible."
fi

echo "=== Delete S3 Objects and Bucket for SES Receiving ==="
# SES受信用バケットも日次削除対象。
# 受信メールはraw MIME形式で保存されているため、必要なら削除前に別途退避する。
if aws s3api head-bucket \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$MAIL_BUCKET_NAME" >/dev/null 2>&1; then

  echo "Deleting received mails in S3 bucket: $MAIL_BUCKET_NAME"
  aws s3 rm "s3://$MAIL_BUCKET_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --recursive

  echo "Deleting S3 bucket: $MAIL_BUCKET_NAME"
  aws s3api delete-bucket \
    --profile "$PROFILE" \
    --region "$REGION" \
    --bucket "$MAIL_BUCKET_NAME"
else
  echo "SES receiving S3 bucket not found or not accessible."
fi

echo "=== Delete IAM Role and Instance Profile for Web EC2 ==="
# Web EC2用のIAM RoleとInstance Profileを削除する。
# RoleにPolicyが付いたままだとRole削除に失敗するため、先にdetachする。
#
# S3:
#   Rails Active Storageの画像保存用。
#
# CloudWatch Agent:
#   nginx / PumaログをCloudWatch Logsへ送信するための権限。
#   11_s3_setup.shで同じRoleに付与しているため、削除時も忘れずに外す。
aws iam detach-role-policy \
  --profile "$PROFILE" \
  --role-name "$ROLE_NAME" \
  --policy-arn "$S3_POLICY_ARN" 2>/dev/null || echo "S3 policy already detached or role not found."

aws iam detach-role-policy \
  --profile "$PROFILE" \
  --role-name "$ROLE_NAME" \
  --policy-arn "$CLOUDWATCH_AGENT_POLICY_ARN" 2>/dev/null || echo "CloudWatch Agent policy already detached or role not found."

aws iam remove-role-from-instance-profile \
  --profile "$PROFILE" \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --role-name "$ROLE_NAME" 2>/dev/null || echo "Role already removed from Instance Profile or not found."

aws iam delete-instance-profile \
  --profile "$PROFILE" \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" 2>/dev/null || echo "Instance Profile already deleted or not found."

aws iam delete-role \
  --profile "$PROFILE" \
  --role-name "$ROLE_NAME" 2>/dev/null || echo "IAM Role already deleted or not found."

echo "================================================"
echo "Cleanup completed."
echo "Kept resources:"
echo "  - Domain registration: ${DOMAIN_NAME}"
echo "  - Public Hosted Zone: ${DOMAIN_NAME}"
echo "  - ACM certificate and validation CNAME"
echo "  - SES Domain Identity / DKIM / SPF / DMARC"
echo "  - SES SMTP IAM user"
echo ""
echo "Next startup notes:"
echo "  - Run setup scripts again from 01 to the needed step."
echo "  - Re-run 12_public_dns_setup.sh after ALB/Bastion creation."
echo "  - Re-run 14_private_dns_setup.sh after EC2/RDS creation."
echo "  - Re-run 15_acm_certificate_setup.sh to attach existing ACM certificate to new ALB."
echo "  - Re-run 18_ses_receiving_setup.sh if you want to receive inquiry mail again."
echo "  - Check costs with check_cost.sh and check cleanup with check_cleanup.sh."
echo "================================================"
