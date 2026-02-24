#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
SQL_FILE="${SQL_FILE:-schema.sql}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws
need jq
need base64
need tr
need awk

clean() {
  printf '%s' "$1" | tr -d '\r\n\t' | tr -d '[:cntrl:]' | awk '{$1=$1;print}'
}

# ---- Load env ----
[[ -f "$ENV_FILE" ]] || { echo "❌ No existe $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

REGION="$(clean "${REGION:-}")"
PROJECT="$(clean "${PROJECT:-}")"
DB_ENDPOINT="$(clean "${DB_ENDPOINT:-}")"
DB_PORT="$(clean "${DB_PORT:-3306}")"
DB_NAME="$(clean "${DB_NAME:-}")"
DB_USER="$(clean "${DB_USER:-}")"
DB_PASS="$(clean "${DB_PASS:-}")"

: "${REGION:?}"
: "${PROJECT:?}"
: "${DB_ENDPOINT:?}"
: "${DB_NAME:?}"
: "${DB_USER:?}"
: "${DB_PASS:?}"

[[ -f "$SQL_FILE" ]] || { echo "❌ No existe $SQL_FILE"; exit 1; }

STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"
[[ -f "$STATE_FILE" ]] || { echo "❌ No existe $STATE_FILE"; exit 1; }

awsq() { aws --region "$REGION" "$@"; }

PRI1_ID="$(clean "$(jq -r '.PRI1_ID // empty' "$STATE_FILE")")"
PRI2_ID="$(clean "$(jq -r '.PRI2_ID // empty' "$STATE_FILE")")"
SG_ECS_PRIVATE_ID="$(clean "$(jq -r '.SG_ECS_PRIVATE_ID // empty' "$STATE_FILE")")"
ROLE_ARN="$(clean "$(jq -r '.ROLE_ARN // empty' "$STATE_FILE")")"

[[ -n "$PRI1_ID" && -n "$PRI2_ID" && -n "$SG_ECS_PRIVATE_ID" && -n "$ROLE_ARN" ]] || {
  echo "❌ Faltan PRI1_ID/PRI2_ID/SG_ECS_PRIVATE_ID/ROLE_ARN en $STATE_FILE"
  exit 1
}

CLUSTER="${PROJECT}-cluster"
TASK_FAMILY="${PROJECT}-db-seed-runner"

# RESET_DB=true -> DROP DATABASE antes de ejecutar
RESET_DB="$(clean "${RESET_DB:-false}")"

# ✅ Convertir SQL a base64 (1 sola línea)
SQL_B64="$(base64 < "$SQL_FILE" | tr -d '\n')"

# Prefijo opcional para reset
RESET_SQL=""
if [[ "$RESET_DB" == "true" ]]; then
  RESET_SQL="DROP DATABASE IF EXISTS \`${DB_NAME}\`; "
fi

echo "👉 Registrando task definition (mysql:8) para ejecutar schema via base64..."
awsq ecs register-task-definition \
  --family "$TASK_FAMILY" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "512" \
  --memory "1024" \
  --execution-role-arn "$ROLE_ARN" \
  --container-definitions "$(jq -nc \
    --arg host "$DB_ENDPOINT" \
    --arg port "$DB_PORT" \
    --arg user "$DB_USER" \
    --arg pass "$DB_PASS" \
    --arg db "$DB_NAME" \
    --arg sqlb64 "$SQL_B64" \
    --arg resetsql "$RESET_SQL" \
    '[
      {
        name: "runner",
        image: "mysql:8",
        essential: true,
        command: [
          "sh","-lc",
          (
            "set -e; " +
            "echo " + $sqlb64 + " | base64 -d > /tmp/schema.sql; " +
            "mysql --protocol=tcp -h " + $host + " -P " + $port + " -u " + $user + " -p" + $pass + " -e \"" + $resetsql + "SELECT 1;\"; " +
            "mysql --protocol=tcp -h " + $host + " -P " + $port + " -u " + $user + " -p" + $pass + " < /tmp/schema.sql; " +
            "echo DONE"
          )
        ]
      }
    ]')" >/dev/null

echo "👉 Ejecutando task dentro de subnets privadas..."
TASK_ARN="$(awsq ecs run-task \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$TASK_FAMILY" \
  --network-configuration "awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_PRIVATE_ID],assignPublicIp=DISABLED}" \
  --query "tasks[0].taskArn" --output text)"

echo "✅ Task lanzada: $TASK_ARN"
echo "👉 Esperando a que termine..."
awsq ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN"
echo "✅ Terminado."
echo ""
echo "👉 Si falla: revisa logs del task en ECS/CloudWatch."