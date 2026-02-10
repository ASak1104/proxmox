#!/bin/bash
# Authelia 배포 (CT 201, 10.1.0.101)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CP_ENV="${SCRIPT_DIR}/../../.chaekpool.env"
[ -f "${CP_ENV}" ] && source "${CP_ENV}"

CT_ID="${CT_AUTHELIA}"
AUTHELIA_VERSION="4.39.15"

echo "=== Deploying Authelia to CT ${CT_ID} ==="

echo "[1/5] Installing Authelia binary..."
pct_script "${CT_ID}" <<SCRIPT
set -e

apk update
apk add --no-cache wget tar openssl

echo "Downloading Authelia v${AUTHELIA_VERSION}..."
cd /tmp
wget -q https://github.com/authelia/authelia/releases/download/v${AUTHELIA_VERSION}/authelia-v${AUTHELIA_VERSION}-linux-amd64-musl.tar.gz
tar -xzf authelia-v${AUTHELIA_VERSION}-linux-amd64-musl.tar.gz
mv authelia-linux-amd64-musl /usr/local/bin/authelia
chmod +x /usr/local/bin/authelia
rm -f authelia-v${AUTHELIA_VERSION}-linux-amd64-musl.tar.gz

addgroup -S authelia 2>/dev/null || true
adduser -S -D -H -h /var/empty -s /sbin/nologin -G authelia -g authelia authelia 2>/dev/null || true

mkdir -p /etc/authelia /var/lib/authelia /var/log/authelia /opt/authelia
chown -R authelia:authelia /etc/authelia /var/lib/authelia /var/log/authelia

echo "Authelia binary installed"
SCRIPT

echo "[2/5] Generating secrets and hashes..."
# Admin 비밀번호 argon2id 해시 생성
ADMIN_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate argon2 --password '${AUTHELIA_ADMIN_PASSWORD}'" 2>/dev/null | grep '^\$')

# OIDC 클라이언트 시크릿 pbkdf2 해시 생성
GRAFANA_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate pbkdf2 --password '${AUTHELIA_OIDC_GRAFANA_SECRET}'" 2>/dev/null | grep '^\$')
JENKINS_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate pbkdf2 --password '${AUTHELIA_OIDC_JENKINS_SECRET}'" 2>/dev/null | grep '^\$')
PGADMIN_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate pbkdf2 --password '${AUTHELIA_OIDC_PGADMIN_SECRET}'" 2>/dev/null | grep '^\$')

# RSA 4096 JWKS 키 생성
pct_exec "${CT_ID}" "openssl genrsa -out /etc/authelia/oidc.jwks.rsa.4096.pem 4096 2>/dev/null && chown authelia:authelia /etc/authelia/oidc.jwks.rsa.4096.pem && chmod 600 /etc/authelia/oidc.jwks.rsa.4096.pem"

echo "Secrets generated"

echo "[3/5] Deploying configuration files..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/configuration.yml" "/etc/authelia/configuration.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/users_database.yml" "/etc/authelia/users_database.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/authelia-wrapper.sh" "/opt/authelia/authelia-wrapper.sh"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/authelia.openrc" "/etc/init.d/authelia"

echo "[4/5] Injecting secrets into configuration..."
pct_script "${CT_ID}" <<SCRIPT
set -e

# configuration.yml 시크릿 주입
sed -i "s|__JWT_SECRET__|${AUTHELIA_JWT_SECRET}|g" /etc/authelia/configuration.yml
sed -i "s|__SESSION_SECRET__|${AUTHELIA_SESSION_SECRET}|g" /etc/authelia/configuration.yml
sed -i "s|__STORAGE_ENCRYPTION_KEY__|${AUTHELIA_STORAGE_ENCRYPTION_KEY}|g" /etc/authelia/configuration.yml
sed -i "s|__OIDC_HMAC_SECRET__|${AUTHELIA_OIDC_HMAC_SECRET}|g" /etc/authelia/configuration.yml
sed -i "s|__OIDC_GRAFANA_HASH__|${GRAFANA_HASH}|g" /etc/authelia/configuration.yml
sed -i "s|__OIDC_JENKINS_HASH__|${JENKINS_HASH}|g" /etc/authelia/configuration.yml
sed -i "s|__OIDC_PGADMIN_HASH__|${PGADMIN_HASH}|g" /etc/authelia/configuration.yml

# users_database.yml admin 비밀번호 해시 주입
sed -i "s|__ADMIN_PASSWORD_HASH__|${ADMIN_HASH}|g" /etc/authelia/users_database.yml

# 파일 권한 설정
chown -R authelia:authelia /etc/authelia
chmod 600 /etc/authelia/configuration.yml /etc/authelia/users_database.yml
chmod 755 /opt/authelia/authelia-wrapper.sh /etc/init.d/authelia

echo "Configuration deployed"
SCRIPT

echo "[5/5] Starting Authelia service..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service authelia start
rc-update add authelia
rc-service authelia status
echo "Authelia is ready"
SCRIPT

echo "=== Authelia deployed ==="
