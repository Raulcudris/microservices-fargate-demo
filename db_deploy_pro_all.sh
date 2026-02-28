#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# db_deploy_pro_all.sh
# - VPC (2 pub, 2 priv) + IGW + NAT + RouteTables
# - SG ECS + SG DB (3306 ONLY from SG ECS)
# - RDS MySQL PRIVATE
# - ECS Cluster + IAM Exec Role + Logs
# - RunTask temporal para ejecutar script.sql SIN EXPONER RDS
#   (sube a S3 + presigned URL + curl dentro del task)
#
# Requisitos: aws, jq, curl
# ============================================================

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need jq; need curl

ENV_FILE="${ENV_FILE:-.env}"
[[ -f "$ENV_FILE" ]] || { echo "❌ No encuentro $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"
MODE_NO_NAT="${MODE_NO_NAT:-false}"

DB_IDENTIFIER="${DB_IDENTIFIER:-${PROJECT}-mysql-${ENV_NAME}}"
DB_ENGINE_VERSION="${DB_ENGINE_VERSION:-8.0.36}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
DB_ALLOCATED_STORAGE="${DB_ALLOCATED_STORAGE:-20}"
DB_STORAGE_TYPE="${DB_STORAGE_TYPE:-gp3}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-ecommerce_myshop}"
DB_USER="${DB_USER:-admin}"
DB_PASS="${DB_PASS:-}"

SQL_FILE="${SQL_FILE:-./script.sql}"
RUN_SQL_ECS="${RUN_SQL_ECS:-true}"

[[ -n "$DB_PASS" ]] || { echo "❌ DB_PASS vacío en .env"; exit 1; }

awsq(){ aws --region "$REGION" "$@"; }
log(){ echo -e "\n👉 $*"; }
ok(){ echo "✅ $*"; }
die(){ echo "❌ $*" >&2; exit 1; }

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
ok "Account: $ACCOUNT_ID"
ok "Region : $REGION"
ok "Project: $PROJECT"
ok "Env    : $ENV_NAME"

# ========= Networking defaults =========
VPC_CIDR="${VPC_CIDR:-10.20.0.0/16}"
PUB1_CIDR="${PUB1_CIDR:-10.20.1.0/24}"
PUB2_CIDR="${PUB2_CIDR:-10.20.2.0/24}"
PRI1_CIDR="${PRI1_CIDR:-10.20.11.0/24}"
PRI2_CIDR="${PRI2_CIDR:-10.20.12.0/24}"

STATE_FILE=".state_db_pro_${PROJECT}_${REGION}.json"
state_init(){ [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"; }
state_get(){ jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true; }
state_set(){ local k="$1" v="$2" tmp; tmp="$(mktemp)"; jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$STATE_FILE" > "$tmp"; mv "$tmp" "$STATE_FILE"; }
state_init

tag_spec(){
  local rtype="$1" name="$2"
  echo "ResourceType=${rtype},Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Env,Value=${ENV_NAME}}]"
}

ensure_sg(){
  local vpc_id="$1" sg_name="$2" desc="$3" state_key="$4"
  local sg_id
  sg_id="$(state_get "$state_key")"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(awsq ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$sg_name" \
      --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true)"
  fi
  if [[ -z "$sg_id" ]]; then
    sg_id="$(awsq ec2 create-security-group --vpc-id "$vpc_id" --group-name "$sg_name" --description "$desc" --query GroupId --output text)"
    awsq ec2 create-tags --resources "$sg_id" --tags \
      "Key=Name,Value=$sg_name" "Key=Project,Value=$PROJECT" "Key=Env,Value=$ENV_NAME" >/dev/null
  fi
  state_set "$state_key" "$sg_id"
  echo "$sg_id"
}

# -------------------------
# 1) VPC + IGW + Subnets + RTB
# -------------------------
log "1) VPC/Subnets/Routes"

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
else
  ok "IGW reusado: $IGW_ID"
fi
state_set IGW_ID "$IGW_ID"

AZ1="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
AZ2="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"

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

RTB_PUB_ID="$(state_get RTB_PUB_ID)"
if [[ -z "$RTB_PUB_ID" || "$RTB_PUB_ID" == "None" ]]; then
  RTB_PUB_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "${PROJECT}-public-rtb")" | jq -r '.RouteTable.RouteTableId')"
  ok "RTB pública: $RTB_PUB_ID"
fi
awsq ec2 create-route --route-table-id "$RTB_PUB_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB1_ID" >/dev/null 2>&1 || true
awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB2_ID" >/dev/null 2>&1 || true
state_set RTB_PUB_ID "$RTB_PUB_ID"

RTB_PRI_ID="$(state_get RTB_PRI_ID)"
if [[ -z "$RTB_PRI_ID" || "$RTB_PRI_ID" == "None" ]]; then
  RTB_PRI_ID="$(awsq ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag_spec route-table "${PROJECT}-private-rtb")" | jq -r '.RouteTable.RouteTableId')"
  ok "RTB privada: $RTB_PRI_ID"
fi
awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI1_ID" >/dev/null 2>&1 || true
awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI2_ID" >/dev/null 2>&1 || true
state_set RTB_PRI_ID "$RTB_PRI_ID"

# -------------------------
# 2) NAT (requerido para migrator)
# -------------------------
if [[ "$MODE_NO_NAT" == "true" ]]; then
  die "MODE_NO_NAT=true => NO recomendado para este flujo (el migrator necesita internet para dnf + curl + S3 presigned). Pon MODE_NO_NAT=false."
fi

log "2) NAT Gateway"
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
ok "Ruta privadas -> NAT OK"

# -------------------------
# 3) SG ECS + SG DB
# -------------------------
log "3) Security Groups"
SG_ECS_ID="$(ensure_sg "$VPC_ID" "${PROJECT}-sg-ecs" "ECS Tasks SG" "SG_ECS_ID")"
SG_DB_ID="$(ensure_sg "$VPC_ID" "${PROJECT}-sg-db-${ENV_NAME}" "RDS DB SG" "SG_DB_ID")"
ok "SG_ECS: $SG_ECS_ID"
ok "SG_DB : $SG_DB_ID"

awsq ec2 authorize-security-group-ingress --group-id "$SG_DB_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${DB_PORT},\"ToPort\":${DB_PORT},\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ECS_ID}\"}]}]" >/dev/null 2>&1 || true
ok "DB 3306 permitido SOLO desde SG_ECS"

# -------------------------
# 4) DB Subnet Group
# -------------------------
log "4) DB Subnet Group"
DB_SUBNET_GROUP="${PROJECT}-dbsubnet-${ENV_NAME}"
awsq rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1 || \
awsq rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "${PROJECT} private db subnet group" \
  --subnet-ids "$PRI1_ID" "$PRI2_ID" >/dev/null
ok "DB Subnet Group: $DB_SUBNET_GROUP"

# -------------------------
# 5) RDS MySQL PRIVADO
# -------------------------
log "5) RDS MySQL (private)"
EXISTS="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
  --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null | grep -v None || true)"

if [[ -z "$EXISTS" ]]; then
  awsq rds create-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --engine mysql --engine-version "$DB_ENGINE_VERSION" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --allocated-storage "$DB_ALLOCATED_STORAGE" \
    --storage-type "$DB_STORAGE_TYPE" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASS" \
    --db-name "$DB_NAME" \
    --vpc-security-group-ids "$SG_DB_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --port "$DB_PORT" \
    --tags "Key=Name,Value=${PROJECT}-rds-${ENV_NAME}" "Key=Project,Value=$PROJECT" "Key=Env,Value=$ENV_NAME" \
    >/dev/null
  ok "RDS en creación: $DB_IDENTIFIER"
else
  ok "RDS ya existe: $DB_IDENTIFIER"
fi

awsq rds wait db-instance-available --db-instance-identifier "$DB_IDENTIFIER"
DB_ENDPOINT="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].Endpoint.Address" --output text)"
ok "RDS listo: $DB_ENDPOINT:$DB_PORT / $DB_NAME"

state_set DB_IDENTIFIER "$DB_IDENTIFIER"
state_set DB_ENDPOINT "$DB_ENDPOINT"
state_set SG_ECS_ID "$SG_ECS_ID"
state_set SG_DB_ID "$SG_DB_ID"

# -------------------------
# 6) ECS Cluster + IAM Exec Role + Logs (para migrator)
# -------------------------
log "6) ECS bootstrap (cluster + role + logs)"
CLUSTER_NAME="${PROJECT}-dbops-cluster"
awsq ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null 2>&1 || true
ok "Cluster: $CLUSTER_NAME"

ROLE_NAME="${PROJECT}-dbops-exec-role"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ROLE_ARN="$(awsq iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
  ROLE_ARN="$(awsq iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" | jq -r '.Role.Arn')"
  awsq iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
  ok "Role creado: $ROLE_ARN"
else
  ok "Role reusado: $ROLE_ARN"
fi

LOG_GROUP="/ecs/${PROJECT}/db-migrator"
awsq logs create-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || true
ok "LogGroup: $LOG_GROUP"

# -------------------------
# 7) Subir SQL a S3 + presigned URL
# -------------------------
if [[ "$RUN_SQL_ECS" != "true" ]]; then
  echo ""
  ok "Deploy DB completado (sin ejecutar SQL)."
  echo "Endpoint: $DB_ENDPOINT:$DB_PORT / $DB_NAME"
  echo "State   : $STATE_FILE"
  exit 0
fi

[[ -f "$SQL_FILE" ]] || die "SQL_FILE no existe: $SQL_FILE"

log "7) S3: subiendo SQL para ejecución interna (presigned URL)"
BUCKET="${PROJECT}-${ENV_NAME}-dbops-${ACCOUNT_ID}-${REGION}"
KEY="sql/$(basename "$SQL_FILE")"

awsq s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || \
awsq s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null 2>&1 || true

awsq s3api put-bucket-tagging --bucket "$BUCKET" --tagging \
"TagSet=[{Key=Project,Value=${PROJECT}},{Key=Env,Value=${ENV_NAME}}]" >/dev/null 2>&1 || true

awsq s3 cp "$SQL_FILE" "s3://${BUCKET}/${KEY}" >/dev/null
PRESIGNED_URL="$(awsq s3 presign "s3://${BUCKET}/${KEY}" --expires-in 3600)"
ok "SQL subido: s3://${BUCKET}/${KEY}"
ok "Presigned URL generado (1h)"

# -------------------------
# 8) RunTask ECS (amazonlinux + mariadb client) y ejecuta SQL
# -------------------------
log "8) ECS RunTask: ejecutando SQL dentro de la VPC (sin exponer RDS)"
TASK_FAMILY="${PROJECT}-db-migrator"
IMAGE="public.ecr.aws/amazonlinux/amazonlinux:2023"

CMD=$(cat <<'EOF'
set -euo pipefail
echo "Installing mysql client..."
dnf -y install mariadb105 >/dev/null
echo "Downloading SQL..."
curl -fsSL "$PRESIGNED_URL" -o /tmp/script.sql
echo "Running SQL..."
mariadb -h "$DB_ENDPOINT" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < /tmp/script.sql
echo "DONE"
EOF
)

TASKDEF_ARN="$(awsq ecs register-task-definition \
  --family "$TASK_FAMILY" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "512" --memory "1024" \
  --execution-role-arn "$ROLE_ARN" \
  --container-definitions "[
    {
      \"name\":\"db-migrator\",
      \"image\":\"${IMAGE}\",
      \"essential\":true,
      \"command\":[\"bash\",\"-lc\",$(jq -Rsa . <<<"$CMD")],
      \"environment\":[
        {\"name\":\"DB_ENDPOINT\",\"value\":\"${DB_ENDPOINT}\"},
        {\"name\":\"DB_PORT\",\"value\":\"${DB_PORT}\"},
        {\"name\":\"DB_NAME\",\"value\":\"${DB_NAME}\"},
        {\"name\":\"DB_USER\",\"value\":\"${DB_USER}\"},
        {\"name\":\"DB_PASS\",\"value\":\"${DB_PASS}\"},
        {\"name\":\"PRESIGNED_URL\",\"value\":\"${PRESIGNED_URL}\"}
      ],
      \"logConfiguration\":{
        \"logDriver\":\"awslogs\",
        \"options\":{
          \"awslogs-group\":\"${LOG_GROUP}\",
          \"awslogs-region\":\"${REGION}\",
          \"awslogs-stream-prefix\":\"ecs\"
        }
      }
    }
  ]" | jq -r '.taskDefinition.taskDefinitionArn')"

ok "TaskDef: $TASKDEF_ARN"

NETCFG="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_ID],assignPublicIp=DISABLED}"

TASK_ARN="$(awsq ecs run-task \
  --cluster "$CLUSTER_NAME" \
  --launch-type FARGATE \
  --task-definition "$TASKDEF_ARN" \
  --network-configuration "$NETCFG" \
  --query "tasks[0].taskArn" --output text)"

ok "RunTask iniciado: $TASK_ARN"
log "Esperando a que termine (esto depende del tamaño del SQL)..."

# Espera simple por estado STOPPED
for _ in {1..120}; do
  ST="$(awsq ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --query "tasks[0].lastStatus" --output text 2>/dev/null || true)"
  [[ "$ST" == "STOPPED" ]] && break
  sleep 5
done

EXIT_CODE="$(awsq ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --query "tasks[0].containers[0].exitCode" --output text 2>/dev/null || echo "UNKNOWN")"
if [[ "$EXIT_CODE" == "0" ]]; then
  ok "SQL ejecutado correctamente (exitCode=0)"
else
  echo "⚠️ SQL task terminó con exitCode=$EXIT_CODE"
  echo "Revisa logs en CloudWatch: $LOG_GROUP"
fi

echo ""
ok "✅ DEPLOY DB + SQL COMPLETADO"
echo "Endpoint : $DB_ENDPOINT"
echo "Port     : $DB_PORT"
echo "DB Name  : $DB_NAME"
echo "User     : $DB_USER"
echo "Logs     : $LOG_GROUP"
echo "State    : $STATE_FILE"