#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }
need aws; need curl

REGION="${REGION:-us-east-1}"
DB_IDENTIFIER="${DB_IDENTIFIER:-microservices-fargate-mysql-free}"
DB_PORT="${DB_PORT:-3306}"

# true => además de revocar la IP, marca RDS como NO pública
MAKE_PRIVATE="${MAKE_PRIVATE:-false}"

awsq(){ aws --region "$REGION" "$@"; }

MYIP="$(curl -s https://checkip.amazonaws.com | tr -d '\n\r')"
[[ -n "$MYIP" ]] || { echo "❌ No pude detectar tu IP"; exit 1; }
CIDR="${MYIP}/32"

SG_ID="$(awsq rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" --output text)"

echo "👉 Revocando inbound MySQL ${DB_PORT} desde ${CIDR} en SG ${SG_ID}..."
awsq ec2 revoke-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${DB_PORT},\"ToPort\":${DB_PORT},\"IpRanges\":[{\"CidrIp\":\"${CIDR}\"}]}]" \
  >/dev/null 2>&1 || true
echo "✅ Regla revocada (o no existía)."

if [[ "$MAKE_PRIVATE" == "true" ]]; then
  echo "👉 Marcando RDS como NO pública..."
  awsq rds modify-db-instance --db-instance-identifier "$DB_IDENTIFIER" --no-publicly-accessible --apply-immediately >/dev/null
  awsq rds wait db-instance-available --db-instance-identifier "$DB_IDENTIFIER"
  echo "✅ RDS ahora es privada."
fi