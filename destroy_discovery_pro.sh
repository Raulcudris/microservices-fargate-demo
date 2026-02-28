#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need jq

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"
DRY_RUN="${DRY_RUN:-true}"   # true = solo muestra, false = elimina

awsq(){ aws --region "$REGION" "$@"; }

log(){ echo -e "\n👉 $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️ $*" >&2; }

run(){
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN> aws --region $REGION $*"
  else
    awsq "$@"
  fi
}

exists(){ [[ -n "${1:-}" && "${1:-}" != "None" && "${1:-}" != "null" ]]; }

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "❌ No pude obtener AccountId (sts). Revisa credenciales AWS."
  exit 1
fi

ok "Account: $ACCOUNT_ID"
ok "Region : $REGION"
ok "Project: $PROJECT"
ok "Env    : $ENV_NAME"
ok "DRY_RUN : $DRY_RUN"

# -----------------------------
# Helpers de búsqueda
# -----------------------------
find_vpcs(){
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Env,Values=$ENV_NAME" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null || true
}

find_vpcs_by_name_fallback(){
  awsq ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null || true
}

find_ecs_clusters(){
  awsq ecs list-clusters --query 'clusterArns[]' --output text 2>/dev/null || true
}

cluster_name_from_arn(){
  awk -F/ '{print $NF}' <<< "$1"
}

# -----------------------------
# 1) ECS: Services + Clusters
# -----------------------------
destroy_ecs(){
  log "1) ECS (Services/Clusters) - buscando clusters con nombre ${PROJECT}*"
  local clusters
  clusters="$(find_ecs_clusters)"
  [[ -z "${clusters// }" ]] && { ok "No hay clusters ECS."; return 0; }

  for c in $clusters; do
    local cname; cname="$(cluster_name_from_arn "$c")"
    if [[ "$cname" != ${PROJECT}* ]]; then
      continue
    fi

    log "Cluster: $cname"

    # Listar servicios
    local svcs
    svcs="$(awsq ecs list-services --cluster "$cname" --query 'serviceArns[]' --output text 2>/dev/null || true)"
    if [[ -n "${svcs// }" ]]; then
      for s in $svcs; do
        log " - Eliminando service: $s"
        # scale a 0 y delete
        run ecs update-service --cluster "$cname" --service "$s" --desired-count 0 >/dev/null 2>&1 || true
        run ecs delete-service --cluster "$cname" --service "$s" --force >/dev/null 2>&1 || true
      done

      if [[ "$DRY_RUN" != "true" ]]; then
        log "   Esperando a que no existan services..."
        for _ in {1..60}; do
          local left
          left="$(awsq ecs list-services --cluster "$cname" --query 'serviceArns[]' --output text 2>/dev/null || true)"
          [[ -z "${left// }" ]] && break
          sleep 5
        done
      fi
    else
      ok " - No hay services en $cname"
    fi

    # Stop tasks
    local tasks
    tasks="$(awsq ecs list-tasks --cluster "$cname" --query 'taskArns[]' --output text 2>/dev/null || true)"
    if [[ -n "${tasks// }" ]]; then
      for t in $tasks; do
        log " - Stop task: $t"
        run ecs stop-task --cluster "$cname" --task "$t" --reason "Destroy discovery" >/dev/null 2>&1 || true
      done
    fi

    # Delete cluster
    log " - Delete cluster: $cname"
    run ecs delete-cluster --cluster "$cname" >/dev/null 2>&1 || true
  done
  ok "ECS cleanup solicitado."
}

# -----------------------------
# 2) ALB + Target Groups
# -----------------------------
destroy_alb(){
  log "2) ALB/TargetGroups - buscando ALB con nombre msf-alb o ${PROJECT}*"

  # Busca ALB por nombre msf-alb (tu script) o prefijo PROJECT
  local lbs
  lbs="$(awsq elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)"
  [[ -z "${lbs// }" ]] && { ok "No hay ALBs."; return 0; }

  for lb in $lbs; do
    local name
    name="$(awsq elbv2 describe-load-balancers --load-balancer-arns "$lb" --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null || true)"
    if [[ "$name" != "msf-alb" && "$name" != ${PROJECT}* ]]; then
      continue
    fi

    log "ALB: $name ($lb)"

    # listeners
    local listeners
    listeners="$(awsq elbv2 describe-listeners --load-balancer-arn "$lb" --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true)"
    if [[ -n "${listeners// }" ]]; then
      for l in $listeners; do
        log " - Delete listener: $l"
        run elbv2 delete-listener --listener-arn "$l" >/dev/null 2>&1 || true
      done
    fi

    # delete ALB
    log " - Delete ALB: $name"
    run elbv2 delete-load-balancer --load-balancer-arn "$lb" >/dev/null 2>&1 || true

    # target groups likely used (msf-tg-gw)
    local tgs
    tgs="$(awsq elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)"
    if [[ -n "${tgs// }" ]]; then
      for tg in $tgs; do
        local tgname
        tgname="$(awsq elbv2 describe-target-groups --target-group-arns "$tg" --query 'TargetGroups[0].TargetGroupName' --output text 2>/dev/null || true)"
        if [[ "$tgname" == "msf-tg-gw" || "$tgname" == ${PROJECT}* ]]; then
          log " - Delete TG: $tgname"
          run elbv2 delete-target-group --target-group-arn "$tg" >/dev/null 2>&1 || true
        fi
      done
    fi
  done

  ok "ALB cleanup solicitado."
}

# -----------------------------
# 3) Cloud Map (Namespace/Services)
# -----------------------------
destroy_cloudmap(){
  log "3) Cloud Map - buscando namespace ${PROJECT}.local o tags"

  local ns_name="${PROJECT}.local"
  local ns_id
  ns_id="$(awsq servicediscovery list-namespaces --query "Namespaces[?Name=='${ns_name}'].Id | [0]" --output text 2>/dev/null | grep -v None || true)"

  if [[ -z "$ns_id" ]]; then
    warn "No encontré namespace exacto: $ns_name (si existe con otro nombre, se queda)."
    return 0
  fi

  ok "Namespace encontrado: $ns_name ($ns_id)"

  # Services in namespace
  local services_json
  services_json="$(awsq servicediscovery list-services --output json 2>/dev/null || echo '{"Services":[]}')"
  local svc_ids
  svc_ids="$(echo "$services_json" | jq -r --arg ns "$ns_id" '.Services[] | select(.NamespaceId==$ns) | .Id' 2>/dev/null || true)"

  if [[ -n "${svc_ids// }" ]]; then
    for sid in $svc_ids; do
      local sname
      sname="$(echo "$services_json" | jq -r --arg sid "$sid" '.Services[] | select(.Id==$sid) | .Name' 2>/dev/null || echo "")"
      log " - Delete CloudMap service: $sname ($sid)"
      run servicediscovery delete-service --id "$sid" >/dev/null 2>&1 || true
    done
  else
    ok "No hay services en namespace."
  fi

  log " - Delete namespace: $ns_name ($ns_id)"
  run servicediscovery delete-namespace --id "$ns_id" >/dev/null 2>&1 || true

  ok "Cloud Map cleanup solicitado."
}

# -----------------------------
# 4) RDS (MySQL) por identificador típico
# -----------------------------
destroy_rds(){
  log "4) RDS - buscando instancias con identificador ${PROJECT}-mysql-*"

  local dbs
  dbs="$(awsq rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null || true)"
  [[ -z "${dbs// }" ]] && { ok "No hay RDS instances."; return 0; }

  for db in $dbs; do
    if [[ "$db" == "${PROJECT}-mysql-"* ]]; then
      log " - Delete RDS: $db (skip final snapshot)"
      run rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot >/dev/null 2>&1 || true
      if [[ "$DRY_RUN" != "true" ]]; then
        log "   Esperando db-instance-deleted..."
        awsq rds wait db-instance-deleted --db-instance-identifier "$db" >/dev/null 2>&1 || true
      fi
    fi
  done

  # subnet groups (tu naming)
  local sgs
  sgs="$(awsq rds describe-db-subnet-groups --query 'DBSubnetGroups[].DBSubnetGroupName' --output text 2>/dev/null || true)"
  for sg in $sgs; do
    if [[ "$sg" == "${PROJECT}-dbsubnet-"* ]]; then
      log " - Delete DB Subnet Group: $sg"
      run rds delete-db-subnet-group --db-subnet-group-name "$sg" >/dev/null 2>&1 || true
    fi
  done

  ok "RDS cleanup solicitado."
}

# -----------------------------
# 5) CloudWatch Logs (por prefijo /ecs/${PROJECT}/)
# -----------------------------
destroy_logs(){
  log "5) CloudWatch Logs - borrando log groups /ecs/${PROJECT}/*"
  local groups
  groups="$(awsq logs describe-log-groups --log-group-name-prefix "/ecs/${PROJECT}/" --query 'logGroups[].logGroupName' --output text 2>/dev/null || true)"
  if [[ -n "${groups// }" ]]; then
    for g in $groups; do
      log " - Delete log group: $g"
      run logs delete-log-group --log-group-name "$g" >/dev/null 2>&1 || true
    done
  else
    ok "No hay log groups con prefijo /ecs/${PROJECT}/"
  fi
}

# -----------------------------
# 6) ECR repos (por nombres típicos)
# -----------------------------
destroy_ecr(){
  log "6) ECR - borrando repos conocidos (config/eureka/gateway/product/orders/payment/users) si existen"
  local repos=("configservice" "eurekaservice" "gatewayservice" "productservice" "orderservice" "paymentservice" "userservice")
  for r in "${repos[@]}"; do
    if awsq ecr describe-repositories --repository-names "$r" >/dev/null 2>&1; then
      log " - Delete ECR repo: $r (force)"
      run ecr delete-repository --repository-name "$r" --force >/dev/null 2>&1 || true
    fi
  done
}

# -----------------------------
# 7) VPC Cleanup (solo VPCs con tags Project/Env o Name=${PROJECT}-vpc)
# -----------------------------
destroy_vpc(){
  log "7) VPC - buscando VPC(s) tag Project=$PROJECT Env=$ENV_NAME o Name=${PROJECT}-vpc"

  local vpcs
  vpcs="$(find_vpcs)"
  if [[ -z "${vpcs// }" ]]; then
    vpcs="$(find_vpcs_by_name_fallback)"
  fi

  if [[ -z "${vpcs// }" ]]; then
    warn "No encontré VPC con tags/Name esperados. Si tu VPC quedó sin tags, NO la borraré por seguridad."
    return 0
  fi

  for vpc in $vpcs; do
    log "VPC encontrada: $vpc"

    # 7.1) VPC Endpoints
    local vpces
    vpces="$(awsq ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)"
    if [[ -n "${vpces// }" ]]; then
      for e in $vpces; do
        log " - Delete VPCE: $e"
        run ec2 delete-vpc-endpoints --vpc-endpoint-ids "$e" >/dev/null 2>&1 || true
      done
    fi

    # 7.2) NAT Gateways + EIPs asociadas
    local ngws
    ngws="$(awsq ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
    if [[ -n "${ngws// }" ]]; then
      for ng in $ngws; do
        log " - Delete NAT GW: $ng"
        run ec2 delete-nat-gateway --nat-gateway-id "$ng" >/dev/null 2>&1 || true
      done

      if [[ "$DRY_RUN" != "true" ]]; then
        log "   Esperando NAT delete..."
        for _ in {1..90}; do
          local left
          left="$(awsq ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null || true)"
          [[ -z "${left// }" ]] && break
          sleep 10
        done
      fi
    fi

    # Libera EIPs no asociados (best-effort)
    local eips
    eips="$(awsq ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || true)"
    if [[ -n "${eips// }" ]]; then
      for e in $eips; do
        log " - Release EIP (unassociated): $e"
        run ec2 release-address --allocation-id "$e" >/dev/null 2>&1 || true
      done
    fi

    # 7.3) Load Balancers suelen estar fuera, pero por si quedó alguno sin borrar:
    # (ya lo hicimos arriba)

    # 7.4) Route Tables: desasocia + elimina (no MAIN)
    local rtbs
    rtbs="$(awsq ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || true)"
    if [[ -n "${rtbs// }" ]]; then
      for rtb in $rtbs; do
        # Disassociate non-main
        local assocs
        assocs="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text 2>/dev/null || true)"
        if [[ -n "${assocs// }" ]]; then
          for a in $assocs; do
            run ec2 disassociate-route-table --association-id "$a" >/dev/null 2>&1 || true
          done
        fi

        # Delete non-local routes
        local dests
        dests="$(awsq ec2 describe-route-tables --route-table-ids "$rtb" --query 'RouteTables[0].Routes[?DestinationCidrBlock!=null && GatewayId!=`local`].DestinationCidrBlock' --output text 2>/dev/null || true)"
        if [[ -n "${dests// }" ]]; then
          for d in $dests; do
            run ec2 delete-route --route-table-id "$rtb" --destination-cidr-block "$d" >/dev/null 2>&1 || true
          done
        fi

        # Delete RTB (puede fallar si es main)
        run ec2 delete-route-table --route-table-id "$rtb" >/dev/null 2>&1 || true
      done
    fi

    # 7.5) Subnets
    local subnets
    subnets="$(awsq ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)"
    if [[ -n "${subnets// }" ]]; then
      for s in $subnets; do
        log " - Delete subnet: $s"
        run ec2 delete-subnet --subnet-id "$s" >/dev/null 2>&1 || true
      done
    fi

    # 7.6) Internet Gateway
    local igws
    igws="$(awsq ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)"
    if [[ -n "${igws// }" ]]; then
      for igw in $igws; do
        log " - Detach+Delete IGW: $igw"
        run ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" >/dev/null 2>&1 || true
        run ec2 delete-internet-gateway --internet-gateway-id "$igw" >/dev/null 2>&1 || true
      done
    fi

    # 7.7) Security Groups (solo los que claramente son del proyecto)
    local sgs
    sgs="$(awsq ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[].{Id:GroupId,Name:GroupName}' --output json 2>/dev/null || echo '[]')"
    echo "$sgs" | jq -r '.[] | "\(.Id) \(.Name)"' | while read -r gid gname; do
      [[ "$gname" == "default" ]] && continue
      if [[ "$gname" == "${PROJECT}-sg-"* || "$gname" == "microservices-fargate-sg-"* ]]; then
        log " - Delete SG: $gname ($gid)"
        run ec2 delete-security-group --group-id "$gid" >/dev/null 2>&1 || true
      fi
    done

    # 7.8) Delete VPC
    log " - Delete VPC: $vpc"
    run ec2 delete-vpc --vpc-id "$vpc" >/dev/null 2>&1 || true
  done

  ok "VPC cleanup solicitado."
}

# -----------------------------
# Ejecuta en orden seguro
# -----------------------------
destroy_ecs
destroy_alb
destroy_cloudmap
destroy_rds
destroy_logs
destroy_ecr
destroy_vpc

echo -e "\n✅ Destroy por descubrimiento finalizado."
if [[ "$DRY_RUN" == "true" ]]; then
  echo "ℹ️ Estás en DRY_RUN=true. Para borrar de verdad: DRY_RUN=false ./destroy_discovery_pro.sh"
fi

echo -e "\n⚠️ Nota:"
echo "- Si algún recurso quedó SIN tags y con nombre no estándar, este script NO lo borra por seguridad."
echo "- Si ves algo que quedó vivo, dime el nombre/ARN y lo agregamos al descubrimiento."