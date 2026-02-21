#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RESUMABLE + IDEMPOTENT FULL DEPLOY (AWS) — SIN NAT, SIN SSM
# - Reusa recursos existentes por TAG/NAME
# - Guarda estado local (checkpoint) y continúa donde quedó
# - VPC (public+private) + VPC Endpoints (ECR/Logs/S3) para NO NAT
# - SOLO configservice sale a Internet (GitHub clone) usando subnet pública + Public IP
# - ECR + build/push
# - IAM ExecutionRole (solo AmazonECSTaskExecutionRolePolicy)
# - CloudWatch Logs
# - ECS Cluster + Cloud Map (Namespace + Services)
# - (Opcional) RDS MySQL (privado)
# - ALB (solo Gateway)
# - ECS Services (create-or-update + force-new-deployment)
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

# Puertos contenedor
PORT_CONFIG=8081
PORT_EUREKA=8761
PORT_GATEWAY=8080
PORT_PRODUCTS=8001
PORT_ORDERS=8002
PORT_PAY=8003
PORT_USERS=8004

# ALB health check (Gateway) — asegúrate que NO requiera auth
HEALTH_PATH_GATEWAY="/health"

# Cloud Map
NAMESPACE_NAME="${PROJECT}.local"

# VPC CIDRs
VPC_CIDR="10.20.0.0/16"
PUB1_CIDR="10.20.1.0/24"
PUB2_CIDR="10.20.2.0/24"
PRI1_CIDR="10.20.11.0/24"
PRI2_CIDR="10.20.12.0/24"

# ECS task sizing
CPU_SMALL="256"
MEM_SMALL="512"
CPU_MED="512"
MEM_MED="1024"

# RDS (opcional)
CREATE_RDS="true"         # true/false
DB_NAME="ecommerce_myshop"
DB_USER="admin"
DB_PASS="R00t2024**"      # ⚠️ HARDCODED (recomendado mover a Secrets Manager)
DB_INSTANCE_ID="${PROJECT}-mysql"
DB_INSTANCE_CLASS="db.t3.micro"
DB_ALLOCATED_STORAGE="20"
DB_STORAGE_TYPE="gp2"
DB_ENGINE="mysql"

# JWT (HARDCODED)
JWT_SECRET="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.KMUFsIDTnFmyG3nMiGM6H9FNFUROf3wh7SmqJp-QV30"

# Nombres cortos (limit 32 chars)
TG_GW_NAME="msfd-tg-gw"
ALB_NAME="msfd-alb"

# Archivo estado (checkpoint)
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# -------------------------
# HELPERS
# -------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }

log() { echo -e "👉 $*"; }
ok()  { echo -e "✅ $*"; }
warn(){ echo -e "⚠️  $*"; }

state_init() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
  fi
}

state_get() {
  local key="$1"
  jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true
}

state_set() {
  local key="$1"; local val="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

step_done() { state_set "step_${1}" "done"; }
is_step_done() { [[ "$(state_get "step_${1}")" == "done" ]]; }

on_error() {
  echo ""
  echo "❌ Error detectado. Estado guardado en: $STATE_FILE"
  echo "   Re-ejecuta este script y reusará recursos / continuará."
}
trap on_error ERR

awsq() { aws --region "$REGION" "$@"; }

tag_spec() {
  local rtype="$1"; local name="$2"
  echo "ResourceType=${rtype},Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}}]"
}

# -------------------------
# DISCOVERY HELPERS (idempotencia)
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
  local name="$1"
  awsq ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${name}" \
    --query "Subnets[0].SubnetId" --output text 2>/dev/null | grep -v "None" || true
}

find_rtb_by_name() {
  local name="$1"
  awsq ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${name}" \
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
    sg_id="$(awsq ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$sg_name" --description "$desc" \
      | jq -r '.GroupId')"
    awsq ec2 create-tags --resources "$sg_id" --tags "Key=Name,Value=$sg_name" "Key=Project,Value=$PROJECT" >/dev/null
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

# Merge de arrays JSON sin /tmp ni /dev/fd (Git Bash safe)
merge_env() {
  local a="${1:-[]}"
  local b="${2:-[]}"

  [[ -z "${a//[[:space:]]/}" ]] && a="[]"
  [[ -z "${b//[[:space:]]/}" ]] && b="[]"

  jq -cn --argjson A "$a" --argjson B "$b" '$A + $B'
}

# ---------- Cloud Map helpers ----------
get_namespace_id_by_name() {
  awsq servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v "None" || true
}

wait_cloudmap_operation_success() {
  local op_id="$1"
  log "Cloud Map: esperando Operation SUCCESS: $op_id"
  for _i in {1..60}; do
    local status
    status="$(awsq servicediscovery get-operation --operation-id "$op_id" \
      --query "Operation.Status" --output text 2>/dev/null || true)"
    if [[ "$status" == "SUCCESS" ]]; then return 0; fi
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
  if [[ -z "${ids// }" ]]; then echo ""; return 0; fi
  for sid in $ids; do
    local sid_ns
    sid_ns="$(awsq servicediscovery get-service --id "$sid" --query "Service.NamespaceId" --output text 2>/dev/null || true)"
    if [[ "$sid_ns" == "$ns_id" ]]; then echo "$sid"; return 0; fi
  done
  echo ""
}

ensure_sd_service() {
  local svc_name="$1"; local ns_id="$2"; local state_key="$3"
  local existing_id
  existing_id="$(state_get "$state_key")"
  if [[ -z "$existing_id" ]]; then
    existing_id="$(get_service_id_by_name_and_namespace "$svc_name" "$ns_id")"
  fi
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
    state_set "$state_key" "$out"
    echo "$out"
    return 0
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

# ---------- ALB helpers ----------
get_tg_arn() {
  awsq elbv2 describe-target-groups \
    --names "$TG_GW_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v "None" || true
}
get_alb_arn() {
  awsq elbv2 describe-load-balancers \
    --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v "None" || true
}
get_alb_dns() {
  local alb_arn="$1"
  awsq elbv2 describe-load-balancers \
    --load-balancer-arns "$alb_arn" --query "LoadBalancers[0].DNSName" --output text 2>/dev/null | grep -v "None" || true
}
get_listener_arn_80() {
  local alb_arn="$1"
  awsq elbv2 describe-listeners \
    --load-balancer-arn "$alb_arn" \
    --query "Listeners[?Port==\`80\`].ListenerArn | [0]" --output text 2>/dev/null | grep -v "None" || true
}

# ---------- ECS helpers ----------
service_exists_ecs() {
  local svc="$1"
  awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" \
    --query "services[0].status" --output text 2>/dev/null | grep -vq "None"
}

# Devuelve el registryArn real (Cloud Map) desde un serviceId (srv-xxxx)
sd_registry_arn_from_id() {
  local sd_service_id="$1"
  # serviceId viene como "srv-xxxx"
  echo "arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/${sd_service_id}"
}

create_or_update_service_sd() {
  local svc="$1"; local td="$2"; local net="$3"; local sd_service_id="$4"
  local registry_arn
  registry_arn="$(sd_registry_arn_from_id "$sd_service_id")"

  if service_exists_ecs "$svc"; then
    log "ECS service existe, actualizando (td + net + registry + force-new-deployment): $svc"
    # 🔥 Importante: actualizar NETWORK + REGISTRY también (no solo task-definition)
    awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" \
      --task-definition "$td" \
      --network-configuration "$net" \
      --service-registries "registryArn=$registry_arn" \
      --desired-count 1 \
      --force-new-deployment >/dev/null
    return 0
  fi

  awsq ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" \
    --task-definition "$td" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$net" \
    --service-registries "registryArn=$registry_arn" \
    --health-check-grace-period-seconds 120 \
    >/dev/null
}

create_or_update_service_sd_lb() {
  local svc="$1"; local td="$2"; local net="$3"; local sd_service_id="$4"
  local tg="$5"; local cname="$6"; local cport="$7"
  local registry_arn
  registry_arn="$(sd_registry_arn_from_id "$sd_service_id")"

  if service_exists_ecs "$svc"; then
    log "ECS service existe, actualizando (td + net + registry + force-new-deployment): $svc"
    # 🔥 Importante: actualizar NETWORK + REGISTRY también
    # Nota: el LB normalmente ya queda asociado, no hace falta re-declararlo en update-service.
    awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" \
      --task-definition "$td" \
      --network-configuration "$net" \
      --service-registries "registryArn=$registry_arn" \
      --desired-count 1 \
      --force-new-deployment >/dev/null
    return 0
  fi

  awsq ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" \
    --task-definition "$td" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$net" \
    --service-registries "registryArn=$registry_arn" \
    --load-balancers "targetGroupArn=$tg,containerName=$cname,containerPort=$cport" \
    --health-check-grace-period-seconds 180 \
    >/dev/null
}
# -------------------------
# PRECHECKS
# -------------------------
need aws
need docker
need jq

state_init

log "0) Identidad AWS..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# -------------------------
# TAG estable para modo resumible
# -------------------------
STATE_TAG="$(state_get TAG)"
if [[ -n "${STATE_TAG:-}" && "${STATE_TAG}" != "null" ]]; then
  TAG="$STATE_TAG"
else
  TAG="$(date +%Y%m%d-%H%M%S)"
  state_set TAG "$TAG"
fi

ok "Account: $ACCOUNT_ID"
ok "Region : $REGION"
ok "ECR    : $ECR"
ok "Tag    : $TAG"

# -------------------------
# STEP 1) VPC + Subnets + IGW + Routes
# -------------------------
if ! is_step_done 1; then
  log "1) VPC y red (idempotente)..."

  VPC_ID="$(state_get VPC_ID)"
  [[ -z "$VPC_ID" ]] && VPC_ID="$(find_vpc)"

  AZ1="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
  AZ2="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"

  if [[ -z "$VPC_ID" ]]; then
    VPC_ID="$(awsq ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(tag_spec vpc "${PROJECT}-vpc")" | jq -r '.Vpc.VpcId')"
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" >/dev/null
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" >/dev/null
    ok "VPC creada: $VPC_ID"
  else
    ok "VPC reusada: $VPC_ID"
  fi
  state_set VPC_ID "$VPC_ID"

  IGW_ID="$(state_get IGW_ID)"
  [[ -z "$IGW_ID" ]] && IGW_ID="$(find_igw)"
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID="$(awsq ec2 create-internet-gateway \
      --tag-specifications "$(tag_spec internet-gateway "${PROJECT}-igw")" | jq -r '.InternetGateway.InternetGatewayId')"
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
    RTB_PUB_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "${PROJECT}-public-rtb")" | jq -r '.RouteTable.RouteTableId')"
    ok "RTB pública creada: $RTB_PUB_ID"
  else ok "RTB pública reusada: $RTB_PUB_ID"; fi
  state_set RTB_PUB_ID "$RTB_PUB_ID"

  awsq ec2 create-route --route-table-id "$RTB_PUB_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB1_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB2_ID" >/dev/null 2>&1 || true

  RTB_PRI_ID="$(state_get RTB_PRI_ID)"; [[ -z "$RTB_PRI_ID" ]] && RTB_PRI_ID="$(find_rtb_by_name "${PROJECT}-private-rtb")"
  if [[ -z "$RTB_PRI_ID" ]]; then
    RTB_PRI_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "${PROJECT}-private-rtb")" | jq -r '.RouteTable.RouteTableId')"
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
# NAT Gateway (para subnets privadas)
# -------------------------
if ! is_step_done "NAT"; then
  log "NAT) Creando NAT Gateway para salida a Internet desde subnets privadas..."

  VPC_ID="$(state_get VPC_ID)"
  PUB1_ID="$(state_get PUB1_ID)"
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"

  # 1) Elastic IP para NAT
  NAT_EIP_ALLOC_ID="$(state_get NAT_EIP_ALLOC_ID)"
  if [[ -z "${NAT_EIP_ALLOC_ID:-}" || "$NAT_EIP_ALLOC_ID" == "None" ]]; then
    NAT_EIP_ALLOC_ID="$(awsq ec2 allocate-address --domain vpc --query AllocationId --output text)"
    state_set NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"
    ok "EIP asignada: $NAT_EIP_ALLOC_ID"
  else
    ok "EIP reusada: $NAT_EIP_ALLOC_ID"
  fi

  # 2) NAT Gateway en subnet pública (recomendado en PUB1)
  NAT_GW_ID="$(state_get NAT_GW_ID)"
  if [[ -z "${NAT_GW_ID:-}" || "$NAT_GW_ID" == "None" ]]; then
    NAT_GW_ID="$(awsq ec2 create-nat-gateway \
      --subnet-id "$PUB1_ID" \
      --allocation-id "$NAT_EIP_ALLOC_ID" \
      --query "NatGateway.NatGatewayId" --output text)"
    state_set NAT_GW_ID "$NAT_GW_ID"
    ok "NAT Gateway creado: $NAT_GW_ID"
  else
    ok "NAT Gateway reusado: $NAT_GW_ID"
  fi
  # 3) Esperar NAT AVAILABLE
  log "Esperando NAT Gateway available..."
  awsq ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
  ok "NAT Gateway listo: $NAT_GW_ID"

  # 4) Ruta default 0.0.0.0/0 en RT privada hacia NAT
  # (si ya existe, ignora)
  awsq ec2 create-route \
    --route-table-id "$RTB_PRI_ID" \
    --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true

  ok "Ruta privada -> NAT configurada en: $RTB_PRI_ID"
  step_done "NAT"
fi
# -------------------------
# STEP 2) Security Groups + VPC Endpoints 
# -------------------------
if ! is_step_done 2; then
  log "2) SG + VPC Endpoints (sin NAT)..."

  VPC_ID="$(state_get VPC_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"

  SG_ALB_ID="$(ensure_sg "${PROJECT}-sg-alb" "ALB SG" "SG_ALB_ID")"
  SG_ECS_PRIVATE_ID="$(ensure_sg "${PROJECT}-sg-ecs-private" "ECS Tasks Private SG" "SG_ECS_PRIVATE_ID")"
  SG_CONFIG_ID="$(ensure_sg "${PROJECT}-sg-config-egress" "ConfigService SG (public subnet w/ public IP)" "SG_CONFIG_ID")"
  SG_RDS_ID="$(ensure_sg "${PROJECT}-sg-rds" "RDS MySQL SG" "SG_RDS_ID")"
  SG_VPCE_ID="$(ensure_sg "${PROJECT}-sg-vpce" "VPC Endpoints SG" "SG_VPCE_ID")"

  # ALB inbound 80
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

  # Gateway 8080 desde ALB -> ECS privado
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_PRIVATE_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_GATEWAY},\"ToPort\":${PORT_GATEWAY},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ALB_ID}\"}]}]" >/dev/null 2>&1 || true

  # ✅ Permitir TODO el tráfico interno entre tasks privadas (self SG)
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_PRIVATE_ID" \
    --ip-permissions "[{\"IpProtocol\":\"-1\",\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" \
    >/dev/null 2>&1 || true

  # Config 8081 desde ECS privado -> Config en público
  awsq ec2 authorize-security-group-ingress --group-id "$SG_CONFIG_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_CONFIG},\"ToPort\":${PORT_CONFIG},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null 2>&1 || true

  # ✅ SOLO ConfigService sale a Internet (GitHub clone) — 80/443
  awsq ec2 authorize-security-group-egress --group-id "$SG_CONFIG_ID" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},
                      {"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

  # ✅ RDS 3306 desde ECS privado
  awsq ec2 authorize-security-group-ingress --group-id "$SG_RDS_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null 2>&1 || true

  # ✅ VPCE SG: 443 desde ECS privado (para ECR/Logs)
  awsq ec2 authorize-security-group-ingress --group-id "$SG_VPCE_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" >/dev/null 2>&1 || true

  # VPC Endpoints (si existe, ignora)
  awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.ecr.api" \
    --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

  awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.ecr.dkr" \
    --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

  awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface --service-name "com.amazonaws.${REGION}.logs" \
    --subnet-ids "$PRI1_ID" "$PRI2_ID" --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

  awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Gateway --service-name "com.amazonaws.${REGION}.s3" \
    --route-table-ids "$RTB_PRI_ID" >/dev/null 2>&1 || true

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

  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

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

  if ! awsq ecr describe-images --repository-name "$REPO_CONFIG" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
    echo "❌ Push terminó, pero el tag '$TAG' NO aparece en ECR ($REPO_CONFIG)."
    exit 1
  fi

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

  ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
  if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
    ROLE_ARN="$(aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" | jq -r '.Role.Arn')"
    aws iam attach-role-policy --role-name "$ROLE_NAME" \
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
if ! is_step_done 7; then
  log "7) Cloud Map namespace + services..."

  VPC_ID="$(state_get VPC_ID)"

  NS_ID="$(state_get NS_ID)"
  [[ -z "$NS_ID" ]] && NS_ID="$(get_namespace_id_by_name)"

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

  SD_CONFIG_ID="$(ensure_sd_service "$SVC_CONFIG" "$NS_ID" "SD_CONFIG_ID")"
  SD_EUREKA_ID="$(ensure_sd_service "$SVC_EUREKA" "$NS_ID" "SD_EUREKA_ID")"
  SD_GATEWAY_ID="$(ensure_sd_service "$SVC_GATEWAY" "$NS_ID" "SD_GATEWAY_ID")"
  SD_PRODUCTS_ID="$(ensure_sd_service "$SVC_PRODUCTS" "$NS_ID" "SD_PRODUCTS_ID")"
  SD_ORDERS_ID="$(ensure_sd_service "$SVC_ORDERS" "$NS_ID" "SD_ORDERS_ID")"
  SD_PAY_ID="$(ensure_sd_service "$SVC_PAY" "$NS_ID" "SD_PAY_ID")"
  SD_USERS_ID="$(ensure_sd_service "$SVC_USERS" "$NS_ID" "SD_USERS_ID")"

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
# STEP 8) (Opcional) RDS MySQL
# -------------------------
DB_ENDPOINT="$(state_get DB_ENDPOINT)"
DB_ENDPOINT="${DB_ENDPOINT:-}"

if [[ "${CREATE_RDS}" == "true" ]] && ! is_step_done 8; then
  log "8) RDS MySQL (privado)..."

  DB_ENGINE_VERSION="$(awsq rds describe-db-engine-versions \
    --engine "$DB_ENGINE" --default-only \
    --query "DBEngineVersions[0].EngineVersion" --output text)"

  if [[ -z "${DB_ENGINE_VERSION:-}" || "${DB_ENGINE_VERSION}" == "None" ]]; then
    echo "❌ No pude resolver engine version default"
    exit 1
  fi
  ok "RDS EngineVersion(default): $DB_ENGINE_VERSION"

  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  SG_RDS_ID="$(state_get SG_RDS_ID)"

  awsq rds create-db-subnet-group \
    --db-subnet-group-name "${PROJECT}-db-subnets" \
    --db-subnet-group-description "Private subnets for RDS" \
    --subnet-ids "$PRI1_ID" "$PRI2_ID" >/dev/null 2>&1 || true

  if ! awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
    awsq rds create-db-instance \
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
    ok "RDS creado: $DB_INSTANCE_ID"
  else
    ok "RDS reusado: $DB_INSTANCE_ID"
  fi

  log "Esperando RDS disponible..."
  awsq rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"

  DB_ENDPOINT="$(awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].Endpoint.Address" --output text)"
  ok "RDS Endpoint: $DB_ENDPOINT"

  state_set DB_ENDPOINT "$DB_ENDPOINT"
  step_done 8
fi

DB_ENDPOINT="$(state_get DB_ENDPOINT)"
DB_ENDPOINT="${DB_ENDPOINT:-}"

# -------------------------
# STEP 9) ALB + Target Group + Listener (solo Gateway)
# ✅ FIX parser: evitamos "if ! ...; then" por issues en algunos entornos
# -------------------------
if is_step_done 9; then
  : # ya hecho
else
  log "9) ALB + TargetGroup..."

  VPC_ID="$(state_get VPC_ID)"
  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  SG_ALB_ID="$(state_get SG_ALB_ID)"

  TG_GW_ARN="$(state_get TG_GW_ARN)"
  [[ -z "$TG_GW_ARN" ]] && TG_GW_ARN="$(get_tg_arn)"
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

  ALB_ARN="$(state_get ALB_ARN)"
  [[ -z "$ALB_ARN" ]] && ALB_ARN="$(get_alb_arn)"
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
  LISTENER_ARN="$(state_get LISTENER_ARN)"
  [[ -z "$LISTENER_ARN" ]] && LISTENER_ARN="$(get_listener_arn_80 "$ALB_ARN")"
  if [[ -z "$LISTENER_ARN" ]]; then
    LISTENER_ARN="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
      --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" \
      | jq -r '.Listeners[0].ListenerArn')"
    ok "Listener creado: $LISTENER_ARN"
  else
    awsq elbv2 modify-listener --listener-arn "$LISTENER_ARN" \
      --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" >/dev/null 2>&1 || true
    ok "Listener reusado: $LISTENER_ARN"
  fi
  state_set LISTENER_ARN "$LISTENER_ARN"

  step_done 9
fi

TG_GW_ARN="$(state_get TG_GW_ARN)"
ALB_DNS="$(state_get ALB_DNS)"

# -------------------------
# GUARD: validar TAG existe en ECR antes del STEP 10
# -------------------------
if ! awsq ecr describe-images --repository-name "$REPO_CONFIG" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  echo "❌ El tag '$TAG' NO existe en ECR para repo '$REPO_CONFIG'."
  echo "   Solución rápida:"
  echo "   - borra step_3 y TAG en $STATE_FILE"
  echo "   - re-ejecuta para rebuild/push y continuar"
  exit 1
fi

# -------------------------
# STEP 10) Task Definitions (env hardcoded) — Git Bash safe
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

    if ! echo "${env_json:-[]}" | jq -e 'type=="array"' >/dev/null 2>&1; then
      env_json="[]"
    fi
    env_json="$(echo "$env_json" | jq -c .)"

    awsq ecs register-task-definition \
      --family "$family" \
      --network-mode "$NETWORK_MODE" \
      --requires-compatibilities FARGATE \
      --cpu "$cpu" \
      --memory "$mem" \
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
      ]" \
      | jq -r '.taskDefinition.taskDefinitionArn'
  }

  ENV_CONFIG='[
    {"name":"SERVER_PORT","value":"8081"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_URI","value":"https://github.com/Raulcudris/microservices-fargate-demo.git"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL","value":"main"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS","value":"config-data"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START","value":"true"}
  ]'

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
    {"name":"SERVER_PORT","value":"8761"},

    {"name":"CONFIG_SERVICE_URL","value":("http://configservice."+ $ns +":8081")},
    {"name":"SPRING_CLOUD_CONFIG_URI","value":("http://configservice."+ $ns +":8081")},
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
    MYSQL_ENV="$(jq -nc \
      --arg host "$DB_ENDPOINT" \
      --arg db "$DB_NAME" \
      --arg user "$DB_USER" \
      --arg pass "$DB_PASS" \
      '[{"name":"DB_HOST","value":$host},
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
  TD_EUREKA_ARN="$(register_task_def "${PROJECT}-td-eureka"     "$ECR/$REPO_EUREKA:$TAG"     "$PORT_EUREKA"   "$LG_EUREKA"   "eurekaservice"   "$CPU_SMALL"   "$MEM_SMALL"  "$ENV_EUREKA")"
  TD_GATEWAY_ARN="$(register_task_def "${PROJECT}-td-gateway"   "$ECR/$REPO_GATEWAY:$TAG"    "$PORT_GATEWAY"  "$LG_GATEWAY"  "gatewayservice"  "$CPU_MED"   "$MEM_MED"   "$ENV_CLIENT_BASE")"
  TD_PRODUCTS_ARN="$(register_task_def "${PROJECT}-td-products" "$ECR/$REPO_PRODUCTS:$TAG"   "$PORT_PRODUCTS" "$LG_PRODUCTS" "productservice"   "$CPU_SMALL" "$MEM_SMALL" "$ENV_PRODUCTS")"
  TD_ORDERS_ARN="$(register_task_def "${PROJECT}-td-orders"     "$ECR/$REPO_ORDERS:$TAG"     "$PORT_ORDERS"   "$LG_ORDERS"   "orderservice"    "$CPU_SMALL" "$MEM_SMALL" "$ENV_ORDERS")"
  TD_PAY_ARN="$(register_task_def "${PROJECT}-td-pay"           "$ECR/$REPO_PAY:$TAG"        "$PORT_PAY"      "$LG_PAY"      "paymentservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_PAY")"
  TD_USERS_ARN="$(register_task_def "${PROJECT}-td-users"       "$ECR/$REPO_USERS:$TAG"      "$PORT_USERS"    "$LG_USERS"    "userservice"     "$CPU_SMALL" "$MEM_SMALL" "$ENV_USERS")"

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
# STEP 11) ECS Services + ALB attach (Gateway)
# -------------------------
if ! is_step_done 11; then
  log "11) ECS Services (create/update)..."

  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  SG_CONFIG_ID="$(state_get SG_CONFIG_ID)"
  SG_ECS_PRIVATE_ID="$(state_get SG_ECS_PRIVATE_ID)"

  # ✅ ConfigService en subnets PUBLICAS + Public IP (para poder clonar GitHub sin NAT)
  NETCONF_CONFIG="awsvpcConfiguration={subnets=[$PUB1_ID,$PUB2_ID],securityGroups=[$SG_CONFIG_ID],assignPublicIp=ENABLED}"

  # ✅ Resto en subnets PRIVADAS (sin Public IP)
  NETCONF_PRIVATE="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_PRIVATE_ID],assignPublicIp=DISABLED}"

  # ✅ Orden recomendado para evitar timeouts al arrancar (config -> eureka -> gateway -> demás)
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
echo "ALB DNS: http://${ALB_DNS}"
echo "Health:  http://${ALB_DNS}${HEALTH_PATH_GATEWAY}"
if [[ -n "${DB_ENDPOINT:-}" ]]; then
  echo "RDS endpoint (privado): ${DB_ENDPOINT}"
fi
echo "Estado: ${STATE_FILE}"