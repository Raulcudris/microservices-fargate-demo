#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# CLEANUP SCRIPT - Elimina todos los recursos desplegados
# ==========================================================

# ----------------------------
# CONFIGURACIÓN
# ----------------------------
REGION="us-east-1"
PROJECT_NAME="microservices-fargate"
ENV_NAME="prod"
STACK_NAME="${PROJECT_NAME}-${ENV_NAME}-pro"
DB_SECRET_NAME="${PROJECT_NAME}/${ENV_NAME}/db"
JWT_SECRET_NAME="${PROJECT_NAME}/${ENV_NAME}/jwt"
RDS_IDENTIFIER="${RDS_IDENTIFIER:-${PROJECT_NAME}-${ENV_NAME}-mysql}"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ----------------------------
# FUNCIONES DE AYUDA
# ----------------------------
log() { echo -e "\n==========================================================\n$1\n=========================================================="; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

confirm() {
    read -r -p "$1 (y/N) " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Obtener ID de cuenta AWS
aws_account_id() { 
    aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null || echo ""
}

# ----------------------------
# LIMPIEZA DE RECURSOS
# ----------------------------

cleanup_ecr_repositories() {
    log "🧹 Limpiando repositorios ECR"
    
    local repos=(
        "${PROJECT_NAME}/configservice"
        "${PROJECT_NAME}/msvc-eureka"
        "${PROJECT_NAME}/msvc-gateway"
        "${PROJECT_NAME}/msvc-users"
        "${PROJECT_NAME}/msvc-orders"
        "${PROJECT_NAME}/msvc-products"
        "${PROJECT_NAME}/msvc-pay"
    )
    
    for repo in "${repos[@]}"; do
        if aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1; then
            warn "Eliminando repositorio: $repo"
            
            # Primero eliminar todas las imágenes
            local image_ids
            image_ids=$(aws ecr list-images --repository-name "$repo" --region "$REGION" --query 'imageIds[*]' --output json 2>/dev/null)
            
            if [[ "$image_ids" != "[]" && -n "$image_ids" ]]; then
                aws ecr batch-delete-image --repository-name "$repo" --image-ids "$image_ids" --region "$REGION" >/dev/null 2>&1 || true
                success "  Imágenes eliminadas de $repo"
            fi
            
            # Eliminar el repositorio
            aws ecr delete-repository --repository-name "$repo" --region "$REGION" >/dev/null 2>&1 && \
                success "  Repositorio $repo eliminado" || \
                warn "  No se pudo eliminar $repo"
        else
            success "  Repositorio $repo no existe"
        fi
    done
}

cleanup_secrets() {
    log "🔐 Limpiando Secrets Manager"
    
    local secrets=("$DB_SECRET_NAME" "$JWT_SECRET_NAME")
    
    for secret in "${secrets[@]}"; do
        if aws secretsmanager describe-secret --secret-id "$secret" --region "$REGION" >/dev/null 2>&1; then
            warn "Eliminando secreto: $secret"
            
            # Forzar eliminación sin período de recuperación
            aws secretsmanager delete-secret \
                --secret-id "$secret" \
                --force-delete-without-recovery \
                --region "$REGION" >/dev/null 2>&1 && \
                success "  Secreto $secret eliminado" || \
                warn "  No se pudo eliminar $secret"
        else
            success "  Secreto $secret no existe"
        fi
    done
}

cleanup_rds() {
    log "🗄️ Limpiando RDS"
    
    if aws rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" >/dev/null 2>&1; then
        warn "Eliminando instancia RDS: $RDS_IDENTIFIER"
        
        # Desactivar deletion protection si está activada
        local del_protection
        del_protection=$(aws rds describe-db-instances \
            --db-instance-identifier "$RDS_IDENTIFIER" \
            --region "$REGION" \
            --query 'DBInstances[0].DeletionProtection' \
            --output text)
        
        if [[ "$del_protection" == "true" ]]; then
            warn "  Desactivando protección de eliminación..."
            aws rds modify-db-instance \
                --db-instance-identifier "$RDS_IDENTIFIER" \
                --no-deletion-protection \
                --apply-immediately \
                --region "$REGION" >/dev/null 2>&1
            
            # Esperar a que la modificación se complete
            sleep 10
        fi
        
        # Eliminar el snapshot final (no crear snapshot)
        aws rds delete-db-instance \
            --db-instance-identifier "$RDS_IDENTIFIER" \
            --skip-final-snapshot \
            --region "$REGION" >/dev/null 2>&1 && \
            success "  Instancia RDS eliminada" || \
            warn "  No se pudo eliminar la instancia RDS"
        
        # Esperar a que la instancia se elimine
        warn "  Esperando eliminación de RDS (esto puede tomar varios minutos)..."
        aws rds wait db-instance-deleted --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" 2>/dev/null || true
        
    else
        success "  Instancia RDS $RDS_IDENTIFIER no existe"
    fi
    
    # Limpiar subnet groups
    local subnet_group_name="${PROJECT_NAME}-${ENV_NAME}-rds-subnet-group"
    if aws rds describe-db-subnet-groups --db-subnet-group-name "$subnet_group_name" --region "$REGION" >/dev/null 2>&1; then
        warn "Eliminando RDS subnet group: $subnet_group_name"
        aws rds delete-db-subnet-group \
            --db-subnet-group-name "$subnet_group_name" \
            --region "$REGION" >/dev/null 2>&1 && \
            success "  Subnet group eliminado" || \
            warn "  No se pudo eliminar subnet group"
    fi
    
    # Limpiar RDS security group (se eliminará con CloudFormation)
    local rds_sg_name="${PROJECT_NAME}-${ENV_NAME}-rds-sg"
    local vpc_id
    vpc_id=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
        local rds_sg_id
        rds_sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${rds_sg_name}" "Name=vpc-id,Values=${vpc_id}" \
            --query 'SecurityGroups[0].GroupId' \
            --output text \
            --region "$REGION" 2>/dev/null || echo "")
        
        if [[ -n "$rds_sg_id" && "$rds_sg_id" != "None" ]]; then
            warn "Eliminando RDS security group: $rds_sg_id"
            aws ec2 delete-security-group --group-id "$rds_sg_id" --region "$REGION" >/dev/null 2>&1 || true
        fi
    fi
}

cleanup_cloudformation() {
    log "📦 Limpiando stack de CloudFormation: $STACK_NAME"
    
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
        warn "Eliminando stack CloudFormation..."
        
        # Vaciar los buckets de logs si existen (opcional, dependiendo de tu template)
        local log_bucket
        log_bucket=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`LogBucketName`].OutputValue' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$log_bucket" && "$log_bucket" != "None" ]]; then
            warn "  Vaciando bucket de logs: $log_bucket"
            aws s3 rm "s3://${log_bucket}" --recursive --region "$REGION" >/dev/null 2>&1 || true
        fi
        
        # Eliminar el stack
        aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
        
        # Esperar a que se elimine
        warn "  Esperando eliminación del stack (esto puede tomar varios minutos)..."
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
        success "  Stack CloudFormation eliminado"
    else
        success "  Stack CloudFormation no existe"
    fi
}

cleanup_log_groups() {
    log "📊 Limpiando grupos de CloudWatch Logs"
    
    local log_group_prefix="/ecs/${PROJECT_NAME}"
    local log_groups
    log_groups=$(aws logs describe-log-groups \
        --log-group-name-prefix "$log_group_prefix" \
        --region "$REGION" \
        --query 'logGroups[].logGroupName' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$log_groups" ]]; then
        for log_group in $log_groups; do
            warn "Eliminando log group: $log_group"
            aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" >/dev/null 2>&1 || true
        done
        success "  Log groups eliminados"
    else
        success "  No se encontraron log groups"
    fi
}

cleanup_ecs_task_definitions() {
    log "🐳 Limpiando definiciones de tareas ECS"
    
    local family_prefix="${PROJECT_NAME}-${ENV_NAME}"
    local families
    families=$(aws ecs list-task-definition-families \
        --family-prefix "$family_prefix" \
        --region "$REGION" \
        --status ACTIVE \
        --query 'families[]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$families" ]]; then
        for family in $families; do
            warn "  Desregistrando definiciones de tarea: $family"
            local task_defs
            task_defs=$(aws ecs list-task-definitions \
                --family-prefix "$family" \
                --region "$REGION" \
                --query 'taskDefinitionArns[]' \
                --output text 2>/dev/null || echo "")
            
            for task_def in $task_defs; do
                aws ecs deregister-task-definition \
                    --task-definition "$task_def" \
                    --region "$REGION" >/dev/null 2>&1 || true
            done
        done
        success "  Definiciones de tarea eliminadas"
    else
        success "  No se encontraron definiciones de tarea"
    fi
}

cleanup_service_discovery() {
    log "🗺️ Limpiando Cloud Map (Service Discovery)"
    
    local namespace_name="${PROJECT_NAME}.local"
    local namespace_id
    namespace_id=$(aws servicediscovery list-namespaces \
        --query "Namespaces[?Name=='${namespace_name}'].Id" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "")
    
    if [[ -n "$namespace_id" && "$namespace_id" != "None" ]]; then
        warn "  Eliminando servicios en el namespace: $namespace_name"
        
        local services
        services=$(aws servicediscovery list-services \
            --query "Services[?NamespaceId=='${namespace_id}'].Id" \
            --output text \
            --region "$REGION" 2>/dev/null || echo "")
        
        for service_id in $services; do
            warn "    Eliminando servicio: $service_id"
            aws servicediscovery delete-service --id "$service_id" --region "$REGION" >/dev/null 2>&1 || true
        done
        
        warn "  Eliminando namespace: $namespace_name"
        aws servicediscovery delete-namespace --id "$namespace_id" --region "$REGION" >/dev/null 2>&1 || true
        success "  Service Discovery eliminado"
    else
        success "  No se encontró namespace de Service Discovery"
    fi
}

# ----------------------------
# MAIN
# ----------------------------
main() {
    log "🧹 INICIANDO LIMPIEZA COMPLETA DEL PROYECTO"
    echo "Región: $REGION"
    echo "Proyecto: $PROJECT_NAME"
    echo "Ambiente: $ENV_NAME"
    echo "Stack: $STACK_NAME"
    echo ""
    
    # Confirmación final
    if ! confirm "¿Estás seguro de que quieres eliminar TODOS los recursos? Esta acción NO se puede deshacer."; then
        error "Limpieza cancelada por el usuario"
        exit 0
    fi
    
    # Segunda confirmación para ser más seguro
    if ! confirm "⚠️  ÚLTIMA OPORTUNIDAD: ¿Realmente quieres eliminar todos los recursos?"; then
        error "Limpieza cancelada por el usuario"
        exit 0
    fi
    
    ACCOUNT_ID="$(aws_account_id)"
    echo "Cuenta AWS: $ACCOUNT_ID"
    
    # Ejecutar limpieza en orden (de dependencias más específicas a más generales)
    
    # 1. Tareas ECS y definiciones
    cleanup_ecs_task_definitions
    
    # 2. Service Discovery
    cleanup_service_discovery
    
    # 3. Log groups
    cleanup_log_groups
    
    # 4. RDS (depende de la VPC que eliminará CloudFormation)
    cleanup_rds
    
    # 5. Secrets (independientes)
    cleanup_secrets
    
    # 6. ECR Repositories
    cleanup_ecr_repositories
    
    # 7. CloudFormation stack (elimina VPC, subnets, security groups, ALB, ECS cluster, roles)
    cleanup_cloudformation
    
    # Verificación final
    log "✅ VERIFICACIÓN FINAL"
    
    # Verificar que el stack fue eliminado
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
        warn "El stack $STACK_NAME aún existe"
    else
        success "Stack $STACK_NAME eliminado correctamente"
    fi
    
    # Verificar RDS
    if aws rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" >/dev/null 2>&1; then
        warn "La instancia RDS $RDS_IDENTIFIER aún existe"
    else
        success "Instancia RDS eliminada correctamente"
    fi
    
    log "🎉 LIMPIEZA COMPLETADA"
    echo "Todos los recursos han sido eliminados."
    echo ""
    echo "Si encuentras algún recurso residual, puedes:"
    echo "1. Revisar manualmente en la consola de AWS"
    echo "2. Verificar eventos de CloudFormation para más detalles"
    echo "3. Ejecutar: aws cloudformation list-stacks --region $REGION | grep $PROJECT_NAME"
}

# Ejecutar main
main "$@"