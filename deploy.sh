#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy.sh - PRO Stable Deploy (ECS Fargate + ALB + Cloud Map)
# - Resumible/Idempotente (state file)
# - NAT ON/OFF (MODE_NO_NAT)
# - ECR build/push
# - ECS Cluster + CloudMap
# - ALB -> Gateway
# - TaskDefinitions + Services create/update
# ============================================================

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

ENV_FILE="${ENV_FILE:-.env}"
[[ -f "$ENV_FILE" ]] || { echo "❌ No encuentro $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need docker; need jq; need curl

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"
MODE_NO_NAT="${MODE_NO_NAT:-false}"

CONFIG_GIT_URI="${CONFIG_GIT_URI:-}"
CONFIG_GIT_BRANCH="${CONFIG_GIT_BRANCH:-deploy}"
CONFIG_GIT_PATHS="${CONFIG_GIT_PATHS:-config-data}"

DB_ENDPOINT="${DB_ENDPOINT:-}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"

JWT_SECRET="${JWT_SECRET:-}"
HEALTH_PATH_GATEWAY="${HEALTH_PATH_GATEWAY:-/actuator/health}"

ENABLE_HTTPS="${ENABLE_HTTPS:-false}"
ACM_CERT_ARN="${ACM_CERT_ARN:-}"

[[ -n "$CONFIG_GIT_URI" ]] || { echo "❌ CONFIG_GIT_URI vacío"; exit 1; }
[[ -n "$JWT_SECRET" ]] || { echo "❌ JWT_SECRET vacío"; exit 1; }
if [[ "$ENABLE_HTTPS" == "true" ]]; then
  [[ -n "$ACM_CERT_ARN" ]] || { echo "❌ ENABLE_HTTPS=true pero ACM_CERT_ARN vacío"; exit 1; }
fi

# Si defines DB_ENDPOINT, exige resto
if [[ -n "$DB_ENDPOINT" ]]; then
  [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASS" ]] || { echo "❌ DB_ENDPOINT definido pero DB_NAME/DB_USER/DB_PASS incompletos"; exit 1; }
fi

awsq(){ aws --region "$REGION" "$@"; }

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ======= Ports =======
PORT_CONFIG=8081
PORT_EUREKA=8761
PORT_GATEWAY=8080
PORT_PRODUCTS=8001
PORT_ORDERS=8002
PORT_PAY=8003
PORT_USERS=8004

# ======= CIDRs =======
VPC_CIDR="10.20.0.0/16"
PUB1_CIDR="10.20.1.0/24"
PUB2_CIDR="10.20.2.0/24"
PRI1_CIDR="10.20.11.0/24"
PRI2_CIDR="10.20.12.0/24"

# ======= Repo dirs =======
DIR_CONFIG="./configservice"
DIR_EUREKA="./eurekaservice"
DIR_GATEWAY="./gatewayservice"
DIR_PRODUCTS="./productservice"
DIR_ORDERS="./orderservice"
DIR_PAY="./paymentservice"
DIR_USERS="./userservice"

# ======= ECR repos =======
REPO_CONFIG="configservice"
REPO_EUREKA="eurekaservice"
REPO_GATEWAY="gatewayservice"
REPO_PRODUCTS="productservice"
REPO_ORDERS="orderservice"
REPO_PAY="paymentservice"
REPO_USERS="userservice"

# ======= ECS names =======
CLUSTER_NAME="${PROJECT}-cluster"
NAMESPACE_NAME="${PROJECT}.local"
SVC_CONFIG="configservice"
SVC_EUREKA="eurekaservice"
SVC_GATEWAY="gatewayservice"
SVC_PRODUCTS="productservice"
SVC_ORDERS="orderservice"
SVC_PAY="paymentservice"
SVC_USERS="userservice"

# ======= ALB =======
TG_GW_NAME="msf-tg-gw"
ALB_NAME="msf-alb"

# ======= State =======
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"
state_init(){ [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"; }
state_get(){ jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true; }
state_set(){ local k="$1"; local v="$2"; local tmp; tmp="$(mktemp)"; jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$STATE_FILE" > "$tmp"; mv "$tmp" "$STATE_FILE"; }
step_done(){ state_set "step_${1}" "done"; }
is_step_done(){ [[ "$(state_get "step_${1}")" == "done" ]]; }

sanitize_token(){ echo "${1:-}" | awk '{print $1}'; }
die(){ echo "❌ $*" >&2; exit 1; }
log(){ echo "👉 $*" >&2; }
ok(){ echo "✅ $*" >&2; }

on_error(){
  echo ""
  echo "❌ Error. Estado guardado en: $STATE_FILE"
  echo "   Re-ejecuta ./deploy.sh para continuar."
}
trap on_error ERR

tag_spec(){
  local rtype="$1"; local name="$2"
  echo "ResourceType=${rtype},Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Env,Value=${ENV_NAME}}]"
}

ensure_repo(){
  local repo="$1"
  awsq ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || awsq ecr create-repository --repository-name "$repo" >/dev/null
}

tag_push(){
  local local_img="$1"; local repo="$2"; local tag="$3"
  docker tag "$local_img" "$ECR/$repo:$tag"
  docker tag "$local_img" "$ECR/$repo:latest"
  docker push "$ECR/$repo:$tag"
  docker push "$ECR/$repo:latest"
}

service_exists_ecs(){
  awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$1" --query "services[0].status" --output text 2>/dev/null | grep -vq "None"
}

state_init

# Stable tag
TAG="$(state_get TAG)"
if [[ -z "${TAG:-}" || "$TAG" == "null" ]]; then
  TAG="$(date +%Y%m%d-%H%M%S)"
  state_set TAG "$TAG"
fi

ok "Account: $ACCOUNT_ID"
ok "Region : $REGION"
ok "Project: $PROJECT"
ok "ECR    : $ECR"
ok "Tag    : $TAG"
ok "MODE_NO_NAT: $MODE_NO_NAT"

# -------------------------
# STEP 1) VPC/Subnets/Routes
# -------------------------
if ! is_step_done 1; then
  log "1) VPC/Subnets/Routes..."

  VPC_ID="$(state_get VPC_ID)"
  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    VPC_ID="$(awsq ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(tag_spec vpc "${PROJECT}-vpc")" | jq -r '.Vpc.VpcId')"
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" >/dev/null
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" >/dev/null
    ok "VPC creada: $VPC_ID"
  else
    ok "VPC reusada: $VPC_ID"
  fi
  state_set VPC_ID "$VPC_ID"

  IGW_ID="$(state_get IGW_ID)"
  if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
    IGW_ID="$(awsq ec2 create-internet-gateway --tag-specifications "$(tag_spec internet-gateway "${PROJECT}-igw")" | jq -r '.InternetGateway.InternetGatewayId')"
    awsq ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" >/dev/null
    ok "IGW creado+adjuntado: $IGW_ID"
  else ok "IGW reusado: $IGW_ID"; fi
  state_set IGW_ID "$IGW_ID"

  AZ1="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
  AZ2="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"

  # Subnets
  PUB1_ID="$(state_get PUB1_ID)"
  if [[ -z "$PUB1_ID" || "$PUB1_ID" == "None" ]]; then
    PUB1_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB1_CIDR" --availability-zone "$AZ1" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-public-a")" | jq -r '.Subnet.SubnetId')"
    awsq ec2 modify-subnet-attribute --subnet-id "$PUB1_ID" --map-public-ip-on-launch >/dev/null
    ok "Subnet pública A: $PUB1_ID"
  fi

  PUB2_ID="$(state_get PUB2_ID)"
  if [[ -z "$PUB2_ID" || "$PUB2_ID" == "None" ]]; then
    PUB2_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB2_CIDR" --availability-zone "$AZ2" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-public-b")" | jq -r '.Subnet.SubnetId')"
    awsq ec2 modify-subnet-attribute --subnet-id "$PUB2_ID" --map-public-ip-on-launch >/dev/null
    ok "Subnet pública B: $PUB2_ID"
  fi

  PRI1_ID="$(state_get PRI1_ID)"
  if [[ -z "$PRI1_ID" || "$PRI1_ID" == "None" ]]; then
    PRI1_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRI1_CIDR" --availability-zone "$AZ1" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-private-a")" | jq -r '.Subnet.SubnetId')"
    ok "Subnet privada A: $PRI1_ID"
  fi

  PRI2_ID="$(state_get PRI2_ID)"
  if [[ -z "$PRI2_ID" || "$PRI2_ID" == "None" ]]; then
    PRI2_ID="$(awsq ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRI2_CIDR" --availability-zone "$AZ2" \
      --tag-specifications "$(tag_spec subnet "${PROJECT}-private-b")" | jq -r '.Subnet.SubnetId')"
    ok "Subnet privada B: $PRI2_ID"
  fi

  state_set PUB1_ID "$PUB1_ID"; state_set PUB2_ID "$PUB2_ID"
  state_set PRI1_ID "$PRI1_ID"; state_set PRI2_ID "$PRI2_ID"

  # Route tables
  RTB_PUB_ID="$(state_get RTB_PUB_ID)"
  if [[ -z "$RTB_PUB_ID" || "$RTB_PUB_ID" == "None" ]]; then
    RTB_PUB_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "${PROJECT}-public-rtb")" | jq -r '.RouteTable.RouteTableId')"
    ok "RTB pública: $RTB_PUB_ID"
  fi
  state_set RTB_PUB_ID "$RTB_PUB_ID"

  awsq ec2 create-route --route-table-id "$RTB_PUB_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB1_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB2_ID" >/dev/null 2>&1 || true

  RTB_PRI_ID="$(state_get RTB_PRI_ID)"
  if [[ -z "$RTB_PRI_ID" || "$RTB_PRI_ID" == "None" ]]; then
    RTB_PRI_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "${PROJECT}-private-rtb")" | jq -r '.RouteTable.RouteTableId')"
    ok "RTB privada: $RTB_PRI_ID"
  fi
  state_set RTB_PRI_ID "$RTB_PRI_ID"

  awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI1_ID" >/dev/null 2>&1 || true
  awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI2_ID" >/dev/null 2>&1 || true

  step_done 1
fi

# -------------------------
# NAT (si MODE_NO_NAT=false)
# -------------------------
if [[ "$MODE_NO_NAT" == "false" ]]; then
  if ! is_step_done NAT; then
    log "NAT) Creando NAT Gateway..."
    VPC_ID="$(state_get VPC_ID)"
    PUB1_ID="$(state_get PUB1_ID)"
    RTB_PRI_ID="$(state_get RTB_PRI_ID)"

    NAT_EIP_ALLOC_ID="$(state_get NAT_EIP_ALLOC_ID)"
    if [[ -z "$NAT_EIP_ALLOC_ID" || "$NAT_EIP_ALLOC_ID" == "None" ]]; then
      NAT_EIP_ALLOC_ID="$(awsq ec2 allocate-address --domain vpc --query AllocationId --output text)"
      state_set NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"
      ok "EIP: $NAT_EIP_ALLOC_ID"
    fi

    NAT_GW_ID="$(state_get NAT_GW_ID)"
    if [[ -z "$NAT_GW_ID" || "$NAT_GW_ID" == "None" ]]; then
      NAT_GW_ID="$(awsq ec2 create-nat-gateway --subnet-id "$PUB1_ID" --allocation-id "$NAT_EIP_ALLOC_ID" --query "NatGateway.NatGatewayId" --output text)"
      state_set NAT_GW_ID "$NAT_GW_ID"
      ok "NAT GW: $NAT_GW_ID"
    fi

    awsq ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
    awsq ec2 create-route --route-table-id "$RTB_PRI_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
    ok "Ruta privada -> NAT OK"
    step_done NAT
  fi
else
  ok "NAT deshabilitado (MODE_NO_NAT=true)."
fi

# -------------------------
# STEP 2) Security Groups (+ Endpoints si NO NAT)
# -------------------------
if ! is_step_done 2; then
  log "2) Security Groups..."

  VPC_ID="$(state_get VPC_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"

  ensure_sg(){
    local sg_name="$1"; local desc="$2"; local key="$3"
    local sg_id
    sg_id="$(state_get "$key")"
    if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
      sg_id="$(awsq ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg_name" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true)"
    fi
    if [[ -z "$sg_id" ]]; then
      sg_id="$(awsq ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$sg_name" --description "$desc" --query GroupId --output text)"
      awsq ec2 create-tags --resources "$sg_id" --tags "Key=Name,Value=$sg_name" "Key=Project,Value=$PROJECT" "Key=Env,Value=$ENV_NAME" >/dev/null
    fi
    state_set "$key" "$sg_id"
    echo "$sg_id"
  }

  SG_ALB_ID="$(ensure_sg "${PROJECT}-sg-alb" "ALB SG" "SG_ALB_ID")"
  SG_ECS_ID="$(ensure_sg "${PROJECT}-sg-ecs" "ECS Tasks SG" "SG_ECS_ID")"
  SG_VPCE_ID="$(ensure_sg "${PROJECT}-sg-vpce" "VPC Endpoints SG" "SG_VPCE_ID")"

  # ALB inbound 80
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

  # Gateway 8080 from ALB -> ECS
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${PORT_GATEWAY},\"ToPort\":${PORT_GATEWAY},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ALB_ID}\"}]}]" >/dev/null 2>&1 || true

  # Allow internal VPC comm
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_ID" \
    --ip-permissions "[{\"IpProtocol\":\"-1\",\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_ID}\"}]}]" >/dev/null 2>&1 || true

  # Endpoints only if no NAT
  if [[ "$MODE_NO_NAT" == "true" ]]; then
    log "MODE_NO_NAT=true: creando VPC Endpoints (ECR API/DKR, Logs, S3)..."
    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.${REGION}.ecr.api" --subnet-ids "$PRI1_ID" "$PRI2_ID" \
      --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.${REGION}.ecr.dkr" --subnet-ids "$PRI1_ID" "$PRI2_ID" \
      --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.${REGION}.logs" --subnet-ids "$PRI1_ID" "$PRI2_ID" \
      --security-group-ids "$SG_VPCE_ID" --private-dns-enabled >/dev/null 2>&1 || true

    awsq ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Gateway \
      --service-name "com.amazonaws.${REGION}.s3" --route-table-ids "$RTB_PRI_ID" >/dev/null 2>&1 || true

    ok "Endpoints OK (o ya existían)."
  fi

  step_done 2
fi

# -------------------------
# STEP 3) ECR build/push
# -------------------------
if ! is_step_done 3; then
  log "3) ECR build/push..."

  ensure_repo "$REPO_CONFIG"
  ensure_repo "$REPO_EUREKA"
  ensure_repo "$REPO_GATEWAY"
  ensure_repo "$REPO_PRODUCTS"
  ensure_repo "$REPO_ORDERS"
  ensure_repo "$REPO_PAY"
  ensure_repo "$REPO_USERS"

  awsq ecr get-login-password | docker login --username AWS --password-stdin "$ECR"

  docker build -t "${PROJECT}-${REPO_CONFIG}:latest"   "$DIR_CONFIG"
  docker build -t "${PROJECT}-${REPO_EUREKA}:latest"   "$DIR_EUREKA"
  docker build -t "${PROJECT}-${REPO_GATEWAY}:latest"  "$DIR_GATEWAY"
  docker build -t "${PROJECT}-${REPO_PRODUCTS}:latest" "$DIR_PRODUCTS"
  docker build -t "${PROJECT}-${REPO_ORDERS}:latest"   "$DIR_ORDERS"
  docker build -t "${PROJECT}-${REPO_PAY}:latest"      "$DIR_PAY"
  docker build -t "${PROJECT}-${REPO_USERS}:latest"    "$DIR_USERS"

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
  log "4) IAM Execution Role..."
  ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

  ROLE_ARN="$(awsq iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
  if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
    ROLE_ARN="$(awsq iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" | jq -r '.Role.Arn')"
    awsq iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
    ok "Role creado: $ROLE_ARN"
  else
    ok "Role reusado: $ROLE_ARN"
  fi

  state_set ROLE_ARN "$ROLE_ARN"
  step_done 4
fi
ROLE_ARN="$(state_get ROLE_ARN)"

# -------------------------
# STEP 5) Logs
# -------------------------
if ! is_step_done 5; then
  log "5) CloudWatch Logs..."
  mklog(){ awsq logs create-log-group --log-group-name "$1" >/dev/null 2>&1 || true; }

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
# STEP 7) Cloud Map
# -------------------------
get_namespace_id_by_name(){
  awsq servicediscovery list-namespaces --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v "None" || true
}

wait_cloudmap_success(){
  local op="$1"
  for _i in {1..60}; do
    local st
    st="$(awsq servicediscovery get-operation --operation-id "$op" --query "Operation.Status" --output text 2>/dev/null || true)"
    [[ "$st" == "SUCCESS" ]] && return 0
    [[ "$st" == "FAIL" || "$st" == "FAILURE" ]] && die "CloudMap op falló: $op"
    sleep 2
  done
  die "Timeout CloudMap op: $op"
}

ensure_sd_service() {
  local svc_name="$1"
  local ns_id="$2"
  local key="$3"

  # 1) si ya está en state, úsalo
  local existing
  existing="$(sanitize_token "$(state_get "$key")")"
  if [[ -n "$existing" && "$existing" != "null" && "$existing" != "None" ]]; then
    echo "$existing"
    return 0
  fi

  # 2) buscar por paginación en list-services
  find_sd_service_id() {
    local token=""
    while :; do
      local resp
      if [[ -n "$token" && "$token" != "null" && "$token" != "None" ]]; then
        resp="$(awsq servicediscovery list-services --next-token "$token" --output json)"
      else
        resp="$(awsq servicediscovery list-services --output json)"
      fi

      local id
      id="$(echo "$resp" | jq -r --arg name "$svc_name" --arg ns "$ns_id" \
        '.Services[] | select(.Name==$name and .NamespaceId==$ns) | .Id' | head -n 1)"
      id="$(sanitize_token "$id")"
      if [[ -n "$id" && "$id" != "null" && "$id" != "None" ]]; then
        echo "$id"
        return 0
      fi

      token="$(echo "$resp" | jq -r '.NextToken // empty')"
      token="$(sanitize_token "$token")"
      [[ -z "$token" || "$token" == "null" || "$token" == "None" ]] && break
    done
    echo ""
    return 0
  }

  existing="$(find_sd_service_id)"
  if [[ -n "$existing" && "$existing" != "null" && "$existing" != "None" ]]; then
    state_set "$key" "$existing"
    echo "$existing"
    return 0
  fi

  # 3) crear (si al crear dice AlreadyExists, reintenta búsqueda y úsalo)
  log "CloudMap: creando service '$svc_name' en namespace '$ns_id'..."
  local out err rc
  err="$(mktemp)"
  out="$(mktemp)"
  set +e
  awsq servicediscovery create-service --name "$svc_name" \
    --dns-config "NamespaceId=${ns_id},DnsRecords=[{Type=A,TTL=30}],RoutingPolicy=WEIGHTED" \
    --health-check-custom-config FailureThreshold=1 \
    --query 'Service.Id' --output text 1>"$out" 2>"$err"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    if grep -q "ServiceAlreadyExists" "$err"; then
      existing="$(find_sd_service_id)"
      [[ -n "$existing" && "$existing" != "null" && "$existing" != "None" ]] || die "ServiceAlreadyExists pero no pude resolver el Id para: $svc_name"
      state_set "$key" "$existing"
      echo "$existing"
      return 0
    fi
    cat "$err" >&2
    die "No pude crear CloudMap service: $svc_name"
  fi

  local id
  id="$(sanitize_token "$(cat "$out")")"
  [[ -n "$id" && "$id" != "null" && "$id" != "None" ]] || die "No pude crear CloudMap service: $svc_name"
  state_set "$key" "$id"
  echo "$id"
}

if ! is_step_done 7; then
  log "7) Cloud Map Namespace + Services..."
  VPC_ID="$(state_get VPC_ID)"

  NS_ID="$(sanitize_token "$(state_get NS_ID)")"
  if [[ -z "$NS_ID" || "$NS_ID" == "null" || "$NS_ID" == "None" ]]; then
    NS_ID="$(sanitize_token "$(get_namespace_id_by_name)")"
  fi

  if [[ -z "$NS_ID" || "$NS_ID" == "null" || "$NS_ID" == "None" ]]; then
    OP_ID="$(awsq servicediscovery create-private-dns-namespace \
      --name "$NAMESPACE_NAME" \
      --vpc "$VPC_ID" \
      --description "${PROJECT} private namespace" \
      --query "OperationId" --output text)"
    wait_cloudmap_success "$OP_ID"

    NS_ID="$(sanitize_token "$(get_namespace_id_by_name)")"
    [[ -n "$NS_ID" && "$NS_ID" != "null" && "$NS_ID" != "None" ]] || die "No pude resolver NamespaceId"
  fi

  state_set NS_ID "$NS_ID"
  ok "Namespace: $NS_ID"

  SD_CONFIG_ID="$(ensure_sd_service "$SVC_CONFIG"   "$NS_ID" SD_CONFIG_ID)";   state_set SD_CONFIG_ID   "$SD_CONFIG_ID"
  SD_EUREKA_ID="$(ensure_sd_service "$SVC_EUREKA"   "$NS_ID" SD_EUREKA_ID)";   state_set SD_EUREKA_ID   "$SD_EUREKA_ID"
  SD_GATEWAY_ID="$(ensure_sd_service "$SVC_GATEWAY" "$NS_ID" SD_GATEWAY_ID)";  state_set SD_GATEWAY_ID  "$SD_GATEWAY_ID"
  SD_PRODUCTS_ID="$(ensure_sd_service "$SVC_PRODUCTS" "$NS_ID" SD_PRODUCTS_ID)"; state_set SD_PRODUCTS_ID "$SD_PRODUCTS_ID"
  SD_ORDERS_ID="$(ensure_sd_service "$SVC_ORDERS"   "$NS_ID" SD_ORDERS_ID)";   state_set SD_ORDERS_ID   "$SD_ORDERS_ID"
  SD_PAY_ID="$(ensure_sd_service "$SVC_PAY"         "$NS_ID" SD_PAY_ID)";      state_set SD_PAY_ID      "$SD_PAY_ID"
  SD_USERS_ID="$(ensure_sd_service "$SVC_USERS"     "$NS_ID" SD_USERS_ID)";    state_set SD_USERS_ID    "$SD_USERS_ID"

  step_done 7
fi

# -------------------------
# STEP 9) ALB + TG + Listener
# -------------------------
get_tg_arn(){ awsq elbv2 describe-target-groups --names "$TG_GW_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v None || true; }
get_alb_arn(){ awsq elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v None || true; }
get_alb_dns(){ awsq elbv2 describe-load-balancers --load-balancer-arns "$1" --query "LoadBalancers[0].DNSName" --output text 2>/dev/null | grep -v None || true; }
get_listener_arn(){ awsq elbv2 describe-listeners --load-balancer-arn "$1" --query "Listeners[?Port==\`${2}\`].ListenerArn | [0]" --output text 2>/dev/null | grep -v None || true; }

if ! is_step_done 9; then
  log "9) ALB + Target Group + Listener..."
  VPC_ID="$(state_get VPC_ID)"
  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  SG_ALB_ID="$(state_get SG_ALB_ID)"

  TG_GW_ARN="$(state_get TG_GW_ARN)"; [[ -z "$TG_GW_ARN" ]] && TG_GW_ARN="$(get_tg_arn)"
  if [[ -z "$TG_GW_ARN" ]]; then
    TG_GW_ARN="$(awsq elbv2 create-target-group --name "$TG_GW_NAME" --protocol HTTP --port "$PORT_GATEWAY" --vpc-id "$VPC_ID" --target-type ip \
      --health-check-protocol HTTP --health-check-path "$HEALTH_PATH_GATEWAY" | jq -r '.TargetGroups[0].TargetGroupArn')"
  fi
  state_set TG_GW_ARN "$TG_GW_ARN"

  ALB_ARN="$(state_get ALB_ARN)"; [[ -z "$ALB_ARN" ]] && ALB_ARN="$(get_alb_arn)"
  if [[ -z "$ALB_ARN" ]]; then
    ALB_ARN="$(awsq elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing --subnets "$PUB1_ID" "$PUB2_ID" --security-groups "$SG_ALB_ID" | jq -r '.LoadBalancers[0].LoadBalancerArn')"
  fi
  state_set ALB_ARN "$ALB_ARN"

  ALB_DNS="$(get_alb_dns "$ALB_ARN")"
  state_set ALB_DNS "$ALB_DNS"
  ok "ALB DNS: $ALB_DNS"

  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    L443="$(state_get LISTENER_ARN_443)"; [[ -z "$L443" ]] && L443="$(get_listener_arn "$ALB_ARN" 443)"
    if [[ -z "$L443" ]]; then
      L443="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 \
        --certificates "CertificateArn=$ACM_CERT_ARN" --ssl-policy ELBSecurityPolicy-2016-08 \
        --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" | jq -r '.Listeners[0].ListenerArn')"
    else
      awsq elbv2 modify-listener --listener-arn "$L443" --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" >/dev/null 2>&1 || true
    fi
    state_set LISTENER_ARN_443 "$L443"

    L80="$(state_get LISTENER_ARN_80)"; [[ -z "$L80" ]] && L80="$(get_listener_arn "$ALB_ARN" 80)"
    if [[ -z "$L80" ]]; then
      L80="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
        --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' | jq -r '.Listeners[0].ListenerArn')"
    else
      awsq elbv2 modify-listener --listener-arn "$L80" \
        --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' >/dev/null 2>&1 || true
    fi
    state_set LISTENER_ARN_80 "$L80"
  else
    L80="$(state_get LISTENER_ARN_80)"; [[ -z "$L80" ]] && L80="$(get_listener_arn "$ALB_ARN" 80)"
    if [[ -z "$L80" ]]; then
      L80="$(awsq elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" | jq -r '.Listeners[0].ListenerArn')"
    else
      awsq elbv2 modify-listener --listener-arn "$L80" --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" >/dev/null 2>&1 || true
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
  log "10) Task Definitions..."

  register_td(){
    local family="$1" image="$2" port="$3" log_group="$4" cname="$5" cpu="$6" mem="$7" env_json="$8" health_path="$9"
    env_json="$(echo "${env_json:-[]}" | jq -c .)"
    awsq ecs register-task-definition \
      --family "$family" --network-mode awsvpc --requires-compatibilities FARGATE \
      --cpu "$cpu" --memory "$mem" --execution-role-arn "$ROLE_ARN" \
      --container-definitions "[
        {
          \"name\":\"$cname\",
          \"image\":\"$image\",
          \"essential\":true,
          \"portMappings\":[{\"containerPort\":$port,\"protocol\":\"tcp\"}],
          \"environment\":$env_json,
          \"healthCheck\":{\"command\":[\"CMD-SHELL\",\"curl -f http://localhost:$port$health_path || exit 1\"],\"interval\":30,\"timeout\":5,\"retries\":3,\"startPeriod\":60},
          \"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"$log_group\",\"awslogs-region\":\"$REGION\",\"awslogs-stream-prefix\":\"ecs\"}}
        }
      ]" | jq -r '.taskDefinition.taskDefinitionArn'
  }

  ENV_CONFIG="$(jq -nc --arg uri "$CONFIG_GIT_URI" --arg br "$CONFIG_GIT_BRANCH" --arg paths "$CONFIG_GIT_PATHS" '[
    {"name":"SERVER_PORT","value":"8081"},
    {"name":"HOME","value":"/tmp"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_URI","value":$uri},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL","value":$br},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS","value":$paths},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START","value":"true"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_FORCE_PULL","value":"true"},
    {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_BASEDIR","value":"/tmp/config-repo"}
  ]')"

  ENV_CLIENT_BASE="$(jq -nc --arg ns "$NAMESPACE_NAME" '[
    {"name":"SPRING_CLOUD_CONFIG_URI","value":("http://configservice."+ $ns +":8081")},
    {"name":"EUREKA_CLIENT_SERVICEURL_DEFAULTZONE","value":("http://eurekaservice."+ $ns +":8761/eureka/")}
  ]')"

  ENV_EUREKA="$(jq -nc --arg ns "$NAMESPACE_NAME" '[
    {"name":"SERVER_PORT","value":"8761"},
    {"name":"SPRING_CLOUD_CONFIG_URI","value":("http://configservice."+ $ns +":8081")},
    {"name":"EUREKA_CLIENT_REGISTER_WITH_EUREKA","value":"false"},
    {"name":"EUREKA_CLIENT_FETCH_REGISTRY","value":"false"}
  ]')"

  MYSQL_ENV="[]"
  if [[ -n "$DB_ENDPOINT" ]]; then
    MYSQL_ENV="$(jq -nc --arg host "$DB_ENDPOINT" --arg port "$DB_PORT" --arg db "$DB_NAME" --arg user "$DB_USER" --arg pass "$DB_PASS" '[
      {"name":"SPRING_DATASOURCE_URL","value":("jdbc:mysql://" + $host + ":" + $port + "/" + $db + "?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC")},
      {"name":"SPRING_DATASOURCE_USERNAME","value":$user},
      {"name":"SPRING_DATASOURCE_PASSWORD","value":$pass}
    ]')"
  fi

  JWT_ENV="$(jq -nc --arg jwt "$JWT_SECRET" '[{"name":"JWT_SECRET","value":$jwt}]')"

  merge_env(){ jq -cn --argjson A "$1" --argjson B "$2" '$A + $B'; }

  ENV_PRODUCTS="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_ORDERS="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_PAY="$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")"
  ENV_USERS="$(merge_env "$(merge_env "$ENV_CLIENT_BASE" "$MYSQL_ENV")" "$JWT_ENV")"

  CPU_SMALL="256"; MEM_SMALL="512"
  CPU_MED="512"; MEM_MED="1024"

  TD_CONFIG="$(register_td "${PROJECT}-td-config"     "$ECR/$REPO_CONFIG:$TAG"     "$PORT_CONFIG"   "$LG_CONFIG"   "configservice"   "$CPU_SMALL" "$MEM_SMALL" "$ENV_CONFIG" "/actuator/health")"
  TD_EUREKA="$(register_td "${PROJECT}-td-eureka"     "$ECR/$REPO_EUREKA:$TAG"     "$PORT_EUREKA"  "$LG_EUREKA"   "eurekaservice"   "$CPU_SMALL" "$MEM_SMALL" "$ENV_EUREKA" "/actuator/health")"
  TD_GATEWAY="$(register_td "${PROJECT}-td-gateway"   "$ECR/$REPO_GATEWAY:$TAG"   "$PORT_GATEWAY" "$LG_GATEWAY"  "gatewayservice"  "$CPU_MED"   "$MEM_MED"   "$ENV_CLIENT_BASE" "/actuator/health")"
  TD_PRODUCTS="$(register_td "${PROJECT}-td-products" "$ECR/$REPO_PRODUCTS:$TAG"  "$PORT_PRODUCTS" "$LG_PRODUCTS" "productservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_PRODUCTS" "/actuator/health")"
  TD_ORDERS="$(register_td "${PROJECT}-td-orders"     "$ECR/$REPO_ORDERS:$TAG"    "$PORT_ORDERS"  "$LG_ORDERS"   "orderservice"    "$CPU_SMALL" "$MEM_SMALL" "$ENV_ORDERS" "/actuator/health")"
  TD_PAY="$(register_td "${PROJECT}-td-pay"           "$ECR/$REPO_PAY:$TAG"       "$PORT_PAY"     "$LG_PAY"      "paymentservice"  "$CPU_SMALL" "$MEM_SMALL" "$ENV_PAY" "/actuator/health")"
  TD_USERS="$(register_td "${PROJECT}-td-users"       "$ECR/$REPO_USERS:$TAG"     "$PORT_USERS"   "$LG_USERS"    "userservice"     "$CPU_SMALL" "$MEM_SMALL" "$ENV_USERS" "/actuator/health")"

  state_set TD_CONFIG "$TD_CONFIG"
  state_set TD_EUREKA "$TD_EUREKA"
  state_set TD_GATEWAY "$TD_GATEWAY"
  state_set TD_PRODUCTS "$TD_PRODUCTS"
  state_set TD_ORDERS "$TD_ORDERS"
  state_set TD_PAY "$TD_PAY"
  state_set TD_USERS "$TD_USERS"

  step_done 10
fi

TD_CONFIG="$(state_get TD_CONFIG)"
TD_EUREKA="$(state_get TD_EUREKA)"
TD_GATEWAY="$(state_get TD_GATEWAY)"
TD_PRODUCTS="$(state_get TD_PRODUCTS)"
TD_ORDERS="$(state_get TD_ORDERS)"
TD_PAY="$(state_get TD_PAY)"
TD_USERS="$(state_get TD_USERS)"

# -------------------------
# STEP 11) ECS Services create/update
# -------------------------
if ! is_step_done 11; then
  log "11) ECS Services..."

  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  SG_ECS_ID="$(state_get SG_ECS_ID)"

  NET_PRIVATE="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_ID],assignPublicIp=DISABLED}"

  # CloudMap service IDs
  SD_CONFIG_ID="$(sanitize_token "$(state_get SD_CONFIG_ID)")"
  SD_EUREKA_ID="$(sanitize_token "$(state_get SD_EUREKA_ID)")"
  SD_GATEWAY_ID="$(sanitize_token "$(state_get SD_GATEWAY_ID)")"
  SD_PRODUCTS_ID="$(sanitize_token "$(state_get SD_PRODUCTS_ID)")"
  SD_ORDERS_ID="$(sanitize_token "$(state_get SD_ORDERS_ID)")"
  SD_PAY_ID="$(sanitize_token "$(state_get SD_PAY_ID)")"
  SD_USERS_ID="$(sanitize_token "$(state_get SD_USERS_ID)")"

  mk_sd_arn(){ echo "arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/$1"; }

  create_or_update_sd(){
    local svc="$1" td="$2" sd_id="$3"
    [[ -n "$sd_id" ]] || die "CloudMap ServiceId vacío: $svc"
    local sd_arn; sd_arn="$(mk_sd_arn "$sd_id")"
    if service_exists_ecs "$svc"; then
      awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" --task-definition "$td" --desired-count 1 --force-new-deployment >/dev/null
    else
      awsq ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" --task-definition "$td" --desired-count 1 \
        --launch-type FARGATE --network-configuration "$NET_PRIVATE" \
        --service-registries "[{\"registryArn\":\"$sd_arn\"}]" --health-check-grace-period-seconds 120 >/dev/null
    fi
  }

  create_or_update_sd_lb(){
    local svc="$1" td="$2" sd_id="$3" tg="$4" cname="$5" cport="$6"
    [[ -n "$sd_id" ]] || die "CloudMap ServiceId vacío: $svc"
    local sd_arn; sd_arn="$(mk_sd_arn "$sd_id")"
    if service_exists_ecs "$svc"; then
      awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" --task-definition "$td" --desired-count 1 --force-new-deployment >/dev/null
    else
      awsq ecs create-service --cluster "$CLUSTER_NAME" --service-name "$svc" --task-definition "$td" --desired-count 1 \
        --launch-type FARGATE --network-configuration "$NET_PRIVATE" \
        --service-registries "[{\"registryArn\":\"$sd_arn\"}]" \
        --load-balancers "targetGroupArn=${tg},containerName=${cname},containerPort=${cport}" \
        --health-check-grace-period-seconds 180 >/dev/null
    fi
  }

  create_or_update_sd "$SVC_CONFIG"   "$TD_CONFIG"   "$SD_CONFIG_ID"
  create_or_update_sd "$SVC_EUREKA"   "$TD_EUREKA"   "$SD_EUREKA_ID"
  create_or_update_sd "$SVC_PRODUCTS" "$TD_PRODUCTS" "$SD_PRODUCTS_ID"
  create_or_update_sd "$SVC_ORDERS"   "$TD_ORDERS"   "$SD_ORDERS_ID"
  create_or_update_sd "$SVC_PAY"      "$TD_PAY"      "$SD_PAY_ID"
  create_or_update_sd "$SVC_USERS"    "$TD_USERS"    "$SD_USERS_ID"

  create_or_update_sd_lb "$SVC_GATEWAY" "$TD_GATEWAY" "$SD_GATEWAY_ID" "$TG_GW_ARN" "gatewayservice" "$PORT_GATEWAY"

  step_done 11
fi

echo ""
ok "Deploy completado."
if [[ "$ENABLE_HTTPS" == "true" ]]; then
  echo "ALB URL : https://${ALB_DNS}"
else
  echo "ALB URL : http://${ALB_DNS}"
fi
echo "Health  : http://${ALB_DNS}${HEALTH_PATH_GATEWAY}"
echo "State   : ${STATE_FILE}"