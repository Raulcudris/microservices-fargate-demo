#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FULL CLEANUP (AWS) - BORRA TODO lo creado por tu deploy
# ✅ Borra imágenes ECR SIEMPRE
# ✅ Borra RDS/Aurora DB SIEMPRE (AUTO)  <-- solicitado
# ============================================================

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
# CONFIG
# -------------------------
REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

MODE_NO_NAT="${MODE_NO_NAT:-true}"

# ✅ FORZADO
DELETE_ECR_IMAGES="true"
DELETE_DB="true"

# ✅ Para borrar DB sin prompts:
SKIP_FINAL_SNAPSHOT="true"          # true = NO final snapshot (borra directo)
FINAL_SNAPSHOT_PREFIX="${PROJECT}-final"  # si SKIP_FINAL_SNAPSHOT=false

CLUSTER_NAME="${PROJECT}-cluster"
NAMESPACE_NAME="${PROJECT}.local"

REPOS=(configservice eurekaservice gatewayservice productservice orderservice paymentservice userservice)

SVC_CONFIG="configservice"
SVC_EUREKA="eurekaservice"
SVC_GATEWAY="gatewayservice"
SVC_PRODUCTS="productservice"
SVC_ORDERS="orderservice"
SVC_PAY="paymentservice"
SVC_USERS="userservice"
ECS_SERVICES=("$SVC_CONFIG" "$SVC_EUREKA" "$SVC_GATEWAY" "$SVC_PRODUCTS" "$SVC_ORDERS" "$SVC_PAY" "$SVC_USERS")

TG_GW_NAME="msf-tg-gw"
ALB_NAME="msf-alb"

STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# -------------------------
# HELPERS
# -------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
log() { echo -e "👉 $*" >&2; }
ok()  { echo -e "✅ $*" >&2; }
warn(){ echo -e "⚠️  $*" >&2; }
awsq() { aws --region "$REGION" "$@"; }
sanitize_token() { echo "${1:-}" | awk '{print $1}'; }

state_get() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true
}

find_vpc() {
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-vpc" "Name=tag:Project,Values=${PROJECT}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -v "None" || true
}
find_igw() {
  local vpc="$1"
  awsq ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=${PROJECT}-igw" "Name=attachment.vpc-id,Values=$vpc" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -v "None" || true
}
get_tg_arn() {
  awsq elbv2 describe-target-groups --names "$TG_GW_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v "None" || true
}
get_alb_arn() {
  awsq elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v "None" || true
}

# -------------------------
# VALIDACIONES
# -------------------------
need aws
need jq

log "Cleanup iniciado"
log "Region : $REGION"
log "Project: $PROJECT"
log "Env    : $ENV_NAME"
log "State  : $STATE_FILE"
log "DELETE_ECR_IMAGES: $DELETE_ECR_IMAGES (FORZADO)"
log "DELETE_DB        : $DELETE_DB (FORZADO)"
log "SKIP_FINAL_SNAPSHOT: $SKIP_FINAL_SNAPSHOT"
echo ""

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ok "Account: $ACCOUNT_ID"
ok "ECR    : $ECR"
echo ""

# -------------------------
# IDs desde state (si existen)
# -------------------------
VPC_ID="$(sanitize_token "$(state_get VPC_ID)")"; [[ -z "$VPC_ID" || "$VPC_ID" == "null" ]] && VPC_ID="$(find_vpc)"
IGW_ID="$(sanitize_token "$(state_get IGW_ID)")"; [[ -z "$IGW_ID" || "$IGW_ID" == "null" ]] && [[ -n "$VPC_ID" ]] && IGW_ID="$(find_igw "$VPC_ID")"

PUB1_ID="$(sanitize_token "$(state_get PUB1_ID)")"
PUB2_ID="$(sanitize_token "$(state_get PUB2_ID)")"
PRI1_ID="$(sanitize_token "$(state_get PRI1_ID)")"
PRI2_ID="$(sanitize_token "$(state_get PRI2_ID)")"

RTB_PUB_ID="$(sanitize_token "$(state_get RTB_PUB_ID)")"
RTB_PRI_ID="$(sanitize_token "$(state_get RTB_PRI_ID)")"

SG_ALB_ID="$(sanitize_token "$(state_get SG_ALB_ID)")"
SG_ECS_PRIVATE_ID="$(sanitize_token "$(state_get SG_ECS_PRIVATE_ID)")"
SG_CONFIG_ID="$(sanitize_token "$(state_get SG_CONFIG_ID)")"
SG_VPCE_ID="$(sanitize_token "$(state_get SG_VPCE_ID)")"

NAT_GW_ID="$(sanitize_token "$(state_get NAT_GW_ID)")"
NAT_EIP_ALLOC_ID="$(sanitize_token "$(state_get NAT_EIP_ALLOC_ID)")"

ALB_ARN="$(sanitize_token "$(state_get ALB_ARN)")"; [[ -z "$ALB_ARN" || "$ALB_ARN" == "null" ]] && ALB_ARN="$(get_alb_arn)"
TG_GW_ARN="$(sanitize_token "$(state_get TG_GW_ARN)")"; [[ -z "$TG_GW_ARN" || "$TG_GW_ARN" == "null" ]] && TG_GW_ARN="$(get_tg_arn)"

ROLE_NAME="${PROJECT}-ecsTaskExecutionRole"

# -------------------------
# 1) ECS Services
# -------------------------
log "1) Eliminando ECS Services..."
for svc in "${ECS_SERVICES[@]}"; do
  if awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" --query "services[0].status" --output text 2>/dev/null | grep -vq "None"; then
    log " - Service: $svc => scale 0"
    awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc" --desired-count 0 >/dev/null 2>&1 || true
    log " - Service: $svc => delete"
    awsq ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc" --force >/dev/null 2>&1 || true
  else
    ok " - Service no existe: $svc"
  fi
done
log "Esperando INACTIVE..."
for svc in "${ECS_SERVICES[@]}"; do
  for _i in {1..40}; do
    st="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" --query "services[0].status" --output text 2>/dev/null || true)"
    [[ "$st" == "INACTIVE" || "$st" == "None" || -z "$st" ]] && break
    sleep 3
  done
done
ok "ECS Services: OK"
echo ""

# -------------------------
# 2) ALB + listeners + TG
# -------------------------
log "2) Eliminando ALB/Listeners/TargetGroup..."
if [[ -n "${ALB_ARN:-}" && "$ALB_ARN" != "null" ]]; then
  LST_JSON="$(awsq elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --output json 2>/dev/null || echo '{}')"
  echo "$LST_JSON" | jq -r '.Listeners[]?.ListenerArn' | while read -r larn; do
    [[ -z "$larn" || "$larn" == "null" ]] && continue
    log " - Deleting listener: $larn"
    awsq elbv2 delete-listener --listener-arn "$larn" >/dev/null 2>&1 || true
  done
  log " - Deleting load balancer: $ALB_ARN"
  awsq elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" >/dev/null 2>&1 || true
  log " - Waiting ALB deleted..."
  for _i in {1..60}; do
    exists="$(awsq elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
    [[ -z "$exists" || "$exists" == "None" ]] && break
    sleep 5
  done
else
  ok " - ALB no encontrado"
fi

if [[ -n "${TG_GW_ARN:-}" && "$TG_GW_ARN" != "null" ]]; then
  log " - Deleting target group: $TG_GW_ARN"
  awsq elbv2 delete-target-group --target-group-arn "$TG_GW_ARN" >/dev/null 2>&1 || true
else
  ok " - TargetGroup no encontrado"
fi
ok "ALB/TG: OK"
echo ""

# -------------------------
# 3) Cloud Map
# -------------------------
log "3) Eliminando Cloud Map (services + namespace)..."
NS_ID="$(sanitize_token "$(state_get NS_ID)")"
if [[ -z "$NS_ID" || "$NS_ID" == "null" ]]; then
  NS_ID="$(awsq servicediscovery list-namespaces --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v "None" || true)"
fi

if [[ -n "${NS_ID:-}" && "$NS_ID" != "null" ]]; then
  SRV_JSON="$(awsq servicediscovery list-services --output json 2>/dev/null || echo '{"Services":[]}')"
  echo "$SRV_JSON" | jq -r --arg ns "$NS_ID" '.Services[] | select(.NamespaceId==$ns) | .Id' | while read -r sid; do
    [[ -z "$sid" || "$sid" == "null" ]] && continue
    log " - Deleting CloudMap service: $sid"
    awsq servicediscovery delete-service --id "$sid" >/dev/null 2>&1 || true
  done

  log " - Deleting namespace: $NS_ID"
  OP_ID="$(awsq servicediscovery delete-namespace --id "$NS_ID" --query OperationId --output text 2>/dev/null || true)"
  if [[ -n "${OP_ID:-}" && "$OP_ID" != "null" ]]; then
    log " - Waiting namespace delete SUCCESS: $OP_ID"
    for _i in {1..80}; do
      st="$(awsq servicediscovery get-operation --operation-id "$OP_ID" --query "Operation.Status" --output text 2>/dev/null || true)"
      [[ "$st" == "SUCCESS" ]] && break
      [[ "$st" == "FAIL" || "$st" == "FAILURE" ]] && { warn "Namespace delete failed"; break; }
      sleep 3
    done
  fi
else
  ok " - Namespace no encontrado"
fi
ok "Cloud Map: OK"
echo ""

# -------------------------
# 4) ECS Cluster
# -------------------------
log "4) Eliminando ECS Cluster..."
awsq ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
ok "Cluster: OK"
echo ""

# -------------------------
# 5) Deregister task defs
# -------------------------
log "5) Deregister task definitions (best-effort)..."
FAMS="$(awsq ecs list-task-definition-families --status ACTIVE --query "families[?starts_with(@, '${PROJECT}-td-')]" --output text 2>/dev/null || true)"
for fam in $FAMS; do
  ARNS="$(awsq ecs list-task-definitions --family-prefix "$fam" --status ACTIVE --query "taskDefinitionArns[]" --output text 2>/dev/null || true)"
  for arn in $ARNS; do
    [[ -z "$arn" ]] && continue
    log " - Deregister: $arn"
    awsq ecs deregister-task-definition --task-definition "$arn" >/dev/null 2>&1 || true
  done
done
ok "Task defs: OK"
echo ""

# -------------------------
# 6) CloudWatch Logs
# -------------------------
log "6) Eliminando CloudWatch Log Groups..."
LOGS="$(awsq logs describe-log-groups --log-group-name-prefix "/ecs/${PROJECT}/" --query "logGroups[].logGroupName" --output text 2>/dev/null || true)"
for lg in $LOGS; do
  [[ -z "$lg" ]] && continue
  log " - Deleting log group: $lg"
  awsq logs delete-log-group --log-group-name "$lg" >/dev/null 2>&1 || true
done
ok "Logs: OK"
echo ""

# -------------------------
# 7) ECR (imágenes + repos) ✅ SIEMPRE
# -------------------------
log "7) Eliminando ECR (imágenes + repos)..."
for repo in "${REPOS[@]}"; do
  # loop por chunks de 100 hasta vaciar
  while true; do
    IMG_JSON="$(awsq ecr list-images --repository-name "$repo" --query 'imageIds' --output json 2>/dev/null || echo '[]')"
    count="$(echo "$IMG_JSON" | jq 'length')"
    [[ "$count" -le 0 ]] && break

    log " - Deleting up to 100 images in repo: $repo (quedan: $count)"
    echo "$IMG_JSON" | jq -c '.[0:100]' > /tmp/imgids_100.json
    awsq ecr batch-delete-image --repository-name "$repo" --image-ids file:///tmp/imgids_100.json >/dev/null 2>&1 || true
    rm -f /tmp/imgids_100.json || true
    sleep 1
  done

  log " - Deleting repository: $repo"
  awsq ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 || true
done
ok "ECR: OK"
echo ""

# -------------------------
# 8) ✅ BORRAR BASE DE DATOS (RDS/Aurora)
# -------------------------
log "8) Eliminando Base de Datos (RDS/Aurora)..."
if [[ "$DELETE_DB" == "true" ]]; then
  # --- Aurora clusters por tags ---
  CL_JSON="$(awsq rds describe-db-clusters --output json 2>/dev/null || echo '{"DBClusters":[]}')"
  echo "$CL_JSON" | jq -r --arg p "$PROJECT" --arg e "$ENV_NAME" '
    .DBClusters[]
    | select((.DBClusterIdentifier|startswith($p)) or (.TagList? // [] | any(.Key=="Project" and .Value==$p)) )
    | .DBClusterIdentifier
  ' | while read -r cid; do
      [[ -z "$cid" || "$cid" == "null" ]] && continue
      log " - Deleting Aurora Cluster: $cid"

      # Primero borrar instancias miembro del cluster
      MEM_JSON="$(awsq rds describe-db-instances --output json 2>/dev/null || echo '{"DBInstances":[]}')"
      echo "$MEM_JSON" | jq -r --arg cid "$cid" '
        .DBInstances[]
        | select(.DBClusterIdentifier==$cid)
        | .DBInstanceIdentifier
      ' | while read -r mid; do
          [[ -z "$mid" || "$mid" == "null" ]] && continue
          log "   - Deleting cluster member instance: $mid"
          if [[ "$SKIP_FINAL_SNAPSHOT" == "true" ]]; then
            awsq rds delete-db-instance --db-instance-identifier "$mid" --skip-final-snapshot >/dev/null 2>&1 || true
          else
            snap="${FINAL_SNAPSHOT_PREFIX}-${mid}-$(date +%Y%m%d%H%M%S)"
            awsq rds delete-db-instance --db-instance-identifier "$mid" --final-db-snapshot-identifier "$snap" >/dev/null 2>&1 || true
          fi
      done

      # Esperar a que no existan instancias del cluster
      log "   - Waiting cluster instances deleted..."
      for _i in {1..120}; do
        left="$(awsq rds describe-db-instances --query "DBInstances[?DBClusterIdentifier=='${cid}'] | length(@)" --output text 2>/dev/null || echo "0")"
        [[ "$left" == "0" ]] && break
        sleep 10
      done

      # Borrar cluster
      if [[ "$SKIP_FINAL_SNAPSHOT" == "true" ]]; then
        awsq rds delete-db-cluster --db-cluster-identifier "$cid" --skip-final-snapshot >/dev/null 2>&1 || true
      else
        snap="${FINAL_SNAPSHOT_PREFIX}-${cid}-$(date +%Y%m%d%H%M%S)"
        awsq rds delete-db-cluster --db-cluster-identifier "$cid" --final-db-snapshot-identifier "$snap" >/dev/null 2>&1 || true
      fi
  done

  # --- RDS instances (no-cluster) por tags/prefijo ---
  INS_JSON="$(awsq rds describe-db-instances --output json 2>/dev/null || echo '{"DBInstances":[]}')"
  echo "$INS_JSON" | jq -r --arg p "$PROJECT" '
    .DBInstances[]
    | select((.DBClusterIdentifier? // "") == "")
    | select((.DBInstanceIdentifier|startswith($p)) or (.TagList? // [] | any(.Key=="Project" and .Value==$p)) )
    | .DBInstanceIdentifier
  ' | while read -r iid; do
      [[ -z "$iid" || "$iid" == "null" ]] && continue
      log " - Deleting RDS Instance: $iid"
      if [[ "$SKIP_FINAL_SNAPSHOT" == "true" ]]; then
        awsq rds delete-db-instance --db-instance-identifier "$iid" --skip-final-snapshot >/dev/null 2>&1 || true
      else
        snap="${FINAL_SNAPSHOT_PREFIX}-${iid}-$(date +%Y%m%d%H%M%S)"
        awsq rds delete-db-instance --db-instance-identifier "$iid" --final-db-snapshot-identifier "$snap" >/dev/null 2>&1 || true
      fi
  done

  # Esperar que no existan DBs con prefijo del proyecto
  log " - Waiting RDS/Aurora deleted..."
  for _i in {1..120}; do
    left1="$(awsq rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'${PROJECT}')]|length(@)" --output text 2>/dev/null || echo "0")"
    left2="$(awsq rds describe-db-clusters  --query "DBClusters[?starts_with(DBClusterIdentifier,'${PROJECT}')]|length(@)" --output text 2>/dev/null || echo "0")"
    [[ "$left1" == "0" && "$left2" == "0" ]] && break
    sleep 10
  done

  # Limpieza subnet groups del proyecto (best-effort)
  log " - Cleaning DB Subnet Groups (best-effort)..."
  SNG="$(awsq rds describe-db-subnet-groups --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'${PROJECT}')].DBSubnetGroupName" --output text 2>/dev/null || true)"
  for g in $SNG; do
    [[ -z "$g" ]] && continue
    log "   - Delete DB subnet group: $g"
    awsq rds delete-db-subnet-group --db-subnet-group-name "$g" >/dev/null 2>&1 || true
  done

else
  ok "DB delete deshabilitado"
fi
ok "DB: OK"
echo ""

# -------------------------
# 9) IAM role
# -------------------------
log "9) Eliminando IAM Role..."
ROLE_ARN="$(awsq iam get-role --role-name "${PROJECT}-ecsTaskExecutionRole" --query Role.Arn --output text 2>/dev/null || true)"
if [[ -n "${ROLE_ARN:-}" && "$ROLE_ARN" != "None" ]]; then
  POLS="$(awsq iam list-attached-role-policies --role-name "${PROJECT}-ecsTaskExecutionRole" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)"
  for p in $POLS; do
    [[ -z "$p" ]] && continue
    log " - Detach policy: $p"
    awsq iam detach-role-policy --role-name "${PROJECT}-ecsTaskExecutionRole" --policy-arn "$p" >/dev/null 2>&1 || true
  done
  log " - Delete role: ${PROJECT}-ecsTaskExecutionRole"
  awsq iam delete-role --role-name "${PROJECT}-ecsTaskExecutionRole" >/dev/null 2>&1 || true
else
  ok " - Role no existe"
fi
ok "IAM: OK"
echo ""

# -------------------------
# 10) VPC Endpoints
# -------------------------
log "10) Eliminando VPC Endpoints..."
if [[ -n "${VPC_ID:-}" && "$VPC_ID" != "null" ]]; then
  VPCE_IDS="$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)"
  for vid in $VPCE_IDS; do
    [[ -z "$vid" ]] && continue
    log " - Deleting VPCE: $vid"
    awsq ec2 delete-vpc-endpoints --vpc-endpoint-ids "$vid" >/dev/null 2>&1 || true
  done
fi
ok "VPCE: OK"
echo ""

# -------------------------
# 11) NAT + EIP
# -------------------------
log "11) Eliminando NAT (si existe)..."
if [[ -n "${NAT_GW_ID:-}" && "$NAT_GW_ID" != "null" && "$NAT_GW_ID" != "None" ]]; then
  log " - Deleting NAT GW: $NAT_GW_ID"
  awsq ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
  log " - Waiting NAT deleted..."
  for _i in {1..80}; do
    st="$(awsq ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" --query "NatGateways[0].State" --output text 2>/dev/null || true)"
    [[ "$st" == "deleted" || "$st" == "None" || -z "$st" ]] && break
    sleep 5
  done
fi
if [[ -n "${NAT_EIP_ALLOC_ID:-}" && "$NAT_EIP_ALLOC_ID" != "null" && "$NAT_EIP_ALLOC_ID" != "None" ]]; then
  log " - Releasing EIP: $NAT_EIP_ALLOC_ID"
  awsq ec2 release-address --allocation-id "$NAT_EIP_ALLOC_ID" >/dev/null 2>&1 || true
fi
ok "NAT/EIP: OK"
echo ""

# -------------------------
# 12) RTBs, Subnets, IGW, SGs, VPC
# -------------------------
log "12) Route tables (best-effort)..."
if [[ -n "${VPC_ID:-}" && "$VPC_ID" != "null" ]]; then
  RTBS="$(awsq ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json 2>/dev/null || echo '{}')"
  echo "$RTBS" | jq -r '.RouteTables[]?.Associations[]? | select(.Main!=true) | .RouteTableAssociationId' | while read -r assoc; do
    [[ -z "$assoc" || "$assoc" == "null" ]] && continue
    log " - Disassociate RTB assoc: $assoc"
    awsq ec2 disassociate-route-table --association-id "$assoc" >/dev/null 2>&1 || true
  done
  for rtb in "$RTB_PUB_ID" "$RTB_PRI_ID"; do
    [[ -z "${rtb:-}" || "$rtb" == "null" || "$rtb" == "None" ]] && continue
    log " - Delete RTB: $rtb"
    awsq ec2 delete-route-table --route-table-id "$rtb" >/dev/null 2>&1 || true
  done
fi
ok "RTBs: OK"
echo ""

log "13) Eliminando Subnets..."
for sn in "$PRI1_ID" "$PRI2_ID" "$PUB1_ID" "$PUB2_ID"; do
  [[ -z "${sn:-}" || "$sn" == "null" || "$sn" == "None" ]] && continue
  log " - Delete subnet: $sn"
  awsq ec2 delete-subnet --subnet-id "$sn" >/dev/null 2>&1 || true
done
ok "Subnets: OK"
echo ""

log "14) Eliminando IGW..."
if [[ -n "${IGW_ID:-}" && "$IGW_ID" != "null" && "$IGW_ID" != "None" && -n "${VPC_ID:-}" && "$VPC_ID" != "null" ]]; then
  log " - Detach IGW: $IGW_ID"
  awsq ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  log " - Delete IGW: $IGW_ID"
  awsq ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null 2>&1 || true
fi
ok "IGW: OK"
echo ""

log "15) Eliminando Security Groups..."
for sg in "$SG_VPCE_ID" "$SG_CONFIG_ID" "$SG_ECS_PRIVATE_ID" "$SG_ALB_ID"; do
  [[ -z "${sg:-}" || "$sg" == "null" || "$sg" == "None" ]] && continue
  log " - Delete SG: $sg"
  awsq ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || true
done
ok "SGs: OK"
echo ""

log "16) Eliminando VPC..."
if [[ -n "${VPC_ID:-}" && "$VPC_ID" != "null" && "$VPC_ID" != "None" ]]; then
  log " - Delete VPC: $VPC_ID"
  awsq ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
fi
ok "VPC: OK"
echo ""

log "17) Limpiando archivos locales..."
if [[ -f "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE"
  ok "State file eliminado: $STATE_FILE"
fi

ok "CLEANUP COMPLETADO ✅"