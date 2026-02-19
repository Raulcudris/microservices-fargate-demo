#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG (AJUSTA AQUÍ)
# =========================
REGION="us-east-1"
PROJECT="microservices-fargate-demo"

CLUSTER_NAME="${PROJECT}-cluster"
ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"

# ALB / Target Group (solo gateway)
ALB_NAME="${PROJECT}-alb"
TG_GW_NAME="${PROJECT}-tg-gateway"

# Security groups creados en el deploy
SG_ALB_NAME="${PROJECT}-sg-alb"
SG_ECS_PRIVATE_NAME="${PROJECT}-sg-ecs-private"
SG_CONFIG_PUBLIC_NAME="${PROJECT}-sg-config-public"
SG_RDS_NAME="${PROJECT}-sg-rds"
SG_VPCE_NAME="${PROJECT}-sg-vpce"

# VPC tags
VPC_TAG_NAME="${PROJECT}-vpc"
IGW_TAG_NAME="${PROJECT}-igw"

# Cloud Map
NAMESPACE_NAME="${PROJECT}.local"

# Logs (CloudWatch)
LG_CONFIG="/ecs/${PROJECT}/config"
LG_EUREKA="/ecs/${PROJECT}/eureka"
LG_GATEWAY="/ecs/${PROJECT}/gateway"
LG_PRODUCTS="/ecs/${PROJECT}/products"
LG_ORDERS="/ecs/${PROJECT}/orders"
LG_PAY="/ecs/${PROJECT}/pay"
LG_USERS="/ecs/${PROJECT}/users"

# ECR repos (BORRA TODO si FORCE_ECR_DELETE=true)
FORCE_ECR_DELETE=true
ECR_REPOS=("configservice" "eurekaservice" "gatewayservice" "productservice" "orderservice" "paymentservice" "userservice")

# RDS (si lo creaste con el deploy)
DELETE_RDS=true
DB_INSTANCE_ID="${PROJECT}-mysql"
DB_SUBNET_GROUP="${PROJECT}-db-subnets"

# =========================
# HELPERS
# =========================
awsq() { aws --region "$REGION" "$@"; }
exists() { "$@" >/dev/null 2>&1; }

get_vpc_id() {
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${VPC_TAG_NAME}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -v None || true
}

get_igw_id() {
  awsq ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=${IGW_TAG_NAME}" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -v None || true
}

get_sg_id_by_name() {
  local name="$1"
  local vpc_id="$2"
  awsq ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${name}" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true
}

get_alb_arn() {
  awsq elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v None || true
}

get_listener_arns() {
  local alb_arn="$1"
  awsq elbv2 describe-listeners --load-balancer-arn "$alb_arn" \
    --query "Listeners[].ListenerArn" --output text 2>/dev/null || true
}

get_tg_arn_by_name() {
  local name="$1"
  awsq elbv2 describe-target-groups --names "$name" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v None || true
}

delete_log_group() {
  local lg="$1"
  if exists awsq logs describe-log-groups --log-group-name-prefix "$lg" \
      --query "logGroups[?logGroupName=='$lg'].logGroupName" --output text | grep -q "$lg"; then
    echo " - Deleting log group $lg"
    awsq logs delete-log-group --log-group-name "$lg" >/dev/null || true
  fi
}

# =========================
# START
# =========================
echo "==> Teardown total (${PROJECT})"
echo "Region : $REGION"
echo "Project: $PROJECT"

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
echo "Account: $ACCOUNT_ID"

# -------------------------
# 0) (Opcional) RDS
# -------------------------
if [[ "$DELETE_RDS" == "true" ]]; then
  echo "==> 0) Eliminando RDS (si existe)..."
  if exists awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID"; then
    echo " - Deleting DB instance: $DB_INSTANCE_ID (skip final snapshot)"
    awsq rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_ID" --skip-final-snapshot >/dev/null || true
    echo " - Waiting DB deletion..."
    awsq rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1 || true
  else
    echo " - RDS instance no encontrada (ok)"
  fi

  if exists awsq rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP"; then
    echo " - Deleting DB subnet group: $DB_SUBNET_GROUP"
    awsq rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null || true
  else
    echo " - DB subnet group no encontrado (ok)"
  fi
fi

# -------------------------
# 1) ECS Services (delete)
# -------------------------
echo "==> 1) Eliminando ECS Services..."
if exists awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text; then
  SERVICES="$(awsq ecs list-services --cluster "$CLUSTER_NAME" --query "serviceArns[]" --output text 2>/dev/null || true)"
  if [[ -n "${SERVICES// }" ]]; then
    for svc_arn in $SERVICES; do
      svc_name="$(basename "$svc_arn")"
      # Solo borramos servicios de este proyecto
      if [[ "$svc_name" == "configservice" || "$svc_name" == "eurekaservice" || "$svc_name" == "gatewayservice" \
         || "$svc_name" == "productservice" || "$svc_name" == "orderservice" || "$svc_name" == "paymentservice" || "$svc_name" == "userservice" \
         || "$svc_name" == *"${PROJECT}"* ]]; then
        echo " - Deleting service: $svc_name"
        awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc_name" --desired-count 0 >/dev/null || true
        awsq ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc_name" --force >/dev/null || true
      fi
    done
  fi
else
  echo " - Cluster ECS no encontrado (ok)"
fi

# -------------------------
# 2) ECS Cluster (delete)
# -------------------------
echo "==> 2) Eliminando ECS Cluster..."
if exists awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text; then
  sleep 8
  awsq ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null || true
  echo " - Cluster eliminado (o en proceso)"
else
  echo " - Cluster no encontrado (ok)"
fi

# -------------------------
# 3) Cloud Map (namespace + services)
# -------------------------
echo "==> 3) Eliminando Cloud Map (namespace + services)..."
NS_ID="$(awsq servicediscovery list-namespaces --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v None || true)"
if [[ -n "${NS_ID}" ]]; then
  # Borrar servicios dentro del namespace
  SD_SERVICES="$(awsq servicediscovery list-services --query "Services[?NamespaceId=='${NS_ID}'].Id" --output text 2>/dev/null || true)"
  if [[ -n "${SD_SERVICES// }" ]]; then
    for sid in $SD_SERVICES; do
      echo " - Deleting Cloud Map service: $sid"
      awsq servicediscovery delete-service --id "$sid" >/dev/null || true
    done
  fi
  echo " - Deleting namespace: $NAMESPACE_NAME"
  awsq servicediscovery delete-namespace --id "$NS_ID" >/dev/null || true
else
  echo " - Namespace no encontrado (ok)"
fi

# -------------------------
# 4) ALB + Listeners + Rules + Target Groups
# -------------------------
echo "==> 4) Eliminando ALB/Listeners/Rules y Target Group..."
ALB_ARN="$(get_alb_arn)"
if [[ -n "${ALB_ARN}" ]]; then
  LISTENERS="$(get_listener_arns "$ALB_ARN")"
  if [[ -n "${LISTENERS// }" ]]; then
    for lst in $LISTENERS; do
      RULES="$(awsq elbv2 describe-rules --listener-arn "$lst" \
        --query "Rules[?IsDefault==\`false\`].RuleArn" --output text 2>/dev/null || true)"
      if [[ -n "${RULES// }" ]]; then
        for r in $RULES; do
          echo " - Deleting rule: $r"
          awsq elbv2 delete-rule --rule-arn "$r" >/dev/null || true
        done
      fi
      echo " - Deleting listener: $lst"
      awsq elbv2 delete-listener --listener-arn "$lst" >/dev/null || true
    done
  fi

  echo " - Deleting ALB: $ALB_NAME"
  awsq elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" >/dev/null || true
  echo " - Waiting for ALB deletion..."
  awsq elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" >/dev/null 2>&1 || true
else
  echo " - ALB no encontrado (ok)"
fi

# Target group del gateway
TG_ARN="$(get_tg_arn_by_name "$TG_GW_NAME")"
if [[ -n "${TG_ARN}" ]]; then
  echo " - Deleting target group: $TG_GW_NAME"
  awsq elbv2 delete-target-group --target-group-arn "$TG_ARN" >/dev/null || true
else
  echo " - Target group no encontrado (ok)"
fi

# -------------------------
# 5) VPC Endpoints
# -------------------------
echo "==> 5) Eliminando VPC Endpoints..."
VPC_ID="$(get_vpc_id)"
if [[ -n "${VPC_ID}" ]]; then
  VPCE_IDS="$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)"
  if [[ -n "${VPCE_IDS// }" ]]; then
    echo " - Deleting VPC endpoints: $VPCE_IDS"
    awsq ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE_IDS >/dev/null || true
  else
    echo " - No hay VPC endpoints (ok)"
  fi
else
  echo " - VPC no encontrada aún (ok)"
fi

# -------------------------
# 6) CloudWatch Logs
# -------------------------
echo "==> 6) Eliminando CloudWatch Log Groups..."
delete_log_group "$LG_CONFIG"
delete_log_group "$LG_EUREKA"
delete_log_group "$LG_GATEWAY"
delete_log_group "$LG_PRODUCTS"
delete_log_group "$LG_ORDERS"
delete_log_group "$LG_PAY"
delete_log_group "$LG_USERS"

# -------------------------
# 7) IAM Role
# -------------------------
echo "==> 7) Eliminando IAM Role (execution role)..."
if exists aws iam get-role --role-name "$ROLE_NAME"; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null || true
  echo " - Role eliminado"
else
  echo " - Role no encontrado (ok)"
fi

# -------------------------
# 8) Cloud Map Namespace + Services (service discovery interno)
# -------------------------
echo "==> 8) Creando Cloud Map namespace y servicios..."

# 8.0) Crear namespace (DEVUELVE OperationId)
OP_ID="$(aws servicediscovery create-private-dns-namespace \
  --name "$NAMESPACE_NAME" \
  --vpc "$VPC_ID" \
  --region "$REGION" \
  --description "${PROJECT} private namespace" \
  --query "OperationId" --output text)"

echo " - OperationId: $OP_ID"

# 8.1) Esperar a que Cloud Map termine y obtener NamespaceId real
echo " - Esperando a que el namespace esté listo..."
for i in {1..30}; do
  NS_ID="$(aws servicediscovery get-operation \
    --operation-id "$OP_ID" \
    --region "$REGION" \
    --query "Operation.Targets.NAMESPACE" --output text 2>/dev/null || true)"

  if [[ -n "${NS_ID}" && "${NS_ID}" != "None" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${NS_ID}" || "${NS_ID}" == "None" ]]; then
  echo "❌ No pude obtener NamespaceId desde la operación $OP_ID"
  echo "   Prueba a listar namespaces:"
  aws servicediscovery list-namespaces --region "$REGION" --output table
  exit 1
fi

echo " - NamespaceId: $NS_ID"

# 8.2) Crear servicios en ese namespace
create_sd_service () {
  local name="$1"
  aws servicediscovery create-service \
    --name "$name" --region "$REGION" \
    --dns-config "NamespaceId=${NS_ID},DnsRecords=[{Type=A,TTL=30}],RoutingPolicy=WEIGHTED" \
    --health-check-custom-config FailureThreshold=1 \
    --query "Service.Id" --output text
}

SD_CONFIG_ID="$(create_sd_service "$SVC_CONFIG")"
SD_EUREKA_ID="$(create_sd_service "$SVC_EUREKA")"
SD_GATEWAY_ID="$(create_sd_service "$SVC_GATEWAY")"
SD_PRODUCTS_ID="$(create_sd_service "$SVC_PRODUCTS")"
SD_ORDERS_ID="$(create_sd_service "$SVC_ORDERS")"
SD_PAY_ID="$(create_sd_service "$SVC_PAY")"
SD_USERS_ID="$(create_sd_service "$SVC_USERS")"

echo "Cloud Map services created:"
echo " - config : $SD_CONFIG_ID"
echo " - eureka : $SD_EUREKA_ID"
echo " - gateway: $SD_GATEWAY_ID"
echo " - products: $SD_PRODUCTS_ID"
echo " - orders : $SD_ORDERS_ID"
echo " - pay    : $SD_PAY_ID"
echo " - users  : $SD_USERS_ID"

# -------------------------
# 9) ECR repos (opcional)
# -------------------------
echo "==> 9) Eliminando ECR repos..."
if [[ "$FORCE_ECR_DELETE" == "true" ]]; then
  for repo in "${ECR_REPOS[@]}"; do
    if exists awsq ecr describe-repositories --repository-names "$repo"; then
      echo " - Deleting ECR repo (force): $repo"
      awsq ecr delete-repository --repository-name "$repo" --force >/dev/null || true
    else
      echo " - Repo no encontrado: $repo (ok)"
    fi
  done
else
  echo " - FORCE_ECR_DELETE=false (no borro ECR)"
fi

echo ""
echo "✅ Teardown completado."
