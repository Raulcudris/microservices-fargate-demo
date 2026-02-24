#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RESUMABLE + IDEMPOTENT FULL DEPLOY (AWS)
# - Lee config desde .env
# - MODE_NO_NAT=true  => SIN NAT (solo VPC Endpoints)
# - MODE_NO_NAT=false => CON NAT (private subnets con salida)
# - NO crea Base de Datos (tú la creas con otro script aparte)
# - ECR + build/push
# - IAM ExecutionRole
# - CloudWatch Logs
# - ECS Cluster + Cloud Map (Namespace + Services)
# - ALB (Gateway) con HTTP o HTTPS (ACM)
# - ECS Services create-or-update + force-new-deployment
# ============================================================

# ✅ FIX Git Bash (MSYS) path conversion:
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# -------------------------
# LOAD .env
# -------------------------
ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "⚠️  No encuentro $ENV_FILE. Crea un .env o exporta variables antes de ejecutar."
  exit 1
fi

# -------------------------
# CONFIG (desde .env + defaults)
# -------------------------
REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

MODE_NO_NAT="${MODE_NO_NAT:-true}" # true = sin NAT

# Git Config (ConfigService)
CONFIG_GIT_URI="${CONFIG_GIT_URI:-}"
CONFIG_GIT_BRANCH="${CONFIG_GIT_BRANCH:-main}"
CONFIG_GIT_PATHS="${CONFIG_GIT_PATHS:-config-data}"

# DB: NO se crea aquí. Solo se consume si tú defines DB_ENDPOINT.
DB_ENDPOINT="${DB_ENDPOINT:-}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"

# JWT
JWT_SECRET="${JWT_SECRET:-}"

# Health checks
HEALTH_PATH_GATEWAY="${HEALTH_PATH_GATEWAY:-/actuator/health}"

# HTTPS ALB
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"
ACM_CERT_ARN="${ACM_CERT_ARN:-}"

# Autoscaling (si luego quieres integrarlo)
ASG_MIN="${ASG_MIN:-1}"
ASG_MAX="${ASG_MAX:-4}"
ASG_CPU_TARGET="${ASG_CPU_TARGET:-60}"
ASG_MEM_TARGET="${ASG_MEM_TARGET:-70}"

# Names
CLUSTER_NAME="${PROJECT}-cluster"
NAMESPACE_NAME="${PROJECT}.local"

# Directorios (repo)
DIR_CONFIG="./configservice"
DIR_EUREKA="./eurekaservice"
DIR_GATEWAY="./gatewayservice"
DIR_PRODUCTS="./productservice"
DIR_ORDERS="./orderservice"
DIR_PAY="./paymentservice"
DIR_USERS="./userservice"

# ECR repos
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

# Ports
PORT_CONFIG=8081
PORT_EUREKA=8761
PORT_GATEWAY=8080
PORT_PRODUCTS=8001
PORT_ORDERS=8002
PORT_PAY=8003
PORT_USERS=8004

# VPC CIDRs
VPC_CIDR="10.20.0.0/16"
PUB1_CIDR="10.20.1.0/24"
PUB2_CIDR="10.20.2.0/24"
PRI1_CIDR="10.20.11.0/24"
PRI2_CIDR="10.20.12.0/24"

# ECS sizing
CPU_SMALL="256"
MEM_SMALL="512"
CPU_MED="512"
MEM_MED="1024"

# ALB names (<=32)
TG_GW_NAME="msf-tg-gw"
ALB_NAME="msf-alb"

# State file
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# -------------------------
# HELPERS
# -------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
log() { echo -e "👉 $*" >&2; }
ok()  { echo -e "✅ $*" >&2; }
warn(){ echo -e "⚠️  $*" >&2; }

awsq() { aws --region "$REGION" "$@"; }

state_init() { [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"; }
state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true; }
state_set() { local k="$1"; local v="$2"; local tmp; tmp="$(mktemp)"; jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$STATE_FILE" > "$tmp"; mv "$tmp" "$STATE_FILE"; }
step_done() { state_set "step_${1}" "done"; }
is_step_done() { [[ "$(state_get "step_${1}")" == "done" ]]; }

on_error() {
  echo ""
  echo "❌ Error detectado. Estado guardado en: $STATE_FILE"
  echo "   Re-ejecuta este script y continuará donde quedó."
}
trap on_error ERR

tag_spec() {
  local rtype="$1"; local name="$2"
  echo "ResourceType=${rtype},Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Env,Value=${ENV_NAME}}]"
}

# -------------------------
# VALIDACIONES MÍNIMAS
# -------------------------
need aws
need docker
need jq

[[ -n "$CONFIG_GIT_URI" ]] || { echo "❌ CONFIG_GIT_URI está vacío en .env"; exit 1; }
[[ -n "$JWT_SECRET" ]]    || { echo "❌ JWT_SECRET está vacío en .env"; exit 1; }

if [[ "$ENABLE_HTTPS" == "true" ]]; then
  [[ -n "$ACM_CERT_ARN" ]] || { echo "❌ ENABLE_HTTPS=true pero ACM_CERT_ARN está vacío"; exit 1; }
fi

state_init

log "0) Identidad AWS..."
ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Tag estable
STATE_TAG="$(state_get TAG)"
if [[ -n "${STATE_TAG:-}" && "${STATE_TAG}" != "null" ]]; then
  TAG="$STATE_TAG"
else
  TAG="$(date +%Y%m%d-%H%M%S)"
  state_set TAG "$TAG"
fi

ok "Account: $ACCOUNT_ID"
ok "Region : $REGION"
ok "Project: $PROJECT"
ok "ECR    : $ECR"
ok "Tag    : $TAG"
ok "MODE_NO_NAT: $MODE_NO_NAT"
ok "HTTPS: $ENABLE_HTTPS"

# -------------------------
# DISCOVERY HELPERS
# -------------------------
find_vpc() {
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-vpc" "Name=tag:Project,Values=${PROJECT}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -v "None" || true
}
find_igw() {
  awsq ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=${PROJECT}-igw" "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -v "None" || true
}
find_subnet_by_name() {
  awsq ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${1}" \
    --query "Subnets[0].SubnetId" --output text 2>/dev/null | grep -v "None" || true
}
find_rtb_by_name() {
  awsq ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${1}" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null | grep -v "None" || true
}

ensure_sg() {
  local sg_name="$1"; local desc="$2"; local state_key="$3"
  local sg_id
  sg_id="$(state_get "$state_key")"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(awsq ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg_name" \
      --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v "None" || true)"
  fi
  if [[ -z "$sg_id" ]]; then
    sg_id="$(awsq ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$sg_name" --description "$desc" | jq -r '.GroupId')"
    awsq ec2 create-tags --resources "$sg_id" --tags "Key=Name,Value=$sg_name" "Key=Project,Value=$PROJECT" "Key=Env,Value=$ENV_NAME" >/dev/null
    ok "SG creado: $sg_name -> $sg_id"
  else
    ok "SG reusado: $sg_name -> $sg_id"
  fi
  state_set "$state_key" "$sg_id"
  echo "$sg_id"
}

ensure_repo() {
  local repo="$1"
  awsq ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 \
    || awsq ecr create-repository --repository-name "$repo" >/dev/null
}

tag_push() {
  local local_img="$1"; local repo="$2"; local tag="$3"
  docker tag "$local_img" "$ECR/$repo:$tag"
  docker tag "$local_img" "$ECR/$repo:latest"
  docker push "$ECR/$repo:$tag"
  docker push "$ECR/$repo:latest"
}

merge_env() {
  local a="${1:-[]}"; local b="${2:-[]}"
  [[ -z "${a//[[:space:]]/}" ]] && a="[]"
  [[ -z "${b//[[:space:]]/}" ]] && b="[]"
  jq -cn --argjson A "$a" --argjson B "$b" '$A + $B'
}

# -------------------------
# STEP 1) VPC + Subnets + IGW + Routes
# -------------------------
if ! is_step_done 1; then
  log "1) VPC y red (idempotente)..."

  VPC_ID="$(state_get VPC_ID)"; [[ -z "$VPC_ID" ]] && VPC_ID="$(find_vpc)"

  AZ1="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
  AZ2="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"

  if [[ -z "$VPC_ID" ]]; then
    VPC_ID="$(awsq ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(tag_spec vpc "${PROJECT}-vpc")" | jq -r '.Vpc.VpcId')"
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" >/dev/null
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" >/dev/null
    ok "VPC creada: $VPC_ID"
  else
    ok "VPC reusada: $VPC_ID"
  fi
  state_set VPC_ID "$VPC_ID"

  IGW_ID="$(state_get IGW_ID)"; [[ -z "$IGW_ID" ]] && IGW_ID="$(find_igw)"
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID="$(awsq ec2 create-internet-gateway --tag-specifications "$(tag_spec internet-gateway "${PROJECT}-igw")" | jq -r '.InternetGateway.InternetGatewayId')"
    awsq ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" >/dev/null
    ok "IGW creado+adjuntado: $IGW_ID"
  else
    ok "IGW reusado: $IGW_ID"
  fi
  state_set IGW_ID "$IGW_ID"

  PUB1_ID="$(state_get PUB1_ID)"; [[ -z "$PUB1_ID" ]] && PUB1_ID="$(find_subnet_by_name "${PROJECT}-public-a")"
  PUB2_ID="$(state_get PUB2_ID)"; [[ -z "$PUB2_ID" ]] && PUB2_ID="$(find_subnet_by_name "${PROJECT}-public-b")"
  PRI1_ID="$(state_get PRI1_ID)"; [[ -z "$PRI1_ID" ]] && PRI1_ID="$(find_subnet_by_name "${PROJECT}-private-a")"
  PRI2_ID="$(state_get PRI2_ID)"; [[ -z "$PRI2_ID" ]] && PRI2_ID="$(find_subnet_by_name "${PROJECT}-private-b")"

  if [[ -z "$PUB1_ID" ]]; then
    PUB1_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB1_CIDR" --availability-zone "$AZ1" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-public-a")" | jq -r '.Subnet.SubnetId')"
    awsq ec2 modify-subnet-attribute --subnet-id "$PUB1_ID" --map-public-ip-on-launch >/dev/null
    ok "Subnet pública A creada: $PUB1_ID"
  else ok "Subnet pública A reusada: $PUB1_ID"; fi

  if [[ -z "$PUB2_ID" ]]; then
    PUB2_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB2_CIDR" --availability-zone "$AZ2" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-public-b")" | jq -r '.Subnet.SubnetId')"
    awsq ec2 modify-subnet-attribute --subnet-id "$PUB2_ID" --map-public-ip-on-launch >/dev/null
    ok "Subnet pública B creada: $PUB2_ID"
  else ok "Subnet pública B reusada: $PUB2_ID"; fi

  if [[ -z "$PRI1_ID" ]]; then
    PRI1_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRI1_CIDR" --availability-zone "$AZ1" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-private-a")" | jq -r '.Subnet.SubnetId')"
    ok "Subnet privada A creada: $PRI1_ID"
  else ok "Subnet privada A reusada: $PRI1_ID"; fi

  if [[ -z "$PRI2_ID" ]]; then
    PRI2_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRI2_CIDR" --availability-zone "$AZ2" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-private-b")" | jq -r '.Subnet.SubnetId')"
    ok "Subnet privada B creada: $PRI2_ID"
  else ok "Subnet privada B reusada: $PRI2_ID"; fi

  state_set PUB1_ID "$PUB1_ID"; state_set PUB2_ID "$PUB2_ID"
  state_set PRI1_ID "$PRI1_ID"; state_set PRI2_ID "$PRI2_ID"

  RTB_PUB_ID="$(state_get RTB_PUB_ID)"; [[ -z "$RTB_PUB_ID" ]] && RTB_PUB_ID="$(find_rtb_by_name "${PROJECT}-public-rtb")"
  if [[ -z "$RTB_PUB_ID" ]]; then
    RTB_PUB_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "${PROJECT}-public-rtb")" | jq -r '.RouteTable.RouteTableId')"
    ok "RTB pública creada: $RTB_PUB_ID"
  else ok "RTB pública reusada: $RTB_PUB_ID"; fi
  state_set RTB_PUB_ID "$RTB_PUB_ID"

  awsq ec2 create-route --route-table-id "$RTB_PUB_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB1_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB2_ID" >/dev/null 2>&1 || true

  RTB_PRI_ID="$(state_get RTB_PRI_ID)"; [[ -z "$RTB_PRI_ID" ]] && RTB_PRI_ID="$(find_rtb_by_name "${PROJECT}-private-rtb")"
  if [[ -z "$RTB_PRI_ID" ]]; then
    RTB_PRI_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "${PROJECT}-private-rtb")" | jq -r '.RouteTable.RouteTableId')"
    ok "RTB privada creada: $RTB_PRI_ID"
  else ok "RTB privada reusada: $RTB_PRI_ID"; fi
  state_set RTB_PRI_ID "$RTB_PRI_ID"

  awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI1_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI2_ID" >/dev/null 2>&1 || true

  ok "VPC: $VPC_ID"
  ok "Public Subnets : $PUB1_ID, $PUB2_ID"
  ok "Private Subnets: $PRI1_ID, $PRI2_ID"

  step_done 1
fi

# -------------------------
# STEP NAT (solo si MODE_NO_NAT=false)
# -------------------------
if [[ "$MODE_NO_NAT" == "false" ]]; then
  if ! is_step_done "NAT"; then
    log "NAT) Creando NAT Gateway (porque MODE_NO_NAT=false)..."

    VPC_ID="$(state_get VPC_ID)"
    PUB1_ID="$(state_get PUB1_ID)"
    RTB_PRI_ID="$(state_get RTB_PRI_ID)"

    NAT_EIP_ALLOC_ID="$(state_get NAT_EIP_ALLOC_ID)"
    if [[ -z "${NAT_EIP_ALLOC_ID:-}" || "$NAT_EIP_ALLOC_ID" == "None" ]]; then
      NAT_EIP_ALLOC_ID="$(awsq ec2 allocate-address --domain vpc --query AllocationId --output text)"
      state_set NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"
      ok "EIP asignada: $NAT_EIP_ALLOC_ID"
    else
      ok "EIP reusada: $NAT_EIP_ALLOC_ID"
    fi

    NAT_GW_ID="$(state_get NAT_GW_ID)"
    if [[ -z "${NAT_GW_ID:-}" || "$NAT_GW_ID" == "None" ]]; then
      NAT_GW_ID="$(awsq ec2 create-nat-gateway --subnet-id "$PUB1_ID" --allocation-id "$NAT_EIP_ALLOC_ID" \
        --query "NatGateway.NatGatewayId" --output text)"
      state_set NAT_GW_ID "$NAT_GW_ID"
      ok "NAT Gateway creado: $NAT_GW_ID"
    else
      ok "NAT Gateway reusado: $NAT_GW_ID"
    fi

    log "Esperando NAT Gateway available..."
    awsq ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
    ok "NAT Gateway listo: $NAT_GW_ID"

    awsq ec2 create-route --route-table-id "$RTB_PRI_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
    ok "Ruta privada -> NAT configurada en: $RTB_PRI_ID"

    step_done "NAT"
  fi
else
  ok "NAT deshabilitado (MODE_NO_NAT=true)."
fi

# -------------------------
# STEP 2) Security Groups + VPC Endpoints (si MODE_NO_NAT=true)
# -------------------------
if ! is_step_done 2; then
  log "2) SG + (opcional) VPC Endpoints..."

  VPC_ID="$(state_get VPC_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"

  SG_ALB_ID="$(ensure_sg "${PROJECT}-sg-alb" "ALB SG" "SG_ALB_ID")"
  SG_ECS_PRIVATE_ID="$(ensure_sg "${PROJECT}-sg-ecs-private" "ECS Tasks Private SG" "SG_ECS_PRIVATE_ID")"
  SG_CONFIG_ID="$(ensure_sg "${PROJECT}-sg-config" "ConfigService SG (public subnet w/ public IP)" "SG_CONFIG_ID")"
  SG_VPCE_ID="$(ensure_sg "${PROJECT}-sg-vpce" "VPC Endpoints SG" "SG_VPCE_ID")"

  # ALB inbound 80
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

  # ALB inbound 443 (si HTTPS)
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    awsq ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
      --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true
  fi

  # Gateway 8080 desde ALB -> ECS privado
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_PRIVATE_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_GATEWAY},\"ToPort\":${PORT_GATEWAY},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ALB_ID}\"}]}]" >/dev/null 2>&1 || true

  # Config 8081 desde ECS privado -> Config en público
  awsq ec2 authorize-security-group-ingress --group-id "$SG_CONFIG_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_CONFIG},\"ToPort\":${PORT_CONFIG},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null 2>&1 || true

  # -------------------------
  # 🔒 Egress control (recomendado cuando MODE_NO_NAT=true)
  # -------------------------
  if [[ "$MODE_NO_NAT" == "true" ]]; then
    # 1) Quitar egress ALL (por defecto) para ECS privado
    awsq ec2 revoke-security-group-egress --group-id "$SG_ECS_PRIVATE_ID" \
      --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

    # 2) Permitir 443 SOLO hacia VPCE SG (ECR/Logs)
    awsq ec2 authorize-security-group-egress --group-id "$SG_ECS_PRIVATE_ID" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_VPCE_ID}\"}]}]" >/dev/null 2>&1 || true

    # 3) Permitir conexión interna a Config/Eureka/Services (dentro del VPC)
    awsq ec2 authorize-security-group-egress --group-id "$SG_ECS_PRIVATE_ID" \
      --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"10.20.0.0/16"}]}]' >/dev/null 2>&1 || true

    ok "Egress ECS privado restringido (sin Internet)."
  fi

  # ConfigService: permitir salida 80/443 (Git clone)
  # (Revocamos egress ALL primero para que sí sea “solo 80/443”)
  awsq ec2 revoke-security-group-egress --group-id "$SG_CONFIG_ID" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

  awsq ec2 authorize-security-group-egress --group-id "$SG_CONFIG_ID" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},
                      {"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

  # VPCE SG: 443 desde ECS privado (para ECR/Logs)
  awsq ec2 authorize-security-group-ingress --group-id "$SG_VPCE_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null 2>&1 || true

  # -------------------------
  # VPC Endpoints (solo si MODE_NO_NAT=true)
  # -------------------------
  if [[ "$MODE_NO_NAT" == "true" ]]; then
    log "Creando VPC Endpoints (ECR API/DKR, Logs, S3)..."

    # ECR API
    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.ecr.api" \
      --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

    # ECR DKR
    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.ecr.dkr" \
      --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

    # CloudWatch Logs
    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.logs" \
      --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

    # S3 Gateway (necesario para capas de ECR en privadas)
    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Gateway --service-name "com.amazonaws.${REGION}.s3" \
      --route-table-ids "$RTB_PRI_ID" >/dev/null 2>&1 || true

    ok "VPC Endpoints listos (o ya existían)."
  else
    ok "MODE_NO_NAT=false: no se crean endpoints obligatorios (puedes dejarlos igual si quieres)."
  fi

  step_done 2
fi

# -------------------------
# STEP 3) ECR + build/push
# -------------------------
if ! is_step_done 3; then
  log "3) ECR repos + login + build/push..."

  ensure_repo "$REPO_CONFIG"
  ensure_repo "$REPO_EUREKA"
  ensure_repo "$REPO_GATEWAY"
  ensure_repo "$REPO_PRODUCTS"
  ensure_repo "$REPO_ORDERS"
  ensure_repo "$REPO_PAY"
  ensure_repo "$REPO_USERS"

  awsq ecr get-login-password | docker login --username AWS --password-stdin "$ECR"

  log "Build imágenes..."
  docker build -t "${PROJECT}-${REPO_CONFIG}:latest"   "$DIR_CONFIG"
  docker build -t "${PROJECT}-${REPO_EUREKA}:latest"   "$DIR_EUREKA"
  docker build -t "${PROJECT}-${REPO_GATEWAY}:latest"  "$DIR_GATEWAY"
  docker build -t "${PROJECT}-${REPO_PRODUCTS}:latest" "$DIR_PRODUCTS"
  docker build -t "${PROJECT}-${REPO_ORDERS}:latest"   "$DIR_ORDERS"
  docker build -t "${PROJECT}-${REPO_PAY}:latest"      "$DIR_PAY"
  docker build -t "${PROJECT}-${REPO_USERS}:latest"    "$DIR_USERS"

  log "Push a ECR (tag=$TAG y latest)..."
  tag_push "${PROJECT}-${REPO_CONFIG}:latest"   "$REPO_CONFIG"   "$TAG"
  tag_push "${PROJECT}-${REPO_EUREKA}:latest"   "$REPO_EUREKA"   "$TAG"
  tag_push "${PROJECT}-${REPO_GATEWAY}:latest"  "$REPO_GATEWAY"  "$TAG"
  tag_push "${PROJECT}-${REPO_PRODUCTS}:latest" "$REPO_PRODUCTS" "$TAG"
  tag_push "${PROJECT}-${REPO_ORDERS}:latest"   "$REPO_ORDERS"   "$TAG"
  tag_push "${PROJECT}-${REPO_PAY}:latest"      "$REPO_PAY"      "$TAG"
  tag_push "${PROJECT}-${REPO_USERS}:latest"    "$REPO_USERS"    "$TAG"

  step_done 3
fi

# -------------------------
# STEP 4) IAM Execution Role
# -------------------------
if ! is_step_done 4; then
  log "4) IAM execution role..."
  ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"

  TRUST_POLICY='{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }'

  ROLE_ARN="$(awsq iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
  if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
    ROLE_ARN="$(awsq iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" | jq -r '.Role.Arn')"
    awsq iam attach-role-policy --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
    ok "Role creado: $ROLE_ARN"
  else
    ok "Role reusado: $ROLE_ARN"
  fi
  state_set ROLE_ARN "$ROLE_ARN"
  step_done 4
fi
ROLE_ARN="$(state_get ROLE_ARN)"

# -------------------------
# STEP 5) CloudWatch Logs
# -------------------------
if ! is_step_done 5; then
  log "5) Log groups..."
  mklog() { awsq logs create-log-group --log-group-name "$1" >/dev/null 2>&1 || true; }

  LG_CONFIG="/ecs/${PROJECT}/config"
  LG_EUREKA="/ecs/${PROJECT}/eureka"
  LG_GATEWAY="/ecs/${PROJECT}/gateway"
  LG_PRODUCTS="/ecs/${PROJECT}/products"
  LG_ORDERS="/ecs/${PROJECT}/orders"
  LG_PAY="/ecs/${PROJECT}/pay"
  LG_USERS="/ecs/${PROJECT}/users"

  mklog "$LG_CONFIG"; mklog "$LG_EUREKA"; mklog "$LG_GATEWAY"
  mklog "$LG_PRODUCTS"; mklog "$LG_ORDERS"; mklog "$LG_PAY"; mklog "$LG_USERS"

  state_set LG_CONFIG "$LG_CONFIG"
  state_set LG_EUREKA "$LG_EUREKA"
  state_set LG_GATEWAY "$LG_GATEWAY"
  state_set LG_PRODUCTS "$LG_PRODUCTS"
  state_set LG_ORDERS "$LG_ORDERS"
  state_set LG_PAY "$LG_PAY"
  state_set LG_USERS "$LG_USERS"

  step_done 5
fi

LG_CONFIG="$(state_get LG_CONFIG)"
LG_EUREKA="$(state_get LG_EUREKA)"
LG_GATEWAY="$(state_get LG_GATEWAY)"
LG_PRODUCTS="$(state_get LG_PRODUCTS)"
LG_ORDERS="$(state_get LG_ORDERS)"
LG_PAY="$(state_get LG_PAY)"
LG_USERS="$(state_get LG_USERS)"

# -------------------------
# STEP 6) ECS Cluster
# -------------------------
if ! is_step_done 6; then
  log "6) ECS Cluster..."
  awsq ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  ok "Cluster listo: $CLUSTER_NAME"
  step_done 6
fi

# -------------------------
# STEP 7) Cloud Map Namespace + Services
# -------------------------
get_namespace_id_by_name() {
  awsq servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v "None" || true
}
wait_cloudmap_operation_success() {
  local op_id="$1"
  log "Cloud Map: esperando SUCCESS: $op_id"
  for _i in {1..60}; do
    local status
    status="$(awsq servicediscovery get-operation --operation-id "$op_id" --query "Operation.Status" --output text 2>/dev/null || true)"
    [[ "$status" == "SUCCESS" ]] && return 0
    if [[ "$status" == "FAIL" || "$status" == "FAILURE" ]]; then
      echo "❌ Cloud Map operation falló: $op_id"
      awsq servicediscovery get-operation --operation-id "$op_id" --output json || true
      exit 1
    fi
    sleep 2
  done
  echo "❌ Timeout esperando SUCCESS: $op_id"
  awsq servicediscovery get-operation --operation-id "$op_id" --output json || true
  exit 1
}
get_service_id_by_name_and_namespace() {
  local svc_name="$1"; local ns_id="$2"
  local ids
  ids="$(awsq servicediscovery list-services --query "Services[?Name=='${svc_name}'].Id" --output text 2>/dev/null || true)"
  [[ -z "${ids// }" ]] && { echo ""; return 0; }
  for sid in $ids; do
    local sid_ns
    sid_ns="$(awsq servicediscovery get-service --id "$sid" --query "Service.NamespaceId" --output text 2>/dev/null || true)"
    [[ "$sid_ns" == "$ns_id" ]] && { echo "$sid"; return 0; }
  done
  echo ""
}
ensure_sd_service() {
  local svc_name="$1"; local ns_id="$2"; local state_key="$3"
  local existing_id
  existing_id="$(state_get "$state_key")"
  [[ -z "$existing_id" ]] && existing_id="$(get_service_id_by_name_and_namespace "$svc_name" "$ns_id")"
  if [[ -n "$existing_id" ]]; then
    ok "Cloud Map service reusado: $svc_name -> $existing_id"
    state_set "$state_key" "$existing_id"
    echo "$existing_id"
    return 0
  fi
  log "Cloud Map: creando service: $svc_name"
  local out rc
  set +e
  out="$(awsq servicediscovery create-service \
    --name "$svc_name" \
    --dns-config "NamespaceId=${ns_id},DnsRecords=[{Type=A,TTL=30}],RoutingPolicy=WEIGHTED" \
    --health-check-custom-config FailureThreshold=1 \
    --query "Service.Id" --output text 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "Cloud Map service creado: $svc_name -> $out"
      local clean_id
      clean_id="$(echo "$out" | tr -d '\r' | grep -oE 'srv-[a-z0-9]+' | head -n1 || true)"
      [[ -n "$clean_id" ]] || { echo "❌ No pude extraer Service.Id de: $out" >&2; exit 1; }
      state_set "$state_key" "$clean_id"
      echo "$clean_id"    return 0
  fi
  if echo "$out" | grep -q "ServiceAlreadyExists"; then
    local id2
    id2="$(get_service_id_by_name_and_namespace "$svc_name" "$ns_id")"
    [[ -n "$id2" ]] || { echo "❌ AlreadyExists pero no encontré ID para $svc_name"; exit 1; }
    ok "Cloud Map service reusado (AlreadyExists): $svc_name -> $id2"
    state_set "$state_key" "$id2"
    echo "$id2"
    return 0
  fi
  echo "❌ Error creando Cloud Map service '$svc_name':"
  echo "$out"
  exit 1
}

if ! is_step_done 7; then
  log "7) Cloud Map namespace + services..."

  VPC_ID="$(state_get VPC_ID)"
  NS_ID="$(state_get NS_ID)"; [[ -z "$NS_ID" ]] && NS_ID="$(get_namespace_id_by_name)"

  if [[ -z "$NS_ID" ]]; then
    log "Namespace no existe, creando..."
    OP_ID="$(awsq servicediscovery create-private-dns-namespace \
      --name "$NAMESPACE_NAME" --vpc "$VPC_ID" --description "${PROJECT} private namespace" \
      --query "OperationId" --output text)"
    wait_cloudmap_operation_success "$OP_ID"
    NS_ID="$(get_namespace_id_by_name)"
    [[ -n "$NS_ID" ]] || { echo "❌ No pude resolver NamespaceId"; exit 1; }
    ok "Namespace creado: $NS_ID"
  else
    ok "Namespace reusado: $NS_ID"
  fi
  state_set NS_ID "$NS_ID"

  state_set SD_CONFIG_ID  "$(ensure_sd_service "$SVC_CONFIG"  "$NS_ID" "SD_CONFIG_ID")"
  state_set SD_EUREKA_ID  "$(ensure_sd_service "$SVC_EUREKA"  "$NS_ID" "SD_EUREKA_ID")"
  state_set SD_GATEWAY_ID "$(ensure_sd_service "$SVC_GATEWAY" "$NS_ID" "SD_GATEWAY_ID")"
  state_set SD_PRODUCTS_ID "$(ensure_sd_service "$SVC_PRODUCTS" "$NS_ID" "SD_PRODUCTS_ID")"
  state_set SD_ORDERS_ID   "$(ensure_sd_service "$SVC_ORDERS"   "$NS_ID" "SD_ORDERS_ID")"
  state_set SD_PAY_ID      "$(ensure_sd_service "$SVC_PAY"      "$NS_ID" "SD_PAY_ID")"
  state_set SD_USERS_ID    "$(ensure_sd_service "$SVC_USERS"    "$NS_ID" "SD_USERS_ID")"

  step_done 7
fi

SD_CONFIG_ID="$(state_get SD_CONFIG_ID)"
SD_EUREKA_ID="$(state_get SD_EUREKA_ID)"
SD_GATEWAY_ID="$(state_get SD_GATEWAY_ID)"
SD_PRODUCTS_ID="$(state_get SD_PRODUCTS_ID)"
SD_ORDERS_ID="$(state_get SD_ORDERS_ID)"
SD_PAY_ID="$(state_get SD_PAY_ID)"
SD_USERS_ID="$(state_get SD_USERS_ID)"

# -------------------------
# STEP 9) ALB + Target Group + Listener(s)
# -------------------------
get_tg_arn() {
  awsq elbv2 describe-target-groups --names "$TG_GW_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v "None" || true
}
get_alb_arn() {
  awsq elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v "None" || true
}
get_alb_dns() {
  awsq elbv2 describe-load-balancers --load-balancer-arns "$1" --query "LoadBalancers[0].DNSName" --output text 2>/dev/null | grep -v "None" || true
}
get_listener_arn() {
  local alb_arn="$1"; local port="$2"
  awsq elbv2 describe-listeners --load-balancer-arn "$alb_arn" \
    --query "Listeners[?Port==\`${port}\`].ListenerArn | [0]" --output text 2>/dev/null | grep -v "None" || true
}

if ! is_step_done 9; then
  log "9) ALB + TargetGroup + Listener..."

  VPC_ID="$(state_get VPC_ID)"
  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  SG_ALB_ID="$(state_get SG_ALB_ID)"

  TG_GW_ARN="$(state_get TG_GW_ARN)"; [[ -z "$TG_GW_ARN" ]] && TG_GW_ARN="$(get_tg_arn)"
  if [[ -z "$TG_GW_ARN" ]]; then
    TG_GW_ARN="$(awsq elbv2 create-target-group --name "$TG_GW_NAME" \
      --protocol HTTP --port "$PORT_GATEWAY" --vpc-id "$VPC_ID" --target-type ip \
      --health-check-protocol HTTP --health-check-path "$HEALTH_PATH_GATEWAY" \
      | jq -r '.TargetGroups[0].TargetGroupArn')"
    ok "TargetGroup creado: $TG_GW_ARN"
  else
    ok "TargetGroup reusado: $TG_GW_ARN"
  fi
  state_set TG_GW_ARN "$TG_GW_ARN"

  ALB_ARN="$(state_get ALB_ARN)"; [[ -z "$ALB_ARN" ]] && ALB_ARN="$(get_alb_arn)"
  if [[ -z "$ALB_ARN" ]]; then
    ALB_ARN="$(awsq elbv2 create-load-balancer --name "$ALB_NAME" \
      --type application --scheme internet-facing \
      --subnets "$PUB1_ID" "$PUB2_ID" --security-groups "$SG_ALB_ID" \
      | jq -r '.LoadBalancers[0].LoadBalancerArn')"
    ok "ALB creado: $ALB_ARN"
  else
    ok "ALB reusado: $ALB_ARN"
  fi
  state_set ALB_ARN "$ALB_ARN"

  ALB_DNS="$(get_alb_dns "$ALB_ARN")"
  state_set ALB_DNS "$ALB_DNS"
  ok "ALB DNS: $ALB_DNS"

  # Listeners
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    # 443 forward
    L443="$(state_get LISTENER_ARN_443)"; [[ -z "$L443" ]] && L443="$(get_listener_arn "$ALB_ARN" 443)"
    if [[ -z "$L443" ]]; then
      L443="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
        --protocol HTTPS --port 443 \
        --certificates "CertificateArn=$ACM_CERT_ARN" \
        --ssl-policy ELBSecurityPolicy-2016-08 \
        --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" \
        | jq -r '.Listeners[0].ListenerArn')"
      ok "Listener 443 creado: $L443"
    else
      awsq elbv2 modify-listener --listener-arn "$L443" \
        --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" >/dev/null 2>&1 || true
      ok "Listener 443 reusado: $L443"
    fi
    state_set LISTENER_ARN_443 "$L443"

    # 80 redirect -> 443
    L80="$(state_get LISTENER_ARN_80)"; [[ -z "$L80" ]] && L80="$(get_listener_arn "$ALB_ARN" 80)"
    if [[ -z "$L80" ]]; then
      L80="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP --port 80 \
        --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' \
        | jq -r '.Listeners[0].ListenerArn')"
      ok "Listener 80 (redirect) creado: $L80"
    else
      awsq elbv2 modify-listener --listener-arn "$L80" \
        --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' >/dev/null 2>&1 || true
      ok "Listener 80 (redirect) reusado: $L80"
    fi
    state_set LISTENER_ARN_80 "$L80"
  else
    # HTTP only: 80 forward
    L80="$(state_get LISTENER_ARN_80)"; [[ -z "$L80" ]] && L80="$(get_listener_arn "$ALB_ARN" 80)"
    if [[ -z "$L80" ]]; then
      L80="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP --port 80 \
        --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" \
        | jq -r '.Listeners[0].ListenerArn')"
      ok "Listener 80 creado: $L80"
    else
      awsq elbv2 modify-listener --listener-arn "$L80" \
        --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" >/dev/null 2>&1 || true
      ok "Listener 80 reusado: $L80"
    fi
    state_set LISTENER_ARN_80 "$L80"
  fi

  step_done 9
fi

TG_GW_ARN="$(state_get TG_GW_ARN)"
ALB_DNS="$(state_get ALB_DNS)"

# -------------------------
# STEP 10) Task Definitions
# -------------------------
if ! is_step_done 10; then
  log "10) Registrando Task Definitions..."

  NETWORK_MODE="awsvpc"

  register_task_def () {
    local family="$1"
    local image="$2"
    local port="$3"
    local log_group="$4"
    local cname="$5"
    local cpu="$6"
    local mem="$7"
    local env_json="${8:-[]}"

    if ! echo "${env_json:-[]}" | jq -e 'type=="array"' >/dev/null 2>&1; then env_json="[]"; fi
    env_json="$(echo "$env_json" | jq -c .)"

    awsq ecs register-task-definition \
      --family "$family" \
      --network-mode "$NETWORK_MODE" \
      --requires-compatibilities FARGATE \
      --cpu "$cpu" --memory "$mem" \
      --execution-role-arn "$ROLE_ARN" \
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

ENV_CONFIG="$(jq -nc \
    --arg uri "$CONFIG_GIT_URI" \
    --arg br "$CONFIG_GIT_BRANCH" \
    --arg paths "$CONFIG_GIT_PATHS" \
    '[
      {"name":"SERVER_PORT","value":"8081"},
      {"name":"HOME","value":"/tmp"},  # <-- NUEVA LÍNEA
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_URI","value":$uri},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL","value":$br},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS","value":$paths},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START","value":"true"}
    ]')"

  ENV_CLIENT_BASE="$(jq -nc --arg ns "$NAMESPACE_NAME" '[
    {"name":"SPRING_CLOUD_CONFIG_URI","value":("http://configservice."+ $ns +":8081")},
    {"name":"SPRING_CLOUD_CONFIG_FAIL_FAST","value":"false"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_MAX_ATTEMPTS","value":"20"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_INITIAL_INTERVAL","value":"2000"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_MULTIPLIER","value":"1.5"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_MAX_INTERVAL","value":"10000"},
    {"name":"EUREKA_CLIENT_SERVICEURL_DEFAULTZONE","value":("http://eurekaservice."+ $ns +":8761/eureka/")}
  ]')"

  ENV_EUREKA="$(jq -nc --arg ns "$NAMESPACE_NAME" '[
    {"name":"HOME","value":"/tmp"},  # Opcional
    {"name":"CONFIG_SERVICE_URL","value":("http://configservice."+ $ns +":8081")},
    {"name":"SPRING_CLOUD_CONFIG_FAIL_FAST","value":"false"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_MAX_ATTEMPTS","value":"20"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_INITIAL_INTERVAL","value":"2000"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_MULTIPLIER","value":"1.5"},
    {"name":"SPRING_CLOUD_CONFIG_RETRY_MAX_INTERVAL","value":"10000"},
    {"name":"EUREKA_CLIENT_REGISTER_WITH_EUREKA","value":"false"},
    {"name":"EUREKA_CLIENT_FETCH_REGISTRY","value":"false"}
  ]')"
  
  MYSQL_ENV="[]"
  if [[ -n "${DB_ENDPOINT:-}" ]]; then
    # Solo si tú decides usar DB_ENDPOINT
    [[ -n "${DB_PASS:-}" ]] || { echo "❌ DB_ENDPOINT definido pero DB_PASS vacío en .env"; exit 1; }
    MYSQL_ENV="$(jq -nc \
      --arg host "$DB_ENDPOINT" \
      --arg port "$DB_PORT" \
      --arg db "$DB_NAME" \
      --arg user "$DB_USER" \
      --arg pass "$DB_PASS" \
      '[{"name":"DB_HOST","value":$host},
        {"name":"DB_PORT","value":$port},
        {"name":"DB_NAME","value":$db},
        {"name":"DB_USER","value":$user},
        {"name":"DB_PASS","value":$pass}]')"
  fi

  JWT_ENV="$(jq -nc --arg jwt "$JWT_SECRET" '[{"name":"JWT_SECRET","value":$jwt}]')"

  ENV_PRODUCTS="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_ORDERS="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_PAY="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_USERS_BASE="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_USERS="$(merge_env "$ENV_USERS_BASE" "$JWT_ENV")"

  TD_CONFIG_ARN="$(register_task_def "${PROJECT}-td-config"     "$ECR/$REPO_CONFIG:$TAG"     "$PORT_CONFIG"   "$LG_CONFIG"   "configservice"   "$CPU_SMALL" "$MEM_SMALL" "$ENV_CONFIG")"
  TD_EUREKA_ARN="$(register_task_def "${PROJECT}-td-eureka"     "$ECR/$REPO_EUREKA:$TAG"     "$PORT_EUREKA"   "$LG_EUREKA"   "eurekaservice"   "$CPU_SMALL" "$MEM_SMALL" "$ENV_EUREKA")"
  TD_GATEWAY_ARN="$(register_task_def "${PROJECT}-td-gateway"   "$ECR/$REPO_GATEWAY:$TAG"    "$PORT_GATEWAY"  "$LG_GATEWAY"  "gatewayservice"  "$CPU_MED"   "$MEM_MED"   "$ENV_CLIENT_BASE")"
  TD_PRODUCTS_ARN="$(register_task_def "${PROJECT}-td-products" "$ECR/$REPO_PRODUCTS:$TAG"   "$PORT_PRODUCTS" "$LG_PRODUCTS" "productservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_PRODUCTS")"
  TD_ORDERS_ARN="$(register_task_def "${PROJECT}-td-orders"     "$ECR/$REPO_ORDERS:$TAG"     "$PORT_ORDERS"   "$LG_ORDERS"   "orderservice"   "$CPU_SMALL" "$MEM_SMALL" "$ENV_ORDERS")"
  TD_PAY_ARN="$(register_task_def "${PROJECT}-td-pay"           "$ECR/$REPO_PAY:$TAG"        "$PORT_PAY"      "$LG_PAY"      "paymentservice" "$CPU_SMALL" "$MEM_SMALL" "$ENV_PAY")"
  TD_USERS_ARN="$(register_task_def "${PROJECT}-td-users"       "$ECR/$REPO_USERS:$TAG"      "$PORT_USERS"    "$LG_USERS"    "userservice"    "$CPU_SMALL" "$MEM_SMALL" "$ENV_USERS")"

  state_set TD_CONFIG_ARN "$TD_CONFIG_ARN"
  state_set TD_EUREKA_ARN "$TD_EUREKA_ARN"
  state_set TD_GATEWAY_ARN "$TD_GATEWAY_ARN"
  state_set TD_PRODUCTS_ARN "$TD_PRODUCTS_ARN"
  state_set TD_ORDERS_ARN "$TD_ORDERS_ARN"
  state_set TD_PAY_ARN "$TD_PAY_ARN"
  state_set TD_USERS_ARN "$TD_USERS_ARN"

  step_done 10
fi

TD_CONFIG_ARN="$(state_get TD_CONFIG_ARN)"
TD_EUREKA_ARN="$(state_get TD_EUREKA_ARN)"
TD_GATEWAY_ARN="$(state_get TD_GATEWAY_ARN)"
TD_PRODUCTS_ARN="$(state_get TD_PRODUCTS_ARN)"
TD_ORDERS_ARN="$(state_get TD_ORDERS_ARN)"
TD_PAY_ARN="$(state_get TD_PAY_ARN)"
TD_USERS_ARN="$(state_get TD_USERS_ARN)"

# -------------------------
# STEP 11) ECS Services (create/update) + Gateway attach to ALB
# -------------------------
service_exists_ecs() {
  awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$1" \
    --query "services[0].status" --output text 2>/dev/null | grep -vq "None"
}

create_or_update_service_sd() {
  local svc="$1"; local td="$2"; local net="$3"; local sd_service_id="$4"
  if service_exists_ecs "$svc"; then
    log "ECS service existe, actualizando: $svc"
    awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" \
      --task-definition "$td" --desired-count 1 --force-new-deployment >/dev/null
    return 0
  fi
  awsq ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" \
    --task-definition "$td" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$net" \
    --service-registries "registryArn=arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/${sd_service_id}" \
    --health-check-grace-period-seconds 120 >/dev/null
}

create_or_update_service_sd_lb() {
  local svc="$1"; local td="$2"; local net="$3"; local sd_service_id="$4"
  local tg="$5"; local cname="$6"; local cport="$7"

  if service_exists_ecs "$svc"; then
    log "ECS service existe, actualizando: $svc"
    awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" \
      --task-definition "$td" --desired-count 1 --force-new-deployment >/dev/null
    return 0
  fi

  awsq ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" \
    --task-definition "$td" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$net" \
    --service-registries "registryArn=arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/${sd_service_id}" \
    --load-balancers "targetGroupArn=$tg,containerName=$cname,containerPort=$cport" \
    --health-check-grace-period-seconds 180 >/dev/null
}

if ! is_step_done 11; then
  log "11) ECS Services (create/update)..."

  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  SG_CONFIG_ID="$(state_get SG_CONFIG_ID)"
  SG_ECS_PRIVATE_ID="$(state_get SG_ECS_PRIVATE_ID)"

  NETCONF_CONFIG="awsvpcConfiguration={subnets=[$PUB1_ID,$PUB2_ID],securityGroups=[$SG_CONFIG_ID],assignPublicIp=ENABLED}"
  NETCONF_PRIVATE="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_PRIVATE_ID],assignPublicIp=DISABLED}"

  create_or_update_service_sd    "$SVC_CONFIG"    "$TD_CONFIG_ARN"    "$NETCONF_CONFIG"   "$SD_CONFIG_ID"
  create_or_update_service_sd    "$SVC_EUREKA"    "$TD_EUREKA_ARN"    "$NETCONF_PRIVATE"  "$SD_EUREKA_ID"
  create_or_update_service_sd_lb "$SVC_GATEWAY"   "$TD_GATEWAY_ARN"   "$NETCONF_PRIVATE"  "$SD_GATEWAY_ID" \
    "$TG_GW_ARN" "gatewayservice" "$PORT_GATEWAY"
  create_or_update_service_sd    "$SVC_PRODUCTS"  "$TD_PRODUCTS_ARN"  "$NETCONF_PRIVATE"  "$SD_PRODUCTS_ID"
  create_or_update_service_sd    "$SVC_ORDERS"    "$TD_ORDERS_ARN"    "$NETCONF_PRIVATE"  "$SD_ORDERS_ID"
  create_or_update_service_sd    "$SVC_PAY"       "$TD_PAY_ARN"       "$NETCONF_PRIVATE"  "$SD_PAY_ID"
  create_or_update_service_sd    "$SVC_USERS"     "$TD_USERS_ARN"     "$NETCONF_PRIVATE"  "$SD_USERS_ID"

  step_done 11
fi

echo ""
ok "Deploy completado (resumible/idempotente)."
if [[ "$ENABLE_HTTPS" == "true" ]]; then
  echo "ALB URL : https://${ALB_DNS}"
else
  echo "ALB URL : http://${ALB_DNS}"
fi
echo "Health  : http://${ALB_DNS}${HEALTH_PATH_GATEWAY}"
if [[ -n "${DB_ENDPOINT:-}" ]]; then
  echo "DB host : ${DB_ENDPOINT}:${DB_PORT} (NO creada aquí)"
else
  echo "DB host : (no definido) — la DB se maneja por tu script aparte"
fi
echo "Estado  : ${STATE_FILE}"