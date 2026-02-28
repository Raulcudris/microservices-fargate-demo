#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need jq

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

DB_IDENTIFIER="${DB_IDENTIFIER:-${PROJECT}-mysql-${ENV_NAME}}"
DB_ENGINE_VERSION="${DB_ENGINE_VERSION:-8.0}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
DB_ALLOCATED_STORAGE="${DB_ALLOCATED_STORAGE:-20}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-ecommerce_myshop}"
DB_USER="${DB_USER:-admin}"
DB_PASS="${DB_PASS:-}"

STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"
awsq(){ aws --region "$REGION" "$@"; }
state_get(){ jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true; }
die(){ echo "❌ $*" >&2; exit 1; }

[[ -f "$STATE_FILE" ]] || die "No existe $STATE_FILE. Ejecuta antes ./deploy.sh (red/sg)."
[[ -n "$DB_PASS" ]] || die "DB_PASS vacío. Pásalo así: DB_PASS='...' ./deploy_rds_pro.sh"

VPC_ID="$(state_get VPC_ID)"
PRI1_ID="$(state_get PRI1_ID)"
PRI2_ID="$(state_get PRI2_ID)"
SG_ECS_ID="$(state_get SG_ECS_ID)"
[[ -n "$VPC_ID" && -n "$PRI1_ID" && -n "$PRI2_ID" && -n "$SG_ECS_ID" ]] || die "Faltan VPC/Subnets/SG_ECS_ID en state."

DB_SUBNET_GROUP="${PROJECT}-dbsubnet-${ENV_NAME}"
DB_SG_NAME="${PROJECT}-sg-db-${ENV_NAME}"

echo "👉 1) DB Subnet Group (privadas)..."
awsq rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1 || \
awsq rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "${PROJECT} private db subnet group" \
  --subnet-ids "$PRI1_ID" "$PRI2_ID" >/dev/null

echo "👉 2) SG DB (3306 solo desde SG ECS)..."
DB_SG_ID="$(awsq ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$DB_SG_NAME" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true)"
if [[ -z "$DB_SG_ID" ]]; then
  DB_SG_ID="$(awsq ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$DB_SG_NAME" --description "DB SG" --query GroupId --output text)"
fi

awsq ec2 authorize-security-group-ingress --group-id "$DB_SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${DB_PORT},\"ToPort\":${DB_PORT},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_ID}\"}]}]" >/dev/null 2>&1 || true

echo "👉 3) Crear RDS privado..."
EXISTS="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null | grep -v None || true)"
if [[ -z "$EXISTS" ]]; then
  awsq rds create-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --engine mysql --engine-version "$DB_ENGINE_VERSION" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --allocated-storage "$DB_ALLOCATED_STORAGE" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASS" \
    --db-name "$DB_NAME" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --backup-retention-period 0 \
    --no-publicly-accessible \
    --port "$DB_PORT" >/dev/null
fi

awsq rds wait db-instance-available --db-instance-identifier "$DB_IDENTIFIER"
ENDPOINT="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].Endpoint.Address" --output text)"
echo "✅ RDS privado listo: $ENDPOINT:${DB_PORT} / $DB_NAME"