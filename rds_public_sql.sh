#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need jq; need curl

REGION="${REGION:-us-east-1}"
DB_IDENTIFIER="${DB_IDENTIFIER:-microservices-fargate-mysql-free}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-ecommerce_myshop}"
DB_USER="${DB_USER:-admin}"
DB_PASS="${DB_PASS:-}"
SQL_FILE="${SQL_FILE:-./script.sql}"

awsq(){ aws --region "$REGION" "$@"; }

MYIP="$(curl -s https://checkip.amazonaws.com | tr -d '\n\r')"
[[ -n "$MYIP" ]] || { echo "❌ No pude detectar tu IP"; exit 1; }
CIDR="${MYIP}/32"

PUBLIC="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].PubliclyAccessible" --output text)"
if [[ "$PUBLIC" != "True" ]]; then
  echo "👉 Haciendo RDS publicly accessible..."
  awsq rds modify-db-instance --db-instance-identifier "$DB_IDENTIFIER" --publicly-accessible --apply-immediately >/dev/null
  awsq rds wait db-instance-available --db-instance-identifier "$DB_IDENTIFIER"
fi

SG_ID="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" --output text)"
ENDPOINT="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].Endpoint.Address" --output text)"

echo "👉 Autorizando inbound MySQL ${DB_PORT} desde ${CIDR} en SG ${SG_ID}..."
awsq ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${DB_PORT},\"ToPort\":${DB_PORT},\"IpRanges\":[{\"CidrIp\":\"${CIDR}\",\"Description\":\"Temp SQL access\"}]}]" \
  >/dev/null 2>&1 || true

echo ""
echo "✅ Conexión:"
echo "Host: $ENDPOINT"
echo "Port: $DB_PORT"
echo "DB  : $DB_NAME"
echo "User: $DB_USER"
echo ""

if command -v mysql >/dev/null 2>&1; then
  [[ -n "$DB_PASS" ]] || { echo "⚠️ DB_PASS vacío, no ejecuto SQL."; exit 0; }
  [[ -f "$SQL_FILE" ]] || { echo "⚠️ SQL_FILE no existe: $SQL_FILE"; exit 0; }
  echo "👉 Ejecutando SQL: $SQL_FILE"
  mysql -h "$ENDPOINT" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"
  echo "✅ SQL ejecutado"
else
  echo "ℹ️ No tienes mysql client. Usa Workbench/DBeaver, o instala mysql-client."
fi