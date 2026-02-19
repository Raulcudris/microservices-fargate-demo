#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FULL DEPLOY: VPC (Public+Private) + Endpoints + ECR + ECS Fargate
#            + Cloud Map + ALB (solo Gateway) + RDS MySQL (opcional)
# ============================================================

# ✅ FIX Git Bash (MSYS) path conversion:
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# -------------------------
# CONFIG (AJUSTA AQUÍ)
# -------------------------
REGION="us-east-1"
PROJECT="microservices-fargate-demo"
CLUSTER_NAME="${PROJECT}-cluster"

# Directorios (coinciden con tu repo)
DIR_CONFIG="./configservice"
DIR_EUREKA="./eurekaservice"
DIR_GATEWAY="./gatewayservice"
DIR_PRODUCTS="./productservice"
DIR_ORDERS="./orderservice"
DIR_PAY="./paymentservice"
DIR_USERS="./userservice"

# ECR repos (se crean si no existen)
REPO_CONFIG="configservice"
REPO_EUREKA="eurekaservice"
REPO_GATEWAY="gatewayservice"
REPO_PRODUCTS="productservice"
REPO_ORDERS="orderservice"
REPO_PAY="paymentservice"
REPO_USERS="userservice"

# ECS service names
SVC_CONFIG="configservice"
SVC_EUREKA="eurekaservice"
SVC_GATEWAY="gatewayservice"
SVC_PRODUCTS="productservice"
SVC_ORDERS="orderservice"
SVC_PAY="paymentservice"
SVC_USERS="userservice"

# Puertos contenedor
PORT_CONFIG=8081
PORT_EUREKA=8761
PORT_GATEWAY=8080
PORT_PRODUCTS=8001
PORT_ORDERS=8002
PORT_PAY=8003
PORT_USERS=8004

# ALB health check (Gateway)
HEALTH_PATH_GATEWAY="/actuator/health"

# Cloud Map (Service Discovery interno)
NAMESPACE_NAME="${PROJECT}.local"   # DNS interno: configservice.microservices-fargate-demo.local

# VPC CIDRs
VPC_CIDR="10.20.0.0/16"
PUB1_CIDR="10.20.1.0/24"
PUB2_CIDR="10.20.2.0/24"
PRI1_CIDR="10.20.11.0/24"
PRI2_CIDR="10.20.12.0/24"

# ECS task sizing (ajústalo si necesitas)
CPU_SMALL="256"
MEM_SMALL="512"
CPU_MED="512"
MEM_MED="1024"

# RDS (opcional)
CREATE_RDS="true"         # true/false
DB_NAME="ecommerce_myshop"
DB_USER="admin"
DB_PASS="R00t2024**"
DB_INSTANCE_ID="${PROJECT}-mysql"
DB_INSTANCE_CLASS="db.t3.micro"    # free-tier friendly (según elegibilidad)
DB_ALLOCATED_STORAGE="20"          # free-tier friendly
DB_ENGINE="mysql"
DB_ENGINE_VERSION="8.0.35"         # puedes ajustar

# JWT (recomendado no hardcode en YAML)
JWT_SECRET="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.KMUFsIDTnFmyG3nMiGM6H9FNFUROf3wh7SmqJp-QV30"

# -------------------------
# HELPERS
# -------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1' en tu sistema"; exit 1; }; }

ensure_repo() {
  local repo="$1"
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$repo" --region "$REGION" >/dev/null
}

tag_push() {
  local local_img="$1"
  local repo="$2"
  local tag="$3"
  docker tag "$local_img" "$ECR/$repo:$tag"
  docker tag "$local_img" "$ECR/$repo:latest"
  docker push "$ECR/$repo:$tag"
  docker push "$ECR/$repo:latest"
}

json_escape() { jq -Rs '.' <<<"${1}"; }

# -------------------------
# PRECHECKS
# -------------------------
need aws
need docker
need jq

echo "==> 0) Identidad AWS..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TAG="$(date +%Y%m%d-%H%M%S)"

echo "Account: $ACCOUNT_ID"
echo "Region : $REGION"
echo "ECR    : $ECR"
echo "Tag    : $TAG"

# -------------------------
# 1) VPC + Subnets + IGW + Routes (public + private)
# -------------------------
echo "==> 1) Creando VPC y red (public + private)..."

AZ1="$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)"
AZ2="$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[1].ZoneName' --output text)"

VPC_ID="$(aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT}-vpc}]" | jq -r '.Vpc.VpcId')"

aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" >/dev/null
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" >/dev/null

IGW_ID="$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw}]" | jq -r '.InternetGateway.InternetGatewayId')"
aws ec2 attach-internet-gateway --region "$REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" >/dev/null

# Public subnets
PUB1_ID="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block "$PUB1_CIDR" --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-public-a}]" | jq -r '.Subnet.SubnetId')"
PUB2_ID="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block "$PUB2_CIDR" --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-public-b}]" | jq -r '.Subnet.SubnetId')"

aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$PUB1_ID" --map-public-ip-on-launch >/dev/null
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$PUB2_ID" --map-public-ip-on-launch >/dev/null

# Private subnets
PRI1_ID="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block "$PRI1_CIDR" --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-private-a}]" | jq -r '.Subnet.SubnetId')"
PRI2_ID="$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block "$PRI2_CIDR" --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-private-b}]" | jq -r '.Subnet.SubnetId')"

# Public route table -> IGW
RTB_PUB_ID="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-public-rtb}]" | jq -r '.RouteTable.RouteTableId')"

aws ec2 create-route --region "$REGION" --route-table-id "$RTB_PUB_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB1_ID" >/dev/null
aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB2_ID" >/dev/null

# Private route table (sin NAT)
RTB_PRI_ID="$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-private-rtb}]" | jq -r '.RouteTable.RouteTableId')"
aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI1_ID" >/dev/null
aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI2_ID" >/dev/null

echo "VPC: $VPC_ID"
echo "Public Subnets : $PUB1_ID, $PUB2_ID"
echo "Private Subnets: $PRI1_ID, $PRI2_ID"

# -------------------------
# 2) Security Groups (ALB, ECS private, Config public, RDS)
# -------------------------
echo "==> 2) Creando Security Groups..."

SG_ALB_ID="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-alb" --description "ALB SG" | jq -r '.GroupId')"

SG_ECS_PRIVATE_ID="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-ecs-private" --description "ECS Tasks Private SG" | jq -r '.GroupId')"

SG_CONFIG_PUBLIC_ID="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-config-public" --description "ConfigService Public SG" | jq -r '.GroupId')"

SG_RDS_ID="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-rds" --description "RDS MySQL SG" | jq -r '.GroupId')"

# ALB inbound 80 from internet
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ALB_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null

# ECS private inbound: Gateway 8080 only from ALB SG
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ECS_PRIVATE_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_GATEWAY},\"ToPort\":${PORT_GATEWAY},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ALB_ID}\"}]}]" >/dev/null

# Config public inbound: 8081 only from ECS private SG (NO desde internet)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_CONFIG_PUBLIC_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_CONFIG},\"ToPort\":${PORT_CONFIG},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null

# RDS inbound 3306 only from ECS private SG
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_RDS_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null

echo "SG ALB         : $SG_ALB_ID"
echo "SG ECS Private  : $SG_ECS_PRIVATE_ID"
echo "SG Config Public: $SG_CONFIG_PUBLIC_ID"
echo "SG RDS          : $SG_RDS_ID"

# -------------------------
# 3) VPC Endpoints (para que tasks privadas usen ECR/Logs sin NAT)
# -------------------------
echo "==> 3) Creando VPC Endpoints (ECR API, ECR DKR, CloudWatch Logs, S3)..."

# Security group para Interface Endpoints
SG_VPCE_ID="$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-vpce" --description "VPC Endpoints SG" | jq -r '.GroupId')"

# Permitir HTTPS desde ECS private SG hacia endpoints
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_VPCE_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null

# Interface Endpoints
aws ec2 create-vpc-endpoint --region "$REGION" --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.ecr.api" \
  --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null

aws ec2 create-vpc-endpoint --region "$REGION" --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.ecr.dkr" \
  --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null

aws ec2 create-vpc-endpoint --region "$REGION" --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.logs" \
  --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null

# Gateway Endpoint for S3 (ECR layers)
aws ec2 create-vpc-endpoint --region "$REGION" --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Gateway --service-name "com.amazonaws.${REGION}.s3" \
  --route-table-ids "$RTB_PRI_ID" >/dev/null

# -------------------------
# 4) ECR repos + login + build + push
# -------------------------
echo "==> 4) ECR repos + login + build/push..."

ensure_repo "$REPO_CONFIG"
ensure_repo "$REPO_EUREKA"
ensure_repo "$REPO_GATEWAY"
ensure_repo "$REPO_PRODUCTS"
ensure_repo "$REPO_ORDERS"
ensure_repo "$REPO_PAY"
ensure_repo "$REPO_USERS"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

echo "   - Build imágenes (docker build por servicio)..."
docker build -t "${PROJECT}-${REPO_CONFIG}:latest"   "$DIR_CONFIG"
docker build -t "${PROJECT}-${REPO_EUREKA}:latest"   "$DIR_EUREKA"
docker build -t "${PROJECT}-${REPO_GATEWAY}:latest"  "$DIR_GATEWAY"
docker build -t "${PROJECT}-${REPO_PRODUCTS}:latest" "$DIR_PRODUCTS"
docker build -t "${PROJECT}-${REPO_ORDERS}:latest"   "$DIR_ORDERS"
docker build -t "${PROJECT}-${REPO_PAY}:latest"      "$DIR_PAY"
docker build -t "${PROJECT}-${REPO_USERS}:latest"    "$DIR_USERS"

echo "   - Tag/push con tag: $TAG (y latest)..."
tag_push "${PROJECT}-${REPO_CONFIG}:latest"   "$REPO_CONFIG"   "$TAG"
tag_push "${PROJECT}-${REPO_EUREKA}:latest"   "$REPO_EUREKA"   "$TAG"
tag_push "${PROJECT}-${REPO_GATEWAY}:latest"  "$REPO_GATEWAY"  "$TAG"
tag_push "${PROJECT}-${REPO_PRODUCTS}:latest" "$REPO_PRODUCTS" "$TAG"
tag_push "${PROJECT}-${REPO_ORDERS}:latest"   "$REPO_ORDERS"   "$TAG"
tag_push "${PROJECT}-${REPO_PAY}:latest"      "$REPO_PAY"      "$TAG"
tag_push "${PROJECT}-${REPO_USERS}:latest"    "$REPO_USERS"    "$TAG"

# -------------------------
# 5) IAM Role for ECS Tasks (execution role)
# -------------------------
echo "==> 5) IAM execution role para ECS tasks..."
ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"

TRUST_POLICY='{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
  ROLE_ARN="$(aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" | jq -r '.Role.Arn')"
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
fi
echo "ExecutionRole: $ROLE_ARN"

# -------------------------
# 6) CloudWatch Log Groups
# -------------------------
echo "==> 6) Log groups (CloudWatch)..."
mklog() { aws logs create-log-group --log-group-name "$1" --region "$REGION" >/dev/null 2>&1 || true; }

LG_CONFIG="/ecs/${PROJECT}/config"
LG_EUREKA="/ecs/${PROJECT}/eureka"
LG_GATEWAY="/ecs/${PROJECT}/gateway"
LG_PRODUCTS="/ecs/${PROJECT}/products"
LG_ORDERS="/ecs/${PROJECT}/orders"
LG_PAY="/ecs/${PROJECT}/pay"
LG_USERS="/ecs/${PROJECT}/users"

mklog "$LG_CONFIG"
mklog "$LG_EUREKA"
mklog "$LG_GATEWAY"
mklog "$LG_PRODUCTS"
mklog "$LG_ORDERS"
mklog "$LG_PAY"
mklog "$LG_USERS"

# -------------------------
# 7) ECS Cluster
# -------------------------
echo "==> 7) Creando cluster ECS..."
aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 || true

# -------------------------
# 8) Cloud Map Namespace + Services (service discovery interno)
# -------------------------
echo "==> 8) Creando Cloud Map namespace y servicios..."

NAMESPACE_ID="$(aws servicediscovery create-private-dns-namespace \
  --name "$NAMESPACE_NAME" --vpc "$VPC_ID" --region "$REGION" \
  --description "${PROJECT} private namespace" | jq -r '.OperationId')"

# Espera corta a que namespace quede listo
sleep 5

create_sd_service () {
  local name="$1"
  aws servicediscovery create-service --name "$name" --region "$REGION" \
    --dns-config "NamespaceId=$(aws servicediscovery list-namespaces --region "$REGION" | jq -r ".Namespaces[] | select(.Name==\"$NAMESPACE_NAME\") | .Id"),DnsRecords=[{Type=A,TTL=30}],RoutingPolicy=WEIGHTED" \
    --health-check-custom-config FailureThreshold=1 \
  | jq -r '.Service.Id'
}

SD_CONFIG_ID="$(create_sd_service "$SVC_CONFIG")"
SD_EUREKA_ID="$(create_sd_service "$SVC_EUREKA")"
SD_GATEWAY_ID="$(create_sd_service "$SVC_GATEWAY")"
SD_PRODUCTS_ID="$(create_sd_service "$SVC_PRODUCTS")"
SD_ORDERS_ID="$(create_sd_service "$SVC_ORDERS")"
SD_PAY_ID="$(create_sd_service "$SVC_PAY")"
SD_USERS_ID="$(create_sd_service "$SVC_USERS")"

echo "Cloud Map services created."

# -------------------------
# 9) (Opcional) RDS MySQL en subnets privadas (Free Tier-friendly)
# -------------------------
DB_ENDPOINT=""
if [[ "${CREATE_RDS}" == "true" ]]; then
  echo "==> 9) Creando RDS MySQL (privado)..."

  # Asegura engine mysql (free tier aplica a RDS MySQL, no Aurora)
  DB_ENGINE="mysql"
  DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
  DB_ALLOCATED_STORAGE="${DB_ALLOCATED_STORAGE:-20}"
  DB_STORAGE_TYPE="${DB_STORAGE_TYPE:-gp2}"

  # Obtener una versión válida en la región (default)
  DB_ENGINE_VERSION="$(aws rds describe-db-engine-versions --region "$REGION" \
    --engine "$DB_ENGINE" --default-only \
    --query "DBEngineVersions[0].EngineVersion" --output text)"

  if [[ -z "$DB_ENGINE_VERSION" || "$DB_ENGINE_VERSION" == "None" ]]; then
    echo "❌ No pude resolver DB_ENGINE_VERSION default para engine=$DB_ENGINE en region=$REGION"
    exit 1
  fi

  echo "   - Engine: $DB_ENGINE"
  echo "   - EngineVersion(default): $DB_ENGINE_VERSION"
  echo "   - Class: $DB_INSTANCE_CLASS | Storage: ${DB_ALLOCATED_STORAGE}GB $DB_STORAGE_TYPE"

  # DB Subnet Group
  aws rds create-db-subnet-group --region "$REGION" \
    --db-subnet-group-name "${PROJECT}-db-subnets" \
    --db-subnet-group-description "Private subnets for RDS" \
    --subnet-ids "$PRI1_ID" "$PRI2_ID" >/dev/null 2>&1 || true

  # Crear DB (si no existe)
  if ! aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
    aws rds create-db-instance --region "$REGION" \
      --db-instance-identifier "$DB_INSTANCE_ID" \
      --db-instance-class "$DB_INSTANCE_CLASS" \
      --engine "$DB_ENGINE" \
      --engine-version "$DB_ENGINE_VERSION" \
      --allocated-storage "$DB_ALLOCATED_STORAGE" \
      --storage-type "$DB_STORAGE_TYPE" \
      --master-username "$DB_USER" \
      --master-user-password "$DB_PASS" \
      --db-name "$DB_NAME" \
      --vpc-security-group-ids "$SG_RDS_ID" \
      --db-subnet-group-name "${PROJECT}-db-subnets" \
      --no-publicly-accessible \
      --backup-retention-period 0 \
      --no-multi-az >/dev/null
  else
    echo "   - RDS ya existe: $DB_INSTANCE_ID (no recreo)"
  fi

  echo "   - Esperando a que RDS esté disponible (puede tardar)..."
  aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID"

  DB_ENDPOINT="$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].Endpoint.Address" --output text)"

  echo "✅ RDS Endpoint: $DB_ENDPOINT"
fi

# -------------------------
# 10) ALB + Target Group + Listener (solo Gateway)
# -------------------------
echo "==> 10) Creando ALB + Target Group (solo Gateway)..."

TG_GW_ARN="$(aws elbv2 create-target-group --name "${PROJECT}-tg-gateway" \
  --protocol HTTP --port "$PORT_GATEWAY" --vpc-id "$VPC_ID" --target-type ip \
  --health-check-protocol HTTP --health-check-path "$HEALTH_PATH_GATEWAY" \
  --region "$REGION" | jq -r '.TargetGroups[0].TargetGroupArn')"

ALB_ARN="$(aws elbv2 create-load-balancer --name "${PROJECT}-alb" --type application --scheme internet-facing \
  --subnets "$PUB1_ID" "$PUB2_ID" --security-groups "$SG_ALB_ID" --region "$REGION" \
  | jq -r '.LoadBalancers[0].LoadBalancerArn')"

ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$REGION" \
  | jq -r '.LoadBalancers[0].DNSName')"
echo "ALB DNS: $ALB_DNS"

LISTENER_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" \
  --region "$REGION" | jq -r '.Listeners[0].ListenerArn')"

# -------------------------
# 11) Task Definitions (7)
# -------------------------
echo "==> 11) Registrando Task Definitions..."

NETWORK_MODE="awsvpc"

register_task_def () {
  local family="$1"
  local image="$2"
  local port="$3"
  local log_group="$4"
  local cname="$5"
  local cpu="$6"
  local mem="$7"
  local env_json="$8"

  aws ecs register-task-definition --family "$family" --network-mode "$NETWORK_MODE" \
    --requires-compatibilities FARGATE --cpu "$cpu" --memory "$mem" \
    --execution-role-arn "$ROLE_ARN" --region "$REGION" \
    --container-definitions "[
      {
        \"name\": \"$cname\",
        \"image\": \"$image\",
        \"essential\": true,
        \"portMappings\": [{\"containerPort\": $port, \"protocol\": \"tcp\"}],
        \"environment\": $env_json,
        \"logConfiguration\": {
          \"logDriver\": \"awslogs\",
          \"options\": {
            \"awslogs-group\": \"$log_group\",
            \"awslogs-region\": \"$REGION\",
            \"awslogs-stream-prefix\": \"ecs\"
          }
        }
      }
    ]" | jq -r '.taskDefinition.taskDefinitionArn'
}

# Env base para que NO dependas de tus variables custom
ENV_CONFIG='[
  {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_URI","value":"https://github.com/Raulcudris/microservices-fargate-demo.git"},
  {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL","value":"main"},
  {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS","value":"config-data"},
  {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START","value":"true"}
]'

# Clientes: apuntan a configservice + eureka internos
ENV_CLIENT_BASE='[
  {"name":"SPRING_CLOUD_CONFIG_URI","value":"http://configservice:8081"},
  {"name":"EUREKA_CLIENT_SERVICEURL_DEFAULTZONE","value":"http://eurekaservice:8761/eureka/"}
]'

# MySQL env (si RDS existe, úsalo; si no, queda vacío y tú lo ajustas)
MYSQL_ENV="[]"
if [[ -n "$DB_ENDPOINT" ]]; then
  MYSQL_ENV="$(jq -nc --arg host "$DB_ENDPOINT" --arg db "$DB_NAME" --arg user "$DB_USER" --arg pass "$DB_PASS" \
    '[{"name":"DB_HOST","value":$host},{"name":"DB_NAME","value":$db},{"name":"DB_USER","value":$user},{"name":"DB_PASS","value":$pass}]')"
fi

# Users JWT env
JWT_ENV="$(jq -nc --arg jwt "$JWT_SECRET" '[{"name":"JWT_SECRET","value":$jwt}]')"

# Merge env arrays helper via jq at runtime
merge_env () {
  jq -s 'add' <(echo "$1") <(echo "$2")
}

TD_CONFIG_ARN="$(register_task_def "${PROJECT}-td-config"   "$ECR/$REPO_CONFIG:$TAG"   "$PORT_CONFIG"   "$LG_CONFIG"   "configservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_CONFIG")"
TD_EUREKA_ARN="$(register_task_def "${PROJECT}-td-eureka"   "$ECR/$REPO_EUREKA:$TAG"   "$PORT_EUREKA"   "$LG_EUREKA"   "eurekaservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_CLIENT_BASE")"
TD_GATEWAY_ARN="$(register_task_def "${PROJECT}-td-gateway" "$ECR/$REPO_GATEWAY:$TAG"  "$PORT_GATEWAY"  "$LG_GATEWAY"  "gatewayservice" "$CPU_MED"   "$MEM_MED"   "$ENV_CLIENT_BASE")"

ENV_PRODUCTS="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
ENV_ORDERS="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
ENV_PAY="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
ENV_USERS="$(merge_env "$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")" "$JWT_ENV")"

TD_PRODUCTS_ARN="$(register_task_def "${PROJECT}-td-products" "$ECR/$REPO_PRODUCTS:$TAG" "$PORT_PRODUCTS" "$LG_PRODUCTS" "productservice" "$CPU_SMALL" "$MEM_SMALL" "$ENV_PRODUCTS")"
TD_ORDERS_ARN="$(register_task_def "${PROJECT}-td-orders"   "$ECR/$REPO_ORDERS:$TAG"   "$PORT_ORDERS"   "$LG_ORDERS"   "orderservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_ORDERS")"
TD_PAY_ARN="$(register_task_def "${PROJECT}-td-pay"         "$ECR/$REPO_PAY:$TAG"      "$PORT_PAY"      "$LG_PAY"      "paymentservice" "$CPU_SMALL" "$MEM_SMALL" "$ENV_PAY")"
TD_USERS_ARN="$(register_task_def "${PROJECT}-td-users"     "$ECR/$REPO_USERS:$TAG"    "$PORT_USERS"    "$LG_USERS"    "userservice"    "$CPU_SMALL" "$MEM_SMALL" "$ENV_USERS")"

# -------------------------
# 12) ECS Services + Cloud Map + ALB attach (solo Gateway)
# -------------------------
echo "==> 12) Creando ECS Services..."

# Network confs
NETCONF_PUBLIC="awsvpcConfiguration={subnets=[$PUB1_ID,$PUB2_ID],securityGroups=[$SG_CONFIG_PUBLIC_ID],assignPublicIp=ENABLED}"
NETCONF_PRIVATE="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_PRIVATE_ID],assignPublicIp=DISABLED}"

create_service_sd () {
  local svc="$1"
  local td="$2"
  local net="$3"
  local sd_id="$4"
  aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" \
    --task-definition "$td" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$net" \
    --service-registries "registryArn=arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/${sd_id}" \
    --health-check-grace-period-seconds 120 \
    --region "$REGION" >/dev/null
}

create_service_sd_lb () {
  local svc="$1"
  local td="$2"
  local net="$3"
  local sd_id="$4"
  local tg="$5"
  local cname="$6"
  local cport="$7"
  aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" \
    --task-definition "$td" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$net" \
    --service-registries "registryArn=arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/${sd_id}" \
    --load-balancers "targetGroupArn=$tg,containerName=$cname,containerPort=$cport" \
    --health-check-grace-period-seconds 180 \
    --region "$REGION" >/dev/null
}

# Orden recomendado (para reducir fallos de arranque)
create_service_sd "$SVC_CONFIG"   "$TD_CONFIG_ARN"   "$NETCONF_PUBLIC"  "$SD_CONFIG_ID"
create_service_sd "$SVC_EUREKA"   "$TD_EUREKA_ARN"   "$NETCONF_PRIVATE" "$SD_EUREKA_ID"
create_service_sd_lb "$SVC_GATEWAY" "$TD_GATEWAY_ARN" "$NETCONF_PRIVATE" "$SD_GATEWAY_ID" "$TG_GW_ARN" "gatewayservice" "$PORT_GATEWAY"
create_service_sd "$SVC_PRODUCTS" "$TD_PRODUCTS_ARN" "$NETCONF_PRIVATE" "$SD_PRODUCTS_ID"
create_service_sd "$SVC_ORDERS"   "$TD_ORDERS_ARN"   "$NETCONF_PRIVATE" "$SD_ORDERS_ID"
create_service_sd "$SVC_PAY"      "$TD_PAY_ARN"      "$NETCONF_PRIVATE" "$SD_PAY_ID"
create_service_sd "$SVC_USERS"    "$TD_USERS_ARN"    "$NETCONF_PRIVATE" "$SD_USERS_ID"

echo ""
echo "✅ Deploy completado."
echo "ALB DNS: http://${ALB_DNS}"
echo ""
echo "Pruebas (vía Gateway):"
echo "  - http://${ALB_DNS}/products/..."
echo "  - http://${ALB_DNS}/orders/..."
echo "  - http://${ALB_DNS}/pay/..."
echo "  - http://${ALB_DNS}/users/login"
echo ""
echo "Health Gateway:"
echo "  - http://${ALB_DNS}${HEALTH_PATH_GATEWAY}"
echo ""
if [[ -n "$DB_ENDPOINT" ]]; then
  echo "RDS endpoint (privado): ${DB_ENDPOINT}"
fi
