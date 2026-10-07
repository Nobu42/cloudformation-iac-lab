#!/bin/bash
set -euo pipefail

PROFILE="learning"
REGION="ap-northeast-1"

DOMAIN_NAME="nobu-iac-lab.com"
DOMAIN_NAME_DOT="${DOMAIN_NAME}."

unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

echo "=== Caller Identity ==="
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== VPCs tagged sample-vpc ==="
aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values=sample-vpc \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,State:State,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

echo "=== EC2 Instances ==="
aws ec2 describe-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],ID:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress}' \
  --output table

echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'NatGateways[*].{ID:NatGatewayId,State:State,VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

echo "=== Elastic IPs ==="
aws ec2 describe-addresses \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'Addresses[*].{AllocationId:AllocationId,PublicIp:PublicIp,AssociationId:AssociationId,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

echo "=== Load Balancers ==="
aws elbv2 describe-load-balancers \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' \
  --output table

echo "=== Target Groups ==="
aws elbv2 describe-target-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'TargetGroups[*].{Name:TargetGroupName,Port:Port,Protocol:Protocol,VpcId:VpcId}' \
  --output table

echo "=== RDS Instances ==="
aws rds describe-db-instances \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Public:PubliclyAccessible}' \
  --output table

echo "=== S3 Buckets ==="
aws s3 ls \
  --profile "$PROFILE"

echo "=== Public Hosted Zone ==="
PUBLIC_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "$DOMAIN_NAME_DOT" \
  --query "HostedZones[?Name==\`$DOMAIN_NAME_DOT\` && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text 2>/dev/null || true)

if [ "$PUBLIC_HOSTED_ZONE_ID" != "None" ] && [ -n "$PUBLIC_HOSTED_ZONE_ID" ]; then
  PUBLIC_HOSTED_ZONE_ID="${PUBLIC_HOSTED_ZONE_ID#/hostedzone/}"
  echo "Public Hosted Zone ID: $PUBLIC_HOSTED_ZONE_ID"

  echo "=== Public DNS temporary records ==="
  aws route53 list-resource-record-sets \
    --profile "$PROFILE" \
    --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name==\`bastion.${DOMAIN_NAME}.\` || Name==\`www.${DOMAIN_NAME}.\` || (Name==\`${DOMAIN_NAME}.\` && Type==\`MX\`)]" \
    --output table

  echo "=== Public DNS kept records for ACM / SES ==="
  aws route53 list-resource-record-sets \
    --profile "$PROFILE" \
    --hosted-zone-id "$PUBLIC_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?contains(Name, \`acm-validations.aws\`) || contains(Name, \`_domainkey.${DOMAIN_NAME}.\`) || Name==\`_dmarc.${DOMAIN_NAME}.\` || (Name==\`${DOMAIN_NAME}.\` && Type==\`TXT\`)]" \
    --output table
else
  echo "Public Hosted Zone not found."
fi

echo "=== Private Hosted Zone home ==="
aws route53 list-hosted-zones-by-name \
  --profile "$PROFILE" \
  --dns-name "home." \
  --query "HostedZones[?Name==\`home.\` && Config.PrivateZone==\`true\`].{ID:Id,Name:Name,Private:Config.PrivateZone}" \
  --output table

echo "=== SES Active Receipt Rule Set ==="
aws ses describe-active-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query '{Name:Metadata.Name,CreatedTimestamp:Metadata.CreatedTimestamp}' \
  --output table 2>/dev/null || echo "No active receipt rule set."

echo "=== SES Receipt Rule Set sample-ruleset ==="
aws ses describe-receipt-rule-set \
  --profile "$PROFILE" \
  --region "$REGION" \
  --rule-set-name sample-ruleset \
  --query 'Rules[*].{Name:Name,Enabled:Enabled,Recipients:Recipients,ScanEnabled:ScanEnabled}' \
  --output table 2>/dev/null || echo "Receipt Rule Set sample-ruleset not found."

echo "=== ACM Certificates kept ==="
aws acm list-certificates \
  --profile "$PROFILE" \
  --region "$REGION" \
  --certificate-statuses ISSUED PENDING_VALIDATION \
  --query 'CertificateSummaryList[*].{DomainName:DomainName,Status:Status,Arn:CertificateArn}' \
  --output table

echo "=== SES Identities kept ==="
aws sesv2 list-email-identities \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'EmailIdentities[*].{IdentityName:IdentityName,IdentityType:IdentityType,SendingEnabled:SendingEnabled,VerificationStatus:VerificationStatus}' \
  --output table

echo "=== Cleanup check completed ==="
echo "Expected after cleanup:"
echo "  - No sample-vpc"
echo "  - No running/stopped EC2"
echo "  - No available NAT Gateway"
echo "  - No Elastic IP"
echo "  - No ALB / Target Group"
echo "  - No RDS instance"
echo "  - No temporary DNS records: bastion, www, MX"
echo "  - No Private Hosted Zone: home"
echo "  - S3 buckets for daily lab should be deleted"
echo ""
echo "Expected to remain:"
echo "  - Public Hosted Zone: ${DOMAIN_NAME}"
echo "  - ACM certificate"
echo "  - SES Domain Identity / DKIM / SPF / DMARC"
echo "  - SES SMTP IAM user"

