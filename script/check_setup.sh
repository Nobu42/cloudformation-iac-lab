#!/bin/bash
set -euo pipefail

PROFILE="learning"
REGION="ap-northeast-1"

DOMAIN_NAME="nobu-iac-lab.com"
DOMAIN_NAME_DOT="${DOMAIN_NAME}."

VPC_NAME="sample-vpc"
ALB_NAME="sample-elb"
TARGET_GROUP_NAME="sample-tg"
DB_INSTANCE_IDENTIFIER="sample-db"
WEB_BUCKET_NAME="nobu-terraform-iac-lab-upload"

unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "=== Caller Identity ==="
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== VPC ==="
aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[*].{Name:Tags[?Key==`Name`].Value|[0],ID:VpcId,CIDR:CidrBlock,State:State,DNSHost:EnableDnsHostnames.Value,DNSSupport:EnableDnsSupport.Value}' \
  --output table

echo "=== Subnets ==="
VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "VPC not found. Stop check."
  exit 1
fi

aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[*].{Name:Tags[?Key==`Name`].Value|[0],Type:Tags[?Key==`Type`].Value|[0],AZ:AvailabilityZone,CIDR:CidrBlock,PublicIP:MapPublicIpOnLaunch,ID:SubnetId}' \
  --output table

echo "=== Internet Gateway ==="
aws ec2 describe-internet-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=attachment.vpc-id,Values="$VPC_ID" \
  --query 'InternetGateways[*].{ID:InternetGatewayId,Name:Tags[?Key==`Name`].Value|[0],State:Attachments[0].State,VPC:Attachments[0].VpcId}' \
  --output table

echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filter Name=vpc-id,Values="$VPC_ID" \
  --query 'NatGateways[*].{Name:Tags[?Key==`Name`].Value|[0],ID:NatGatewayId,State:State,Subnet:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp}' \
  --output table

echo "=== Route Tables ==="
aws ec2 describe-route-tables \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'RouteTables[*].{Name:Tags[?Key==`Name`].Value|[0],ID:RouteTableId,AssociatedSubnets:Associations[?SubnetId!=`null`].SubnetId,IGW:Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId|[0],NGW:Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId|[0]}' \
  --output table

echo "=== Security Groups ==="
aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[?starts_with(GroupName, `sample-sg-`)].{Name:GroupName,ID:GroupId,Description:Description}' \
  --output table

echo "=== EC2 Instances ==="
aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,Subnet:SubnetId}' \
  --output table

echo "=== ALB ==="
LB_ARN=$(aws elbv2 describe-load-balancers \
  --profile "$PROFILE" \
  --region "$REGION" \
  --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)

if [ "$LB_ARN" != "None" ] && [ -n "$LB_ARN" ]; then
  aws elbv2 describe-load-balancers \
    --profile "$PROFILE" \
    --region "$REGION" \
    --load-balancer-arns "$LB_ARN" \
    --query 'LoadBalancers[*].{Name:LoadBalancerName,DNSName:DNSName,State:State.Code,Scheme:Scheme,Type:Type,VpcId:VpcId}' \
    --output table

  echo "=== ALB Listeners ==="
  aws elbv2 describe-listeners \
    --profile "$PROFILE" \
    --region "$REGION" \
    --load-balancer-arn "$LB_ARN" \
    --query 'Listeners[*].{Port:Port,Protocol:Protocol,DefaultActions:DefaultActions[*].Type,Certificate:Certificates[0].CertificateArn}' \
    --output table
else
  echo "ALB not found."
fi

echo "=== Target Health ==="
TG_ARN=$(aws elbv2 describe-target-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --names "$TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || true)

if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
  aws elbv2 describe-target-health \
    --profile "$PROFILE" \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[*].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
    --output table
else
  echo "Target Group not found."
fi

echo "=== RDS ==="
aws rds describe-db-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Engine:Engine,Endpoint:Endpoint.Address,Public:PubliclyAccessible,MultiAZ:MultiAZ}' \
  --output table 2>/dev/null || echo "RDS instance not found."

echo "=== S3 Web Upload Bucket ==="
aws s3api head-bucket \
  --profile "$PROFILE" \
  --region "$REGION" \
  --bucket "$WEB_BUCKET_NAME" >/dev/null 2>&1 && echo "S3 bucket exists: $WEB_BUCKET_NAME" || echo "S3 bucket not found: $WEB_BUCKET_NAME"

echo "=== Public DNS Records ==="
PUBLIC_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$DOMAIN_NAME_DOT" \
  --query "HostedZones[?Name==\`$DOMAIN_NAME_DOT\` && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text 2>/dev/null || true)

if [ "$PUBLIC_HOSTED_ZONE_ID" != "None" ] && [ -n "$PUBLIC_HOSTED_ZONE_ID" ]; then
  PUBLIC_HOSTED_ZONE_ID="${PUBLIC_HOSTED_ZONE_ID#/hostedzone/}"

  aws route53 list-resource-record-sets \
    --profile "$PROFILE" \
    --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name==\`bastion.${DOMAIN_NAME}.\` || Name==\`www.${DOMAIN_NAME}.\`]" \
    --output table
else
  echo "Public Hosted Zone not found."
fi

echo "=== Private Hosted Zone home ==="
PRIVATE_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "home." \
  --query "HostedZones[?Name==\`home.\` && Config.PrivateZone==\`true\`].Id | [0]" \
  --output text 2>/dev/null || true)

if [ "$PRIVATE_HOSTED_ZONE_ID" != "None" ] && [ -n "$PRIVATE_HOSTED_ZONE_ID" ]; then
  PRIVATE_HOSTED_ZONE_ID="${PRIVATE_HOSTED_ZONE_ID#/hostedzone/}"

  aws route53 list-resource-record-sets \
    --profile "$PROFILE" \
    --hosted-zone-id "$PRIVATE_HOSTED_ZONE_ID" \
    --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' \
    --output table
else
  echo "Private Hosted Zone home not found."
fi

echo "=== ACM Certificate ==="
aws acm list-certificates \
  --profile "$PROFILE" \
  --region "$REGION" \
  --certificate-statuses ISSUED PENDING_VALIDATION \
  --query 'CertificateSummaryList[?DomainName==`www.nobu-iac-lab.com`].{DomainName:DomainName,Status:Status,Arn:CertificateArn}' \
  --output table

echo "=== SES Identities ==="
aws sesv2 list-email-identities \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'EmailIdentities[*].{IdentityName:IdentityName,IdentityType:IdentityType,SendingEnabled:SendingEnabled,VerificationStatus:VerificationStatus}' \
  --output table

echo "=== Setup check completed ==="
echo "Next manual checks:"
echo "  - Start python3 -m http.server 3000 on web01/web02 if needed."
echo "  - Open https://www.${DOMAIN_NAME} in browser."
echo "  - Check ssh bastion / ssh web01 / ssh web02."
echo "  - Check mysqladmin ping -u adminuser -p -h db.home from web01."

