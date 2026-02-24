#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
STATE_FILE="${STATE_FILE:-.deploy_state.microservices-fargate.us-east-1.json}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws
need jq
need awk
need tr

# ---- helpers limpieza ----
clean() {
  # elimina \r \n \t y cualquier control char ASCII (0-31, 127)
  # y recorta espacios extremos
  printf '%s' "$1" \
    | tr -d '\r\n\t' \
    | tr -d '[:cntrl:]' \
    | awk '{$1=$1;print}'
}

# ---- Cargar .env ----
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "❌ No encuentro $ENV_FILE"
  exit 1
fi

# ---- Sanitizar variables críticas ----
REGION="$(clean "${REGION:-}")"
PROJECT="$(clean "${PROJECT:-}")"
DB_NAME="$(clean "${DB_NAME:-}")"
DB_USER="$(clean "${DB_USER:-}")"
DB_PASS="$(clean "${DB_PASS:-}")"

: "${REGION:?Falta REGION}"
: "${PROJECT:?Falta PROJECT}"
: "${DB_NAME:?Falta DB_NAME}"
: "${DB_USER:?Falta DB_USER}"
: "${DB_PASS:?Falta DB_PASS}"

DB_INSTANCE_ID="$(clean "${DB_INSTANCE_ID:-${PROJECT}-mysql-free}")"
DB_SUBNET_GROUP="$(clean "${DB_SUBNET_GROUP:-${PROJECT}-db-subnets}")"

SG_RDS_NAME="$(clean "${SG_RDS_NAME:-${PROJECT}-sg-rds}")"
SG_ECS_PRIVATE_NAME="$(clean "${SG_ECS_PRIVATE_NAME:-${PROJECT}-sg-ecs-private}")"

DB_ALLOCATED_STORAGE="$(clean "${DB_ALLOCATED_STORAGE:-20}")"
DB_STORAGE_TYPE="$(clean "${DB_STORAGE_TYPE:-gp2}")"
DB_ENGINE="$(clean "${DB_ENGINE:-mysql}")"
DB_PUBLIC="$(clean "${DB_PUBLIC:-false}")"

awsq() { aws --region "$REGION" "$@"; }

# ---- Leer IDs desde STATE_FILE ----
[[ -f "$STATE_FILE" ]] || { echo "❌ No encuentro STATE_FILE: $STATE_FILE"; exit 1; }

VPC_ID="$(jq -r '.VPC_ID // empty' "$STATE_FILE")"
PRI1_ID="$(jq -r '.PRI1_ID // empty' "$STATE_FILE")"
PRI2_ID="$(jq -r '.PRI2_ID // empty' "$STATE_FILE")"

VPC_ID="$(clean "$VPC_ID")"
PRI1_ID="$(clean "$PRI1_ID")"
PRI2_ID="$(clean "$PRI2_ID")"

[[ -n "$VPC_ID" && -n "$PRI1_ID" && -n "$PRI2_ID" ]] || {
  echo "❌ STATE_FILE no tiene VPC_ID/PRI1_ID/PRI2_ID"
  exit 1
}

# ---- Helpers SG ----
find_sg_by_group_name() {
  local sg_name="$1"
  awsq ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg_name" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v "None" || true
}
find_sg_by_tag_name() {
  local tag_name="$1"
  awsq ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$tag_name" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v "None" || true
}
create_sg_if_missing() {
  local sg_name="$1"
  local desc="$2"
  local sg_id
  sg_id="$(find_sg_by_group_name "$sg_name")"
  [[ -z "$sg_id" ]] && sg_id="$(find_sg_by_tag_name "$sg_name")"
  if [[ -n "$sg_id" ]]; then echo "$sg_id"; return 0; fi

  echo "👉 SG no existe, creando: $sg_name"
  sg_id="$(awsq ec2 create-security-group \
    --vpc-id "$VPC_ID" \
    --group-name "$sg_name" \
    --description "$desc" \
    --query "GroupId" --output text)"

  awsq ec2 create-tags --resources "$sg_id" \
    --tags "Key=Name,Value=$sg_name" "Key=Project,Value=$PROJECT" >/dev/null
  echo "✅ SG creado: $sg_name -> $sg_id"
  echo "$sg_id"
}

# ---- Resolver SG ECS private ----
SG_ECS_PRIVATE_ID="$(find_sg_by_group_name "$SG_ECS_PRIVATE_NAME")"
[[ -z "$SG_ECS_PRIVATE_ID" ]] && SG_ECS_PRIVATE_ID="$(find_sg_by_tag_name "$SG_ECS_PRIVATE_NAME")"
SG_ECS_PRIVATE_ID="$(clean "$SG_ECS_PRIVATE_ID")"
[[ -n "$SG_ECS_PRIVATE_ID" ]] || { echo "❌ No pude resolver SG ECS private"; exit 1; }

# ---- Resolver/crear SG RDS ----
SG_RDS_ID="$(create_sg_if_missing "$SG_RDS_NAME" "RDS MySQL SG for ${PROJECT}")"
SG_RDS_ID="$(clean "$SG_RDS_ID")"
[[ -n "$SG_RDS_ID" ]] || { echo "❌ No pude resolver/crear SG RDS"; exit 1; }

# ---- Regla SG 3306 ----
awsq ec2 authorize-security-group-ingress --group-id "$SG_RDS_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_PRIVATE_ID}\"}]}]" \
  >/dev/null 2>&1 || true
echo "✅ SG RDS permite 3306 desde ECS private"

# ---- DB Subnet Group ----
awsq rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Private subnets for RDS (${PROJECT})" \
  --subnet-ids "$PRI1_ID" "$PRI2_ID" >/dev/null 2>&1 || true
echo "✅ DB Subnet Group listo: $DB_SUBNET_GROUP"

# ---- Clase free tier friendly ----
pick_instance_class() {
  local candidates=("db.t3.micro" "db.t4g.micro")
  for c in "${candidates[@]}"; do
    if awsq rds describe-orderable-db-instance-options \
      --engine "$DB_ENGINE" --db-instance-class "$c" \
      --query "OrderableDBInstanceOptions[0].DBInstanceClass" --output text 2>/dev/null | grep -q "$c"; then
      echo "$c"; return 0
    fi
  done
  echo "db.t3.micro"
}
DB_INSTANCE_CLASS="$(clean "$(pick_instance_class)")"
echo "✅ Clase elegida: $DB_INSTANCE_CLASS"

DB_ENGINE_VERSION="$(awsq rds describe-db-engine-versions \
  --engine "$DB_ENGINE" --default-only \
  --query "DBEngineVersions[0].EngineVersion" --output text)"
DB_ENGINE_VERSION="$(clean "$DB_ENGINE_VERSION")"
[[ -n "$DB_ENGINE_VERSION" && "$DB_ENGINE_VERSION" != "None" ]] || { echo "❌ No pude resolver EngineVersion"; exit 1; }

# ---- Crear RDS ----
if ! awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  echo "👉 Creando RDS (privado)..."

  CREATE_ARGS=(
    rds create-db-instance
    --db-instance-identifier "$DB_INSTANCE_ID"
    --db-instance-class "$DB_INSTANCE_CLASS"
    --engine "$DB_ENGINE"
    --engine-version "$DB_ENGINE_VERSION"
    --allocated-storage "$DB_ALLOCATED_STORAGE"
    --storage-type "$DB_STORAGE_TYPE"
    --master-username "$DB_USER"
    --master-user-password "$DB_PASS"
    --db-name "$DB_NAME"
    --vpc-security-group-ids "$SG_RDS_ID"
    --db-subnet-group-name "$DB_SUBNET_GROUP"
    --backup-retention-period 0
    --no-multi-az
    --no-enable-performance-insights
    --tags "Key=Name,Value=${DB_INSTANCE_ID}" "Key=Project,Value=${PROJECT}"
  )

  if [[ "$DB_PUBLIC" == "true" ]]; then
    CREATE_ARGS+=(--publicly-accessible)
  else
    CREATE_ARGS+=(--no-publicly-accessible)
  fi

  awsq "${CREATE_ARGS[@]}" >/dev/null
  echo "✅ RDS creado: $DB_INSTANCE_ID"
else
  echo "✅ RDS ya existe: $DB_INSTANCE_ID"
fi

echo "👉 Esperando RDS disponible..."
awsq rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
echo "✅ RDS disponible"

DB_ENDPOINT_NEW="$(awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query "DBInstances[0].Endpoint.Address" --output text)"
DB_PORT_NEW="$(awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query "DBInstances[0].Endpoint.Port" --output text)"
DB_ENDPOINT_NEW="$(clean "$DB_ENDPOINT_NEW")"
DB_PORT_NEW="$(clean "$DB_PORT_NEW")"

echo "✅ Endpoint: ${DB_ENDPOINT_NEW}:${DB_PORT_NEW}"

tmp_env="$(mktemp)"
awk -v ep="$DB_ENDPOINT_NEW" -v port="$DB_PORT_NEW" '
  BEGIN{foundEP=0; foundPORT=0; foundCR=0}
  /^export CREATE_RDS=/ {print "export CREATE_RDS=\"true\""; foundCR=1; next}
  /^export DB_ENDPOINT=/ {print "export DB_ENDPOINT=\"" ep "\""; foundEP=1; next}
  /^export DB_PORT=/ {print "export DB_PORT=\"" port "\""; foundPORT=1; next}
  {print}
  END{
    if(!foundCR)  print "export CREATE_RDS=\"true\""
    if(!foundEP)  print "export DB_ENDPOINT=\"" ep "\""
    if(!foundPORT)print "export DB_PORT=\"" port "\""
  }
' "$ENV_FILE" > "$tmp_env"
mv "$tmp_env" "$ENV_FILE"

echo ""
echo "✅ .env actualizado:"
echo "   CREATE_RDS=true"
echo "   DB_ENDPOINT=${DB_ENDPOINT_NEW}"
echo "   DB_PORT=${DB_PORT_NEW}"