#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws
need jq

log() { echo "👉 $*" >&2; }
ok()  { echo "✅ $*" >&2; }
warn(){ echo "⚠️  $*" >&2; }

ENV_FILE="${ENV_FILE:-.env}"
[[ -f "$ENV_FILE" ]] || { echo "❌ No encuentro $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"
MODE_NO_NAT="${MODE_NO_NAT:-false}"

DESTROY_ECR="${DESTROY_ECR:-false}"
DESTROY_IAM="${DESTROY_IAM:-false}"
DESTROY_LOGS="${DESTROY_LOGS:-true}"
DESTROY_CLOUDMAP="${DESTROY_CLOUDMAP:-true}"
DESTROY_RDS="${DESTROY_RDS:-true}"
DRY_RUN="${DRY_RUN:-false}"

CLUSTER_NAME="${PROJECT}-cluster"
NAMESPACE_NAME="${PROJECT}.local"
ALB_NAME="msf-alb"
TG_GW_NAME="msf-tg-gw"
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# --- RDS naming (alínea con tu deploy_rds_pro.sh)
DB_IDENTIFIER="${DB_IDENTIFIER:-${PROJECT}-mysql-${ENV_NAME}}"
DB_SUBNET_GROUP="${DB_SUBNET_GROUP:-${PROJECT}-dbsubnet-${ENV_NAME}}"
DB_SG_NAME="${DB_SG_NAME:-${PROJECT}-sg-db-${ENV_NAME}}"

awsq() { aws --region "$REGION" "$@"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> $*"
  else
    eval "$@"
  fi
}

state_get() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true
}

sanitize() { echo "${1:-}" | awk '{print $1}'; }

get_alb_arn() {
  awsq elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v None || true
}
get_tg_arn() {
  awsq elbv2 describe-target-groups --names "$TG_GW_NAME" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v None || true
}
find_vpc() {
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-vpc" "Name=tag:Project,Values=${PROJECT}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -v None || true
}
find_igw() {
  local vpc="$1"
  awsq ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -v None || true
}

# -------------------------
# SG + ENI HELPERS (PRO)
# -------------------------
list_sg_ids_project() {
  local vpc="$1"
  awsq ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$vpc" "Name=tag:Project,Values=${PROJECT}" \
    --query "SecurityGroups[].GroupId" --output text 2>/dev/null | tr '\t' '\n' || true
}

list_sg_ids_by_names() {
  local vpc="$1"
  names=(
    "${PROJECT}-sg-alb"
    "${PROJECT}-sg-ecs"
    "${PROJECT}-sg-vpce"
    "${DB_SG_NAME}"
    "${PROJECT}-sg-rds"
  )
  for n in "${names[@]}"; do
    awsq ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=$n" \
      --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true
  done
}

revoke_all_sg_rules() {
  local sg="$1"
  ingress_json="$(awsq ec2 describe-security-groups --group-ids "$sg" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || echo "[]")"
  egress_json="$(awsq ec2 describe-security-groups --group-ids "$sg" --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null || echo "[]")"

  if echo "$ingress_json" | jq -e 'length>0' >/dev/null 2>&1; then
    run "awsq ec2 revoke-security-group-ingress --group-id \"$sg\" --ip-permissions '$(echo "$ingress_json" | jq -c .)' >/dev/null 2>&1 || true"
  fi

  # OJO: si revocas TODO egress, luego delete SG funciona igual.
  if echo "$egress_json" | jq -e 'length>0' >/dev/null 2>&1; then
    run "awsq ec2 revoke-security-group-egress --group-id \"$sg\" --ip-permissions '$(echo "$egress_json" | jq -c .)' >/dev/null 2>&1 || true"
  fi
}

delete_leftover_enis() {
  local vpc="$1"
  enis="$(awsq ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$vpc" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null | tr '\t' '\n' || true)"

  [[ -z "$enis" ]] && { ok "Sin ENIs en VPC."; return 0; }

  warn "Intentando limpiar ENIs residuales..."
  echo "$enis" | while read -r eni; do
    [[ -z "$eni" ]] && continue
    status="$(awsq ec2 describe-network-interfaces --network-interface-ids "$eni" --query "NetworkInterfaces[0].Status" --output text 2>/dev/null || true)"
    att_id="$(awsq ec2 describe-network-interfaces --network-interface-ids "$eni" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null || true)"

    if [[ "$status" == "in-use" && -n "$att_id" && "$att_id" != "None" ]]; then
      run "awsq ec2 detach-network-interface --attachment-id \"$att_id\" --force >/dev/null 2>&1 || true"
    fi
    run "awsq ec2 delete-network-interface --network-interface-id \"$eni\" >/dev/null 2>&1 || true"
  done
}

# -------------------------
# RDS HELPERS (PRO)
# -------------------------
get_db_exists() {
  awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
    --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null | grep -v None || true
}

disable_rds_deletion_protection_if_needed() {
  local dp
  dp="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
    --query "DBInstances[0].DeletionProtection" --output text 2>/dev/null || true)"
  if [[ "$dp" == "True" || "$dp" == "true" ]]; then
    warn "RDS tiene DeletionProtection=true. Desactivando..."
    run "awsq rds modify-db-instance --db-instance-identifier \"$DB_IDENTIFIER\" --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true"
    sleep 10
  fi
}

delete_rds_instance() {
  if [[ "$DESTROY_RDS" != "true" ]]; then
    warn "DESTROY_RDS=false (no borro RDS)."
    return 0
  fi

  log "X) RDS: eliminando instancia (si existe)..."
  if [[ -n "$(get_db_exists)" ]]; then
    disable_rds_deletion_protection_if_needed
    run "awsq rds delete-db-instance --db-instance-identifier \"$DB_IDENTIFIER\" --skip-final-snapshot >/dev/null 2>&1 || true"
    if [[ "$DRY_RUN" != "true" ]]; then
      warn "Esperando eliminación de RDS (puede tardar)..."
      awsq rds wait db-instance-deleted --db-instance-identifier "$DB_IDENTIFIER" >/dev/null 2>&1 || true
    fi
    ok "RDS eliminado (o en proceso)."
  else
    ok "RDS no existe: $DB_IDENTIFIER"
  fi

  log "X) RDS: eliminando subnet group (si existe)..."
  run "awsq rds delete-db-subnet-group --db-subnet-group-name \"$DB_SUBNET_GROUP\" >/dev/null 2>&1 || true"

  log "X) SG DB: eliminando SG de base (si existe)..."
  # ojo: solo si ya no hay RDS
  # buscamos por nombre en la VPC si está disponible
}

# -------------------------
# START
# -------------------------
ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text 2>/dev/null || true)"

log "Proyecto : $PROJECT"
log "Región   : $REGION"
log "Cuenta   : ${ACCOUNT_ID:-unknown}"
log "Cluster  : $CLUSTER_NAME"
log "Flags    : RDS=$DESTROY_RDS LOGS=$DESTROY_LOGS CLOUDMAP=$DESTROY_CLOUDMAP ECR=$DESTROY_ECR IAM=$DESTROY_IAM DRY_RUN=$DRY_RUN"
log "State    : $STATE_FILE"
log "RDS      : $DB_IDENTIFIER"

# Resolver VPC temprano
VPC_ID="$(sanitize "$(state_get VPC_ID)")"
[[ -z "$VPC_ID" ]] && VPC_ID="$(find_vpc)"

# 1) ECS Services
log "1) ECS: borrando servicios..."
SERVICES="configservice eurekaservice gatewayservice productservice orderservice paymentservice userservice"
for svc in $SERVICES; do
  status="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" --query "services[0].status" --output text 2>/dev/null || true)"
  if [[ "$status" == "ACTIVE" ]]; then
    run "awsq ecs update-service --cluster \"$CLUSTER_NAME\" --service \"$svc\" --desired-count 0 >/dev/null 2>&1 || true"
    run "awsq ecs delete-service --cluster \"$CLUSTER_NAME\" --service \"$svc\" --force >/dev/null 2>&1 || true"
  else
    ok "No existe/ya borrado: $svc"
  fi
done
if [[ "$DRY_RUN" != "true" ]]; then
  for svc in $SERVICES; do
    awsq ecs wait services-inactive --cluster "$CLUSTER_NAME" --services "$svc" >/dev/null 2>&1 || true
  done
fi
ok "ECS services: OK"

# 2) ALB/TG
log "2) ALB/TG..."
ALB_ARN="$(sanitize "$(state_get ALB_ARN)")"; [[ -z "$ALB_ARN" ]] && ALB_ARN="$(get_alb_arn)"
TG_ARN="$(sanitize "$(state_get TG_GW_ARN)")"; [[ -z "$TG_ARN" ]] && TG_ARN="$(get_tg_arn)"

if [[ -n "$ALB_ARN" ]]; then
  listeners="$(awsq elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "Listeners[].ListenerArn" --output text 2>/dev/null | tr '\t' '\n' || true)"
  if [[ -n "$listeners" ]]; then
    echo "$listeners" | while read -r larn; do
      [[ -z "$larn" ]] && continue
      run "awsq elbv2 delete-listener --listener-arn \"$larn\" >/dev/null 2>&1 || true"
    done
  fi
  run "awsq elbv2 delete-load-balancer --load-balancer-arn \"$ALB_ARN\" >/dev/null 2>&1 || true"
  if [[ "$DRY_RUN" != "true" ]]; then
    awsq elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" >/dev/null 2>&1 || true
  fi
else
  ok "ALB no encontrado."
fi

if [[ -n "$TG_ARN" ]]; then
  run "awsq elbv2 delete-target-group --target-group-arn \"$TG_ARN\" >/dev/null 2>&1 || true"
else
  ok "TG no encontrado."
fi
ok "ALB/TG: OK"

# 3) Cluster
log "3) ECS cluster..."
cluster_status="$(awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null || true)"
if [[ "$cluster_status" == "ACTIVE" ]]; then
  run "awsq ecs delete-cluster --cluster \"$CLUSTER_NAME\" >/dev/null 2>&1 || true"
fi
ok "Cluster: OK"

# 4) Cloud Map
if [[ "$DESTROY_CLOUDMAP" == "true" ]]; then
  log "4) Cloud Map..."
  NS_ID="$(sanitize "$(state_get NS_ID)")"
  if [[ -z "$NS_ID" ]]; then
    NS_ID="$(awsq servicediscovery list-namespaces --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v None || true)"
  fi
  if [[ -n "$NS_ID" ]]; then
    svcs_json="$(awsq servicediscovery list-services --output json 2>/dev/null || echo '{"Services":[]}')"
    svc_ids="$(echo "$svcs_json" | jq -r --arg ns "$NS_ID" '.Services[] | select(.NamespaceId==$ns) | .Id' | tr '\n' ' ')"
    for sid in $svc_ids; do
      [[ -z "$sid" ]] && continue
      run "awsq servicediscovery delete-service --id \"$sid\" >/dev/null 2>&1 || true"
    done
    run "awsq servicediscovery delete-namespace --id \"$NS_ID\" >/dev/null 2>&1 || true"
  else
    ok "Namespace no encontrado."
  fi
else
  warn "DESTROY_CLOUDMAP=false"
fi

# 5) Logs
if [[ "$DESTROY_LOGS" == "true" ]]; then
  log "5) Logs..."
  for g in "/ecs/${PROJECT}/config" "/ecs/${PROJECT}/eureka" "/ecs/${PROJECT}/gateway" "/ecs/${PROJECT}/products" "/ecs/${PROJECT}/orders" "/ecs/${PROJECT}/pay" "/ecs/${PROJECT}/users"; do
    run "awsq logs delete-log-group --log-group-name \"$g\" >/dev/null 2>&1 || true"
  done
  ok "Logs: OK"
else
  warn "DESTROY_LOGS=false"
fi

# 6) VPCE
log "6) VPC Endpoints..."
if [[ -n "$VPC_ID" ]]; then
  vpces="$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null | tr '\t' '\n' || true)"
  if [[ -n "$vpces" ]]; then
    echo "$vpces" | while read -r vid; do
      [[ -z "$vid" ]] && continue
      run "awsq ec2 delete-vpc-endpoints --vpc-endpoint-ids \"$vid\" >/dev/null 2>&1 || true"
    done
  else
    ok "Sin VPCE."
  fi
else
  ok "VPC no encontrada."
fi

# 7) NAT/EIP
log "7) NAT/EIP..."
NAT_GW_ID="$(sanitize "$(state_get NAT_GW_ID)")"
NAT_EIP_ALLOC_ID="$(sanitize "$(state_get NAT_EIP_ALLOC_ID)")"

if [[ -n "$NAT_GW_ID" && "$NAT_GW_ID" != "null" ]]; then
  run "awsq ec2 delete-nat-gateway --nat-gateway-id \"$NAT_GW_ID\" >/dev/null 2>&1 || true"
  if [[ "$DRY_RUN" != "true" ]]; then
    awsq ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GW_ID" >/dev/null 2>&1 || true
  fi
fi

if [[ -n "$NAT_EIP_ALLOC_ID" && "$NAT_EIP_ALLOC_ID" != "null" ]]; then
  run "awsq ec2 release-address --allocation-id \"$NAT_EIP_ALLOC_ID\" >/dev/null 2>&1 || true"
fi
ok "NAT/EIP: OK"

# 8) RDS (ANTES de SG/VPC)
delete_rds_instance

# 9) SG cleanup
log "9) Security Groups..."
if [[ -n "$VPC_ID" ]]; then
  # limpiar ENIs residuales primero
  delete_leftover_enis "$VPC_ID"

  sg_list="$( (list_sg_ids_project "$VPC_ID"; list_sg_ids_by_names "$VPC_ID") | sort -u )"
  if [[ -z "$sg_list" ]]; then
    ok "No se encontraron SG del proyecto."
  else
    # revocar reglas
    echo "$sg_list" | while read -r sg; do
      [[ -z "$sg" ]] && continue
      warn "Revoke rules SG: $sg"
      revoke_all_sg_rules "$sg" || true
    done

    default_sg="$(awsq ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)"
    echo "$sg_list" | while read -r sg; do
      [[ -z "$sg" ]] && continue
      [[ "$sg" == "$default_sg" ]] && continue
      warn "Delete SG: $sg"
      run "awsq ec2 delete-security-group --group-id \"$sg\" >/dev/null 2>&1 || true"
    done
  fi
else
  ok "VPC no encontrada, omitiendo SG cleanup."
fi
ok "SG: OK"

# 10) IGW, RTB, Subnets, VPC
log "10) VPC resources..."
if [[ -n "$VPC_ID" ]]; then
  IGW_ID="$(sanitize "$(state_get IGW_ID)")"
  [[ -z "$IGW_ID" ]] && IGW_ID="$(find_igw "$VPC_ID")"
  if [[ -n "$IGW_ID" ]]; then
    run "awsq ec2 detach-internet-gateway --internet-gateway-id \"$IGW_ID\" --vpc-id \"$VPC_ID\" >/dev/null 2>&1 || true"
    run "awsq ec2 delete-internet-gateway --internet-gateway-id \"$IGW_ID\" >/dev/null 2>&1 || true"
  fi

  rtbs="$(awsq ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json 2>/dev/null || echo '{}')"
  assoc_ids="$(echo "$rtbs" | jq -r '.RouteTables[].Associations[]? | select(.Main!=true) | .RouteTableAssociationId' | tr '\n' ' ')"
  for aid in $assoc_ids; do
    [[ -z "$aid" ]] && continue
    run "awsq ec2 disassociate-route-table --association-id \"$aid\" >/dev/null 2>&1 || true"
  done
  rtb_ids="$(echo "$rtbs" | jq -r '.RouteTables[] | select(.Associations[]?.Main!=true) | .RouteTableId' | tr '\n' ' ')"
  for rid in $rtb_ids; do
    [[ -z "$rid" ]] && continue
    run "awsq ec2 delete-route-table --route-table-id \"$rid\" >/dev/null 2>&1 || true"
  done

  subnets="$(awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text 2>/dev/null | tr '\t' '\n' || true)"
  if [[ -n "$subnets" ]]; then
    echo "$subnets" | while read -r sid; do
      [[ -z "$sid" ]] && continue
      run "awsq ec2 delete-subnet --subnet-id \"$sid\" >/dev/null 2>&1 || true"
    done
  fi

  delete_leftover_enis "$VPC_ID"
  run "awsq ec2 delete-vpc --vpc-id \"$VPC_ID\" >/dev/null 2>&1 || true"
  ok "VPC: OK"
else
  ok "No se encontró VPC."
fi

# 11) ECR
if [[ "$DESTROY_ECR" == "true" ]]; then
  log "11) ECR..."
  for r in "configservice" "eurekaservice" "gatewayservice" "productservice" "orderservice" "paymentservice" "userservice"; do
    run "awsq ecr delete-repository --repository-name \"$r\" --force >/dev/null 2>&1 || true"
  done
  ok "ECR: OK"
else
  warn "DESTROY_ECR=false"
fi

# 12) IAM
if [[ "$DESTROY_IAM" == "true" ]]; then
  log "12) IAM..."
  ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"
  run "awsq iam detach-role-policy --role-name \"$ROLE_NAME\" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1 || true"
  pols="$(awsq iam list-role-policies --role-name "$ROLE_NAME" --query "PolicyNames[]" --output text 2>/dev/null | tr '\t' '\n' || true)"
  if [[ -n "$pols" ]]; then
    echo "$pols" | while read -r p; do
      [[ -z "$p" ]] && continue
      run "awsq iam delete-role-policy --role-name \"$ROLE_NAME\" --policy-name \"$p\" >/dev/null 2>&1 || true"
    done
  fi
  run "awsq iam delete-role --role-name \"$ROLE_NAME\" >/dev/null 2>&1 || true"
  ok "IAM: OK"
else
  warn "DESTROY_IAM=false"
fi

# 13) State file
log "13) State file..."
if [[ -f "$STATE_FILE" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> rm -f \"$STATE_FILE\""
  else
    rm -f "$STATE_FILE" || true
  fi
  ok "State eliminado"
else
  ok "Sin state file"
fi

echo ""
ok "Destroy finalizado ✅"
echo "Si algo falla por dependencias, re-ejecuta (idempotente)."