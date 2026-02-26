#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy_all.sh - Orquestador PRO
# 1) Deploy infraestructura + ECS (deploy.sh)
# 2) (Opcional) Abrir RDS pública solo para tu IP y ejecutar SQL
# 3) (Opcional) Cerrar acceso público (revocar IP y opcional no-public)
# 4) Validaciones: ALB health + ECS services status
#
# Requiere: deploy.sh, rds_public_sql.sh, rds_close_public.sh
# ============================================================

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need bash
need jq
need curl
need aws

ENV_FILE="${ENV_FILE:-.env}"
[[ -f "$ENV_FILE" ]] || { echo "❌ No encuentro $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# Flags (puedes setearlos en .env)
RUN_SQL_BOOTSTRAP="${RUN_SQL_BOOTSTRAP:-false}"     # true/false
SQL_FILE="${SQL_FILE:-./script.sql}"               # ruta sql
DB_IDENTIFIER="${DB_IDENTIFIER:-}"                 # si no lo pones, intenta inferirlo
AUTO_CLOSE_DB_PUBLIC="${AUTO_CLOSE_DB_PUBLIC:-true}" # true/false
MAKE_PRIVATE_AFTER_SQL="${MAKE_PRIVATE_AFTER_SQL:-false}" # true => marca RDS no-public

awsq(){ aws --region "$REGION" "$@"; }

state_get(){
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true
}

banner(){
  echo ""
  echo "============================================================"
  echo "🚀  $*"
  echo "============================================================"
  echo ""
}

die(){ echo "❌ $*" >&2; exit 1; }

# -------------------------
# 0) Validaciones básicas
# -------------------------
[[ -x "./deploy.sh" ]] || die "No encuentro ./deploy.sh (o no es ejecutable). Ejecuta: chmod +x deploy.sh"
[[ -x "./rds_public_sql.sh" ]] || echo "⚠️ No encuentro ./rds_public_sql.sh (SQL bootstrap se omitirá si falta)."
[[ -x "./rds_close_public.sh" ]] || echo "⚠️ No encuentro ./rds_close_public.sh (cierre público se omitirá si falta)."

# -------------------------
# 1) Deploy principal
# -------------------------
banner "Paso 1: Deploy Infra + ECS"
./deploy.sh

[[ -f "$STATE_FILE" ]] || die "No se generó el state file: $STATE_FILE"

ALB_DNS="$(state_get ALB_DNS)"
HEALTH_PATH_GATEWAY="${HEALTH_PATH_GATEWAY:-/actuator/health}"
ALB_URL="http://${ALB_DNS}"

echo "✅ ALB: ${ALB_URL}"
echo "✅ Health endpoint: ${ALB_URL}${HEALTH_PATH_GATEWAY}"

# -------------------------
# 2) SQL Bootstrap (opcional)
# -------------------------
if [[ "$RUN_SQL_BOOTSTRAP" == "true" ]]; then
  banner "Paso 2: SQL Bootstrap (RDS pública temporal por IP + ejecutar .sql)"

  [[ -x "./rds_public_sql.sh" ]] || die "RUN_SQL_BOOTSTRAP=true pero falta ./rds_public_sql.sh"

  # Inferir DB_IDENTIFIER si no vino
  if [[ -z "${DB_IDENTIFIER:-}" ]]; then
    # Si tú lo manejas en .env como microservices-fargate-mysql-free, ponlo ahí.
    # Aquí intentamos usar el nombre del endpoint si está en env, o fallamos.
    if [[ -n "${DB_ENDPOINT:-}" ]]; then
      # intenta obtener identifier listando instancias y matcheando endpoint
      DB_IDENTIFIER="$(awsq rds describe-db-instances --query "DBInstances[?Endpoint.Address=='${DB_ENDPOINT}'].DBInstanceIdentifier | [0]" --output text 2>/dev/null | grep -v None || true)"
    fi
  fi

  [[ -n "${DB_IDENTIFIER:-}" ]] || die "No tengo DB_IDENTIFIER. Defínelo en .env (ej: microservices-fargate-mysql-free)"

  [[ -n "${DB_PASS:-}" ]] || die "DB_PASS vacío. Ponlo en tu .env o exporta DB_PASS antes."
  [[ -f "$SQL_FILE" ]] || die "SQL_FILE no existe: $SQL_FILE"

  DB_IDENTIFIER="$DB_IDENTIFIER" DB_PASS="$DB_PASS" SQL_FILE="$SQL_FILE" ./rds_public_sql.sh

  # -------------------------
  # 3) Cerrar acceso público (opcional)
  # -------------------------
  if [[ "$AUTO_CLOSE_DB_PUBLIC" == "true" ]]; then
    banner "Paso 3: Cerrar acceso público (revocar IP)"
    [[ -x "./rds_close_public.sh" ]] || die "AUTO_CLOSE_DB_PUBLIC=true pero falta ./rds_close_public.sh"
    DB_IDENTIFIER="$DB_IDENTIFIER" MAKE_PRIVATE="$MAKE_PRIVATE_AFTER_SQL" ./rds_close_public.sh
  else
    echo "⚠️ AUTO_CLOSE_DB_PUBLIC=false. Recuerda cerrar la IP luego."
  fi
else
  echo "ℹ️ RUN_SQL_BOOTSTRAP=false. Omitiendo SQL bootstrap."
fi

# -------------------------
# 4) Validaciones finales
# -------------------------
banner "Paso 4: Validación final (Health + ECS Services)"

# Health check
if [[ -n "${ALB_DNS:-}" && "$ALB_DNS" != "null" ]]; then
  echo "👉 Probando health: ${ALB_URL}${HEALTH_PATH_GATEWAY}"
  set +e
  curl -fsS "${ALB_URL}${HEALTH_PATH_GATEWAY}" >/dev/null
  HRC=$?
  set -e
  if [[ $HRC -eq 0 ]]; then
    echo "✅ Health OK"
  else
    echo "⚠️ Health no respondió OK aún. Revisa logs en CloudWatch y estado de target group."
  fi
else
  echo "⚠️ No pude leer ALB_DNS desde state."
fi

# ECS services status
CLUSTER_NAME="${PROJECT}-cluster"
echo ""
echo "👉 Estado servicios ECS (cluster: $CLUSTER_NAME)"
awsq ecs list-services --cluster "$CLUSTER_NAME" --query "serviceArns[]" --output text | tr '\t' '\n' | while read -r arn; do
  [[ -z "$arn" ]] && continue
  svc="$(basename "$arn")"
  status="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" --query "services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}" --output json)"
  echo "• $svc => $status"
done

banner "FIN ✅"
echo "URL: ${ALB_URL}"
echo "Health: ${ALB_URL}${HEALTH_PATH_GATEWAY}"
echo "State: ${STATE_FILE}"