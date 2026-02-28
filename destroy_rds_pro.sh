#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need jq

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

DB_IDENTIFIER="${DB_IDENTIFIER:-${PROJECT}-mysql-${ENV_NAME}}"
DB_PORT="${DB_PORT:-3306}"

STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"
awsq(){ aws --region "$REGION" "$@"; }
state_get(){ jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true; }

log(){ echo "👉 $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️ $*" >&2; }

[[ -f "$STATE_FILE" ]] || { echo "❌ No existe $STATE_FILE. No tengo de dónde leer VPC/Subnets/SG_ECS."; exit 1; }

VPC_ID="$(state_get VPC_ID)"
SG_ECS_ID="$(state_get SG_ECS_ID)"

DB_SUBNET_GROUP="${PROJECT}-dbsubnet-${ENV_NAME}"
DB_SG_NAME="${PROJECT}-sg-db-${ENV_NAME}"

log "Destroy RDS stack (deploy_rds_pro.sh)"
ok "REGION=$REGION PROJECT=$PROJECT ENV=$ENV_NAME DB_IDENTIFIER=$DB_IDENTIFIER"

# 1) Delete DB instance (no snapshot)
EXISTS_DB="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
  --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null | grep -v None || true)"

if [[ -n "$EXISTS_DB" ]]; then
  log "1) Eliminando RDS instance: $DB_IDENTIFIER (skip final snapshot)"
  awsq rds delete-db-instance --db-instance-identifier "$DB_IDENTIFIER" --skip-final-snapshot >/dev/null
  log "   Esperando a que se elimine..."
  awsq rds wait db-instance-deleted --db-instance-identifier "$DB_IDENTIFIER"
  ok "RDS eliminado: $DB_IDENTIFIER"
else
  ok "RDS no existe: $DB_IDENTIFIER"
fi

# 2) Delete DB subnet group
EXISTS_SUBNET_GRP="$(awsq rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --query "DBSubnetGroups[0].DBSubnetGroupName" --output text 2>/dev/null | grep -v None || true)"

if [[ -n "$EXISTS_SUBNET_GRP" ]]; then
  log "2) Eliminando DB Subnet Group: $DB_SUBNET_GROUP"
  awsq rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null
  ok "DB Subnet Group eliminado"
else
  ok "DB Subnet Group no existe: $DB_SUBNET_GROUP"
fi

# 3) Delete DB security group (created by deploy_rds_pro.sh)
DB_SG_ID="$(awsq ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$DB_SG_NAME" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true)"

if [[ -n "$DB_SG_ID" ]]; then
  log "3) Eliminando SG DB: $DB_SG_NAME ($DB_SG_ID)"
  # puede fallar si está en uso; si es así, avisa.
  if ! awsq ec2 delete-security-group --group-id "$DB_SG_ID" >/dev/null 2>&1; then
    warn "No pude borrar SG DB ($DB_SG_ID). ¿Está en uso por otra cosa? Intenta luego."
  else
    ok "SG DB eliminado"
  fi
else
  ok "SG DB no existe: $DB_SG_NAME"
fi

echo ""
ok "Destroy deploy_rds_pro.sh completado."