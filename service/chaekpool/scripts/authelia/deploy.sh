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
mv authelia /usr/local/bin/authelia
chmod +x /usr/local/bin/authelia
rm -f authelia-v${AUTHELIA_VERSION}-linux-amd64-musl.tar.gz

addgroup -S authelia 2>/dev/null || true
adduser -S -D -H -h /var/empty -s /sbin/nologin -G authelia -g authelia authelia 2>/dev/null || true

mkdir -p /etc/authelia /var/lib/authelia /var/log/authelia /opt/authelia
chown -R authelia:authelia /etc/authelia /var/lib/authelia /var/log/authelia

echo "Authelia binary installed"
SCRIPT

echo "[2/5] Generating secrets and hashes..."
# 사용자 비밀번호 argon2id 해시 생성
CPADMIN_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate argon2 --password '${AUTHELIA_CPADMIN_PASSWORD}'" 2>/dev/null | sed -n 's/^Digest: //p')
CPUSER_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate argon2 --password '${AUTHELIA_CPUSER_PASSWORD}'" 2>/dev/null | sed -n 's/^Digest: //p')

# OIDC 클라이언트 시크릿 pbkdf2 해시 생성
GRAFANA_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate pbkdf2 --password '${AUTHELIA_OIDC_GRAFANA_SECRET}'" 2>/dev/null | sed -n 's/^Digest: //p')
JENKINS_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate pbkdf2 --password '${AUTHELIA_OIDC_JENKINS_SECRET}'" 2>/dev/null | sed -n 's/^Digest: //p')
PGADMIN_HASH=$(pve_ssh "sudo pct exec ${CT_ID} -- /usr/local/bin/authelia crypto hash generate pbkdf2 --password '${AUTHELIA_OIDC_PGADMIN_SECRET}'" 2>/dev/null | sed -n 's/^Digest: //p')

# RSA 4096 JWKS 키 생성 (기존 키가 없을 때만)
pct_exec "${CT_ID}" "[ -f /etc/authelia/oidc.jwks.rsa.4096.pem ] || { openssl genrsa -out /etc/authelia/oidc.jwks.rsa.4096.pem 4096 2>/dev/null && chown authelia:authelia /etc/authelia/oidc.jwks.rsa.4096.pem && chmod 600 /etc/authelia/oidc.jwks.rsa.4096.pem; }"

echo "Secrets generated"

echo "[3/5] Deploying configuration files..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/configuration.yml" "/etc/authelia/configuration.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/users_database.yml" "/etc/authelia/users_database.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/authelia-wrapper.sh" "/opt/authelia/authelia-wrapper.sh"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/authelia.openrc" "/etc/init.d/authelia"

echo "[4/5] Injecting secrets into configuration..."
# 해시 값에 $가 포함되어 bash heredoc에서 변수로 치환되는 문제 방지
# 시크릿/해시를 임시 파일로 push 후 컨테이너 내부 Python으로 치환
cat > /tmp/authelia_secrets.env <<EOF_SECRETS
JWT_SECRET=${AUTHELIA_JWT_SECRET}
SESSION_SECRET=${AUTHELIA_SESSION_SECRET}
STORAGE_ENCRYPTION_KEY=${AUTHELIA_STORAGE_ENCRYPTION_KEY}
OIDC_HMAC_SECRET=${AUTHELIA_OIDC_HMAC_SECRET}
OIDC_GRAFANA_HASH=${GRAFANA_HASH}
OIDC_JENKINS_HASH=${JENKINS_HASH}
OIDC_PGADMIN_HASH=${PGADMIN_HASH}
CPADMIN_PASSWORD_HASH=${CPADMIN_HASH}
CPUSER_PASSWORD_HASH=${CPUSER_HASH}
CPADMIN_EMAIL=${AUTHELIA_CPADMIN_EMAIL}
CPUSER_EMAIL=${AUTHELIA_CPUSER_EMAIL}
EOF_SECRETS
pct_push "${CT_ID}" "/tmp/authelia_secrets.env" "/tmp/authelia_secrets.env"
rm -f /tmp/authelia_secrets.env

pct_script "${CT_ID}" <<'SCRIPT'
set -e
apk add --no-cache python3 > /dev/null 2>&1 || true

python3 -c "
import os

# Read secrets from temp file
secrets = {}
with open('/tmp/authelia_secrets.env') as f:
    for line in f:
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            secrets[k] = v

# Replace placeholders in configuration.yml
with open('/etc/authelia/configuration.yml') as f:
    cfg = f.read()
for k, v in secrets.items():
    cfg = cfg.replace(f'__{k}__', v)
with open('/etc/authelia/configuration.yml', 'w') as f:
    f.write(cfg)

# Replace placeholder in users_database.yml
with open('/etc/authelia/users_database.yml') as f:
    udb = f.read()
for k, v in secrets.items():
    udb = udb.replace(f'__{k}__', v)
with open('/etc/authelia/users_database.yml', 'w') as f:
    f.write(udb)
"

rm -f /tmp/authelia_secrets.env

# 파일 권한 설정
chown -R authelia:authelia /etc/authelia
chmod 600 /etc/authelia/configuration.yml /etc/authelia/users_database.yml
chmod 755 /opt/authelia/authelia-wrapper.sh /etc/init.d/authelia

echo "Configuration deployed"
SCRIPT

echo "[5/5] Starting Authelia service..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service authelia restart 2>/dev/null || rc-service authelia start
rc-update add authelia
rc-service authelia status
echo "Authelia is ready"
SCRIPT

echo "=== Authelia deployed ==="
