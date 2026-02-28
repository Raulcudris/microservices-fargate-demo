#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need jq

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

DB_IDENTIFIER="${DB_IDENTIFIER:-${PROJECT}-mysql-${ENV_NAME}}"

STATE_FILE=".state_db_pro_${PROJECT}_${REGION}.json"
awsq(){ aws --region "$REGION" "$@"; }
state_get(){ jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true; }

log(){ echo "👉 $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️ $*" >&2; }

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"

[[ -f "$STATE_FILE" ]] || { echo "❌ No existe $STATE_FILE. No tengo de dónde leer recursos."; exit 1; }

# From state
VPC_ID="$(state_get VPC_ID)"
IGW_ID="$(state_get IGW_ID)"
PUB1_ID="$(state_get PUB1_ID)"
PUB2_ID="$(state_get PUB2_ID)"
PRI1_ID="$(state_get PRI1_ID)"
PRI2_ID="$(state_get PRI2_ID)"
RTB_PUB_ID="$(state_get RTB_PUB_ID)"
RTB_PRI_ID="$(state_get RTB_PRI_ID)"
NAT_GW_ID="$(state_get NAT_GW_ID)"
NAT_EIP_ALLOC_ID="$(state_get NAT_EIP_ALLOC_ID)"
SG_ECS_ID="$(state_get SG_ECS_ID)"
SG_DB_ID="$(state_get SG_DB_ID)"
DB_ENDPOINT="$(state_get DB_ENDPOINT)"

DB_SUBNET_GROUP="${PROJECT}-dbsubnet-${ENV_NAME}"
CLUSTER_NAME="${PROJECT}-dbops-cluster"
ROLE_NAME="${PROJECT}-dbops-exec-role"
LOG_GROUP="/ecs/${PROJECT}/db-migrator"
BUCKET="${PROJECT}-${ENV_NAME}-dbops-${ACCOUNT_ID}-${REGION}"

log "Destroy total (db_deploy_pro_all.sh)"
ok "REGION=$REGION PROJECT=$PROJECT ENV=$ENV_NAME"
ok "DB_IDENTIFIER=$DB_IDENTIFIER"
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || warn "VPC_ID vacío en state (algunas cosas pueden no borrarse)."

# -------------------------
# A) ECS DBOPS (cluster/tasks) + LogGroup
# -------------------------
log "A) ECS dbops cleanup"

# Stop running tasks (best-effort)
TASKS="$(awsq ecs list-tasks --cluster "$CLUSTER_NAME" --query 'taskArns[]' --output text 2>/dev/null || true)"
if [[ -n "${TASKS// }" ]]; then
  for t in $TASKS; do
    awsq ecs stop-task --cluster "$CLUSTER_NAME" --task "$t" --reason "Destroy stack" >/dev/null 2>&1 || true
  done
fi

# Deregister task definitions (best-effort)
TDS="$(awsq ecs list-task-definitions --family-prefix "${PROJECT}-db-migrator" --status ACTIVE \
  --query 'taskDefinitionArns[]' --output text 2>/dev/null || true)"
if [[ -n "${TDS// }" ]]; then
  for td in $TDS; do
    awsq ecs deregister-task-definition --task-definition "$td" >/dev/null 2>&1 || true
  done
fi

# Delete cluster
if awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null | grep -vq "None"; then
  awsq ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
  ok "Cluster eliminado (o en proceso): $CLUSTER_NAME"
else
  ok "Cluster no existe: $CLUSTER_NAME"
fi

# Delete log group
awsq logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || true
ok "LogGroup eliminado (o no existía): $LOG_GROUP"

# (Opcional) IAM role: si la borras pero hay policies adjuntas, hay que detach primero.
# Te la dejo best-effort:
log "A2) IAM role cleanup (best-effort)"
awsq iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1 || true
awsq iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
ok "Role eliminado (o no existía): $ROLE_NAME"

# -------------------------
# B) S3 bucket (SQL uploads)
# -------------------------
log "B) S3 bucket cleanup (best-effort): $BUCKET"
if [[ -n "$ACCOUNT_ID" ]]; then
  if awsq s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    # remove all objects/versions
    # 1) versiones
    VERS="$(awsq s3api list-object-versions --bucket "$BUCKET" --output json 2>/dev/null || echo '{}')"
    DEL1="$(echo "$VERS" | jq -c '{Objects: ([.Versions[]? | {Key:.Key,VersionId:.VersionId}] + [.DeleteMarkers[]? | {Key:.Key,VersionId:.VersionId}])} | select(.Objects|length>0)')"
    if [[ -n "$DEL1" ]]; then
      echo "$DEL1" | jq -e . >/dev/null 2>&1 && awsq s3api delete-objects --bucket "$BUCKET" --delete "$DEL1" >/dev/null 2>&1 || true
    fi
    # 2) por si no versiona, limpia list-objects
    KEYS="$(awsq s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output text 2>/dev/null || true)"
    if [[ -n "${KEYS// }" ]]; then
      for k in $KEYS; do
        awsq s3api delete-object --bucket "$BUCKET" --key "$k" >/dev/null 2>&1 || true
      done
    fi
    awsq s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 || true
    ok "Bucket eliminado: $BUCKET"
  else
    ok "Bucket no existe: $BUCKET"
  fi
else
  warn "No pude resolver ACCOUNT_ID; omitiendo bucket cleanup."
fi

# -------------------------
# C) RDS + Subnet group
# -------------------------
log "C) RDS cleanup"

EXISTS_DB="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
  --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null | grep -v None || true)"

if [[ -n "$EXISTS_DB" ]]; then
  log "   Eliminando RDS: $DB_IDENTIFIER (skip final snapshot)"
  awsq rds delete-db-instance --db-instance-identifier "$DB_IDENTIFIER" --skip-final-snapshot >/dev/null
  log "   Esperando db-instance-deleted..."
  awsq rds wait db-instance-deleted --db-instance-identifier "$DB_IDENTIFIER"
  ok "RDS eliminado: $DB_IDENTIFIER"
else
  ok "RDS no existe: $DB_IDENTIFIER"
fi

EXISTS_SUBNET_GRP="$(awsq rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --query "DBSubnetGroups[0].DBSubnetGroupName" --output text 2>/dev/null | grep -v None || true)"

if [[ -n "$EXISTS_SUBNET_GRP" ]]; then
  awsq rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null
  ok "DB Subnet Group eliminado: $DB_SUBNET_GROUP"
else
  ok "DB Subnet Group no existe: $DB_SUBNET_GROUP"
fi

# -------------------------
# D) Security Groups
# -------------------------
log "D) Security Groups cleanup"
# DB SG first
if [[ -n "${SG_DB_ID:-}" && "$SG_DB_ID" != "None" ]]; then
  if ! awsq ec2 delete-security-group --group-id "$SG_DB_ID" >/dev/null 2>&1; then
    warn "No pude borrar SG_DB_ID ($SG_DB_ID). ¿En uso? Intenta luego."
  else
    ok "SG DB eliminado: $SG_DB_ID"
  fi
fi

# ECS SG
if [[ -n "${SG_ECS_ID:-}" && "$SG_ECS_ID" != "None" ]]; then
  if ! awsq ec2 delete-security-group --group-id "$SG_ECS_ID" >/dev/null 2>&1; then
    warn "No pude borrar SG_ECS_ID ($SG_ECS_ID). ¿En uso? (servicios ECS vivos, endpoints, etc.)"
  else
    ok "SG ECS eliminado: $SG_ECS_ID"
  fi
fi

# -------------------------
# E) NAT + EIP
# -------------------------
log "E) NAT + EIP cleanup"

if [[ -n "${NAT_GW_ID:-}" && "$NAT_GW_ID" != "None" ]]; then
  awsq ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
  log "   Esperando a que NAT se borre (puede tardar)..."
  # wait until deleted (best-effort)
  for _ in {1..90}; do
    ST="$(awsq ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")"
    [[ "$ST" == "deleted" || "$ST" == "None" ]] && break
    sleep 10
  done
  ok "NAT delete solicitado/completado: $NAT_GW_ID"
fi

if [[ -n "${NAT_EIP_ALLOC_ID:-}" && "$NAT_EIP_ALLOC_ID" != "None" ]]; then
  awsq ec2 release-address --allocation-id "$NAT_EIP_ALLOC_ID" >/dev/null 2>&1 || true
  ok "EIP liberada (o ya no existía): $NAT_EIP_ALLOC_ID"
fi

# -------------------------
# F) Route tables associations/routes then delete RTBs
# -------------------------
log "F) RouteTables cleanup"

delete_rtb(){
  local rtb_id="$1"
  [[ -n "$rtb_id" && "$rtb_id" != "None" ]] || return 0

  # disassociate non-main associations
  ASSOCS="$(awsq ec2 describe-route-tables --route-table-ids "$rtb_id" --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text 2>/dev/null || true)"
  if [[ -n "${ASSOCS// }" ]]; then
    for a in $ASSOCS; do
      awsq ec2 disassociate-route-table --association-id "$a" >/dev/null 2>&1 || true
    done
  fi

  # delete routes (except local)
  DESTS="$(awsq ec2 describe-route-tables --route-table-ids "$rtb_id" --query 'RouteTables[0].Routes[?Origin!=`CreateRouteTable`].[DestinationCidrBlock]' --output text 2>/dev/null || true)"
  if [[ -n "${DESTS// }" ]]; then
    for d in $DESTS; do
      [[ "$d" == "None" || -z "$d" ]] && continue
      awsq ec2 delete-route --route-table-id "$rtb_id" --destination-cidr-block "$d" >/dev/null 2>&1 || true
    done
  fi

  awsq ec2 delete-route-table --route-table-id "$rtb_id" >/dev/null 2>&1 || true
  ok "RTB eliminado (o no existía): $rtb_id"
}

delete_rtb "$RTB_PUB_ID"
delete_rtb "$RTB_PRI_ID"

# -------------------------
# G) Subnets
# -------------------------
log "G) Subnets cleanup"
for sn in "$PUB1_ID" "$PUB2_ID" "$PRI1_ID" "$PRI2_ID"; do
  if [[ -n "${sn:-}" && "$sn" != "None" ]]; then
    awsq ec2 delete-subnet --subnet-id "$sn" >/dev/null 2>&1 || true
    ok "Subnet delete solicitado: $sn"
  fi
done

# -------------------------
# H) IGW
# -------------------------
log "H) IGW cleanup"
if [[ -n "${IGW_ID:-}" && "$IGW_ID" != "None" && -n "${VPC_ID:-}" && "$VPC_ID" != "None" ]]; then
  awsq ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  awsq ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null 2>&1 || true
  ok "IGW eliminado (o no existía): $IGW_ID"
fi

# -------------------------
# I) VPC
# -------------------------
log "I) VPC cleanup"
if [[ -n "${VPC_ID:-}" && "$VPC_ID" != "None" ]]; then
  awsq ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
  ok "VPC delete solicitado: $VPC_ID"
fi

# -------------------------
# J) State file cleanup
# -------------------------
log "J) Limpiando state file"
rm -f "$STATE_FILE" || true
ok "State eliminado: $STATE_FILE"

echo ""
ok "Destroy db_deploy_pro_all.sh completado."