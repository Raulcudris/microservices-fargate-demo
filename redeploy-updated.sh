#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# DEPLOY Y REINICIO COMBINADO
# - Ejecuta el deploy script (solo si hay cambios en infra)
# - Detecta cambios en task definitions
# - Reinicia servicios con nuevas versiones
# - Modo "watch" para desarrollo continuo
# ============================================================

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# Configuración
ENV_FILE="${ENV_FILE:-.env}"
REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
CLUSTER_NAME="${PROJECT}-cluster"
DEPLOY_SCRIPT="./deploy.sh"  # Tu script original de deploy
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Servicios en orden de dependencia
SERVICES=(
  "configservice"
  "eurekaservice"
  "productservice"
  "orderservice"
  "paymentservice"
  "userservice"
  "gatewayservice"
)

# Mapeo de servicios a familias de task definitions
declare -A FAMILY_MAP=(
  ["configservice"]="${PROJECT}-td-config"
  ["eurekaservice"]="${PROJECT}-td-eureka"
  ["productservice"]="${PROJECT}-td-products"
  ["orderservice"]="${PROJECT}-td-orders"
  ["paymentservice"]="${PROJECT}-td-pay"
  ["userservice"]="${PROJECT}-td-users"
  ["gatewayservice"]="${PROJECT}-td-gateway"
)

# Funciones helper
log() { echo -e "${BLUE}👉 $*${NC}" >&2; }
ok()  { echo -e "${GREEN}✅ $*${NC}" >&2; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}" >&2; }
error(){ echo -e "${RED}❌ $*${NC}" >&2; }
step(){ echo -e "${PURPLE}📦 $*${NC}" >&2; }

awsq() { aws --region "$REGION" "$@"; }

# Verificar prerequisitos
check_prerequisites() {
  need() { command -v "$1" >/dev/null 2>&1 || { error "Falta '$1'"; exit 1; }; }
  need aws
  need docker
  need jq
  need curl
}

# Cargar configuración
load_config() {
  if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
  fi
}

# Obtener última task definition registrada
get_latest_task_definition() {
  local family="$1"
  awsq ecs list-task-definitions --family-prefix "$family" --sort DESC --max-items 1 \
    --query "taskDefinitionArns[0]" --output text 2>/dev/null | grep -v "None" || true
}

# Obtener task definition actual de un servicio
get_current_task_definition() {
  local service="$1"
  awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$service" \
    --query "services[0].taskDefinition" --output text 2>/dev/null | grep -v "None" || true
}

# Verificar si un servicio necesita actualización
needs_update() {
  local service="$1"
  local family="${FAMILY_MAP[$service]}"
  
  if [[ -z "$family" ]]; then
    return 1
  fi
  
  local current_td
  current_td="$(get_current_task_definition "$service")"
  
  if [[ -z "$current_td" ]]; then
    # Servicio no existe, necesita creación
    echo "new"
    return 0
  fi
  
  local latest_td
  latest_td="$(get_latest_task_definition "$family")"
  
  if [[ -z "$latest_td" ]]; then
    return 1
  fi
  
  if [[ "$current_td" != "$latest_td" ]]; then
    echo "$latest_td"
    return 0
  fi
  
  return 1
}

# Esperar a que el servicio esté estable
wait_for_service_stable() {
  local service="$1"
  local timeout=300
  local interval=10
  local elapsed=0
  
  log "Esperando que $service esté estable..."
  
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$service" \
      --query "services[0].deployments[?status=='PRIMARY'].rolloutState" --output text 2>/dev/null || true)"
    
    if [[ "$status" == "COMPLETED" ]]; then
      ok "$service está estable"
      return 0
    elif [[ "$status" == "FAILED" ]]; then
      error "Deployment falló para $service"
      # Mostrar logs de error
      show_service_logs "$service" 5
      return 1
    fi
    
    sleep $interval
    elapsed=$((elapsed + interval))
    echo -n "."
  done
  
  echo ""
  warn "Timeout esperando que $service esté estable"
  return 1
}

# Mostrar últimos logs de un servicio
show_service_logs() {
  local service="$1"
  local lines="${2:-20}"
  local log_group="/ecs/${PROJECT}/${service/configservice/config}"
  log_group="${log_group/config/config}"
  
  local log_stream
  log_stream="$(awsq logs describe-log-streams \
    --log-group-name "$log_group" \
    --order-by LastEventTime \
    --descending \
    --limit 1 \
    --query 'logStreams[0].logStreamName' \
    --output text 2>/dev/null || true)"
  
  if [[ -n "$log_stream" && "$log_stream" != "None" ]]; then
    echo -e "${YELLOW}Últimos $lines logs de $service:${NC}"
    awsq logs get-log-events \
      --log-group-name "$log_group" \
      --log-stream-name "$log_stream" \
      --limit "$lines" \
      --query 'events[*].message' \
      --output text | while read -r line; do
        echo "  $line"
      done
  fi
}

# Verificar health del gateway
check_gateway_health() {
  local alb_dns
  alb_dns="$(jq -r '.ALB_DNS // empty' "$STATE_FILE" 2>/dev/null || true)"
  
  if [[ -z "$alb_dns" ]]; then
    # Intentar obtener del deploy script
    alb_dns="$(awsq elbv2 describe-load-balancers --names "msf-alb" --query "LoadBalancers[0].DNSName" --output text 2>/dev/null || true)"
  fi
  
  if [[ -z "$alb_dns" || "$alb_dns" == "None" ]]; then
    warn "No se encuentra ALB DNS"
    return 1
  fi
  
  log "Verificando health endpoint: http://${alb_dns}/actuator/health"
  
  local http_code
  http_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${alb_dns}/actuator/health" 2>/dev/null || echo "000")"
  
  if [[ "$http_code" == "200" ]]; then
    ok "Gateway health check: OK (200)"
    return 0
  else
    warn "Gateway health check: $http_code"
    return 1
  fi
}

# Ejecutar deploy script si es necesario
run_deploy_if_needed() {
  local force="$1"
  
  if [[ "$force" == "true" ]]; then
    step "Forzando ejecución del deploy script..."
    "$DEPLOY_SCRIPT"
    return $?
  fi
  
  # Verificar si el state file existe
  if [[ ! -f "$STATE_FILE" ]]; then
    step "Primera ejecución, corriendo deploy completo..."
    "$DEPLOY_SCRIPT"
    return $?
  fi
  
  # Verificar cambios en el script de deploy
  local deploy_script_mtime
  local state_file_mtime
  deploy_script_mtime="$(stat -c %Y "$DEPLOY_SCRIPT" 2>/dev/null || echo 0)"
  state_file_mtime="$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)"
  
  if [[ $deploy_script_mtime -gt $state_file_mtime ]]; then
    step "El script de deploy ha cambiado, ejecutando..."
    "$DEPLOY_SCRIPT"
    return $?
  fi
  
  log "No hay cambios en el script de deploy, saltando..."
  return 0
}

# Reiniciar servicios específicos
redeploy_services() {
  local services_to_redeploy=("$@")
  local any_failure=false
  
  for service in "${services_to_redeploy[@]}"; do
    local new_td
    new_td="$(needs_update "$service")"
    
    if [[ "$new_td" == "new" ]]; then
      step "Servicio $service no existe, necesita deploy completo"
      return 2
    elif [[ -n "$new_td" ]]; then
      step "Actualizando $service con nueva task definition: $(basename "$new_td")"
      
      awsq ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$service" \
        --task-definition "$new_td" \
        --force-new-deployment \
        --desired-count 1 >/dev/null
      
      ok "Deployment iniciado para $service"
      
      if ! wait_for_service_stable "$service"; then
        any_failure=true
      fi
      
      # Actualizar state file si existe
      if [[ -f "$STATE_FILE" ]]; then
        local td_key
        case "$service" in
          configservice) td_key="TD_CONFIG_ARN" ;;
          eurekaservice) td_key="TD_EUREKA_ARN" ;;
          gatewayservice) td_key="TD_GATEWAY_ARN" ;;
          productservice) td_key="TD_PRODUCTS_ARN" ;;
          orderservice) td_key="TD_ORDERS_ARN" ;;
          paymentservice) td_key="TD_PAY_ARN" ;;
          userservice) td_key="TD_USERS_ARN" ;;
        esac
        
        if [[ -n "$td_key" ]]; then
          local tmp_file
          tmp_file="$(mktemp)"
          jq --arg key "$td_key" --arg value "$new_td" '.[$key]=$value' "$STATE_FILE" > "$tmp_file"
          mv "$tmp_file" "$STATE_FILE"
        fi
      fi
    else
      ok "✓ $service ya está actualizado"
    fi
    
    # Pequeña pausa entre servicios
    sleep 3
  done
  
  if [[ "$any_failure" == "true" ]]; then
    return 1
  fi
  
  return 0
}

# Modo watch - monitorear cambios continuamente
watch_mode() {
  local interval="${1:-10}"
  step "Modo WATCH activado - Monitoreando cambios cada $interval segundos"
  warn "Presiona Ctrl+C para salir"
  
  local last_deploy_time="$(date +%s)"
  local last_check_time=0
  
  while true; do
    local current_time="$(date +%s)"
    
    # Verificar cambios en el script de deploy
    local deploy_mtime="$(stat -c %Y "$DEPLOY_SCRIPT" 2>/dev/null || echo 0)"
    if [[ $deploy_mtime -gt $last_check_time ]]; then
      step "📝 Cambio detectado en script de deploy"
      run_deploy_if_needed false
      redeploy_services "${SERVICES[@]}"
      last_deploy_time="$current_time"
    fi
    
    # Verificar cambios en imágenes (opcional)
    if [[ $((current_time - last_deploy_time)) -gt 300 ]]; then
      # Cada 5 minutos, verificar si hay nuevas imágenes
      local updated_services=()
      for service in "${SERVICES[@]}"; do
        if [[ -n "$(needs_update "$service")" ]]; then
          updated_services+=("$service")
        fi
      done
      
      if [[ ${#updated_services[@]} -gt 0 ]]; then
        step "📦 Nuevas imágenes detectadas para: ${updated_services[*]}"
        redeploy_services "${updated_services[@]}"
      fi
      last_deploy_time="$current_time"
    fi
    
    last_check_time="$current_time"
    sleep "$interval"
  done
}

# Mostrar resumen
show_summary() {
  echo ""
  echo "==================================="
  echo "         📊 RESUMEN FINAL"
  echo "==================================="
  
  local all_ok=true
  
  for service in "${SERVICES[@]}"; do
    local status
    local task_count
    local td_info
    
    status="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$service" \
      --query "services[0].status" --output text 2>/dev/null || echo "NOT_FOUND")"
    
    if [[ "$status" != "ACTIVE" ]]; then
      echo -e "  ${RED}✗ $service: $status${NC}"
      all_ok=false
      continue
    fi
    
    task_count="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$service" \
      --query "services[0].runningCount" --output text)"
    
    current_td="$(get_current_task_definition "$service" | xargs -n 1 basename)"
    latest_td="$(get_latest_task_definition "${FAMILY_MAP[$service]}" | xargs -n 1 basename)"
    
    if [[ "$current_td" == "$latest_td" ]]; then
      echo -e "  ${GREEN}✓ $service: $task_count tareas (TD: $current_td)${NC}"
    else
      echo -e "  ${YELLOW}⚠ $service: $task_count tareas (TD: $current_td → $latest_td disponible)${NC}"
      all_ok=false
    fi
  done
  
  echo "==================================="
  
  if check_gateway_health; then
    echo -e "  ${GREEN}✓ Gateway health: OK${NC}"
  else
    echo -e "  ${RED}✗ Gateway health: ERROR${NC}"
    all_ok=false
  fi
  
  echo "==================================="
  
  if $all_ok; then
    ok "Todos los servicios están actualizados y funcionando"
  else
    warn "Algunos servicios necesitan atención"
  fi
}

# Menú de ayuda
show_help() {
  cat << EOF
Uso: $0 [OPCIÓN]

OPCIONES:
  -d, --deploy       Ejecuta deploy y luego reinicia servicios actualizados
  -r, --redeploy     Solo reinicia servicios con nuevas task definitions
  -f, --force        Fuerza deploy completo y reinicio de todos los servicios
  -w, --watch [N]    Modo watch (monitorea cambios cada N segundos, default 10)
  -s, --status       Muestra estado actual de los servicios
  -l, --logs [SVC]   Muestra logs de un servicio específico
  -h, --help         Muestra esta ayuda

EJEMPLOS:
  $0 --deploy        # Deploy + reinicio inteligente
  $0 --redeploy      # Solo reinicia servicios con cambios
  $0 --force         # Deploy completo + reinicio total
  $0 --watch 5       # Monitorea cambios cada 5 segundos
  $0 --status        # Ver estado
  $0 --logs gateway  # Ver logs del gateway
EOF
}

# Main
main() {
  check_prerequisites
  load_config
  
  # Sin argumentos, mostrar ayuda
  if [[ $# -eq 0 ]]; then
    show_help
    exit 0
  fi
  
  # Procesar argumentos
  case "${1:-}" in
    -d|--deploy)
      step "MODO: Deploy + Reinicio inteligente"
      run_deploy_if_needed false
      redeploy_services "${SERVICES[@]}"
      show_summary
      ;;
      
    -r|--redeploy)
      step "MODO: Solo reinicio de servicios con cambios"
      redeploy_services "${SERVICES[@]}"
      show_summary
      ;;
      
    -f|--force)
      step "MODO: Deploy forzado + Reinicio total"
      run_deploy_if_needed true
      redeploy_services "${SERVICES[@]}"
      show_summary
      ;;
      
    -w|--watch)
      interval="${2:-10}"
      watch_mode "$interval"
      ;;
      
    -s|--status)
      show_summary
      ;;
      
    -l|--logs)
      if [[ -n "${2:-}" ]]; then
        show_service_logs "$2" 50
      else
        error "Especifica un servicio: configservice, eurekaservice, gatewayservice, etc."
        exit 1
      fi
      ;;
      
    -h|--help)
      show_help
      ;;
      
    *)
      error "Opción desconocida: $1"
      show_help
      exit 1
      ;;
  esac
}

# Ejecutar
main "$@"