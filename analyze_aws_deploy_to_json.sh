#!/usr/bin/env bash
set -euo pipefail

# analyze_aws_deploy_to_json.sh
# -> Genera un informe JSON completo sobre los recursos detectados por el deploy
# Requisitos: aws, jq
# Uso: ./analyze_aws_deploy_to_json.sh

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "⚠️  No encuentro $ENV_FILE. Crea un .env o exporta variables antes de ejecutar."
  exit 1
fi

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-microservices-fargate}"
ENV_NAME="${ENV_NAME:-prod}"

# Nombres por defecto (ajusta si usas otros)
CLUSTER_NAME="${PROJECT}-cluster"
NAMESPACE_NAME="${PROJECT}.local"
TG_GW_NAME="${TG_GW_NAME:-msf-tg-gw}"
ALB_NAME="${ALB_NAME:-msf-alb}"

REPOS=(configservice eurekaservice gatewayservice productservice orderservice paymentservice userservice)
ECS_SERVICES=(configservice eurekaservice gatewayservice productservice orderservice paymentservice userservice)

STATE_FILE="${STATE_FILE:-.deploy_state.${PROJECT}.${REGION}.json}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
awsq() { aws --region "$REGION" "$@"; }
log() { echo -e "👉 $*" >&2; }

need aws
need jq

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="analysis_report.${PROJECT}.${REGION}.${TIMESTAMP}.json"

# helper: leer valor del state file o vacío
state_get() {
  local key="$1"
  if [[ -f "$STATE_FILE" ]]; then
    jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

sanitize_token() { echo "${1:-}" | awk '{print $1}'; }

ACCOUNT_ID="$(awsq sts get-caller-identity --query Account --output text 2>/dev/null || true)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --------------------------------------------------------------------
# Recolectar JSON crudo (si la consulta falla, dejamos un JSON vacío)
# --------------------------------------------------------------------
safe_aws_json() {
  # $1 ... resto del comando AWS (sin aws/región)
  local out
  if out="$(aws --region "$REGION" "$@" 2>/dev/null)"; then
    # si salida vacía -> return empty array/object heurístico
    if [[ -z "$out" ]]; then
      echo "null"
    else
      # intentar parsear como JSON; si no es JSON, envolver en string
      if echo "$out" | jq -e . >/dev/null 2>&1; then
        echo "$out"
      else
        jq -Rn --arg s "$out" '$s'
      fi
    fi
  else
    echo "null"
  fi
}

# -------------------------
# Cargar from state (IDs/ARNs conocidos)
# -------------------------
VPC_ID="$(sanitize_token "$(state_get VPC_ID)")"
PUB1_ID="$(sanitize_token "$(state_get PUB1_ID)")"
PUB2_ID="$(sanitize_token "$(state_get PUB2_ID)")"
PRI1_ID="$(sanitize_token "$(state_get PRI1_ID)")"
PRI2_ID="$(sanitize_token "$(state_get PRI2_ID)")"
RTB_PUB_ID="$(sanitize_token "$(state_get RTB_PUB_ID)")"
RTB_PRI_ID="$(sanitize_token "$(state_get RTB_PRI_ID)")"
SG_ALB_ID="$(sanitize_token "$(state_get SG_ALB_ID)")"
SG_ECS_PRIVATE_ID="$(sanitize_token "$(state_get SG_ECS_PRIVATE_ID)")"
SG_CONFIG_ID="$(sanitize_token "$(state_get SG_CONFIG_ID)")"
SG_VPCE_ID="$(sanitize_token "$(state_get SG_VPCE_ID)")"
NAT_GW_ID="$(sanitize_token "$(state_get NAT_GW_ID)")"
NAT_EIP_ALLOC_ID="$(sanitize_token "$(state_get NAT_EIP_ALLOC_ID)")"
ALB_ARN="$(sanitize_token "$(state_get ALB_ARN)")"
ALB_DNS="$(sanitize_token "$(state_get ALB_DNS)")"
TG_GW_ARN="$(sanitize_token "$(state_get TG_GW_ARN)")"
NS_ID="$(sanitize_token "$(state_get NS_ID)")"

TD_CONFIG_ARN="$(sanitize_token "$(state_get TD_CONFIG_ARN)")"
TD_EUREKA_ARN="$(sanitize_token "$(state_get TD_EUREKA_ARN)")"
TD_GATEWAY_ARN="$(sanitize_token "$(state_get TD_GATEWAY_ARN)")"
TD_PRODUCTS_ARN="$(sanitize_token "$(state_get TD_PRODUCTS_ARN)")"
TD_ORDERS_ARN="$(sanitize_token "$(state_get TD_ORDERS_ARN)")"
TD_PAY_ARN="$(sanitize_token "$(state_get TD_PAY_ARN)")"
TD_USERS_ARN="$(sanitize_token "$(state_get TD_USERS_ARN)")"

SD_CONFIG_ID="$(sanitize_token "$(state_get SD_CONFIG_ID)")"
SD_EUREKA_ID="$(sanitize_token "$(state_get SD_EUREKA_ID)")"
SD_GATEWAY_ID="$(sanitize_token "$(state_get SD_GATEWAY_ID)")"
SD_PRODUCTS_ID="$(sanitize_token "$(state_get SD_PRODUCTS_ID)")"
SD_ORDERS_ID="$(sanitize_token "$(state_get SD_ORDERS_ID)")"
SD_PAY_ID="$(sanitize_token "$(state_get SD_PAY_ID)")"
SD_USERS_ID="$(sanitize_token "$(state_get SD_USERS_ID)")"

LG_CONFIG="$(sanitize_token "$(state_get LG_CONFIG)")"
LG_EUREKA="$(sanitize_token "$(state_get LG_EUREKA)")"
LG_GATEWAY="$(sanitize_token "$(state_get LG_GATEWAY)")"
LG_PRODUCTS="$(sanitize_token "$(state_get LG_PRODUCTS)")"
LG_ORDERS="$(sanitize_token "$(state_get LG_ORDERS)")"
LG_PAY="$(sanitize_token "$(state_get LG_PAY)")"
LG_USERS="$(sanitize_token "$(state_get LG_USERS)")"

# -------------------------
# ECS: cluster, services, task defs, running tasks
# -------------------------
cluster_json="$(safe_aws_json ecs describe-clusters --clusters "$CLUSTER_NAME" --output json --query 'clusters[0]' )"
ecs_services_json="$(safe_aws_json ecs list-services --cluster "$CLUSTER_NAME" --output json --query 'serviceArns' )"
# list details for expected services
declare -A svc_status_map
for svc in "${ECS_SERVICES[@]}"; do
  svc_status="$(aws --region "$REGION" ecs describe-services --cluster "$CLUSTER_NAME" --services "$svc" --query 'services[0]' --output json 2>/dev/null || echo 'null')"
  svc_status_map["$svc"]="$svc_status"
done

# task definitions: describe if exist
tds_json="$(safe_aws_json ecs list-task-definition-families --status ACTIVE --query "families[?starts_with(@, '${PROJECT}-td-')]" --output json )"
# For the specific TD ARNs from state, fetch their describe
declare -A td_describe_map
for td in "$TD_CONFIG_ARN" "$TD_EUREKA_ARN" "$TD_GATEWAY_ARN" "$TD_PRODUCTS_ARN" "$TD_ORDERS_ARN" "$TD_PAY_ARN" "$TD_USERS_ARN"; do
  if [[ -n "$td" && "$td" != "None" && "$td" != "null" ]]; then
    td_des="$(aws --region "$REGION" ecs describe-task-definition --task-definition "$td" --output json 2>/dev/null || echo 'null')"
    td_describe_map["$td"]="$td_des"
  fi
done

# -------------------------
# ECR: repos + sample images
# -------------------------
repos_json="$(safe_aws_json ecr describe-repositories --output json --query 'repositories[].repositoryName')"
declare -A repo_images_map
for repo in "${REPOS[@]}"; do
  imgs="$(aws --region "$REGION" ecr describe-images --repository-name "$repo" --query 'imageDetails | sort_by(@,&imagePushedAt) | reverse(@)[:10]' --output json 2>/dev/null || echo '[]')"
  repo_images_map["$repo"]="$imgs"
done

# -------------------------
# ALB / TG / Listeners / target health
# -------------------------
alb_json="null"
alb_dns=""
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" && "$ALB_ARN" != "null" ]]; then
  alb_json="$(safe_aws_json elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --output json 2>/dev/null || echo 'null')"
  alb_dns="$(aws --region "$REGION" elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo '')"
else
  # try by name
  ALB_ARN="$(aws --region "$REGION" elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
  if [[ -n "$ALB_ARN" ]]; then
    alb_json="$(safe_aws_json elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --output json 2>/dev/null || echo 'null')"
    alb_dns="$(aws --region "$REGION" elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo '')"
  fi
fi
tg_json="null"
if [[ -n "$TG_GW_ARN" && "$TG_GW_ARN" != "None" && "$TG_GW_ARN" != "null" ]]; then
  tg_json="$(safe_aws_json elbv2 describe-target-groups --target-group-arns "$TG_GW_ARN" --output json 2>/dev/null || echo 'null')"
fi
listeners_json="null"
if [[ -n "$ALB_ARN" ]]; then
  listeners_json="$(safe_aws_json elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --output json 2>/dev/null || echo 'null')"
fi
tg_health_json="null"
if [[ -n "$TG_GW_ARN" ]]; then
  tg_health_json="$(safe_aws_json elbv2 describe-target-health --target-group-arn "$TG_GW_ARN" --output json 2>/dev/null || echo 'null')"
fi

# -------------------------
# Cloud Map (namespace + services)
# -------------------------
ns_json="null"
if [[ -n "$NS_ID" && "$NS_ID" != "None" && "$NS_ID" != "null" ]]; then
  ns_json="$(safe_aws_json servicediscovery get-namespace --id "$NS_ID" --output json 2>/dev/null || echo 'null')"
else
  # try by name
  ns_list="$(aws --region "$REGION" servicediscovery list-namespaces --query "Namespaces[?Name=='${NAMESPACE_NAME}']" --output json 2>/dev/null || echo '[]')"
  ns_json="$ns_list"
  # if found, set NS_ID
  NS_ID_DISC="$(echo "$ns_list" | jq -r '.[0].Id // empty')"
  [[ -n "$NS_ID_DISC" ]] && NS_ID="$NS_ID_DISC"
fi
cm_services_json="$(safe_aws_json servicediscovery list-services --query \"Services[?NamespaceId=='${NS_ID}']\" --output json 2>/dev/null || echo 'null')"

# -------------------------
# VPC / Subnets / SG / VPCE / NAT
# -------------------------
vpc_json="null"
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" && "$VPC_ID" != "null" ]]; then
  vpc_json="$(safe_aws_json ec2 describe-vpcs --vpc-ids "$VPC_ID" --output json 2>/dev/null || echo 'null')"
fi
subnets_json="$(safe_aws_json ec2 describe-subnets --filters \"Name=vpc-id,Values=${VPC_ID}\" --output json 2>/dev/null || echo 'null')"
sgs_json="$(safe_aws_json ec2 describe-security-groups --filters \"Name=vpc-id,Values=${VPC_ID}\" --output json 2>/dev/null || echo 'null')"
vpce_json="$(safe_aws_json ec2 describe-vpc-endpoints --filters \"Name=vpc-id,Values=${VPC_ID}\" --output json 2>/dev/null || echo 'null')"
nat_json="null"
if [[ -n "$NAT_GW_ID" && "$NAT_GW_ID" != "None" && "$NAT_GW_ID" != "null" ]]; then
  nat_json="$(safe_aws_json ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" --output json 2>/dev/null || echo 'null')"
fi

# -------------------------
# CloudWatch Logs (prefix)
# -------------------------
logs_prefix="/ecs/${PROJECT}/"
logs_json="$(safe_aws_json logs describe-log-groups --log-group-name-prefix "$logs_prefix" --output json --query 'logGroups' 2>/dev/null || echo '[]')"

# -------------------------
# RDS / Aurora
# -------------------------
rds_instances_json="$(safe_aws_json rds describe-db-instances --output json --query \"DBInstances[?starts_with(DBInstanceIdentifier,'${PROJECT}')]\")"
rds_clusters_json="$(safe_aws_json rds describe-db-clusters --output json --query \"DBClusters[?starts_with(DBClusterIdentifier,'${PROJECT}')]\")"

# -------------------------
# Discovery: services in cluster (huérfanos)
# -------------------------
cluster_services_list_json="$(safe_aws_json ecs list-services --cluster "$CLUSTER_NAME" --output json --query 'serviceArns' 2>/dev/null || echo '[]')"

# -------------------------
# Construcción del JSON final usando jq
# -------------------------
# Convertir arreglos map a JSON object para inyectar detalles
# Generar mapas para svc_status_map y td_describe_map y repo_images_map
svc_status_entries="[]"
for svc in "${ECS_SERVICES[@]}"; do
  val="${svc_status_map[$svc]:-null}"
  # val may be 'null' or JSON; ensure it's valid JSON value
  if [[ "$val" == "null" || -z "$val" ]]; then
    svc_status_entries="$(jq --arg name "$svc" --null-input '$ARGS.named' --argjson v 'null' '$ARGS.named')"
    # Trick: build as object list later; simplest: append using jq
    svc_status_entries="$(jq -n --arg name "$svc" --argjson v "$val" '[{name:$name,detail:$v}]' 2>/dev/null || echo "[]")"
  else
    svc_status_entries="$(jq -n --arg name "$svc" --argjson v "$val" '[{name:$name,detail:$v}]' 2>/dev/null || echo "[]")"
  fi
  # append to array file (we'll collect later)
  echo "$svc" > /dev/null
done

# Instead of complex appends in bash (error-prone), we'll build final object by passing the pre-collected raw JSON strings to jq:
jq -n \
  --arg region "$REGION" \
  --arg project "$PROJECT" \
  --arg env "$ENV_NAME" \
  --arg account "$ACCOUNT_ID" \
  --arg ecr "$ECR_REGISTRY" \
  --arg cluster "$CLUSTER_NAME" \
  --arg namespace "$NAMESPACE_NAME" \
  --arg alb_arn "${ALB_ARN:-}" \
  --arg alb_dns "${alb_dns:-}" \
  --arg tg_arn "${TG_GW_ARN:-}" \
  --arg ns_id "${NS_ID:-}" \
  --argfile cluster_json <(echo "$cluster_json") \
  --argfile ecs_services <(echo "$ecs_services_json") \
  --argfile tdfams <(echo "$tds_json") \
  --argfile alb <(echo "$alb_json") \
  --argfile tg <(echo "$tg_json") \
  --argfile listeners <(echo "$listeners_json") \
  --argfile tg_health <(echo "$tg_health_json") \
  --argfile cm_ns <(echo "$ns_json") \
  --argfile cm_svcs <(echo "$cm_services_json") \
  --argfile vpc <(echo "$vpc_json") \
  --argfile subnets <(echo "$subnets_json") \
  --argfile sgs <(echo "$sgs_json") \
  --argfile vpce <(echo "$vpce_json") \
  --argfile nat <(echo "$nat_json") \
  --argfile logs <(echo "$logs_json") \
  --argfile rds_instances <(echo "$rds_instances_json") \
  --argfile rds_clusters <(echo "$rds_clusters_json") \
  --argfile cluster_services_list <(echo "$cluster_services_list_json") \
  '{
    meta: {
      generated_at: now | todate,
      region: $region,
      project: $project,
      env: $env,
      account: $account,
      ecr_registry: $ecr,
      cluster: $cluster,
      namespace: $namespace
    },
    state_file: ($ENV.STATE_FILE // null),
    cluster: $cluster_json,
    cluster_services_arns: $ecs_services,
    task_definition_families: $tdfams,
    alb: $alb,
    alb_dns: $alb_dns,
    target_group: $tg,
    listeners: $listeners,
    target_health: $tg_health,
    cloudmap_namespace: $cm_ns,
    cloudmap_services: $cm_svcs,
    vpc: $vpc,
    subnets: $subnets,
    security_groups: $sgs,
    vpc_endpoints: $vpce,
    nat: $nat,
    logs: $logs,
    rds_instances: $rds_instances,
    rds_clusters: $rds_clusters,
    discovered_cluster_services: $cluster_services_list
  }' \
  > "$REPORT_FILE"

# Añadir detalle por repos (images) y task-def describes y services describes en un archivo auxiliar si quieres.
# Para conveniencia, añadimos un campo adicional "repos" y "td_describes" y "service_describes"
# (construimos con jq -s para fusionar)

# build repos object
repos_obj="$(jq -n '{}')"
for repo in "${REPOS[@]}"; do
  imgs="${repo_images_map[$repo]:-[]}"
  # imgs may be raw JSON string; ensure it's valid
  if [[ -z "$imgs" ]]; then imgs="[]"; fi
  repos_obj="$(echo '{}' | jq --arg name "$repo" --argjson imgs "$imgs" '. + {($name): $imgs}')"
done

# build td_describes object
tds_obj="$(jq -n '{}')"
for td in "${!td_describe_map[@]}"; do
  des="${td_describe_map[$td]:-null}"
  if [[ -z "$des" ]]; then des="null"; fi
  tds_obj="$(echo '{}' | jq --arg name "$td" --argjson v "$des" '. + {($name): $v}')"
done

# build services describes object
svc_describes_obj="$(jq -n '{}')"
for svc in "${ECS_SERVICES[@]}"; do
  raw="${svc_status_map[$svc]:-null}"
  if [[ -z "$raw" ]]; then raw="null"; fi
  svc_describes_obj="$(echo '{}' | jq --arg name "$svc" --argjson v "$raw" '. + {($name): $v}')"
done

# merge these into report
jq --argfile repos <(echo "$repos_obj") \
   --argfile tds <(echo "$tds_obj") \
   --argfile svcs <(echo "$svc_describes_obj") \
   '. + {repos: $repos, taskDef_describes: $tds, service_describes: $svcs}' \
   "$REPORT_FILE" > "${REPORT_FILE}.tmp" && mv "${REPORT_FILE}.tmp" "$REPORT_FILE"

log "Reporte JSON generado: $REPORT_FILE"
log "Puedes abrirlo con: jq . $REPORT_FILE"

exit 0