#!/bin/bash
# CP Traefik 배포 (CT 200, 10.0.1.100)
# SSL 없이 HTTP만 처리 (OPNsense HAProxy에서 SSL 종료 후 포워딩)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CT_ID="${CT_TRAEFIK}"
TRAEFIK_VERSION="3.6.7"

echo "=== Deploying CP Traefik to CT ${CT_ID} ==="

echo "[1/4] Installing Traefik binary..."
pct_script "${CT_ID}" <<SCRIPT
set -e

apk update
apk add --no-cache wget tar libcap-utils

echo "Downloading Traefik v${TRAEFIK_VERSION}..."
cd /tmp
wget -q https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz
tar -xzf traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz
mv traefik /usr/local/bin/traefik
chmod +x /usr/local/bin/traefik
setcap cap_net_bind_service=+ep /usr/local/bin/traefik
rm -f traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz

addgroup -S traefik 2>/dev/null || true
adduser -S -D -H -h /var/empty -s /sbin/nologin -G traefik -g traefik traefik 2>/dev/null || true

mkdir -p /etc/traefik/conf.d /var/log/traefik
chown -R traefik:traefik /etc/traefik /var/log/traefik

echo "Traefik binary installed"
SCRIPT

echo "[2/4] Deploying static config..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/traefik.yml" "/etc/traefik/traefik.yml"

echo "[3/4] Deploying dynamic config..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/services.yml" "/etc/traefik/conf.d/services.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/traefik.openrc" "/etc/init.d/traefik"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown -R traefik:traefik /etc/traefik
chmod 644 /etc/traefik/traefik.yml /etc/traefik/conf.d/services.yml
chmod 755 /etc/init.d/traefik
SCRIPT

echo "[4/4] Starting Traefik service..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service traefik start
rc-update add traefik
rc-service traefik status
echo "CP Traefik is ready"
SCRIPT

echo "=== CP Traefik deployed ==="
