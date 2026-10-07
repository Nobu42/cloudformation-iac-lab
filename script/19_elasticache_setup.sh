#!/bin/bash
set -euo pipefail

# 使用するAWS CLIプロファイルとリージョン。
PROFILE="learning"
REGION="ap-northeast-1"

# ElastiCacheを配置するVPC。
VPC_NAME="sample-vpc"

# ElastiCache for Redis設定。
# クラスターモード有効構成として、複数シャードを作成する。
REPLICATION_GROUP_ID="sample-elasticache"
REPLICATION_GROUP_DESCRIPTION="Sample Elasticache"
ENGINE="redis"
CACHE_NODE_TYPE="cache.t3.micro"

# クラスターモード有効時の構成。
# 2シャード、各シャードにReplicaを2台作成する。
# 合計ノード数は 2 * (1 Primary + 2 Replica) = 6台。
NUM_NODE_GROUPS="2"
REPLICAS_PER_NODE_GROUP="2"

# ElastiCache Subnet Group。
# 名前は指定どおり sample-elasticache-sg とする。
# ただし、この "sg" はSecurity GroupではなくSubnet Group名として扱う。
CACHE_SUBNET_GROUP_NAME="sample-elasticache-sg"
CACHE_SUBNET_GROUP_DESCRIPTION="Sample ElastiCache Subnet Group"

# ElastiCache用Security Group。
# WebサーバーからRedisへ接続するため、6379/tcpをsample-sg-webから許可する。
ELASTICACHE_SG_NAME="sample-sg-elasticache"
WEB_SG_NAME="sample-sg-web"

# Redisのデフォルトポート。
REDIS_PORT="6379"

# LocalStack向けのaliasや環境変数が残っていると、実AWSではなくLocalStackへ接続してしまう。
unalias aws 2>/dev/null || true
unset AWS_ENDPOINT_URL
unset LOCALSTACK_HOST

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

# ElastiCacheは課金対象のため、操作先アカウントを確認する。
aws sts get-caller-identity \
  --profile "$PROFILE" \
  --output table

echo "=== Get VPC ID ==="

VPC_ID=$(aws ec2 describe-vpcs \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=tag:Name,Values="$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

VPC_ID=$(get_required_value "VPC" "$VPC_ID")

echo "VPC ID: $VPC_ID"

echo "=== Get Private Subnet IDs ==="

# ElastiCacheは外部公開せず、Private Subnetに配置する。
# 02_subnet_setup.shで付与している Type=private タグを使って取得する。
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Type,Values=private \
  --query 'Subnets[].SubnetId' \
  --output text)

PRIVATE_SUBNET_IDS=$(get_required_value "Private Subnets" "$PRIVATE_SUBNET_IDS")

echo "Private Subnets: $PRIVATE_SUBNET_IDS"

echo "=== Get Web Security Group ID ==="

# Redisへの接続元として許可するWebサーバー用Security Groupを取得する。
WEB_SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$WEB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

WEB_SG_ID=$(get_required_value "Web Security Group" "$WEB_SG_ID")

echo "Web Security Group: $WEB_SG_ID"

echo "=== Create ElastiCache Security Group ==="

# ElastiCache用Security Groupが存在するか確認する。
ELASTICACHE_SG_ID=$(aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$ELASTICACHE_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [ "$ELASTICACHE_SG_ID" = "None" ] || [ -z "$ELASTICACHE_SG_ID" ]; then
  echo "ElastiCache Security Group not found. Creating: $ELASTICACHE_SG_NAME"

  ELASTICACHE_SG_ID=$(aws ec2 create-security-group \
    --profile "$PROFILE" \
    --region "$REGION" \
    --group-name "$ELASTICACHE_SG_NAME" \
    --description "for ElastiCache Redis" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$ELASTICACHE_SG_NAME},{Key=Project,Value=terraform-iac-lab},{Key=Environment,Value=learning}]" \
    --query 'GroupId' \
    --output text)

  echo "ElastiCache Security Group created: $ELASTICACHE_SG_ID"
else
  echo "ElastiCache Security Group already exists: $ELASTICACHE_SG_ID"
fi

echo "=== Authorize Redis Access from Web Security Group ==="

# WebサーバーからRedisへ接続できるように、6379/tcpを許可する。
# すでに同じルールがある場合はエラーになるため、その場合は続行する。
aws ec2 authorize-security-group-ingress \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-id "$ELASTICACHE_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$REDIS_PORT,ToPort=$REDIS_PORT,UserIdGroupPairs=[{GroupId=$WEB_SG_ID,Description='Redis access from web servers'}]" \
  2>/dev/null || echo "Redis ingress rule already exists or skipped."

echo "=== Create or Get ElastiCache Subnet Group ==="

# ElastiCache Subnet Groupは、ElastiCacheをどのSubnetに配置するかを定義する。
# 今回は作成済みのPrivate Subnetすべてを指定する。
SUBNET_GROUP_EXISTS="true"
aws elasticache describe-cache-subnet-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" >/dev/null 2>&1 || SUBNET_GROUP_EXISTS="false"

if [ "$SUBNET_GROUP_EXISTS" = "false" ]; then
  echo "ElastiCache Subnet Group not found. Creating: $CACHE_SUBNET_GROUP_NAME"

  aws elasticache create-cache-subnet-group \
    --profile "$PROFILE" \
    --region "$REGION" \
    --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" \
    --cache-subnet-group-description "$CACHE_SUBNET_GROUP_DESCRIPTION" \
    --subnet-ids $PRIVATE_SUBNET_IDS \
    --tags Key=Name,Value="$CACHE_SUBNET_GROUP_NAME" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning >/dev/null

  echo "ElastiCache Subnet Group created: $CACHE_SUBNET_GROUP_NAME"
else
  echo "ElastiCache Subnet Group already exists: $CACHE_SUBNET_GROUP_NAME"
fi

echo "=== Create or Get ElastiCache Replication Group ==="

# Replication Groupがすでに存在するか確認する。
REPLICATION_GROUP_STATUS=$(aws elasticache describe-replication-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --replication-group-id "$REPLICATION_GROUP_ID" \
  --query 'ReplicationGroups[0].Status' \
  --output text 2>/dev/null || true)

if [ "$REPLICATION_GROUP_STATUS" = "None" ] || [ -z "$REPLICATION_GROUP_STATUS" ]; then
  echo "ElastiCache Replication Group not found. Creating: $REPLICATION_GROUP_ID"

  # Cluster Mode Enabled相当のRedis構成を作成する。
  # --num-node-groups がシャード数。
  # --replicas-per-node-group が各シャードごとのReplica数。
  #
  # Replicaを持つ構成ではAutomatic Failoverを有効化する。
  # Availability Zoneは明示指定せず、AWS側に配置を任せる。
  aws elasticache create-replication-group \
    --profile "$PROFILE" \
    --region "$REGION" \
    --replication-group-id "$REPLICATION_GROUP_ID" \
    --replication-group-description "$REPLICATION_GROUP_DESCRIPTION" \
    --engine "$ENGINE" \
    --cache-node-type "$CACHE_NODE_TYPE" \
    --num-node-groups "$NUM_NODE_GROUPS" \
    --replicas-per-node-group "$REPLICAS_PER_NODE_GROUP" \
    --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" \
    --security-group-ids "$ELASTICACHE_SG_ID" \
    --automatic-failover-enabled \
    --multi-az-enabled \
    --tags Key=Name,Value="$REPLICATION_GROUP_ID" Key=Project,Value=terraform-iac-lab Key=Environment,Value=learning >/dev/null

  echo "ElastiCache Replication Group creation started: $REPLICATION_GROUP_ID"
else
  echo "ElastiCache Replication Group already exists: $REPLICATION_GROUP_ID"
  echo "Current status: $REPLICATION_GROUP_STATUS"
fi

echo "=== Wait for ElastiCache Replication Group to be available ==="

# ElastiCacheの作成には時間がかかる。
# availableになるまで待つ。
aws elasticache wait replication-group-available \
  --profile "$PROFILE" \
  --region "$REGION" \
  --replication-group-id "$REPLICATION_GROUP_ID"

echo "ElastiCache Replication Group is available."

echo "=== Describe ElastiCache Replication Group ==="

aws elasticache describe-replication-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --replication-group-id "$REPLICATION_GROUP_ID" \
  --query 'ReplicationGroups[*].{ID:ReplicationGroupId,Status:Status,Description:Description,ClusterEnabled:ClusterEnabled,MemberClusters:MemberClusters,ConfigurationEndpoint:ConfigurationEndpoint.Address}' \
  --output table

echo "=== Describe ElastiCache Security Group ==="

aws ec2 describe-security-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --group-ids "$ELASTICACHE_SG_ID" \
  --query 'SecurityGroups[*].{Name:GroupName,ID:GroupId,Rules:IpPermissions[*].{Protocol:IpProtocol,FromPort:FromPort,ToPort:ToPort,SourceGroup:UserIdGroupPairs[0].GroupId,Description:UserIdGroupPairs[0].Description}}' \
  --output table

echo "=== Describe ElastiCache Subnet Group ==="

aws elasticache describe-cache-subnet-groups \
  --profile "$PROFILE" \
  --region "$REGION" \
  --cache-subnet-group-name "$CACHE_SUBNET_GROUP_NAME" \
  --query 'CacheSubnetGroups[*].{Name:CacheSubnetGroupName,Description:CacheSubnetGroupDescription,VpcId:VpcId,Subnets:Subnets[*].SubnetIdentifier}' \
  --output table

echo "------------------------------------------------"
echo "ElastiCache setup completed."
echo "Replication Group:"
echo "  ${REPLICATION_GROUP_ID}"
echo "Engine:"
echo "  ${ENGINE}"
echo "Node type:"
echo "  ${CACHE_NODE_TYPE}"
echo "Shards:"
echo "  ${NUM_NODE_GROUPS}"
echo "Replicas per shard:"
echo "  ${REPLICAS_PER_NODE_GROUP}"
echo "Subnet Group:"
echo "  ${CACHE_SUBNET_GROUP_NAME}"
echo "Security Group:"
echo "  ${ELASTICACHE_SG_NAME} (${ELASTICACHE_SG_ID})"
echo "------------------------------------------------"
echo "Note:"
echo "  This configuration creates 6 cache nodes."
echo "  Delete it after learning to avoid unnecessary cost."
echo "------------------------------------------------"

