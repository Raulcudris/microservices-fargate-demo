#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# DESTROY SCRIPT MEJORADO
# - Usa el state file JSON como fuente de verdad
# - Eliminación ordenada y robusta
# - Manejo de dependencias y tiempos de espera
# - Modo dry-run para ver qué se eliminará
# ============================================================

# ✅ FIX Git Bash (MSYS) path conversion:
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Funciones de logging
log() { echo -e "${BLUE}👉 $*${NC}" >&2; }
ok()  { echo -e "${GREEN}✅ $*${NC}" >&2; }
warn(){ echo -e "${YELLOW}⚠️  $*${NC}" >&2; }
error(){ echo -e "${RED}❌ $*${NC}" >&2; }
step(){ echo -e "${PURPLE}📦 $*${NC}" >&2; }
dry(){ echo -e "${CYAN}[DRY-RUN] $*${NC}" >&2; }

# Verificar herramientas necesarias
need() { 
  command -v "$1" >/dev/null 2>&1 || { error "Falta '$1'"; exit 1; }
}
need aws
need jq

# Configuración
ENV_FILE="${ENV_FILE:-.env}"
REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

# Flags de destrucción (seguros por defecto)
DESTROY_ECR="${DESTROY_ECR:-false}"
DESTROY_IAM="${DESTROY_IAM:-false}"
DESTROY_RDS="${DESTROY_RDS:-false}"
DESTROY_EIP="${DESTROY_EIP:-true}"      # Las EIP siempre se liberan
FORCE_DESTROY="${FORCE_DESTROY:-false}"  # Modo no interactivo
DRY_RUN="${DRY_RUN:-false}"              # Modo dry-run (solo mostrar)

# State file
STATE_FILE=".deploy_state.${PROJECT}.${REGION}.json"
[[ -f "$STATE_FILE" ]] || { error "No encuentro STATE_FILE: $STATE_FILE"; exit 1; }

awsq() { aws --region "$REGION" "$@"; }
safe() { "$@" >/dev/null 2>&1 || true; }
safe_dry() { 
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "$*"
  else
    "$@" >/dev/null 2>&1 || true
  fi
}

# Obtener valor del state file
state_get() { 
  local value
  value="$(jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true)"
  # Limpiar saltos de línea y espacios
  echo "$value" | tr -d '\n\r' | xargs || true
}

# Cargar TODAS las variables del state file
load_state_vars() {
  step "Cargando variables desde state file..."
  
  # VPC y networking
  VPC_ID="$(state_get VPC_ID)"
  IGW_ID="$(state_get IGW_ID)"
  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  RTB_PUB_ID="$(state_get RTB_PUB_ID)"
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"
  
  # NAT
  NAT_GW_ID="$(state_get NAT_GW_ID)"
  NAT_EIP_ALLOC_ID="$(state_get NAT_EIP_ALLOC_ID)"
  
  # Security Groups
  SG_ALB_ID="$(state_get SG_ALB_ID)"
  SG_ECS_PRIVATE_ID="$(state_get SG_ECS_PRIVATE_ID)"
  SG_CONFIG_ID="$(state_get SG_CONFIG_ID)"
  SG_VPCE_ID="$(state_get SG_VPCE_ID)"
  SG_RDS_ID="$(state_get SG_RDS_ID | grep -o 'sg-[a-f0-9]\+' | head -1)"
  
  # IAM
  ROLE_ARN="$(state_get ROLE_ARN)"
  ROLE_NAME="$(basename "$ROLE_ARN" 2>/dev/null || echo "${PROJECT}-ecsTaskExecutionRole")"
  
  # Log Groups
  LG_CONFIG="$(state_get LG_CONFIG)"
  LG_EUREKA="$(state_get LG_EUREKA)"
  LG_GATEWAY="$(state_get LG_GATEWAY)"
  LG_PRODUCTS="$(state_get LG_PRODUCTS)"
  LG_ORDERS="$(state_get LG_ORDERS)"
  LG_PAY="$(state_get LG_PAY)"
  LG_USERS="$(state_get LG_USERS)"
  
  # Cloud Map
  NS_ID="$(state_get NS_ID)"
  SD_CONFIG_ID="$(state_get SD_CONFIG_ID)"
  SD_EUREKA_ID="$(state_get SD_EUREKA_ID)"
  SD_GATEWAY_ID="$(state_get SD_GATEWAY_ID)"
  SD_PRODUCTS_ID="$(state_get SD_PRODUCTS_ID)"
  SD_ORDERS_ID="$(state_get SD_ORDERS_ID)"
  SD_PAY_ID="$(state_get SD_PAY_ID)"
  SD_USERS_ID="$(state_get SD_USERS_ID)"
  
  # ALB
  ALB_ARN="$(state_get ALB_ARN)"
  ALB_DNS="$(state_get ALB_DNS)"
  TG_GW_ARN="$(state_get TG_GW_ARN)"
  LISTENER_ARN_80="$(state_get LISTENER_ARN_80)"
  LISTENER_ARN_443="$(state_get LISTENER_ARN_443)"
  
  # Task Definitions
  TD_CONFIG_ARN="$(state_get TD_CONFIG_ARN)"
  TD_EUREKA_ARN="$(state_get TD_EUREKA_ARN)"
  TD_GATEWAY_ARN="$(state_get TD_GATEWAY_ARN)"
  TD_PRODUCTS_ARN="$(state_get TD_PRODUCTS_ARN)"
  TD_ORDERS_ARN="$(state_get TD_ORDERS_ARN)"
  TD_PAY_ARN="$(state_get TD_PAY_ARN)"
  TD_USERS_ARN="$(state_get TD_USERS_ARN)"
  
  # Nombres derivados
  CLUSTER_NAME="${PROJECT}-cluster"
  NAMESPACE_NAME="${PROJECT}.local"
  
  # Array de servicios
  SERVICES=(
    "configservice"
    "eurekaservice"
    "gatewayservice"
    "productservice"
    "orderservice"
    "paymentservice"
    "userservice"
  )
  
  # Array de log groups
  LOG_GROUPS=(
    "$LG_CONFIG"
    "$LG_EUREKA"
    "$LG_GATEWAY"
    "$LG_PRODUCTS"
    "$LG_ORDERS"
    "$LG_PAY"
    "$LG_USERS"
  )
  
  # Array de Cloud Map services
  SD_IDS=(
    "$SD_CONFIG_ID"
    "$SD_EUREKA_ID"
    "$SD_GATEWAY_ID"
    "$SD_PRODUCTS_ID"
    "$SD_ORDERS_ID"
    "$SD_PAY_ID"
    "$SD_USERS_ID"
  )
  
  # Array de Security Groups
  SGS=(
    "$SG_ALB_ID"
    "$SG_ECS_PRIVATE_ID"
    "$SG_CONFIG_ID"
    "$SG_VPCE_ID"
    "$SG_RDS_ID"
  )
  
  # Array de subnets
  SUBNETS=(
    "$PUB1_ID"
    "$PUB2_ID"
    "$PRI1_ID"
    "$PRI2_ID"
  )
  
  # Array de task definitions
  TD_ARNS=(
    "$TD_CONFIG_ARN"
    "$TD_EUREKA_ARN"
    "$TD_GATEWAY_ARN"
    "$TD_PRODUCTS_ARN"
    "$TD_ORDERS_ARN"
    "$TD_PAY_ARN"
    "$TD_USERS_ARN"
  )
  
  ok "Variables cargadas"
}

# Mostrar resumen de lo que se eliminará
show_summary() {
  echo ""
  echo "========================================="
  echo "     📋 RESUMEN DE RECURSOS A ELIMINAR"
  echo "========================================="
  
  [[ -n "$VPC_ID" ]] && echo "  • VPC: $VPC_ID"
  [[ -n "$ALB_ARN" ]] && echo "  • ALB: $(basename "$ALB_ARN")"
  [[ -n "$CLUSTER_NAME" ]] && echo "  • Cluster ECS: $CLUSTER_NAME"
  [[ -n "$NAT_GW_ID" ]] && echo "  • NAT Gateway: $NAT_GW_ID"
  
  echo ""
  echo "  Servicios ECS: ${#SERVICES[@]}"
  echo "  Security Groups: $(printf '%s\n' "${SGS[@]}" | grep -v '^$' | wc -l)"
  echo "  Subnets: $(printf '%s\n' "${SUBNETS[@]}" | grep -v '^$' | wc -l)"
  echo "  Cloud Map Services: $(printf '%s\n' "${SD_IDS[@]}" | grep -v '^$' | wc -l)"
  echo "  Log Groups: $(printf '%s\n' "${LOG_GROUPS[@]}" | grep -v '^$' | wc -l)"
  
  if [[ "$DESTROY_ECR" == "true" ]]; then
    echo "  ⚠️  ECR Repos: 7 (se eliminarán)"
  fi
  if [[ "$DESTROY_IAM" == "true" ]]; then
    echo "  ⚠️  IAM Role: $ROLE_NAME (se eliminará)"
  fi
  if [[ "$DESTROY_RDS" == "true" ]]; then
    echo "  ⚠️  RDS: Se eliminará (si existe)"
  fi
  
  echo "========================================="
}

# Confirmar destrucción
confirm_destroy() {
  if [[ "$FORCE_DESTROY" == "true" ]]; then
    warn "Modo FORCE activado - procediendo sin confirmación"
    return 0
  fi
  
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Modo DRY-RUN activado - no se eliminará nada realmente"
    return 0
  fi
  
  echo ""
  read -p "⚠️  ¿Estás SEGURO de querer eliminar TODOS estos recursos? (escribe 'BORRAR' para confirmar): " confirm
  if [[ "$confirm" != "BORRAR" ]]; then
    error "Operación cancelada"
    exit 1
  fi
}

# Verificar si un servicio ECS existe
ecs_service_exists() {
  local svc="$1"
  local status
  status="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" \
    --query "services[0].status" --output text 2>/dev/null || true)"
  [[ "$status" != "None" && -n "$status" ]]
}

# Esperar a que servicio esté INACTIVE
wait_services_inactive() {
  local svc="$1"
  log "Esperando que $svc esté INACTIVE..."
  for i in {1..60}; do
    local st
    st="$(awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" \
      --query "services[0].status" --output text 2>/dev/null || true)"
    if [[ "$st" == "INACTIVE" || "$st" == "None" || -z "$st" ]]; then
      ok "$svc eliminado"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  warn "Timeout esperando INACTIVE: $svc (continúo igual)"
}

# Obtener namespace ID por nombre
get_namespace_id_by_name() {
  awsq servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v "None" || true
}

# Deregistrar task definitions de una familia
deregister_task_family() {
  local td_arn="$1"
  local name="$2"
  
  if [[ -z "$td_arn" || "$td_arn" == "null" ]]; then
    return
  fi
  
  local family="$(echo "$td_arn" | cut -d'/' -f2 | cut -d':' -f1)"
  if [[ -n "$family" ]]; then
    log "Deregistrando task definitions de: $family"
    local revisions
    revisions="$(awsq ecs list-task-definitions --family-prefix "$family" --query "taskDefinitionArns[]" --output text 2>/dev/null || true)"
    if [[ -n "$revisions" ]]; then
      for rev in $revisions; do
        safe_dry awsq ecs deregister-task-definition --task-definition "$rev"
      done
    fi
  fi
}

# Esperar a que NAT se elimine
wait_nat_deleted() {
  local nat_id="$1"
  log "Esperando eliminación de NAT Gateway..."
  for i in {1..60}; do
    local state
    state="$(awsq ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" \
      --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")"
    if [[ "$state" == "deleted" || "$state" == "None" ]]; then
      ok "NAT Gateway eliminado"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  warn "Timeout esperando NAT deletion"
}

# Esperar a que ALB se elimine
wait_alb_deleted() {
  local alb_arn="$1"
  log "Esperando eliminación de ALB..."
  for i in {1..60}; do
    if ! awsq elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" 2>/dev/null; then
      ok "ALB eliminado"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  warn "Timeout esperando ALB deletion"
}

# -----------------------------
# MAIN DESTROY SEQUENCE
# -----------------------------
main() {
  echo ""
  echo "🔥 SCRIPT DE DESTRUCCIÓN MEJORADO"
  echo "=================================="
  
  # Cargar variables
  load_state_vars
  
  # Mostrar resumen
  show_summary
  
  # Confirmar (si no es dry-run)
  confirm_destroy
  
  echo ""
  
  # -----------------------------
  # 1) ESCALAR SERVICIOS A 0
  # -----------------------------
  step "1) Escalando servicios ECS a 0..."
  for s in "${SERVICES[@]}"; do
    if ecs_service_exists "$s"; then
      log "Escalando a 0: $s"
      safe_dry awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$s" --desired-count 0
    else
      ok "Servicio no existe: $s"
    fi
  done
  
  # Pequeña pausa para que el escalado se propague
  sleep 10
  
  # -----------------------------
  # 2) ELIMINAR SERVICIOS ECS
  # -----------------------------
  step "2) Eliminando servicios ECS..."
  for s in "${SERVICES[@]}"; do
    if ecs_service_exists "$s"; then
      log "Eliminando: $s"
      safe_dry awsq ecs delete-service --cluster "$CLUSTER_NAME" --service "$s" --force
      wait_services_inactive "$s"
    fi
  done
  
  # -----------------------------
  # 3) DEREGISTRAR TASK DEFINITIONS
  # -----------------------------
  step "3) Deregistrando task definitions..."
  local td_index=0
  for td in "${TD_ARNS[@]}"; do
    if [[ -n "$td" && "$td" != "null" ]]; then
      local svc_name="${SERVICES[$td_index]:-unknown}"
      deregister_task_family "$td" "$svc_name"
    fi
    td_index=$((td_index + 1))
  done
  
  # -----------------------------
  # 4) ELIMINAR ALB Y TARGET GROUP
  # -----------------------------
  step "4) Eliminando ALB y Target Group..."
  
  # Eliminar listeners primero
  if [[ -n "$LISTENER_ARN_80" && "$LISTENER_ARN_80" != "null" ]]; then
    log "Eliminando listener 80"
    safe_dry awsq elbv2 delete-listener --listener-arn "$LISTENER_ARN_80"
  fi
  
  if [[ -n "$LISTENER_ARN_443" && "$LISTENER_ARN_443" != "null" ]]; then
    log "Eliminando listener 443"
    safe_dry awsq elbv2 delete-listener --listener-arn "$LISTENER_ARN_443"
  fi
  
  # Eliminar ALB
  if [[ -n "$ALB_ARN" && "$ALB_ARN" != "null" ]]; then
    log "Eliminando ALB"
    safe_dry awsq elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
    wait_alb_deleted "$ALB_ARN"
  fi
  
  # Eliminar Target Group
  if [[ -n "$TG_GW_ARN" && "$TG_GW_ARN" != "null" ]]; then
    log "Eliminando Target Group"
    safe_dry awsq elbv2 delete-target-group --target-group-arn "$TG_GW_ARN"
  fi
  
  # -----------------------------
  # 5) ELIMINAR CLOUD MAP
  # -----------------------------
  step "5) Eliminando Cloud Map..."
  
  # Eliminar servicios Cloud Map
  for sid in "${SD_IDS[@]}"; do
    if [[ -n "$sid" && "$sid" != "null" ]]; then
      log "Eliminando Cloud Map service: $sid"
      safe_dry awsq servicediscovery delete-service --id "$sid"
    fi
  done
  
  # Pequeña pausa para que se eliminen los servicios
  sleep 10
  
  # Eliminar namespace
  NS_ID_TO_DELETE="$NS_ID"
  if [[ -z "$NS_ID_TO_DELETE" || "$NS_ID_TO_DELETE" == "null" ]]; then
    NS_ID_TO_DELETE="$(get_namespace_id_by_name)"
  fi
  
  if [[ -n "$NS_ID_TO_DELETE" && "$NS_ID_TO_DELETE" != "null" ]]; then
    log "Eliminando namespace: $NS_ID_TO_DELETE"
    safe_dry awsq servicediscovery delete-namespace --id "$NS_ID_TO_DELETE"
  fi
  
  # -----------------------------
  # 6) ELIMINAR CLUSTER ECS
  # -----------------------------
  step "6) Eliminando cluster ECS..."
  safe_dry awsq ecs delete-cluster --cluster "$CLUSTER_NAME"
  
  # -----------------------------
  # 7) ELIMINAR LOG GROUPS
  # -----------------------------
  step "7) Eliminando CloudWatch Log Groups..."
  for lg in "${LOG_GROUPS[@]}"; do
    if [[ -n "$lg" && "$lg" != "null" ]]; then
      log "Eliminando log group: $lg"
      safe_dry awsq logs delete-log-group --log-group-name "$lg"
    fi
  done
  
  # -----------------------------
  # 8) ELIMINAR VPC ENDPOINTS
  # -----------------------------
  step "8) Eliminando VPC Endpoints..."
  if [[ -n "$VPC_ID" && "$VPC_ID" != "null" ]]; then
    EP_IDS="$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)"
    if [[ -n "${EP_IDS// }" ]]; then
      log "Eliminando VPC endpoints: $EP_IDS"
      safe_dry awsq ec2 delete-vpc-endpoints --vpc-endpoint-ids $EP_IDS
    fi
  fi
  
  # -----------------------------
  # 9) ELIMINAR NAT GATEWAY
  # -----------------------------
  if [[ -n "$NAT_GW_ID" && "$NAT_GW_ID" != "null" ]]; then
    step "9) Eliminando NAT Gateway..."
    log "Eliminando NAT Gateway: $NAT_GW_ID"
    safe_dry awsq ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID"
    wait_nat_deleted "$NAT_GW_ID"
  fi
  
  # -----------------------------
  # 10) LIBERAR ELASTIC IP
  # -----------------------------
  if [[ "$DESTROY_EIP" == "true" && -n "$NAT_EIP_ALLOC_ID" && "$NAT_EIP_ALLOC_ID" != "null" ]]; then
    step "10) Liberando Elastic IP..."
    log "Liberando EIP: $NAT_EIP_ALLOC_ID"
    safe_dry awsq ec2 release-address --allocation-id "$NAT_EIP_ALLOC_ID"
  fi
  
  # -----------------------------
  # 11) ELIMINAR SECURITY GROUPS
  # -----------------------------
  step "11) Eliminando Security Groups..."
  for sg in "${SGS[@]}"; do
    if [[ -n "$sg" && "$sg" != "null" ]]; then
      log "Eliminando Security Group: $sg"
      safe_dry awsq ec2 delete-security-group --group-id "$sg"
      sleep 2
    fi
  done
  
  # -----------------------------
  # 12) ELIMINAR SUBNETS
  # -----------------------------
  step "12) Eliminando Subnets..."
  for sn in "${SUBNETS[@]}"; do
    if [[ -n "$sn" && "$sn" != "null" ]]; then
      log "Eliminando Subnet: $sn"
      safe_dry awsq ec2 delete-subnet --subnet-id "$sn"
      sleep 2
    fi
  done
  
  # -----------------------------
  # 13) ELIMINAR ROUTE TABLES
  # -----------------------------
  step "13) Eliminando Route Tables..."
  
  # Desasociar route tables primero
  for rtb in "$RTB_PUB_ID" "$RTB_PRI_ID"; do
    if [[ -n "$rtb" && "$rtb" != "null" ]]; then
      ASSOCS="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" \
        --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null || true)"
      for a in $ASSOCS; do
        safe_dry awsq ec2 disassociate-route-table --association-id "$a"
      done
    fi
  done
  
  # Eliminar route tables
  [[ -n "$RTB_PUB_ID" && "$RTB_PUB_ID" != "null" ]] && { 
    log "Eliminando Route Table pública: $RTB_PUB_ID"
    safe_dry awsq ec2 delete-route-table --route-table-id "$RTB_PUB_ID"
  }
  
  [[ -n "$RTB_PRI_ID" && "$RTB_PRI_ID" != "null" ]] && { 
    log "Eliminando Route Table privada: $RTB_PRI_ID"
    safe_dry awsq ec2 delete-route-table --route-table-id "$RTB_PRI_ID"
  }
  
  # -----------------------------
  # 14) ELIMINAR INTERNET GATEWAY
  # -----------------------------
  step "14) Eliminando Internet Gateway..."
  if [[ -n "$IGW_ID" && "$IGW_ID" != "null" && -n "$VPC_ID" && "$VPC_ID" != "null" ]]; then
    log "Desadjuntando IGW: $IGW_ID"
    safe_dry awsq ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    log "Eliminando IGW: $IGW_ID"
    safe_dry awsq ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
  fi
  
  # -----------------------------
  # 15) ELIMINAR VPC
  # -----------------------------
  step "15) Eliminando VPC..."
  if [[ -n "$VPC_ID" && "$VPC_ID" != "null" ]]; then
    log "Eliminando VPC: $VPC_ID"
    safe_dry awsq ec2 delete-vpc --vpc-id "$VPC_ID"
  fi
  
  # -----------------------------
  # 16) ELIMINAR ECR (opcional)
  # -----------------------------
  if [[ "$DESTROY_ECR" == "true" ]]; then
    step "16) Eliminando ECR repositories..."
    ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text)"
    for repo in configservice eurekaservice gatewayservice productservice orderservice paymentservice userservice; do
      log "Eliminando ECR repo: $repo"
      safe_dry awsq ecr delete-repository --repository-name "$repo" --force
    done
  else
    warn "16) DESTROY_ECR=false - conservando ECR repos"
  fi
  
  # -----------------------------
  # 17) ELIMINAR IAM ROLE (opcional)
  # -----------------------------
  if [[ "$DESTROY_IAM" == "true" && -n "$ROLE_NAME" ]]; then
    step "17) Eliminando IAM Role..."
    log "Desadjuntando políticas de: $ROLE_NAME"
    safe_dry aws iam detach-role-policy --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    log "Eliminando role: $ROLE_NAME"
    safe_dry aws iam delete-role --role-name "$ROLE_NAME"
  else
    warn "17) DESTROY_IAM=false - conservando IAM role"
  fi
  
  # -----------------------------
  # 18) ELIMINAR RDS (opcional)
  # -----------------------------
  if [[ "$DESTROY_RDS" == "true" ]]; then
    step "18) Eliminando RDS..."
    DB_INSTANCE_ID="${PROJECT}-mysql"
    
    log "Desactivando deletion protection para: $DB_INSTANCE_ID"
    safe_dry awsq rds modify-db-instance --db-instance-identifier "$DB_INSTANCE_ID" \
      --no-deletion-protection --apply-immediately
    
    log "Eliminando RDS instance: $DB_INSTANCE_ID"
    safe_dry awsq rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_ID" \
      --skip-final-snapshot --delete-automated-backups
  else
    warn "18) DESTROY_RDS=false - conservando RDS"
  fi
  
  # -----------------------------
  # 19) BACKUP DEL STATE FILE
  # -----------------------------
  if [[ "$DRY_RUN" != "true" ]]; then
    step "19) Respaldando state file..."
    BACKUP_FILE="${STATE_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$STATE_FILE" "$BACKUP_FILE"
    ok "State file respaldado en: $BACKUP_FILE"
    
    # Preguntar si eliminar el state file original
    if [[ "$FORCE_DESTROY" != "true" ]]; then
      read -p "¿Eliminar el state file original? (s/N): " delete_state
      if [[ "$delete_state" =~ ^[Ss]$ ]]; then
        rm "$STATE_FILE"
        ok "State file eliminado"
      fi
    fi
  fi
  
  echo ""
  ok "🎉 PROCESO DE DESTRUCCIÓN COMPLETADO"
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "Modo DRY-RUN - no se eliminó nada realmente"
  fi
}

# Procesar argumentos de línea de comandos
while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE_DESTROY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --destroy-ecr)
      DESTROY_ECR=true
      shift
      ;;
    --destroy-iam)
      DESTROY_IAM=true
      shift
      ;;
    --destroy-rds)
      DESTROY_RDS=true
      shift
      ;;
    --help)
      echo "Uso: $0 [opciones]"
      echo "  --force       Modo no interactivo (no pide confirmación)"
      echo "  --dry-run     Solo muestra lo que se eliminaría (no ejecuta)"
      echo "  --destroy-ecr Elimina también los repositorios ECR"
      echo "  --destroy-iam Elimina también el IAM role"
      echo "  --destroy-rds Elimina también la base de datos RDS"
      exit 0
      ;;
    *)
      error "Opción desconocida: $1"
      exit 1
      ;;
  esac
done

# Ejecutar main
main