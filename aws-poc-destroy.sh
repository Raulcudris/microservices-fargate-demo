#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG (AJUSTA AQUÍ)
# =========================
REGION="us-east-1"
PROJECT="microservices-fargate-demo"

CLUSTER_NAME="${PROJECT}-cluster"
ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"

# ⚠️ IMPORTANT: Estos nombres deben coincidir con tu deploy ACTUAL
# (en tu deploy resumible los pusiste hardcodeados así)
ALB_NAME="msfd-alb"
TG_GW_NAME="msfd-tg-gw"

# Security groups (según tu deploy actual)
SG_ALB_NAME="${PROJECT}-sg-alb"
SG_ECS_PRIVATE_NAME="${PROJECT}-sg-ecs-private"
SG_CONFIG_NAME="${PROJECT}-sg-config-egress"   # ✅ antes era sg-config-public
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

# RDS
DELETE_RDS=true
DB_INSTANCE_ID="${PROJECT}-mysql"
DB_SUBNET_GROUP="${PROJECT}-db-subnets"

# Task Definition families (limpieza 100%)
TD_FAMILIES=(
  "${PROJECT}-td-config"
  "${PROJECT}-td-eureka"
  "${PROJECT}-td-gateway"
  "${PROJECT}-td-products"
  "${PROJECT}-td-orders"
  "${PROJECT}-td-pay"
  "${PROJECT}-td-users"
)

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

delete_taskdef_family() {
  local family="$1"
  local arns
  arns="$(awsq ecs list-task-definitions --family-prefix "$family" --status ACTIVE \
    --query "taskDefinitionArns[]" --output text 2>/dev/null || true)"
  if [[ -n "${arns// }" ]]; then
    for td in $arns; do
      echo " - Deregister task definition: $td"
      awsq ecs deregister-task-definition --task-definition "$td" >/dev/null || true
    done
  else
    echo " - No task definitions active for: $family (ok)"
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
# 0) RDS primero
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
      echo " - Scaling to 0: $svc_name"
      awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc_name" --desired-count 0 >/dev/null || true
      echo " - Deleting service: $svc_name"
      awsq ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc_name" --force >/dev/null || true
    done
  else
    echo " - No hay servicios ECS (ok)"
  fi
else
  echo " - Cluster ECS no encontrado (ok)"
fi

# -------------------------
# 2) Task Definitions (deregister)
# -------------------------
echo "==> 2) Deregistrando Task Definitions..."
for fam in "${TD_FAMILIES[@]}"; do
  delete_taskdef_family "$fam"
done

# -------------------------
# 3) ECS Cluster (delete)
# -------------------------
echo "==> 3) Eliminando ECS Cluster..."
if exists awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text; then
  awsq ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null || true
  echo " - Cluster eliminado (o en proceso)"
else
  echo " - Cluster no encontrado (ok)"
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

TG_ARN="$(get_tg_arn_by_name "$TG_GW_NAME")"
if [[ -n "${TG_ARN}" ]]; then
  echo " - Deleting target group: $TG_GW_NAME"
  awsq elbv2 delete-target-group --target-group-arn "$TG_ARN" >/dev/null || true
else
  echo " - Target group no encontrado (ok)"
fi

# -------------------------
# 5) Cloud Map (services + namespace)  ✅ FIX ResourceInUse
# -------------------------
echo "==> 5) Eliminando Cloud Map (namespace + services)..."

NS_ID="$(awsq servicediscovery list-namespaces \
  --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v None || true)"

if [[ -n "${NS_ID}" ]]; then
  echo " - Namespace encontrado: $NAMESPACE_NAME ($NS_ID)"

  # 5.1) Borrar services asociados (si existen)
  SD_SERVICES="$(awsq servicediscovery list-services \
    --query "Services[?NamespaceId=='${NS_ID}'].Id" --output text 2>/dev/null || true)"

  if [[ -n "${SD_SERVICES// }" ]]; then
    for sid in $SD_SERVICES; do
      echo " - Deleting Cloud Map service: $sid"
      awsq servicediscovery delete-service --id "$sid" >/dev/null 2>&1 || true
    done
  else
    echo " - No hay servicios asociados (ok)"
  fi

  # 5.2) Esperar hasta que realmente desaparezcan los services del namespace
  echo " - Waiting services deletion (Cloud Map async)..."
  for i in {1..60}; do
    SD_LEFT="$(awsq servicediscovery list-services \
      --query "Services[?NamespaceId=='${NS_ID}'].Id" --output text 2>/dev/null || true)"

    if [[ -z "${SD_LEFT// }" ]]; then
      echo " - Services eliminados."
      break
    fi

    echo "   * Aún quedan services: ${SD_LEFT} (intentando de nuevo...)"
    # Reintenta borrado por si alguno quedó “pegado”
    for sid in $SD_LEFT; do
      awsq servicediscovery delete-service --id "$sid" >/dev/null 2>&1 || true
    done
    sleep 5
  done

  # 5.3) Borrar namespace con retry (por si AWS tarda un poco más)
  echo " - Deleting namespace: $NAMESPACE_NAME ($NS_ID)"
  for i in {1..20}; do
    if awsq servicediscovery delete-namespace --id "$NS_ID" >/dev/null 2>&1; then
      echo " - Namespace eliminado (o en proceso)."
      break
    fi
    echo "   * Namespace aún en uso, reintentando... ($i/20)"
    sleep 5
  done
else
  echo " - Namespace no encontrado (ok)"
fi

# -------------------------
# 6) VPC Endpoints
# -------------------------
echo "==> 6) Eliminando VPC Endpoints..."
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
  echo " - VPC no encontrada (ok)"
fi

# -------------------------
# 7) CloudWatch Logs
# -------------------------
echo "==> 7) Eliminando CloudWatch Log Groups..."
delete_log_group "$LG_CONFIG"
delete_log_group "$LG_EUREKA"
delete_log_group "$LG_GATEWAY"
delete_log_group "$LG_PRODUCTS"
delete_log_group "$LG_ORDERS"
delete_log_group "$LG_PAY"
delete_log_group "$LG_USERS"

# -------------------------
# 8) IAM Role
# -------------------------
echo "==> 8) Eliminando IAM Role (execution role)..."
if exists aws iam get-role --role-name "$ROLE_NAME"; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null || true
  echo " - Role eliminado"
else
  echo " - Role no encontrado (ok)"
fi

# -------------------------
# 9) Networking (SGs, IGW, RTBs, Subnets, VPC)
# -------------------------
echo "==> 9) Eliminando VPC y networking..."
VPC_ID="$(get_vpc_id)"
if [[ -n "${VPC_ID}" ]]; then
  echo " - VPC: $VPC_ID"

  SG_ALB_ID="$(get_sg_id_by_name "$SG_ALB_NAME" "$VPC_ID")"
  SG_ECS_PRIVATE_ID="$(get_sg_id_by_name "$SG_ECS_PRIVATE_NAME" "$VPC_ID")"
  SG_CONFIG_ID="$(get_sg_id_by_name "$SG_CONFIG_NAME" "$VPC_ID")"
  SG_RDS_ID="$(get_sg_id_by_name "$SG_RDS_NAME" "$VPC_ID")"
  SG_VPCE_ID="$(get_sg_id_by_name "$SG_VPCE_NAME" "$VPC_ID")"

  for sg in "$SG_RDS_ID" "$SG_VPCE_ID" "$SG_CONFIG_ID" "$SG_ECS_PRIVATE_ID" "$SG_ALB_ID"; do
    if [[ -n "${sg}" && "${sg}" != "None" ]]; then
      echo " - Deleting SG: $sg"
      awsq ec2 delete-security-group --group-id "$sg" >/dev/null || true
    fi
  done

  IGW_ID="$(get_igw_id)"
  if [[ -n "${IGW_ID}" ]]; then
    echo " - Detaching IGW: $IGW_ID"
    awsq ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null || true
    echo " - Deleting IGW: $IGW_ID"
    awsq ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null || true
  fi

  RTBS="$(awsq ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[].RouteTableId" --output text 2>/dev/null || true)"

  for rtb in $RTBS; do
    IS_MAIN="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" \
      --query "RouteTables[0].Associations[?Main==\`true\`].Main | [0]" --output text 2>/dev/null || true)"
    if [[ "$IS_MAIN" == "True" ]]; then
      continue
    fi

    ASSOCS="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" \
      --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null || true)"
    if [[ -n "${ASSOCS// }" ]]; then
      for a in $ASSOCS; do
        echo " - Disassociating RTB assoc: $a"
        awsq ec2 disassociate-route-table --association-id "$a" >/dev/null || true
      done
    fi

    echo " - Deleting route table: $rtb"
    awsq ec2 delete-route-table --route-table-id "$rtb" >/dev/null || true
  done

  SUBNETS="$(awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[].SubnetId" --output text 2>/dev/null || true)"
  for sn in $SUBNETS; do
    echo " - Deleting subnet: $sn"
    awsq ec2 delete-subnet --subnet-id "$sn" >/dev/null || true
  done

  echo " - Deleting VPC: $VPC_ID"
  awsq ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null || true
else
  echo " - VPC no encontrada (ok)"
fi

# -------------------------
# 10) ECR repos
# -------------------------
echo "==> 10) Eliminando ECR repos..."
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
