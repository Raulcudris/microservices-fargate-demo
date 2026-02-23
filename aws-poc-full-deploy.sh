#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# aws-full-deploy.sh - OPTIMIZED VERSION WITH .ENV INTEGRATION
# Full deploy de microservicios Spring Boot a ECS Fargate
# ============================================================

# Configuración de colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -------------------------
# FUNCIÓN DE LOGGING MEJORADA
# -------------------------
log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] 👉${NC} $*"; }
ok()  { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅${NC} $*"; }
warn(){ echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️${NC} $*"; }
error(){ echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌${NC} $*"; }
# -------------------------
# FUNCIÓN PARA VERIFICAR CUOTA DE EIPS
# -------------------------
# -------------------------
# FUNCIÓN PARA VERIFICAR CUOTA DE EIPS (VERSIÓN CORREGIDA)
# -------------------------
check_eip_quota() {
  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  
  # Intentar obtener límite de Service Quotas (si está disponible)
  local eip_quota=5  # valor por defecto
  if command -v aws service-quotas &>/dev/null; then
    eip_quota_raw="$(aws service-quotas get-service-quota \
      --service-code ec2 \
      --quota-code L-0263D0A3 \
      --region "$REGION" \
      --query 'Quota.Value' --output text 2>/dev/null || echo "5")"
    
    # Convertir a entero (eliminar parte decimal)
    eip_quota="${eip_quota_raw%.*}"
  fi
  
  local eips_in_use
  eips_in_use_raw="$(awsq ec2 describe-addresses \
    --query 'length(Addresses[?Domain==`vpc`])' \
    --output text 2>/dev/null || echo "0")"
  
  # Convertir a entero
  eips_in_use="${eips_in_use_raw%.*}"
  
  log "EIPs en uso: $eips_in_use / $eip_quota"
  
  if [[ $eips_in_use -ge $eip_quota ]]; then
    warn "⚠️  Límite de EIPs alcanzado ($eips_in_use/$eip_quota)"
    
    # Mostrar EIPs en uso
    echo ""
    echo "📋 EIPs en uso en región $REGION:"
    awsq ec2 describe-addresses --output table --query 'Addresses[*].[PublicIp,InstanceId,NetworkInterfaceId,Tags[?Key==`Name`].Value|[0]]' 2>/dev/null || true
    echo ""
    
    # Buscar EIPs no asociadas
    local unused_eips
    unused_eips="$(awsq ec2 describe-addresses \
      --filters "Name=domain,Values=vpc" \
      --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' \
      --output text 2>/dev/null || true)"
    
    if [[ -n "$unused_eips" ]]; then
      warn "Hay EIPs sin asociar. Puedes liberarlas con:"
      echo ""
      echo "$unused_eips" | while read -r alloc_id ip; do
        if [[ -n "$alloc_id" && "$alloc_id" != "None" ]]; then
          echo "   aws ec2 release-address --allocation-id $alloc_id --region $REGION"
        fi
      done
      echo ""
    fi
    
    return 1
  fi
  return 0
}

# -------------------------
# CARGA DE VARIABLES DE ENTORNO DESDE .ENV
# -------------------------
load_env_file() {
    local env_file="${1:-.env}"
    local found=false
    
    # Buscar archivo .env en orden de prioridad
    for possible_env in "$env_file" "./.env" "../.env" "./config/.env" "./environments/.env"; do
        if [[ -f "$possible_env" ]]; then
            env_file="$possible_env"
            found=true
            break
        fi
    done
    
    if [[ "$found" == true ]]; then
        log "Cargando variables desde: $env_file"
        
        # Cargar variables respetando exportaciones
        set -a
        source "$env_file"
        set +a
        
        ok "Variables cargadas correctamente"
        
        # Mostrar resumen de variables cargadas (sin contraseñas)
        echo ""
        echo -e "${GREEN}📋 Variables cargadas desde .env:${NC}"
        echo "   PROYECTO: ${PROJECT:-No definido}"
        echo "   ENTORNO: ${ENV_NAME:-No definido}"
        echo "   REGIÓN: ${REGION:-No definido}"
        echo "   MODO RED: $([ "${MODE_NO_NAT:-}" == "true" ] && echo "Sin NAT" || echo "Con NAT")"
        echo "   RDS: $([ "${CREATE_RDS:-}" == "true" ] && echo "Crear nueva" || echo "Usar existente")"
        
        if [[ -n "${DB_ENDPOINT:-}" ]]; then
            echo "   DB ENDPOINT: ${DB_ENDPOINT}"
            echo "   DB NAME: ${DB_NAME:-ecommerce_myshop}"
            echo "   DB USER: ${DB_USER:-admin}"
            echo "   DB PORT: ${DB_PORT:-3306}"
        fi
        
        if [[ -n "${JWT_SECRET:-}" ]]; then
            echo "   JWT SECRET: ${JWT_SECRET:0:15}... (configurado)"
        fi
        echo ""
    else
        warn "Archivo .env no encontrado: usando variables de entorno existentes"
        echo ""
    fi
}

# Buscar y cargar archivo .env (primer argumento o por defecto)
ENV_FILE="${1:-.env}"
load_env_file "$ENV_FILE"

# -------------------------
# CONFIGURACIÓN INICIAL (con valores del .env o por defecto)
# -------------------------
export REGION="${REGION:-us-east-1}"
export PROJECT="${PROJECT:-microservices-fargate}"
export ENV_NAME="${ENV_NAME:-prod}"
export MODE_NO_NAT="${MODE_NO_NAT:-false}"  # false = con NAT (recomendado producción)
export CREATE_RDS="${CREATE_RDS:-false}"

# Configuración de Git para Config Server
export CONFIG_GIT_URI="${CONFIG_GIT_URI:-https://github.com/Raulcudris/microservices-fargate-demo.git}"
export CONFIG_GIT_BRANCH="${CONFIG_GIT_BRANCH:-deploy}"
export CONFIG_GIT_PATHS="${CONFIG_GIT_PATHS:-config-data}"

# Configuración de Base de Datos (valores específicos proporcionados)
export DB_ENDPOINT="${DB_ENDPOINT:-}"
export DB_PORT="${DB_PORT:-3306}"
export DB_NAME="${DB_NAME:-ecommerce_myshop}"
export DB_USER="${DB_USER:-}"
export DB_PASS="${DB_PASS:-}"

# JWT Secret (valor específico proporcionado)
export JWT_SECRET="${JWT_SECRET:-}"

# Nombres de recursos
export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT}-${ENV_NAME}-cluster}"
export NAMESPACE_NAME="${NAMESPACE_NAME:-${PROJECT}-${ENV_NAME}.local}"

# Paths de servicios (deben existir)
export DIR_CONFIG="${DIR_CONFIG:-./configservice}"
export DIR_EUREKA="${DIR_EUREKA:-./eurekaservice}"
export DIR_GATEWAY="${DIR_GATEWAY:-./gatewayservice}"
export DIR_PRODUCTS="${DIR_PRODUCTS:-./productservice}"
export DIR_ORDERS="${DIR_ORDERS:-./orderservice}"
export DIR_PAY="${DIR_PAY:-./paymentservice}"
export DIR_USERS="${DIR_USERS:-./userservice}"

# En la sección de PORTS (cerca del inicio del script)
declare -A PORTS=(
  [config]=8081
  [eureka]=8761  # Cambiado de 8080 a 8761
  [gateway]=8080
  [products]=8001
  [orders]=8002
  [pay]=8003
  [users]=8004
)

# Health check
export HEALTH_PATH_GATEWAY="${HEALTH_PATH_GATEWAY:-/actuator/health}"

# Tamaños de tareas ECS
export CPU_SMALL="${CPU_SMALL:-256}"
export MEM_SMALL="${MEM_SMALL:-512}"
export CPU_MED="${CPU_MED:-512}"
export MEM_MED="${MEM_MED:-1024}"

# VPC CIDRs
export VPC_CIDR="${VPC_CIDR:-10.20.0.0/16}"
export PUB1_CIDR="${PUB1_CIDR:-10.20.1.0/24}"
export PUB2_CIDR="${PUB2_CIDR:-10.20.2.0/24}"
export PRI1_CIDR="${PRI1_CIDR:-10.20.11.0/24}"
export PRI2_CIDR="${PRI2_CIDR:-10.20.12.0/24}"

# ALB (nombres cortos para no exceder 32 chars)
export TG_GW_NAME="${TG_GW_NAME:-ms-${ENV_NAME}-gw}"
export ALB_NAME="${ALB_NAME:-ms-${ENV_NAME}-alb}"

# RDS (opcional)
export DB_INSTANCE_ID="${DB_INSTANCE_ID:-${PROJECT}-${ENV_NAME}-mysql}"
export DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
export DB_ALLOCATED_STORAGE="${DB_ALLOCATED_STORAGE:-20}"
export DB_ENGINE="${DB_ENGINE:-mysql}"

# -------------------------
# VALIDACIONES INICIALES
# -------------------------
validate_requirements() {
  local missing_tools=()
  command -v aws >/dev/null 2>&1 || missing_tools+=("aws")
  command -v docker >/dev/null 2>&1 || missing_tools+=("docker")
  command -v jq >/dev/null 2>&1 || missing_tools+=("jq")
  
  if [ ${#missing_tools[@]} -gt 0 ]; then
    error "Missing required tools: ${missing_tools[*]}"
    exit 1
  fi
}

validate_required_vars() {
  local missing_vars=()
  
  # Validar JWT_SECRET (siempre requerido)
  if [[ -z "${JWT_SECRET:-}" ]]; then
    missing_vars+=("JWT_SECRET (export JWT_SECRET=your-secret)")
  else
    ok "JWT_SECRET configurado correctamente"
  fi
  
  # Validar credenciales DB según el caso
  if [[ "$CREATE_RDS" == "true" ]]; then
    if [[ -z "${DB_USER:-}" ]]; then
      missing_vars+=("DB_USER (requerido para crear RDS)")
    fi
    if [[ -z "${DB_PASS:-}" ]]; then
      missing_vars+=("DB_PASS (requerido para crear RDS)")
    fi
  elif [[ -n "${DB_ENDPOINT:-}" ]]; then
    # Si hay endpoint, validar credenciales
    if [[ -z "${DB_USER:-}" ]]; then
      missing_vars+=("DB_USER (requerido para BD existente)")
    fi
    if [[ -z "${DB_PASS:-}" ]]; then
      missing_vars+=("DB_PASS (requerido para BD existente)")
    fi
    if [[ -z "${DB_NAME:-}" ]]; then
      warn "DB_NAME no definido, usando 'ecommerce_myshop' por defecto"
    fi
    
    # Mostrar confirmación de BD
    ok "Base de datos configurada:"
    echo "   - Endpoint: ${DB_ENDPOINT}"
    echo "   - Database: ${DB_NAME}"
    echo "   - Usuario: ${DB_USER}"
  else
    warn "BD no configurada. Los servicios no tendrán conexión a base de datos."
  fi
  
  if [ ${#missing_vars[@]} -gt 0 ]; then
    error "Variables requeridas faltantes:"
    printf '  - %s\n' "${missing_vars[@]}"
    echo ""
    echo "💡 Crea un archivo .env con el siguiente contenido:"
    echo "   export JWT_SECRET=\"${JWT_SECRET:-tu-secreto-jwt-aqui}\""
    echo "   export DB_ENDPOINT=\"${DB_ENDPOINT:-tu-endpoint.rds.amazonaws.com}\""
    echo "   export DB_USER=\"${DB_USER:-admin}\""
    echo "   export DB_PASS=\"${DB_PASS:-tu-contraseña}\""
    echo "   export DB_NAME=\"${DB_NAME:-ecommerce_myshop}\""
    echo "   export CREATE_RDS=\"${CREATE_RDS:-false}\""
    exit 1
  fi
  
  # Validar formato de JWT (opcional)
  if [[ ${#JWT_SECRET} -lt 32 ]]; then
    warn "JWT_SECRET tiene menos de 32 caracteres, considera usar uno más seguro"
  fi
}

# -------------------------
# CONFIGURACIÓN DE WINDOWS (Git Bash)
# -------------------------
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

# -------------------------
# FUNCIONES DE ESTADO (CHECKPOINT)
# -------------------------
STATE_FILE="${STATE_FILE:-.deploy_state.${PROJECT}.${ENV_NAME}.${REGION}.json}"

state_init() { 
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
    log "Archivo de estado creado: $STATE_FILE"
  fi
}

state_get() { 
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || echo ""
}

state_set() { 
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

step_done() { 
  state_set "step_${1}" "done"
  ok "Step $1 completado"
}

is_step_done() { 
  [[ "$(state_get "step_${1}")" == "done" ]]
}

# -------------------------
# MANEJO DE ERRORES
# -------------------------
on_error() {
  error "Error detectado. Estado guardado en: $STATE_FILE"
  error "Re-ejecuta el script para continuar desde donde falló."
}
trap on_error ERR

# -------------------------
# FUNCIONES UTILS AWS
# -------------------------
awsq() { aws --region "$REGION" "$@"; }

tag_spec() {
  local rtype="$1" name="$2"
  echo "ResourceType=${rtype},Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Env,Value=${ENV_NAME}}]"
}

# -------------------------
# FUNCIONES DE DISCOVERY (IDEMPOTENTES)
# -------------------------
find_vpc() {
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-${ENV_NAME}-vpc" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -v "None" || true
}

find_subnet_by_name() {
  local name="$1"
  awsq ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${name}" \
    --query "Subnets[0].SubnetId" --output text 2>/dev/null | grep -v "None" || true
}

find_rtb_by_name() {
  local name="$1"
  awsq ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${name}" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null | grep -v "None" || true
}

find_igw() {
  awsq ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=${PROJECT}-${ENV_NAME}-igw" "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -v "None" || true
}

# -------------------------
# FUNCIÓN PARA GARANTIZAR SECURITY GROUPS
# -------------------------
ensure_sg() {
  local sg_name="$1" desc="$2" state_key="$3"
  local sg_id
  
  sg_id="$(state_get "$state_key")"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(awsq ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$sg_name" \
      --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v "None" || true)"
  fi
  
  if [[ -z "$sg_id" ]]; then
    sg_id="$(awsq ec2 create-security-group \
      --vpc-id "$VPC_ID" \
      --group-name "$sg_name" \
      --description "$desc" \
      --tag-specifications "$(tag_spec security-group "$sg_name")" \
      --query 'GroupId' --output text)"
    ok "SG creado: $sg_name -> $sg_id"
  else
    ok "SG reutilizado: $sg_name -> $sg_id"
  fi
  
  state_set "$state_key" "$sg_id"
  echo "$sg_id"
}

# -------------------------
# FUNCIONES ECR
# -------------------------
ensure_repo() {
  local repo="$1"
  if ! awsq ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1; then
    awsq ecr create-repository \
      --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true >/dev/null
    ok "Repositorio ECR creado: $repo"
  else
    ok "Repositorio ECR reutilizado: $repo"
  fi
}

tag_push() {
  local local_img="$1" repo="$2" tag="$3"
  local ecr_repo="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repo}"
  
  docker tag "$local_img" "${ecr_repo}:${tag}"
  docker tag "$local_img" "${ecr_repo}:latest"
  docker push "${ecr_repo}:${tag}"
  docker push "${ecr_repo}:latest"
  ok "Imagen pusheada: ${repo}:${tag}"
}

# -------------------------
# FUNCIONES CLOUD MAP
# -------------------------
get_namespace_id() {
  awsq servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v "None" || true
}

wait_cloudmap_operation() {
  local op_id="$1"
  log "Esperando operación Cloud Map: $op_id"
  for _ in {1..60}; do
    local status
    status="$(awsq servicediscovery get-operation --operation-id "$op_id" --query "Operation.Status" --output text 2>/dev/null || true)"
    case "$status" in
      "SUCCESS") return 0 ;;
      "FAIL"|"FAILURE")
        error "Operación Cloud Map falló: $op_id"
        awsq servicediscovery get-operation --operation-id "$op_id" --output json || true
        exit 1
        ;;
    esac
    sleep 2
  done
  error "Timeout esperando operación Cloud Map: $op_id"
  exit 1
}

# -------------------------
# FUNCIÓN CLOUD MAP MEJORADA
# -------------------------
ensure_sd_service() {
  local svc_name="$1" ns_id="$2" state_key="$3"
  local existing_id
  
  # Buscar ID existente
  existing_id="$(awsq servicediscovery list-services \
    --query "Services[?Name=='${svc_name}' && NamespaceId=='${ns_id}'].Id | [0]" \
    --output text 2>/dev/null | grep -v "None" || true)"
  
  if [[ -n "$existing_id" && "$existing_id" != "None" ]]; then
    ok "Cloud Map service reutilizado: $svc_name -> $existing_id"
    echo "$existing_id"
    return 0
  fi
  
  log "Creando Cloud Map service: $svc_name"
  
  # Crear servicio y capturar solo el ID
  local create_output
  create_output="$(awsq servicediscovery create-service \
    --name "$svc_name" \
    --dns-config "NamespaceId=${ns_id},DnsRecords=[{Type=A,TTL=30}]" \
    --health-check-custom-config FailureThreshold=1 \
    --output json 2>&1)" || {
    
    if echo "$create_output" | grep -q "ServiceAlreadyExists"; then
      existing_id="$(awsq servicediscovery list-services \
        --query "Services[?Name=='${svc_name}' && NamespaceId=='${ns_id}'].Id | [0]" \
        --output text)"
      echo "$existing_id"
      return 0
    else
      error "Error creando Cloud Map service: $create_output"
      exit 1
    fi
  }
  
  # Extraer ID del JSON de respuesta
  local new_id
  new_id="$(echo "$create_output" | jq -r '.Service.Id' 2>/dev/null || true)"
  
  if [[ -n "$new_id" && "$new_id" != "null" ]]; then
    ok "Cloud Map service creado: $svc_name -> $new_id"
    echo "$new_id"
  else
    error "No se pudo extraer ID de la respuesta: $create_output"
    exit 1
  fi
}
# -------------------------
# FUNCIONES ALB
# -------------------------
get_tg_arn() {
  awsq elbv2 describe-target-groups --names "$TG_GW_NAME" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v "None" || true
}

get_alb_arn() {
  awsq elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v "None" || true
}

get_alb_dns() {
  local alb_arn="$1"
  awsq elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" \
    --query "LoadBalancers[0].DNSName" --output text 2>/dev/null | grep -v "None" || true
}

# -------------------------
# FUNCIONES ECS
# -------------------------
service_exists() {
  local svc="$1"
  awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" \
    --query "services[0].status" --output text 2>/dev/null | grep -q "ACTIVE"
}

wait_service_stable() {
  local svc="$1"
  local max_attempts=30
  local attempt=0
  
  log "Esperando que el servicio $svc esté estable..."
  while [ $attempt -lt $max_attempts ]; do
    if awsq ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" \
      --query "services[0].deployments[?status=='PRIMARY'].rolloutState" \
      --output text 2>/dev/null | grep -q "COMPLETED"; then
      ok "Servicio $svc estable"
      return 0
    fi
    sleep 10
    attempt=$((attempt+1))
  done
  warn "Timeout esperando servicio $svc, continuando..."
  return 0
}

# -------------------------
# FUNCIÓN PARA ENCONTRAR DOCKERFILE
# -------------------------
find_dockerfile() {
  local svc_dir="$1"
  local possible_paths=(
    "${svc_dir}/${DOCKERFILE_PATH:-Dockerfile}"
    "${svc_dir}/Dockerfile"
    "${svc_dir}/docker/Dockerfile"
  )
  
  for path in "${possible_paths[@]}"; do
    if [[ -f "$path" ]]; then
      echo "$path"
      return 0
    fi
  done
  
  error "No se encontró Dockerfile en: $svc_dir"
  exit 1
}

# -------------------------
# FUNCIÓN PARA MERGE DE JSON ARRAYS
# -------------------------
merge_json_arrays() {
  local a="${1:-[]}" b="${2:-[]}"
  [[ -z "${a//[[:space:]]/}" ]] && a="[]"
  [[ -z "${b//[[:space:]]/}" ]] && b="[]"
  jq -cn --argjson A "$a" --argjson B "$b" '$A + $B'
}

# -------------------------
# INICIO DEL SCRIPT
# -------------------------
clear
echo -e "${BLUE}=========================================================${NC}"
echo -e "${BLUE}🚀 Microservices Full Deploy to AWS ECS Fargate${NC}"
echo -e "${BLUE}=========================================================${NC}"
echo "Project : $PROJECT"
echo "Environment : $ENV_NAME"
echo "Region : $REGION"
echo "Mode : $([ "$MODE_NO_NAT" == "true" ] && echo "No NAT (VPC Endpoints)" || echo "With NAT Gateway")"
echo "RDS : $([ "$CREATE_RDS" == "true" ] && echo "Will be created" || echo "External/None")"
echo -e "${BLUE}=========================================================${NC}"

# Validaciones
validate_requirements
validate_required_vars
state_init

# Obtener Account ID y ECR URI
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ok "Account ID: $ACCOUNT_ID"
ok "ECR URI: $ECR_URI"

# Generar o recuperar TAG
TAG="$(state_get TAG)"
if [[ -z "$TAG" ]]; then
  TAG="$(date +%Y%m%d-%H%M%S)-${ENV_NAME}"
  state_set TAG "$TAG"
fi
ok "Deployment TAG: $TAG"

# -------------------------
# STEP 1: VPC y Networking
# -------------------------
if ! is_step_done 1; then
  log "STEP 1: Creando VPC y networking..."
  
  # Obtener o crear VPC
  VPC_ID="$(state_get VPC_ID)"
  if [[ -z "$VPC_ID" ]]; then
    VPC_ID="$(find_vpc)"
  fi
  
  # Obtener zonas de disponibilidad
  AZ1="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
  AZ2="$(awsq ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"
  
  if [[ -z "$VPC_ID" ]]; then
    VPC_ID="$(awsq ec2 create-vpc \
      --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(tag_spec vpc "${PROJECT}-${ENV_NAME}-vpc")" \
      --query 'Vpc.VpcId' --output text)"
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}" >/dev/null
    awsq ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}" >/dev/null
    ok "VPC creada: $VPC_ID"
  else
    ok "VPC reutilizada: $VPC_ID"
  fi
  state_set VPC_ID "$VPC_ID"
  
  # Internet Gateway
  IGW_ID="$(state_get IGW_ID)"
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID="$(find_igw)"
  fi
  
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID="$(awsq ec2 create-internet-gateway \
      --tag-specifications "$(tag_spec internet-gateway "${PROJECT}-${ENV_NAME}-igw")" \
      --query 'InternetGateway.InternetGatewayId' --output text)"
    awsq ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" >/dev/null
    ok "IGW creado: $IGW_ID"
  else
    ok "IGW reutilizado: $IGW_ID"
  fi
  state_set IGW_ID "$IGW_ID"
  
  # Subnets - Versión corregida (SIN usar local)
  for subnet in PUB1 PUB2 PRI1 PRI2; do
    # Determinar nombre y características de la subnet
    if [[ "$subnet" == "PUB1" || "$subnet" == "PUB2" ]]; then
      subnet_type="public"
    else
      subnet_type="private"
    fi
    
    if [[ "$subnet" == "PUB1" || "$subnet" == "PRI1" ]]; then
      subnet_az="a"
    else
      subnet_az="b"
    fi
    
    subnet_name="${PROJECT}-${ENV_NAME}-${subnet_type}-${subnet_az}"
    
    # Obtener ID del state o buscar por nombre
    subnet_id_var="${subnet}_ID"
    subnet_id="$(state_get "$subnet_id_var")"
    
    if [[ -z "$subnet_id" ]]; then
      subnet_id="$(find_subnet_by_name "$subnet_name")"
    fi
    
    # Crear si no existe
    if [[ -z "$subnet_id" ]]; then
      cidr_var="${subnet}_CIDR"
      
      if [[ "$subnet" == "PUB1" || "$subnet" == "PRI1" ]]; then
        az="$AZ1"
      else
        az="$AZ2"
      fi
      
      subnet_id="$(awsq ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block "${!cidr_var}" \
        --availability-zone "$az" \
        --tag-specifications "$(tag_spec subnet "$subnet_name")" \
        --query 'Subnet.SubnetId' --output text)"
      
      if [[ "$subnet_type" == "public" ]]; then
        awsq ec2 modify-subnet-attribute --subnet-id "$subnet_id" --map-public-ip-on-launch >/dev/null
      fi
      ok "Subnet $subnet_name creada: $subnet_id"
    else
      ok "Subnet $subnet_name reutilizada: $subnet_id"
    fi
    
    # Guardar en state y asignar a variable global
    state_set "$subnet_id_var" "$subnet_id"
    declare "${subnet_id_var}=${subnet_id}"
  done
  
  # Route Tables
  RTB_PUB_ID="$(state_get RTB_PUB_ID)"
  if [[ -z "$RTB_PUB_ID" ]]; then
    RTB_PUB_ID="$(find_rtb_by_name "${PROJECT}-${ENV_NAME}-public-rtb")"
  fi
  
  if [[ -z "$RTB_PUB_ID" ]]; then
    RTB_PUB_ID="$(awsq ec2 create-route-table \
      --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "${PROJECT}-${ENV_NAME}-public-rtb")" \
      --query 'RouteTable.RouteTableId' --output text)"
    
    awsq ec2 create-route --route-table-id "$RTB_PUB_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
    awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB1_ID" >/dev/null 2>&1 || true
    awsq ec2 associate-route-table --route-table-id "$RTB_PUB_ID" --subnet-id "$PUB2_ID" >/dev/null 2>&1 || true
    ok "Public Route Table creada: $RTB_PUB_ID"
  else
    ok "Public Route Table reutilizada: $RTB_PUB_ID"
  fi
  state_set RTB_PUB_ID "$RTB_PUB_ID"
  
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"
  if [[ -z "$RTB_PRI_ID" ]]; then
    RTB_PRI_ID="$(find_rtb_by_name "${PROJECT}-${ENV_NAME}-private-rtb")"
  fi
  
  if [[ -z "$RTB_PRI_ID" ]]; then
    RTB_PRI_ID="$(awsq ec2 create-route-table \
      --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "${PROJECT}-${ENV_NAME}-private-rtb")" \
      --query 'RouteTable.RouteTableId' --output text)"
    
    awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI1_ID" >/dev/null 2>&1 || true
    awsq ec2 associate-route-table --route-table-id "$RTB_PRI_ID" --subnet-id "$PRI2_ID" >/dev/null 2>&1 || true
    ok "Private Route Table creada: $RTB_PRI_ID"
  else
    ok "Private Route Table reutilizada: $RTB_PRI_ID"
  fi
  state_set RTB_PRI_ID "$RTB_PRI_ID"
  
  step_done 1
else
  # Recuperar IDs del state
  VPC_ID="$(state_get VPC_ID)"
  PUB1_ID="$(state_get PUB1_ID)"
  PUB2_ID="$(state_get PUB2_ID)"
  PRI1_ID="$(state_get PRI1_ID)"
  PRI2_ID="$(state_get PRI2_ID)"
  RTB_PUB_ID="$(state_get RTB_PUB_ID)"
  RTB_PRI_ID="$(state_get RTB_PRI_ID)"
  IGW_ID="$(state_get IGW_ID)"
fi
# -------------------------
# STEP 1b: NAT Gateway (si aplica) - VERSIÓN CORREGIDA
# -------------------------
if [[ "$MODE_NO_NAT" != "true" ]] && ! is_step_done NAT; then
  log "STEP 1b: Creando NAT Gateway..."
  
  # Verificar quota de EIPs
  if ! check_eip_quota; then
    # Si la quota está llena, intentar usar una EIP no asociada
    log "Buscando EIPs no asociadas para reutilizar..."
    
    UNUSED_EIP="$(awsq ec2 describe-addresses \
      --filters "Name=domain,Values=vpc" \
      --query 'Addresses[?AssociationId==null].AllocationId | [0]' \
      --output text 2>/dev/null | grep -v "None" || true)"
    
    if [[ -n "$UNUSED_EIP" ]]; then
      warn "Reutilizando EIP no asociada: $UNUSED_EIP"
      NAT_EIP_ALLOC_ID="$UNUSED_EIP"
      state_set NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"
      ok "EIP existente reutilizada: $NAT_EIP_ALLOC_ID"
    else
      error "Límite de EIPs alcanzado y no hay EIPs sin usar disponibles."
      error "Solicita aumento de límite en Service Quotas o libera EIPs no usadas."
      exit 1
    fi
  else
    # Hay espacio para crear nueva EIP
    NAT_EIP_ALLOC_ID="$(state_get NAT_EIP_ALLOC_ID)"
    if [[ -z "$NAT_EIP_ALLOC_ID" ]]; then
      NAT_EIP_ALLOC_ID="$(awsq ec2 allocate-address --domain vpc --query AllocationId --output text)"
      state_set NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"
      ok "Nueva EIP para NAT asignada: $NAT_EIP_ALLOC_ID"
    fi
  fi
  
  NAT_GW_ID="$(state_get NAT_GW_ID)"
  if [[ -z "$NAT_GW_ID" ]]; then
    NAT_GW_ID="$(awsq ec2 create-nat-gateway \
      --subnet-id "$PUB1_ID" \
      --allocation-id "$NAT_EIP_ALLOC_ID" \
      --query 'NatGateway.NatGatewayId' --output text)"
    state_set NAT_GW_ID "$NAT_GW_ID"
    ok "NAT Gateway creado: $NAT_GW_ID"
  fi
  
  log "Esperando que NAT Gateway esté disponible..."
  awsq ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
  ok "NAT Gateway listo"
  
  # Añadir ruta por defecto a la tabla de rutas privada
  awsq ec2 create-route \
    --route-table-id "$RTB_PRI_ID" \
    --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
  ok "Ruta por defecto añadida a tabla privada"
  
  step_done NAT
fi
# -------------------------
# STEP 2: Security Groups
# -------------------------
if ! is_step_done 2; then
  log "STEP 2: Creando Security Groups..."
  
  SG_ALB_ID="$(ensure_sg "${PROJECT}-${ENV_NAME}-sg-alb" "ALB Security Group" "SG_ALB_ID")"
  SG_ECS_PRIVATE_ID="$(ensure_sg "${PROJECT}-${ENV_NAME}-sg-ecs-private" "ECS Tasks Private SG" "SG_ECS_PRIVATE_ID")"
  SG_CONFIG_ID="$(ensure_sg "${PROJECT}-${ENV_NAME}-sg-config" "Config Service SG" "SG_CONFIG_ID")"
  SG_RDS_ID="$(ensure_sg "${PROJECT}-${ENV_NAME}-sg-rds" "RDS MySQL SG" "SG_RDS_ID")"
  SG_VPCE_ID="$(ensure_sg "${PROJECT}-${ENV_NAME}-sg-vpce" "VPC Endpoints SG" "SG_VPCE_ID")"
  
  # Reglas de ingreso ALB
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ALB_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  
  # Gateway desde ALB
  awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_PRIVATE_ID" \
    --protocol tcp --port "${PORTS[gateway]}" --source-group "$SG_ALB_ID" >/dev/null 2>&1 || true
  
  # Comunicación interna entre servicios
  for port in "${PORTS[@]}"; do
    awsq ec2 authorize-security-group-ingress --group-id "$SG_ECS_PRIVATE_ID" \
      --protocol tcp --port "$port" --source-group "$SG_ECS_PRIVATE_ID" >/dev/null 2>&1 || true
  done
  
  # Config service accesible desde servicios privados
  awsq ec2 authorize-security-group-ingress --group-id "$SG_CONFIG_ID" \
    --protocol tcp --port "${PORTS[config]}" --source-group "$SG_ECS_PRIVATE_ID" >/dev/null 2>&1 || true
  awsq ec2 authorize-security-group-ingress --group-id "$SG_CONFIG_ID" \
    --protocol tcp --port "${PORTS[config]}" --source-group "$SG_CONFIG_ID" >/dev/null 2>&1 || true
  
  # RDS accesible desde servicios privados
  awsq ec2 authorize-security-group-ingress --group-id "$SG_RDS_ID" \
    --protocol tcp --port 3306 --source-group "$SG_ECS_PRIVATE_ID" >/dev/null 2>&1 || true
  
  if [[ "$MODE_NO_NAT" == "true" ]]; then
    # Config service necesita salida a internet para Git
    awsq ec2 authorize-security-group-egress --group-id "$SG_CONFIG_ID" \
      --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
    awsq ec2 authorize-security-group-egress --group-id "$SG_CONFIG_ID" \
      --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
    
    # VPC Endpoints accesibles desde servicios privados
    awsq ec2 authorize-security-group-ingress --group-id "$SG_VPCE_ID" \
      --protocol tcp --port 443 --source-group "$SG_ECS_PRIVATE_ID" >/dev/null 2>&1 || true
    
    # Crear VPC Endpoints para servicios AWS
    for service in "ecr.api" "ecr.dkr" "logs"; do
      awsq ec2 create-vpc-endpoint \
        --vpc-id "$VPC_ID" \
        --vpc-endpoint-type Interface \
        --service-name "com.amazonaws.${REGION}.${service}" \
        --subnet-ids "$PRI1_ID" "$PRI2_ID" \
        --security-group-ids "$SG_VPCE_ID" \
        --private-dns-enabled >/dev/null 2>&1 || true
    done
    
    # S3 endpoint (Gateway type)
    awsq ec2 create-vpc-endpoint \
      --vpc-id "$VPC_ID" \
      --vpc-endpoint-type Gateway \
      --service-name "com.amazonaws.${REGION}.s3" \
      --route-table-ids "$RTB_PRI_ID" >/dev/null 2>&1 || true
  fi
  
  step_done 2
else
  # Recuperar SGs del state
  SG_ALB_ID="$(state_get SG_ALB_ID)"
  SG_ECS_PRIVATE_ID="$(state_get SG_ECS_PRIVATE_ID)"
  SG_CONFIG_ID="$(state_get SG_CONFIG_ID)"
  SG_RDS_ID="$(state_get SG_RDS_ID)"
  SG_VPCE_ID="$(state_get SG_VPCE_ID)"
fi

# -------------------------
# STEP 3: ECR Repos + Build + Push
# -------------------------
if ! is_step_done 3; then
  log "STEP 3: Preparando imágenes Docker..."
  
  # Crear repositorios ECR
  for repo in config eureka gateway products orders pay users; do
    ensure_repo "${PROJECT}-${repo}"
  done
  
  # Login a ECR
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URI" >/dev/null
  ok "Login ECR exitoso"
  
  # Construir imágenes
  declare -A dockerfiles
  dockerfiles[config]="$(find_dockerfile "$DIR_CONFIG")"
  dockerfiles[eureka]="$(find_dockerfile "$DIR_EUREKA")"
  dockerfiles[gateway]="$(find_dockerfile "$DIR_GATEWAY")"
  dockerfiles[products]="$(find_dockerfile "$DIR_PRODUCTS")"
  dockerfiles[orders]="$(find_dockerfile "$DIR_ORDERS")"
  dockerfiles[pay]="$(find_dockerfile "$DIR_PAY")"
  dockerfiles[users]="$(find_dockerfile "$DIR_USERS")"
  
  for service in config eureka gateway products orders pay users; do
    log "Construyendo ${service}..."
    docker build \
      -t "${PROJECT}-${service}:latest" \
      -f "${dockerfiles[$service]}" \
      "$(dirname "${dockerfiles[$service]}")"
  done
  
  # Pushear imágenes
  for service in config eureka gateway products orders pay users; do
    log "Pusheando ${service}..."
    tag_push "${PROJECT}-${service}:latest" "${PROJECT}-${service}" "$TAG"
  done
  
  step_done 3
fi

# -------------------------
# STEP 4: IAM Role
# -------------------------
if ! is_step_done 4; then
  log "STEP 4: Creando IAM Role..."
  
  ROLE_NAME="${PROJECT}-${ENV_NAME}-ecsTaskExecutionRole"
  TRUST_POLICY='{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"ecs-tasks.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'
  
  ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
  if [[ -z "$ROLE_ARN" ]]; then
    ROLE_ARN="$(aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "$TRUST_POLICY" \
      --query Role.Arn --output text)"
    
    # Políticas necesarias - CORREGIDAS
    aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
    
    # ✅ CORRECCIÓN: Usar SecretsManagerReadWrite (es la que existe)
    aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite >/dev/null
    
    ok "IAM Role creado: $ROLE_ARN"
  else
    ok "IAM Role reutilizado: $ROLE_ARN"
  fi
  state_set ROLE_ARN "$ROLE_ARN"
  
  step_done 4
fi

# -------------------------
# STEP 5: CloudWatch Logs
# -------------------------
if ! is_step_done 5; then
  log "STEP 5: Creando Log Groups..."
  
  declare -A log_groups
  for service in config eureka gateway products orders pay users; do
    log_group="/ecs/${PROJECT}/${ENV_NAME}/${service}"
    awsq logs create-log-group --log-group-name "$log_group" >/dev/null 2>&1 || true
    log_groups[$service]="$log_group"
    state_set "LG_${service^^}" "$log_group"
    ok "Log group: $log_group"
  done
  
  step_done 5
fi

# -------------------------
# STEP 6: ECS Cluster
# -------------------------
if ! is_step_done 6; then
  log "STEP 6: Creando ECS Cluster..."
  
  awsq ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  ok "ECS Cluster: $CLUSTER_NAME"
  
  step_done 6
fi

# -------------------------
# STEP 7: Cloud Map - VERSIÓN CORREGIDA
# -------------------------
if ! is_step_done 7; then
  log "STEP 7: Configurando Cloud Map..."
  
  NS_ID="$(state_get NS_ID)"
  if [[ -z "$NS_ID" ]]; then
    NS_ID="$(get_namespace_id)"
  fi
  
  if [[ -z "$NS_ID" ]]; then
    OP_ID="$(awsq servicediscovery create-private-dns-namespace \
      --name "$NAMESPACE_NAME" \
      --vpc "$VPC_ID" \
      --description "${PROJECT}-${ENV_NAME} private namespace" \
      --query "OperationId" --output text)"
    wait_cloudmap_operation "$OP_ID"
    NS_ID="$(get_namespace_id)"
    ok "Namespace creado: $NS_ID"
  else
    ok "Namespace reutilizado: $NS_ID"
  fi
  state_set NS_ID "$NS_ID"
  
  # Función para limpiar ID de Cloud Map (extraer solo srv-xxxxx)
  clean_cloudmap_id() {
    local raw_id="$1"
    # Extraer solo el ID que empieza con srv-
    echo "$raw_id" | grep -o 'srv-[a-zA-Z0-9]\+' | head -1
  }
  
  # Crear servicios en Cloud Map y guardar IDs limpios
  for service in config eureka gateway products orders pay users; do
    sd_id_var="SD_${service^^}_ID"
    log "Creando servicio Cloud Map: $service"
    
    # Obtener el ID (puede venir con texto de logs)
    sd_id_raw="$(ensure_sd_service "$service" "$NS_ID" "$sd_id_var")"
    
    # Limpiar el ID (extraer solo srv-xxxxx)
    sd_id_clean="$(clean_cloudmap_id "$sd_id_raw")"
    
    if [[ -n "$sd_id_clean" ]]; then
      state_set "$sd_id_var" "$sd_id_clean"
      ok "Servicio $service creado con ID: $sd_id_clean"
    else
      # Si no se pudo limpiar, intentar obtener el ID de otra forma
      warn "No se pudo limpiar ID: $sd_id_raw, intentando obtener directamente..."
      
      # Intentar obtener el ID directamente de AWS
      direct_id="$(awsq servicediscovery list-services \
        --query "Services[?Name=='${service}' && NamespaceId=='${NS_ID}'].Id | [0]" \
        --output text 2>/dev/null || true)"
      
      if [[ -n "$direct_id" && "$direct_id" != "None" ]]; then
        state_set "$sd_id_var" "$direct_id"
        ok "Servicio $service ID obtenido directamente: $direct_id"
      else
        error "No se pudo obtener ID limpio para $service"
        exit 1
      fi
    fi
  done
  
  # Verificar que todos los IDs se guardaron correctamente
  log "Verificando IDs guardados..."
  for service in config eureka gateway products orders pay users; do
    sd_id_var="SD_${service^^}_ID"
    saved_id="$(state_get "$sd_id_var")"
    if [[ -z "$saved_id" ]]; then
      error "ID para $service no se guardó correctamente"
      exit 1
    else
      ok "ID para $service: $saved_id"
    fi
  done
  
  step_done 7
fi
# -------------------------
# STEP 8: RDS (opcional)
# -------------------------
if [[ "$CREATE_RDS" == "true" ]] && ! is_step_done 8; then
  log "STEP 8: Creando RDS MySQL..."
  
  # Crear DB Subnet Group
  awsq rds create-db-subnet-group \
    --db-subnet-group-name "${PROJECT}-${ENV_NAME}-db-subnets" \
    --db-subnet-group-description "Private subnets for RDS" \
    --subnet-ids "$PRI1_ID" "$PRI2_ID" >/dev/null 2>&1 || true
  
  # Obtener versión por defecto del engine
  DB_ENGINE_VERSION="$(awsq rds describe-db-engine-versions \
    --engine "$DB_ENGINE" \
    --default-only \
    --query "DBEngineVersions[0].EngineVersion" --output text)"
  
  # Crear instancia RDS
  if ! awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
    awsq rds create-db-instance \
      --db-instance-identifier "$DB_INSTANCE_ID" \
      --db-instance-class "$DB_INSTANCE_CLASS" \
      --engine "$DB_ENGINE" \
      --engine-version "$DB_ENGINE_VERSION" \
      --allocated-storage "$DB_ALLOCATED_STORAGE" \
      --storage-type gp2 \
      --master-username "$DB_USER" \
      --master-user-password "$DB_PASS" \
      --db-name "${DB_NAME:-${PROJECT//-/}}" \
      --vpc-security-group-ids "$SG_RDS_ID" \
      --db-subnet-group-name "${PROJECT}-${ENV_NAME}-db-subnets" \
      --no-publicly-accessible \
      --backup-retention-period 0 \
      --no-multi-az >/dev/null
    ok "RDS instance creada: $DB_INSTANCE_ID"
  else
    ok "RDS instance reutilizada: $DB_INSTANCE_ID"
  fi
  
  log "Esperando que RDS esté disponible..."
  awsq rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
  
  DB_ENDPOINT="$(awsq rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].Endpoint.Address" --output text)"
  ok "RDS endpoint: $DB_ENDPOINT"
  
  state_set DB_ENDPOINT "$DB_ENDPOINT"
  step_done 8
fi

# Recuperar DB_ENDPOINT del state si existe
DB_ENDPOINT_STATE="$(state_get DB_ENDPOINT)"
if [[ -n "$DB_ENDPOINT_STATE" ]]; then
  DB_ENDPOINT="$DB_ENDPOINT_STATE"
fi

# -------------------------
# STEP 9: Secrets Manager
# -------------------------
if ! is_step_done SECRETS; then
  log "STEP 9: Creando secrets en Secrets Manager..."
  
  SECRET_DB_NAME="${PROJECT}/db"
  SECRET_JWT_NAME="${PROJECT}/jwt"
  
  # DB Secret
  if [[ -n "${DB_ENDPOINT:-}" && -n "${DB_USER:-}" && -n "${DB_PASS:-}" ]]; then
    DB_SECRET_JSON="$(jq -nc \
      --arg host "$DB_ENDPOINT" \
      --arg db "${DB_NAME:-${PROJECT//-/}}" \
      --arg user "$DB_USER" \
      --arg pass "$DB_PASS" \
      '{
        jdbcUrl: ("jdbc:mysql://"+$host+":3306/"+$db+"?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"),
        username: $user,
        password: $pass
      }')"
    
    if awsq secretsmanager describe-secret --secret-id "$SECRET_DB_NAME" >/dev/null 2>&1; then
      awsq secretsmanager put-secret-value --secret-id "$SECRET_DB_NAME" --secret-string "$DB_SECRET_JSON" >/dev/null
      ok "Secret DB actualizado: $SECRET_DB_NAME"
    else
      awsq secretsmanager create-secret --name "$SECRET_DB_NAME" --secret-string "$DB_SECRET_JSON" >/dev/null
      ok "Secret DB creado: $SECRET_DB_NAME"
    fi
    
    SECRET_DB_ARN="$(awsq secretsmanager describe-secret --secret-id "$SECRET_DB_NAME" --query ARN --output text)"
    state_set SECRET_DB_ARN "$SECRET_DB_ARN"
  fi
  
  # JWT Secret
  JWT_SECRET_JSON="$(jq -nc --arg secret "$JWT_SECRET" '{secret: $secret}')"
  
  if awsq secretsmanager describe-secret --secret-id "$SECRET_JWT_NAME" >/dev/null 2>&1; then
    awsq secretsmanager put-secret-value --secret-id "$SECRET_JWT_NAME" --secret-string "$JWT_SECRET_JSON" >/dev/null
    ok "Secret JWT actualizado: $SECRET_JWT_NAME"
  else
    awsq secretsmanager create-secret --name "$SECRET_JWT_NAME" --secret-string "$JWT_SECRET_JSON" >/dev/null
    ok "Secret JWT creado: $SECRET_JWT_NAME"
  fi
  
  SECRET_JWT_ARN="$(awsq secretsmanager describe-secret --secret-id "$SECRET_JWT_NAME" --query ARN --output text)"
  state_set SECRET_JWT_ARN "$SECRET_JWT_ARN"
  
  step_done SECRETS
fi

SECRET_DB_ARN="$(state_get SECRET_DB_ARN)"
SECRET_JWT_ARN="$(state_get SECRET_JWT_ARN)"

# -------------------------
# STEP 9b: ALB + Target Group
# -------------------------
if ! is_step_done 9; then
  log "STEP 9b: Creando ALB y Target Group..."
  
  # Target Group
  TG_GW_ARN="$(state_get TG_GW_ARN)"
  if [[ -z "$TG_GW_ARN" ]]; then
    TG_GW_ARN="$(get_tg_arn)"
  fi
  
  if [[ -z "$TG_GW_ARN" ]]; then
    TG_GW_ARN="$(awsq elbv2 create-target-group \
      --name "$TG_GW_NAME" \
      --protocol HTTP \
      --port "${PORTS[gateway]}" \
      --vpc-id "$VPC_ID" \
      --target-type ip \
      --health-check-protocol HTTP \
      --health-check-path "$HEALTH_PATH_GATEWAY" \
      --health-check-interval-seconds 30 \
      --healthy-threshold-count 2 \
      --unhealthy-threshold-count 2 \
      --query 'TargetGroups[0].TargetGroupArn' --output text)"
    ok "Target Group creado: $TG_GW_ARN"
  else
    ok "Target Group reutilizado: $TG_GW_ARN"
  fi
  state_set TG_GW_ARN "$TG_GW_ARN"
  
  # Load Balancer
  ALB_ARN="$(state_get ALB_ARN)"
  if [[ -z "$ALB_ARN" ]]; then
    ALB_ARN="$(get_alb_arn)"
  fi
  
  if [[ -z "$ALB_ARN" ]]; then
    ALB_ARN="$(awsq elbv2 create-load-balancer \
      --name "$ALB_NAME" \
      --type application \
      --scheme internet-facing \
      --subnets "$PUB1_ID" "$PUB2_ID" \
      --security-groups "$SG_ALB_ID" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
    ok "ALB creado: $ALB_ARN"
  else
    ok "ALB reutilizado: $ALB_ARN"
  fi
  state_set ALB_ARN "$ALB_ARN"
  
  # Obtener DNS
  ALB_DNS="$(get_alb_dns "$ALB_ARN")"
  state_set ALB_DNS "$ALB_DNS"
  ok "ALB DNS: $ALB_DNS"
  
  # Listener
  LISTENER_ARN="$(state_get LISTENER_ARN)"
  if [[ -z "$LISTENER_ARN" ]]; then
    LISTENER_ARN="$(awsq elbv2 create-listener \
      --load-balancer-arn "$ALB_ARN" \
      --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" \
      --query 'Listeners[0].ListenerArn' --output text)"
    ok "Listener creado: $LISTENER_ARN"
  else
    awsq elbv2 modify-listener \
      --listener-arn "$LISTENER_ARN" \
      --default-actions "Type=forward,TargetGroupArn=$TG_GW_ARN" >/dev/null 2>&1 || true
    ok "Listener reutilizado: $LISTENER_ARN"
  fi
  state_set LISTENER_ARN "$LISTENER_ARN"
  
  step_done 9
fi

TG_GW_ARN="$(state_get TG_GW_ARN)"
ALB_DNS="$(state_get ALB_DNS)"

# -------------------------
# STEP 10: Task Definitions
# -------------------------
if ! is_step_done 10; then
  log "STEP 10: Registrando Task Definitions..."
  
  # Función para registrar task definition
  register_task_definition() {
    local family="$1" image="$2" port="$3" log_group="$4" cpu="$5" mem="$6"
    local env_json="${7:-[]}" secrets_json="${8:-[]}"
    
    # Validar JSONs
    if ! echo "$env_json" | jq empty 2>/dev/null; then env_json="[]"; fi
    if ! echo "$secrets_json" | jq empty 2>/dev/null; then secrets_json="[]"; fi
    
    awsq ecs register-task-definition \
      --family "$family" \
      --network-mode awsvpc \
      --requires-compatibilities FARGATE \
      --cpu "$cpu" \
      --memory "$mem" \
      --execution-role-arn "$ROLE_ARN" \
      --task-role-arn "$ROLE_ARN" \
      --container-definitions "[{
        \"name\": \"${family##*-}\",
        \"image\": \"$image\",
        \"essential\": true,
        \"portMappings\": [{\"containerPort\": $port, \"protocol\": \"tcp\"}],
        \"environment\": $env_json,
        \"secrets\": $secrets_json,
        \"logConfiguration\": {
          \"logDriver\": \"awslogs\",
          \"options\": {
            \"awslogs-group\": \"$log_group\",
            \"awslogs-region\": \"$REGION\",
            \"awslogs-stream-prefix\": \"ecs\"
          }
        }
      }]" \
      --query 'taskDefinition.taskDefinitionArn' --output text
  }
  
  # Construir variables de entorno
  ENV_CLIENT_BASE="$(jq -nc --arg ns "$NAMESPACE_NAME" '[
    {"name":"SPRING_CLOUD_CONFIG_URI","value":("http://configservice." + $ns + ":8081")},
    {"name":"SPRING_CLOUD_CONFIG_FAIL_FAST","value":"false"},
    {"name":"EUREKA_CLIENT_SERVICEURL_DEFAULTZONE","value":("http://eurekaservice." + $ns + ":8761/eureka/")}
  ]')"
  
  ENV_CONFIG="$(jq -nc \
    --arg uri "$CONFIG_GIT_URI" \
    --arg branch "$CONFIG_GIT_BRANCH" \
    --arg paths "$CONFIG_GIT_PATHS" \
    '[
      {"name":"SERVER_PORT","value":"8081"},
      {"name":"SPRING_APPLICATION_NAME","value":"configservice"},
      {"name":"SPRING_PROFILES_ACTIVE","value":"git"},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_URI","value":$uri},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL","value":$branch},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCH_PATHS","value":$paths},
      {"name":"SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START","value":"true"}
    ]')"
  
  ENV_EUREKA="$(merge_json_arrays "$ENV_CLIENT_BASE" "$(jq -nc '[
    {"name":"SERVER_PORT","value":"8761"},
    {"name":"EUREKA_CLIENT_REGISTER_WITH_EUREKA","value":"false"},
    {"name":"EUREKA_CLIENT_FETCH_REGISTRY","value":"false"}
    ]')")"
  
  # Secrets
  SECRETS_DB="[]"
  if [[ -n "${SECRET_DB_ARN:-}" ]]; then
    SECRETS_DB="$(jq -nc --arg arn "$SECRET_DB_ARN" '[
      {"name":"SPRING_DATASOURCE_URL","valueFrom":($arn + ":jdbcUrl::")},
      {"name":"SPRING_DATASOURCE_USERNAME","valueFrom":($arn + ":username::")},
      {"name":"SPRING_DATASOURCE_PASSWORD","valueFrom":($arn + ":password::")}
    ]')"
  fi
  
  SECRETS_JWT="[]"
  if [[ -n "${SECRET_JWT_ARN:-}" ]]; then
    SECRETS_JWT="$(jq -nc --arg arn "$SECRET_JWT_ARN" '[
      {"name":"JWT_SECRET","valueFrom":($arn + ":secret::")}
    ]')"
  fi
  
  SECRETS_USERS="$(merge_json_arrays "$SECRETS_DB" "$SECRETS_JWT")"
  
  # Registrar task definitions
  LG_CONFIG="$(state_get LG_CONFIG)"
  LG_EUREKA="$(state_get LG_EUREKA)"
  LG_GATEWAY="$(state_get LG_GATEWAY)"
  LG_PRODUCTS="$(state_get LG_PRODUCTS)"
  LG_ORDERS="$(state_get LG_ORDERS)"
  LG_PAY="$(state_get LG_PAY)"
  LG_USERS="$(state_get LG_USERS)"
  
  TD_CONFIG_ARN="$(register_task_definition \
    "${PROJECT}-config" \
    "${ECR_URI}/${PROJECT}-config:${TAG}" \
    "${PORTS[config]}" "$LG_CONFIG" \
    "$CPU_SMALL" "$MEM_SMALL" \
    "$ENV_CONFIG" "[]")"
  state_set TD_CONFIG_ARN "$TD_CONFIG_ARN"
  
  TD_EUREKA_ARN="$(register_task_definition \
    "${PROJECT}-eureka" \
    "${ECR_URI}/${PROJECT}-eureka:${TAG}" \
    "${PORTS[eureka]}" "$LG_EUREKA" \
    "$CPU_SMALL" "$MEM_SMALL" \
    "$ENV_EUREKA" "[]")"
  state_set TD_EUREKA_ARN "$TD_EUREKA_ARN"
  
  TD_GATEWAY_ARN="$(register_task_definition \
    "${PROJECT}-gateway" \
    "${ECR_URI}/${PROJECT}-gateway:${TAG}" \
    "${PORTS[gateway]}" "$LG_GATEWAY" \
    "$CPU_MED" "$MEM_MED" \
    "$ENV_CLIENT_BASE" "[]")"
  state_set TD_GATEWAY_ARN "$TD_GATEWAY_ARN"
  
  TD_PRODUCTS_ARN="$(register_task_definition \
    "${PROJECT}-products" \
    "${ECR_URI}/${PROJECT}-products:${TAG}" \
    "${PORTS[products]}" "$LG_PRODUCTS" \
    "$CPU_SMALL" "$MEM_SMALL" \
    "$ENV_CLIENT_BASE" "$SECRETS_DB")"
  state_set TD_PRODUCTS_ARN "$TD_PRODUCTS_ARN"
  
  TD_ORDERS_ARN="$(register_task_definition \
    "${PROJECT}-orders" \
    "${ECR_URI}/${PROJECT}-orders:${TAG}" \
    "${PORTS[orders]}" "$LG_ORDERS" \
    "$CPU_SMALL" "$MEM_SMALL" \
    "$ENV_CLIENT_BASE" "$SECRETS_DB")"
  state_set TD_ORDERS_ARN "$TD_ORDERS_ARN"
  
  TD_PAY_ARN="$(register_task_definition \
    "${PROJECT}-pay" \
    "${ECR_URI}/${PROJECT}-pay:${TAG}" \
    "${PORTS[pay]}" "$LG_PAY" \
    "$CPU_SMALL" "$MEM_SMALL" \
    "$ENV_CLIENT_BASE" "$SECRETS_DB")"
  state_set TD_PAY_ARN "$TD_PAY_ARN"
  
  TD_USERS_ARN="$(register_task_definition \
    "${PROJECT}-users" \
    "${ECR_URI}/${PROJECT}-users:${TAG}" \
    "${PORTS[users]}" "$LG_USERS" \
    "$CPU_SMALL" "$MEM_SMALL" \
    "$ENV_CLIENT_BASE" "$SECRETS_USERS")"
  state_set TD_USERS_ARN "$TD_USERS_ARN"
  
  step_done 10
fi

# -------------------------
# STEP 11: ECS Services - VERSIÓN CORREGIDA
# -------------------------
if ! is_step_done 11; then
  log "STEP 11: Creando/Actualizando servicios ECS..."
  
  # Configurar network configuration
  if [[ "$MODE_NO_NAT" == "true" ]]; then
    NETCONF_CONFIG="awsvpcConfiguration={subnets=[$PUB1_ID,$PUB2_ID],securityGroups=[$SG_CONFIG_ID],assignPublicIp=ENABLED}"
    NETCONF_PRIVATE="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_PRIVATE_ID],assignPublicIp=DISABLED}"
  else
    NETCONF_CONFIG="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_CONFIG_ID],assignPublicIp=DISABLED}"
    NETCONF_PRIVATE="awsvpcConfiguration={subnets=[$PRI1_ID,$PRI2_ID],securityGroups=[$SG_ECS_PRIVATE_ID],assignPublicIp=DISABLED}"
  fi
  
  # Obtener y LIMPIAR IDs de servicios Cloud Map
  log "Verificando IDs de Cloud Map..."
  
  # Función para limpiar IDs (eliminar textos de log)
  clean_sd_id() {
    local raw_id="$1"
    # Extraer solo el ID (srv-xxxx) usando grep
    echo "$raw_id" | grep -o 'srv-[a-zA-Z0-9]\+' | head -1
  }
  
  SD_CONFIG_ID_RAW="$(state_get SD_CONFIG_ID)"
  SD_CONFIG_ID="$(clean_sd_id "$SD_CONFIG_ID_RAW")"
  ok "Config Service ID: $SD_CONFIG_ID"
  
  SD_EUREKA_ID_RAW="$(state_get SD_EUREKA_ID)"
  SD_EUREKA_ID="$(clean_sd_id "$SD_EUREKA_ID_RAW")"
  ok "Eureka Service ID: $SD_EUREKA_ID"
  
  SD_GATEWAY_ID_RAW="$(state_get SD_GATEWAY_ID)"
  SD_GATEWAY_ID="$(clean_sd_id "$SD_GATEWAY_ID_RAW")"
  ok "Gateway Service ID: $SD_GATEWAY_ID"
  
  SD_PRODUCTS_ID_RAW="$(state_get SD_PRODUCTS_ID)"
  SD_PRODUCTS_ID="$(clean_sd_id "$SD_PRODUCTS_ID_RAW")"
  ok "Products Service ID: $SD_PRODUCTS_ID"
  
  SD_ORDERS_ID_RAW="$(state_get SD_ORDERS_ID)"
  SD_ORDERS_ID="$(clean_sd_id "$SD_ORDERS_ID_RAW")"
  ok "Orders Service ID: $SD_ORDERS_ID"
  
  SD_PAY_ID_RAW="$(state_get SD_PAY_ID)"
  SD_PAY_ID="$(clean_sd_id "$SD_PAY_ID_RAW")"
  ok "Payments Service ID: $SD_PAY_ID"
  
  SD_USERS_ID_RAW="$(state_get SD_USERS_ID)"
  SD_USERS_ID="$(clean_sd_id "$SD_USERS_ID_RAW")"
  ok "Users Service ID: $SD_USERS_ID"
  
  # Verificar que todos los IDs existen y están limpios
  for svc in config eureka gateway products orders pay users; do
    id_var="SD_${svc^^}_ID"
    if [[ -z "${!id_var}" ]]; then
      error "ID de Cloud Map para $svc no encontrado"
      exit 1
    fi
  done
  
  # Obtener ARNs de task definitions
  TD_CONFIG_ARN="$(state_get TD_CONFIG_ARN)"
  TD_EUREKA_ARN="$(state_get TD_EUREKA_ARN)"
  TD_GATEWAY_ARN="$(state_get TD_GATEWAY_ARN)"
  TD_PRODUCTS_ARN="$(state_get TD_PRODUCTS_ARN)"
  TD_ORDERS_ARN="$(state_get TD_ORDERS_ARN)"
  TD_PAY_ARN="$(state_get TD_PAY_ARN)"
  TD_USERS_ARN="$(state_get TD_USERS_ARN)"
  
  # Función para crear/actualizar servicio
  create_or_update_service() {
    local service_name="$1" td_arn="$2" netconf="$3" sd_id="$4"
    local tg_arn="${5:-}" container_name="${6:-}" container_port="${7:-}"
    
    # Construir el registry ARN (con ID limpio)
    local registry_arn="arn:aws:servicediscovery:${REGION}:${ACCOUNT_ID}:service/${sd_id}"
    log "Registry ARN: $registry_arn"
    
    if service_exists "$service_name"; then
      log "Actualizando servicio existente: $service_name"
      
      # Actualizar servicio existente
      local update_cmd=(
        awsq ecs update-service
        --cluster "$CLUSTER_NAME"
        --service "$service_name"
        --task-definition "$td_arn"
        --force-new-deployment
      )
      
      # Añadir load balancer si aplica
      if [[ -n "$tg_arn" ]]; then
        update_cmd+=(
          --load-balancers "targetGroupArn=$tg_arn,containerName=$container_name,containerPort=$container_port"
        )
      fi
      
      "${update_cmd[@]}" >/dev/null
      ok "Servicio $service_name actualizado"
    else
      log "Creando nuevo servicio: $service_name"
      
      # Preparar el servicio registries como JSON (escapado correctamente)
      local service_registries_json="[{\"registryArn\":\"${registry_arn}\"}]"
      log "Service registries JSON: $service_registries_json"
      
      # Comando base de creación
      local create_cmd=(
        awsq ecs create-service
        --cluster "$CLUSTER_NAME"
        --service-name "$service_name"
        --task-definition "$td_arn"
        --desired-count 1
        --launch-type FARGATE
        --network-configuration "$netconf"
        --service-registries "$service_registries_json"
        --health-check-grace-period-seconds 120
      )
      
      # Añadir load balancer si aplica
      if [[ -n "$tg_arn" ]]; then
        create_cmd+=(
          --load-balancers "targetGroupArn=$tg_arn,containerName=$container_name,containerPort=$container_port"
        )
      fi
      
      # Ejecutar comando
      "${create_cmd[@]}" >/dev/null
      ok "Servicio $service_name creado"
    fi
  }
  
  # Crear servicios en orden (config primero, luego eureka, luego el resto)
  log "Desplegando Config Service..."
  create_or_update_service "configservice" "$TD_CONFIG_ARN" "$NETCONF_CONFIG" "$SD_CONFIG_ID"
  wait_service_stable "configservice"
  
  log "Desplegando Eureka Service..."
  create_or_update_service "eurekaservice" "$TD_EUREKA_ARN" "$NETCONF_PRIVATE" "$SD_EUREKA_ID"
  wait_service_stable "eurekaservice"
  
  # Pequeña pausa para que Eureka se estabilice
  sleep 15
  
  log "Desplegando Gateway Service (público)..."
  create_or_update_service "gatewayservice" "$TD_GATEWAY_ARN" "$NETCONF_PRIVATE" "$SD_GATEWAY_ID" \
    "$TG_GW_ARN" "gateway" "${PORTS[gateway]}"
  
  log "Desplegando servicios de negocio..."
  create_or_update_service "productservice" "$TD_PRODUCTS_ARN" "$NETCONF_PRIVATE" "$SD_PRODUCTS_ID"
  create_or_update_service "orderservice" "$TD_ORDERS_ARN" "$NETCONF_PRIVATE" "$SD_ORDERS_ID"
  create_or_update_service "paymentservice" "$TD_PAY_ARN" "$NETCONF_PRIVATE" "$SD_PAY_ID"
  create_or_update_service "userservice" "$TD_USERS_ARN" "$NETCONF_PRIVATE" "$SD_USERS_ID"
  
  step_done 11
fi
# -------------------------
# FINAL: Mostrar resumen
# -------------------------
echo ""
echo -e "${GREEN}=========================================================${NC}"
echo -e "${GREEN}✅ DEPLOY COMPLETADO CON ÉXITO${NC}"
echo -e "${GREEN}=========================================================${NC}"
echo "🔗 ALB URL: http://${ALB_DNS}"
echo "🔍 Health Check: http://${ALB_DNS}${HEALTH_PATH_GATEWAY}"
echo "📁 Estado guardado en: ${STATE_FILE}"
echo ""
echo "📊 Servicios desplegados:"
echo "   - Config Server   : configservice.${NAMESPACE_NAME}:8081"
echo "   - Eureka          : eurekaservice.${NAMESPACE_NAME}:8761"
echo "   - Gateway         : ${ALB_DNS}"
echo "   - Products        : productservice.${NAMESPACE_NAME}:8001"
echo "   - Orders          : orderservice.${NAMESPACE_NAME}:8002"
echo "   - Payments        : paymentservice.${NAMESPACE_NAME}:8003"
echo "   - Users           : userservice.${NAMESPACE_NAME}:8004"
echo ""

if [[ -n "${DB_ENDPOINT:-}" ]]; then
  echo -e "${GREEN}🗄️  RDS Endpoint: ${DB_ENDPOINT}${NC}"
  echo "   Base de datos: ${DB_NAME}"
  echo "   Usuario: ${DB_USER}"
else
  echo -e "${YELLOW}🗄️  RDS: No configurada (usa CREATE_RDS=true o export DB_ENDPOINT)${NC}"
fi

echo ""
echo -e "${BLUE}🔄 Para re-ejecutar: ./aws-full-deploy.sh [ruta/a/.env]${NC}"
echo -e "${GREEN}=========================================================${NC}"