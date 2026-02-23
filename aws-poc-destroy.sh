#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# aws-poc-destroy.sh - DESTRUCCIÓN COMPLETA DE RECURSOS
# Versión mejorada que combina lo mejor de ambos scripts
# ============================================================

# Configuración de colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# -------------------------
# FUNCIONES DE LOGGING
# -------------------------
log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] 👉${NC} $*"; }
ok()  { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅${NC} $*"; }
warn(){ echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️${NC} $*"; }
error(){ echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌${NC} $*"; }
info(){ echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] ℹ️${NC} $*"; }

# -------------------------
# CONFIGURACIÓN (desde .env o parámetros)
# -------------------------
load_config() {
    # Intentar cargar desde .env
    if [[ -f ".env" ]]; then
        info "Cargando configuración desde .env"
        set -a
        source .env
        set +a
    fi
    
    # Intentar cargar desde state file más reciente
    STATE_FILE="${STATE_FILE:-$(ls -t .deploy_state.*.json 2>/dev/null | head -1)}"
    
    if [[ -f "$STATE_FILE" ]]; then
        info "Cargando estado desde: $STATE_FILE"
        
        # Extraer valores del state file
        export PROJECT="$(jq -r '.PROJECT // "microservices-fargate"' "$STATE_FILE")"
        export ENV_NAME="$(jq -r '.ENV_NAME // "prod"' "$STATE_FILE")"
        export REGION="$(jq -r '.REGION // "us-east-1"' "$STATE_FILE")"
        
        # IDs específicos
        VPC_ID="$(jq -r '.VPC_ID // empty' "$STATE_FILE")"
        ALB_ARN="$(jq -r '.ALB_ARN // empty' "$STATE_FILE")"
        TG_GW_ARN="$(jq -r '.TG_GW_ARN // empty' "$STATE_FILE")"
        
        ok "Configuración cargada: $PROJECT-$ENV_NAME en $REGION"
    else
        # Valores por defecto
        export PROJECT="${PROJECT:-microservices-fargate}"
        export ENV_NAME="${ENV_NAME:-prod}"
        export REGION="${REGION:-us-east-1}"
        warn "No se encontró state file, usando valores por defecto"
    fi
    
    # Configurar nombres de recursos basados en PROJECT
    export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT}-${ENV_NAME}-cluster}"
    export NAMESPACE_NAME="${NAMESPACE_NAME:-${PROJECT}-${ENV_NAME}.local}"
    export ROLE_NAME="${PROJECT}-${ENV_NAME}-ecsTaskExecutionRole"
    
    # ALB (versión corta para no exceder 32 chars)
    export ALB_NAME="${ALB_NAME:-ms-${ENV_NAME}-alb}"
    export TG_GW_NAME="${TG_GW_NAME:-ms-${ENV_NAME}-gw}"
    
    # Security groups
    export SG_ALB_NAME="${PROJECT}-${ENV_NAME}-sg-alb"
    export SG_ECS_PRIVATE_NAME="${PROJECT}-${ENV_NAME}-sg-ecs-private"
    export SG_CONFIG_NAME="${PROJECT}-${ENV_NAME}-sg-config"
    export SG_RDS_NAME="${PROJECT}-${ENV_NAME}-sg-rds"
    export SG_VPCE_NAME="${PROJECT}-${ENV_NAME}-sg-vpce"
    
    # VPC tags
    export VPC_TAG_NAME="${PROJECT}-${ENV_NAME}-vpc"
    export IGW_TAG_NAME="${PROJECT}-${ENV_NAME}-igw"
    
    # Log groups
    export LG_CONFIG="/ecs/${PROJECT}/${ENV_NAME}/config"
    export LG_EUREKA="/ecs/${PROJECT}/${ENV_NAME}/eureka"
    export LG_GATEWAY="/ecs/${PROJECT}/${ENV_NAME}/gateway"
    export LG_PRODUCTS="/ecs/${PROJECT}/${ENV_NAME}/products"
    export LG_ORDERS="/ecs/${PROJECT}/${ENV_NAME}/orders"
    export LG_PAY="/ecs/${PROJECT}/${ENV_NAME}/pay"
    export LG_USERS="/ecs/${PROJECT}/${ENV_NAME}/users"
    
    # ECR repos
    export ECR_REPOS=(
        "${PROJECT}-config"
        "${PROJECT}-eureka"
        "${PROJECT}-gateway"
        "${PROJECT}-products"
        "${PROJECT}-orders"
        "${PROJECT}-pay"
        "${PROJECT}-users"
    )
    
    # Task Definition families
    export TD_FAMILIES=(
        "${PROJECT}-config"
        "${PROJECT}-eureka"
        "${PROJECT}-gateway"
        "${PROJECT}-products"
        "${PROJECT}-orders"
        "${PROJECT}-pay"
        "${PROJECT}-users"
    )
    
    # RDS
    export DB_INSTANCE_ID="${PROJECT}-${ENV_NAME}-mysql"
    export DB_SUBNET_GROUP="${PROJECT}-${ENV_NAME}-db-subnets"
}

# -------------------------
# FUNCIONES AWS
# -------------------------
awsq() { aws --region "$REGION" "$@"; }
exists() { "$@" >/dev/null 2>&1; }

# -------------------------
# FUNCIONES DE UTILIDAD
# -------------------------
get_vpc_id() {
    awsq ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=${VPC_TAG_NAME}" \
        --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -v None || true
}

get_igw_id() {
    awsq ec2 describe-internet-gateways \
        --filters "Name=tag:Name,Values=${IGW_TAG_NAME}" \
        --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -v None || true
}

get_sg_id_by_name() {
    local name="$1"
    local vpc_id="$2"
    awsq ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${name}" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true
}

get_alb_arn() {
    awsq elbv2 describe-load-balancers --names "$ALB_NAME" \
        --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null | grep -v None || true
}

get_listener_arns() {
    local alb_arn="$1"
    awsq elbv2 describe-listeners --load-balancer-arn "$alb_arn" \
        --query "Listeners[].ListenerArn" --output text 2>/dev/null || true
}

get_tg_arn_by_name() {
    local name="$1"
    awsq elbv2 describe-target-groups --names "$name" \
        --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null | grep -v None || true
}

delete_log_group() {
    local lg="$1"
    if exists awsq logs describe-log-groups --log-group-name-prefix "$lg" \
        --query "logGroups[?logGroupName=='$lg'].logGroupName" --output text | grep -q "$lg"; then
        log "Eliminando log group: $lg"
        awsq logs delete-log-group --log-group-name "$lg" >/dev/null || true
    fi
}

delete_taskdef_family() {
    local family="$1"
    local arns
    arns="$(awsq ecs list-task-definitions --family-prefix "$family" --status ACTIVE \
        --query "taskDefinitionArns[]" --output text 2>/dev/null || true)"
    if [[ -n "${arns// }" ]]; then
        for td in $arns; do
            log "Deregistrando task definition: $td"
            awsq ecs deregister-task-definition --task-definition "$td" >/dev/null || true
        done
    fi
}

# ---- NAT helpers ----
list_nat_gateways_in_vpc() {
    local vpc_id="$1"
    awsq ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=${vpc_id}" \
        --query "NatGateways[?State!='deleted'].NatGatewayId" \
        --output text 2>/dev/null || true
}

nat_eip_allocation_ids() {
    local nat_id="$1"
    awsq ec2 describe-nat-gateways \
        --nat-gateway-ids "$nat_id" \
        --query "NatGateways[0].NatGatewayAddresses[].AllocationId" \
        --output text 2>/dev/null || true
}

wait_nat_deleted() {
    local nat_id="$1"
    info "Esperando eliminación NAT: $nat_id"
    for i in {1..60}; do
        state="$(awsq ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" \
            --query "NatGateways[0].State" --output text 2>/dev/null || true)"
        if [[ "$state" == "deleted" || "$state" == "None" || -z "$state" ]]; then
            ok "NAT eliminado: $nat_id"
            return 0
        fi
        info "Estado NAT: $state (intento $i/60)"
        sleep 10
    done
    warn "Timeout esperando NAT deleted: $nat_id"
}

# -------------------------
# CONFIRMACIÓN
# -------------------------
confirm_destroy() {
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  ATENCIÓN  ⚠️                          ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  Esto DESTRUIRÁ PERMANENTEMENTE todos los recursos:        ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  - ECS Services y Tasks                                    ║${NC}"
    echo -e "${RED}║  - Cloud Map Services y Namespace                          ║${NC}"
    echo -e "${RED}║  - Load Balancer (ALB) y Target Groups                     ║${NC}"
    echo -e "${RED}║  - VPC, Subnets, NAT Gateway, Internet Gateway             ║${NC}"
    echo -e "${RED}║  - Security Groups y VPC Endpoints                         ║${NC}"
    echo -e "${RED}║  - CloudWatch Log Groups                                   ║${NC}"
    echo -e "${RED}║  - IAM Role                                                 ║${NC}"
    echo -e "${RED}║  - ECR Repositories (opcional)                             ║${NC}"
    echo -e "${RED}║  - Secrets en Secrets Manager (opcional)                   ║${NC}"
    echo -e "${RED}║  - RDS Database (si fue creada)                            ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Proyecto: $PROJECT"
    echo "Entorno: $ENV_NAME"
    echo "Región: $REGION"
    echo "Cluster: $CLUSTER_NAME"
    echo ""
    read -p "¿Estás SEGURO de que quieres destruir todo? (escribe 'destruir' para confirmar): " confirmation
    
    if [[ "$confirmation" != "destruir" ]]; then
        error "Confirmación fallida. Abortando."
        exit 1
    fi
    
    # Segunda confirmación
    echo ""
    warn "ÚLTIMA OPORTUNIDAD: Esta acción NO SE PUEDE DESHACER"
    read -p "¿Confirmar destrucción? (si/NO): " final_confirm
    
    if [[ ! "$final_confirm" =~ ^[Ss][Ii]$ ]]; then
        error "Abortando por confirmación final negativa"
        exit 1
    fi
    
    ok "Confirmación recibida. Procediendo con la destrucción..."
}

# -------------------------
# FUNCIONES DE DESTRUCCIÓN
# -------------------------

# 0) RDS (opcional)
destroy_rds() {
    if [[ "${DELETE_RDS:-false}" == "true" ]]; then
        info "=== 0) Procesando RDS ==="
        
        # Verificar si hay instancia RDS
        if exists awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" 2>/dev/null; then
            log "Eliminando DB instance: $DB_INSTANCE_ID (skip final snapshot)"
            awsq rds delete-db-instance \
                --db-instance-identifier "$DB_INSTANCE_ID" \
                --skip-final-snapshot \
                --delete-automated-backups >/dev/null 2>&1 || true
            
            info "Esperando eliminación de RDS (puede tomar varios minutos)..."
            awsq rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID" 2>/dev/null || true
            ok "RDS instance eliminada"
        else
            info "RDS instance no encontrada"
        fi
        
        # Eliminar DB subnet group
        if exists awsq rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" 2>/dev/null; then
            log "Eliminando DB subnet group: $DB_SUBNET_GROUP"
            awsq rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1 || true
            ok "DB subnet group eliminado"
        fi
    fi
}

# 1) ECS Services
destroy_ecs_services() {
    info "=== 1) Eliminando ECS Services ==="
    
    if exists awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null; then
        local services
        services="$(awsq ecs list-services --cluster "$CLUSTER_NAME" --query "serviceArns[]" --output text 2>/dev/null || true)"
        
        if [[ -n "${services// }" ]]; then
            # Lista de servicios en orden inverso al de creación
            local ordered_services=()
            for svc_arn in $services; do
                svc_name="$(basename "$svc_arn")"
                ordered_services+=("$svc_name")
            done
            
            # Ordenar: users, payments, orders, products, gateway, eureka, config
            # (esto es solo visual, la eliminación forzada funciona en cualquier orden)
            
            for svc_arn in $services; do
                svc_name="$(basename "$svc_arn")"
                log "Procesando servicio: $svc_name"
                
                # Escalar a 0
                log "Escalando a 0: $svc_name"
                awsq ecs update-service --cluster "$CLUSTER_NAME" --service "$svc_name" --desired-count 0 >/dev/null 2>&1 || true
                sleep 2
                
                # Eliminar servicio
                log "Eliminando servicio: $svc_name"
                awsq ecs delete-service --cluster "$CLUSTER_NAME" --service "$svc_name" --force >/dev/null 2>&1 || true
            done
            
            info "Esperando 30 segundos para que los servicios se eliminen..."
            sleep 30
        else
            info "No hay servicios ECS"
        fi
    else
        info "Cluster ECS no encontrado"
    fi
}

# 2) Task Definitions
destroy_task_definitions() {
    info "=== 2) Deregistrando Task Definitions ==="
    
    for fam in "${TD_FAMILIES[@]}"; do
        log "Procesando familia: $fam"
        delete_taskdef_family "$fam"
    done
}

# 3) ECS Cluster
destroy_ecs_cluster() {
    info "=== 3) Eliminando ECS Cluster ==="
    
    if exists awsq ecs describe-clusters --clusters "$CLUSTER_NAME" --query "clusters[0].status" --output text 2>/dev/null; then
        log "Eliminando cluster: $CLUSTER_NAME"
        awsq ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
        ok "Cluster eliminado"
    else
        info "Cluster no encontrado"
    fi
}

# 4) ALB + Target Groups
destroy_alb() {
    info "=== 4) Eliminando ALB y Target Groups ==="
    
    ALB_ARN="$(get_alb_arn)"
    if [[ -n "${ALB_ARN}" ]]; then
        # Eliminar listeners
        local listeners
        listeners="$(get_listener_arns "$ALB_ARN")"
        if [[ -n "${listeners// }" ]]; then
            for lst in $listeners; do
                log "Eliminando listener: $lst"
                awsq elbv2 delete-listener --listener-arn "$lst" >/dev/null 2>&1 || true
            done
        fi
        
        # Eliminar ALB
        log "Eliminando ALB: $ALB_NAME"
        awsq elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" >/dev/null 2>&1 || true
        
        info "Esperando eliminación de ALB..."
        awsq elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
        ok "ALB eliminado"
    else
        info "ALB no encontrado"
    fi
    
    # Eliminar Target Group
    TG_ARN="$(get_tg_arn_by_name "$TG_GW_NAME")"
    if [[ -n "${TG_ARN}" ]]; then
        log "Eliminando target group: $TG_GW_NAME"
        awsq elbv2 delete-target-group --target-group-arn "$TG_ARN" >/dev/null 2>&1 || true
        ok "Target group eliminado"
    else
        info "Target group no encontrado"
    fi
}

# 5) Cloud Map
destroy_cloudmap() {
    info "=== 5) Eliminando Cloud Map ==="
    
    local ns_id
    ns_id="$(awsq servicediscovery list-namespaces \
        --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" --output text 2>/dev/null | grep -v None || true)"
    
    if [[ -n "${ns_id}" ]]; then
        log "Namespace encontrado: $NAMESPACE_NAME ($ns_id)"
        
        # Eliminar servicios
        local svc_ids
        svc_ids="$(awsq servicediscovery list-services \
            --query "Services[?NamespaceId=='${ns_id}'].Id" --output text 2>/dev/null || true)"
        
        if [[ -n "${svc_ids// }" ]]; then
            for sid in $svc_ids; do
                log "Eliminando Cloud Map service: $sid"
                awsq servicediscovery delete-service --id "$sid" >/dev/null 2>&1 || true
            done
            
            # Esperar a que se eliminen los servicios
            info "Esperando eliminación de servicios Cloud Map..."
            for i in {1..30}; do
                svc_left="$(awsq servicediscovery list-services \
                    --query "Services[?NamespaceId=='${ns_id}'].Id" --output text 2>/dev/null || true)"
                if [[ -z "${svc_left// }" ]]; then
                    break
                fi
                sleep 5
            done
        fi
        
        # Eliminar namespace
        log "Eliminando namespace: $NAMESPACE_NAME"
        for i in {1..20}; do
            if awsq servicediscovery delete-namespace --id "$ns_id" >/dev/null 2>&1; then
                ok "Namespace eliminado"
                break
            fi
            info "Namespace aún en uso, reintentando... ($i/20)"
            sleep 5
        done
    else
        info "Namespace Cloud Map no encontrado"
    fi
}

# 6) VPC Endpoints
destroy_vpc_endpoints() {
    info "=== 6) Eliminando VPC Endpoints ==="
    
    local vpc_id="$1"
    if [[ -z "$vpc_id" ]]; then
        vpc_id="$(get_vpc_id)"
    fi
    
    if [[ -n "${vpc_id}" ]]; then
        local vpce_ids
        vpce_ids="$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${vpc_id}" \
            --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)"
        
        if [[ -n "${vpce_ids// }" ]]; then
            log "Eliminando VPC endpoints: $vpce_ids"
            awsq ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpce_ids >/dev/null 2>&1 || true
            ok "VPC endpoints eliminados"
        else
            info "No hay VPC endpoints"
        fi
    fi
}

# 7) CloudWatch Logs
destroy_log_groups() {
    info "=== 7) Eliminando CloudWatch Log Groups ==="
    
    delete_log_group "$LG_CONFIG"
    delete_log_group "$LG_EUREKA"
    delete_log_group "$LG_GATEWAY"
    delete_log_group "$LG_PRODUCTS"
    delete_log_group "$LG_ORDERS"
    delete_log_group "$LG_PAY"
    delete_log_group "$LG_USERS"
}

# 8) IAM Role
destroy_iam_role() {
    info "=== 8) Eliminando IAM Role ==="
    
    if exists aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
        # Detachar políticas
        log "Detachando políticas del rol: $ROLE_NAME"
        aws iam detach-role-policy --role-name "$ROLE_NAME" \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1 || true
        aws iam detach-role-policy --role-name "$ROLE_NAME" \
            --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite >/dev/null 2>&1 || true
        
        # Eliminar rol
        log "Eliminando rol: $ROLE_NAME"
        aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
        ok "Rol IAM eliminado"
    else
        info "Rol IAM no encontrado"
    fi
}

# 9) Secrets Manager (opcional)
destroy_secrets() {
    warn "¿Eliminar también los secrets de Secrets Manager?"
    read -p "Esto eliminará JWT y credenciales de DB (s/N): " delete_secrets
    
    if [[ "$delete_secrets" =~ ^[Ss]$ ]]; then
        info "=== 9) Eliminando Secrets Manager ==="
        
        local secrets=("${PROJECT}/db" "${PROJECT}/jwt")
        
        for secret in "${secrets[@]}"; do
            if awsq secretsmanager describe-secret --secret-id "$secret" >/dev/null 2>&1; then
                log "Eliminando secret: $secret"
                awsq secretsmanager delete-secret \
                    --secret-id "$secret" \
                    --force-delete-without-recovery >/dev/null 2>&1 || true
                ok "Secret $secret eliminado"
            fi
        done
    fi
}

# 10) ECR Repos (opcional)
destroy_ecr_repos() {
    if [[ "${FORCE_ECR_DELETE:-false}" == "true" ]]; then
        info "=== 10) Eliminando ECR Repositorios ==="
        
        for repo in "${ECR_REPOS[@]}"; do
            if exists awsq ecr describe-repositories --repository-names "$repo" 2>/dev/null; then
                log "Eliminando ECR repo: $repo"
                awsq ecr delete-repository --repository-name "$repo" --force >/dev/null 2>&1 || true
                ok "Repositorio $repo eliminado"
            else
                info "Repo no encontrado: $repo"
            fi
        done
    else
        warn "FORCE_ECR_DELETE=false - No se eliminarán repositorios ECR"
    fi
}

# 11) VPC y Networking (completo)
destroy_networking() {
    info "=== 11) Eliminando VPC y recursos de red ==="
    
    local vpc_id="$1"
    if [[ -z "$vpc_id" ]]; then
        vpc_id="$(get_vpc_id)"
    fi
    
    if [[ -z "$vpc_id" ]]; then
        info "VPC no encontrada"
        return 0
    fi
    
    log "Procesando VPC: $vpc_id"
    
    # 11.1) NAT Gateways
    info "--- 11.1) Eliminando NAT Gateways ---"
    local nat_ids
    nat_ids="$(list_nat_gateways_in_vpc "$vpc_id")"
    if [[ -n "${nat_ids// }" ]]; then
        for nat in $nat_ids; do
            log "Eliminando NAT Gateway: $nat"
            local allocs
            allocs="$(nat_eip_allocation_ids "$nat")"
            
            awsq ec2 delete-nat-gateway --nat-gateway-id "$nat" >/dev/null 2>&1 || true
            wait_nat_deleted "$nat"
            
            # Liberar EIPs
            if [[ -n "${allocs// }" ]]; then
                for alloc in $allocs; do
                    log "Liberando EIP: $alloc"
                    awsq ec2 release-address --allocation-id "$alloc" >/dev/null 2>&1 || true
                done
            fi
        done
    else
        info "No hay NAT Gateways"
    fi
    
    # 11.2) Security Groups
    info "--- 11.2) Eliminando Security Groups ---"
    local sg_ids=()
    
    for sg_name in "$SG_ALB_NAME" "$SG_ECS_PRIVATE_NAME" "$SG_CONFIG_NAME" "$SG_RDS_NAME" "$SG_VPCE_NAME"; do
        sg_id="$(get_sg_id_by_name "$sg_name" "$vpc_id")"
        if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
            sg_ids+=("$sg_id")
        fi
    done
    
    # También buscar cualquier SG con el tag del proyecto
    local project_sgs
    project_sgs="$(awsq ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Project,Values=$PROJECT" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)"
    
    for sg in $project_sgs; do
        if [[ ! " ${sg_ids[@]} " =~ " ${sg} " ]]; then
            sg_ids+=("$sg")
        fi
    done
    
    # Eliminar SGs (varias veces para superar dependencias)
    for attempt in {1..3}; do
        for sg in "${sg_ids[@]}"; do
            log "Eliminando SG (intento $attempt): $sg"
            awsq ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || true
        done
        sleep 5
    done
    
    # 11.3) Internet Gateway
    info "--- 11.3) Eliminando Internet Gateway ---"
    local igw_id
    igw_id="$(get_igw_id)"
    if [[ -n "$igw_id" ]]; then
        log "Desasociando IGW: $igw_id"
        awsq ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" >/dev/null 2>&1 || true
        log "Eliminando IGW: $igw_id"
        awsq ec2 delete-internet-gateway --internet-gateway-id "$igw_id" >/dev/null 2>&1 || true
    fi
    
    # 11.4) Route Tables
    info "--- 11.4) Eliminando Route Tables ---"
    local rtbs
    rtbs="$(awsq ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" \
        --query "RouteTables[].RouteTableId" --output text 2>/dev/null || true)"
    
    for rtb in $rtbs; do
        # Verificar si es la tabla principal
        local is_main
        is_main="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" \
            --query "RouteTables[0].Associations[?Main==\`true\`].Main | [0]" --output text 2>/dev/null || true)"
        
        if [[ "$is_main" == "True" ]]; then
            info "Tabla principal (se eliminará con VPC)"
            continue
        fi
        
        # Disociar subnets
        local assocs
        assocs="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" \
            --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null || true)"
        
        if [[ -n "${assocs// }" ]]; then
            for a in $assocs; do
                log "Disociando RTB assoc: $a"
                awsq ec2 disassociate-route-table --association-id "$a" >/dev/null 2>&1 || true
            done
        fi
        
        log "Eliminando route table: $rtb"
        awsq ec2 delete-route-table --route-table-id "$rtb" >/dev/null 2>&1 || true
    done
    
    # 11.5) Subnets
    info "--- 11.5) Eliminando Subnets ---"
    local subnets
    subnets="$(awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" \
        --query "Subnets[].SubnetId" --output text 2>/dev/null || true)"
    
    for sn in $subnets; do
        log "Eliminando subnet: $sn"
        awsq ec2 delete-subnet --subnet-id "$sn" >/dev/null 2>&1 || true
    done
    
    # 11.6) VPC
    info "--- 11.6) Eliminando VPC ---"
    log "Eliminando VPC: $vpc_id"
    awsq ec2 delete-vpc --vpc-id "$vpc_id" >/dev/null 2>&1 || true
    ok "VPC eliminada"
}

# 12) Archivos de estado
cleanup_state_files() {
    info "=== 12) Limpiando archivos de estado ==="
    
    local state_files=(
        ".deploy_state.${PROJECT}.${ENV_NAME}.${REGION}.json"
        "$STATE_FILE"
    )
    
    for file in "${state_files[@]}"; do
        if [[ -f "$file" ]]; then
            log "Eliminando: $file"
            rm -v "$file"
        fi
    done
    
    # Preguntar si eliminar .env
    if [[ -f ".env" ]]; then
        warn "Se encontró archivo .env con credenciales"
        read -p "¿Eliminar .env? (s/N): " delete_env
        if [[ "$delete_env" =~ ^[Ss]$ ]]; then
            rm -v ".env"
        fi
    fi
}

# -------------------------
# MAIN
# -------------------------
clear
echo -e "${RED}=========================================================${NC}"
echo -e "${RED}     🗑️  AWS POC DESTROY - ELIMINAR TODOS LOS RECURSOS   ${NC}"
echo -e "${RED}=========================================================${NC}"

# Cargar configuración
load_config

# Confirmar destrucción
confirm_destroy

# Ejecutar destrucción en orden
destroy_rds
destroy_ecs_services
destroy_task_definitions
destroy_ecs_cluster
destroy_alb
destroy_cloudmap

# Obtener VPC ID para siguientes pasos
VPC_ID="$(get_vpc_id)"
destroy_vpc_endpoints "$VPC_ID"
destroy_log_groups
destroy_iam_role
destroy_secrets
destroy_ecr_repos
destroy_networking "$VPC_ID"
cleanup_state_files

# Resumen final
echo ""
echo -e "${GREEN}=========================================================${NC}"
echo -e "${GREEN}     ✅ DESTRUCCIÓN COMPLETADA EXITOSAMENTE              ${NC}"
echo -e "${GREEN}=========================================================${NC}"
echo ""
echo "📊 Resumen de recursos eliminados:"
echo "   - Proyecto: $PROJECT"
echo "   - Entorno: $ENV_NAME"
echo "   - Región: $REGION"
echo "   - VPC: ${VPC_ID:-No encontrada}"
echo ""
echo "🔍 Revisa la consola de AWS para verificar que no queden recursos residuales."
echo ""