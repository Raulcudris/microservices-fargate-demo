#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# QUICK REDEPLOY - Reinicio rápido de servicios
# Uso: ./quick-redeploy.sh [servicio1 servicio2 ...]
# ============================================================

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

ENV_FILE="${ENV_FILE:-.env}"
REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
CLUSTER_NAME="${PROJECT}-cluster"
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

awsq() { aws --region "$REGION" "$@"; }

# Cargar variables
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# Función para reiniciar servicio
redeploy_service() {
  local service="$1"
  echo -e "${YELLOW}🔄 Reiniciando $service...${NC}"
  
  # Obtener última task definition
  local family
  case "$service" in
    configservice) family="${PROJECT}-td-config" ;;
    eurekaservice) family="${PROJECT}-td-eureka" ;;
    gatewayservice) family="${PROJECT}-td-gateway" ;;
    productservice) family="${PROJECT}-td-products" ;;
    orderservice) family="${PROJECT}-td-orders" ;;
    paymentservice) family="${PROJECT}-td-pay" ;;
    userservice) family="${PROJECT}-td-users" ;;
    *) echo -e "${RED}Servicio desconocido: $service${NC}"; return 1 ;;
  esac
  
  local latest_td
  latest_td="$(awsq ecs list-task-definitions --family-prefix "$family" --sort DESC --max-items 1 --query "taskDefinitionArns[0]" --output text)"
  
  if [[ -z "$latest_td" || "$latest_td" == "None" ]]; then
    echo -e "${RED}No se encuentra task definition para $service${NC}"
    return 1
  fi
  
  # Forzar deployment
  awsq ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$service" \
    --task-definition "$latest_td" \
    --force-new-deployment \
    --desired-count 1 >/dev/null
  
  echo -e "${GREEN}✅ Deployment iniciado para $service con TD: $latest_td${NC}"
  
  # Esperar estabilidad (opcional)
  if [[ "${WAIT:-false}" == "true" ]]; then
    echo "Esperando que $service esté estable..."
    awsq ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$service"
    echo -e "${GREEN}✅ $service estable${NC}"
  fi
}

# Main
if [[ $# -eq 0 ]]; then
  # Si no hay argumentos, reiniciar todos
  SERVICES=("configservice" "eurekaservice" "productservice" "orderservice" "paymentservice" "userservice" "gatewayservice")
  echo "🔄 Reiniciando TODOS los servicios..."
  for svc in "${SERVICES[@]}"; do
    redeploy_service "$svc"
    sleep 5
  done
else
  # Reiniciar servicios específicos
  for svc in "$@"; do
    redeploy_service "$svc"
  done
fi

echo -e "${GREEN}✅ Proceso completado${NC}"