#!/bin/bash
# 모니터링 통합 배포 (CT 220, 10.0.1.120)
# Prometheus + Grafana + Loki + Jaeger v2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CT_ID="${CT_MONITORING}"
PROMETHEUS_VERSION="3.9.1"
GRAFANA_VERSION="12.3.2"
LOKI_VERSION="3.6.5"
JAEGER_VERSION="2.15.0"

echo "=== Deploying Monitoring Stack to CT ${CT_ID} ==="

# ============================================================
# Prometheus
# ============================================================
echo "[1/8] Installing Prometheus v${PROMETHEUS_VERSION}..."
pct_script "${CT_ID}" <<SCRIPT
set -e

apk update
apk add --no-cache wget tar unzip

addgroup -S prometheus 2>/dev/null || true
adduser -S -D -H -h /var/empty -s /sbin/nologin -G prometheus -g prometheus prometheus 2>/dev/null || true

mkdir -p /opt/prometheus /etc/prometheus /var/lib/prometheus
chown -R prometheus:prometheus /opt/prometheus /etc/prometheus /var/lib/prometheus

cd /tmp
wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar -xzf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz

cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /opt/prometheus/
cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /opt/prometheus/

chown -R prometheus:prometheus /opt/prometheus /etc/prometheus
chmod 755 /opt/prometheus/prometheus /opt/prometheus/promtool

rm -rf /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64*

echo "Prometheus installed"
SCRIPT

echo "[2/8] Deploying Prometheus configs..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/prometheus.yml"    "/etc/prometheus/prometheus.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/prometheus.openrc" "/etc/init.d/prometheus"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown prometheus:prometheus /etc/prometheus/prometheus.yml
chmod 644 /etc/prometheus/prometheus.yml
chmod 755 /etc/init.d/prometheus
touch /var/log/prometheus.log
chown prometheus:prometheus /var/log/prometheus.log
rc-service prometheus start
rc-update add prometheus
echo "Prometheus started"
SCRIPT

# ============================================================
# Grafana
# ============================================================
echo "[3/8] Installing Grafana v${GRAFANA_VERSION}..."
pct_script "${CT_ID}" <<SCRIPT
set -e

addgroup -S grafana 2>/dev/null || true
adduser -S -D -H -h /opt/grafana -s /sbin/nologin -G grafana -g grafana grafana 2>/dev/null || true

mkdir -p /opt/grafana /etc/grafana/provisioning/datasources /var/lib/grafana /var/log/grafana

cd /tmp
wget -q https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
tar -xzf grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
cp -r grafana-v${GRAFANA_VERSION}/* /opt/grafana/ 2>/dev/null || cp -r grafana-${GRAFANA_VERSION}/* /opt/grafana/ 2>/dev/null || true

chown -R grafana:grafana /opt/grafana /etc/grafana /var/lib/grafana /var/log/grafana
chmod 755 /opt/grafana/bin/grafana-server /opt/grafana/bin/grafana-cli

rm -rf /tmp/grafana-*

echo "Grafana installed"
SCRIPT

echo "[4/8] Deploying Grafana configs..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/grafana.ini"       "/etc/grafana/grafana.ini"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/datasources.yml"   "/etc/grafana/provisioning/datasources/datasources.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/grafana.openrc"    "/etc/init.d/grafana"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown -R grafana:grafana /etc/grafana
chmod 644 /etc/grafana/grafana.ini /etc/grafana/provisioning/datasources/datasources.yml
chmod 755 /etc/init.d/grafana
rc-service grafana start
rc-update add grafana
echo "Grafana started"
SCRIPT

# ============================================================
# Loki
# ============================================================
echo "[5/8] Installing Loki v${LOKI_VERSION}..."
pct_script "${CT_ID}" <<SCRIPT
set -e

addgroup -S loki 2>/dev/null || true
adduser -S -D -H -h /var/lib/loki -s /sbin/nologin -G loki -g loki loki 2>/dev/null || true

mkdir -p /opt/loki /etc/loki /var/lib/loki/chunks /var/lib/loki/rules /var/lib/loki/compactor

cd /tmp
wget -q https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip
unzip -o loki-linux-amd64.zip
mv loki-linux-amd64 /opt/loki/loki
chmod 755 /opt/loki/loki

chown -R loki:loki /opt/loki /etc/loki /var/lib/loki

rm -f /tmp/loki-linux-amd64.zip

echo "Loki installed"
SCRIPT

echo "[6/8] Deploying Loki configs..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/loki.yml"     "/etc/loki/loki.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/loki.openrc"  "/etc/init.d/loki"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown loki:loki /etc/loki/loki.yml
chmod 644 /etc/loki/loki.yml
chmod 755 /etc/init.d/loki
touch /var/log/loki.log
chown loki:loki /var/log/loki.log
rc-service loki start
rc-update add loki
echo "Loki started"
SCRIPT

# ============================================================
# Jaeger v2
# ============================================================
echo "[7/8] Installing Jaeger v${JAEGER_VERSION}..."
pct_script "${CT_ID}" <<SCRIPT
set -e

addgroup -S jaeger 2>/dev/null || true
adduser -S -D -H -h /var/lib/jaeger -s /sbin/nologin -G jaeger -g jaeger jaeger 2>/dev/null || true

mkdir -p /opt/jaeger /etc/jaeger /var/lib/jaeger/keys /var/lib/jaeger/values

cd /tmp
wget -q https://github.com/jaegertracing/jaeger/releases/download/v${JAEGER_VERSION}/jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz
tar -xzf jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz
cp jaeger-${JAEGER_VERSION}-linux-amd64/jaeger /opt/jaeger/ 2>/dev/null || \
    cp jaeger-${JAEGER_VERSION}-linux-amd64/jaeger-all-in-one /opt/jaeger/jaeger 2>/dev/null || true
chmod 755 /opt/jaeger/jaeger

chown -R jaeger:jaeger /opt/jaeger /etc/jaeger /var/lib/jaeger

rm -rf /tmp/jaeger-*

echo "Jaeger installed"
SCRIPT

echo "[8/8] Deploying Jaeger configs..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/jaeger.yml"    "/etc/jaeger/jaeger.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/jaeger.openrc" "/etc/init.d/jaeger"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown -R jaeger:jaeger /etc/jaeger
chmod 644 /etc/jaeger/jaeger.yml
chmod 755 /etc/init.d/jaeger
touch /var/log/jaeger.log
chown jaeger:jaeger /var/log/jaeger.log
rc-service jaeger start
rc-update add jaeger
echo "Jaeger started"
SCRIPT

echo "=== Monitoring Stack deployed ==="
echo "  Prometheus: http://${IP_MONITORING}:${PORT_PROMETHEUS}"
echo "  Grafana:    http://${IP_MONITORING}:${PORT_GRAFANA}"
echo "  Loki:       http://${IP_MONITORING}:${PORT_LOKI}"
echo "  Jaeger UI:  http://${IP_MONITORING}:${PORT_JAEGER_UI}"
