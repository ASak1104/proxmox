#!/bin/bash
# service/chaekpool/scripts/common.sh - Chaekpool 공용 변수/함수
set -euo pipefail

# VPN 연결 필수 (secrets.env의 PROXMOX_HOST 참조)
# VPN 미연결 시 긴급: PROXMOX_HOST="<PROXMOX_EXTERNAL_IP>"
PROXMOX_HOST="10.0.0.254"
PROXMOX_USER="admin"

# 컨테이너 ID (카테고리별 그룹)
# LB: 200-209
CT_TRAEFIK="200"
# Data: 210-219
CT_POSTGRESQL="210"
CT_VALKEY="211"
# Monitoring: 220-229
CT_MONITORING="220"
# CI/CD: 230-239
CT_JENKINS="230"
# App: 240-249
CT_KOPRING="240"

# 컨테이너 IP
IP_TRAEFIK="10.1.0.100"
IP_POSTGRESQL="10.1.0.110"
IP_VALKEY="10.1.0.111"
IP_MONITORING="10.1.0.120"
IP_JENKINS="10.1.0.130"
IP_KOPRING="10.1.0.140"

# 서비스 포트
PORT_TRAEFIK="80"
PORT_POSTGRESQL="5432"
PORT_PGADMIN="5050"
PORT_VALKEY="6379"
PORT_REDIS_COMMANDER="8081"
PORT_PROMETHEUS="9090"
PORT_GRAFANA="3000"
PORT_LOKI="3100"
PORT_JAEGER_UI="16686"
PORT_JAEGER_OTLP_GRPC="4317"
PORT_JAEGER_OTLP_HTTP="4318"
PORT_JENKINS="8080"
PORT_KOPRING="8080"

# 비밀번호 (단일 환경)
PG_DB="chaekpool"
PG_USER="chaekpool"
PG_PASSWORD="changeme"
VALKEY_PASSWORD="changeme"

# pgAdmin 인증
PGADMIN_EMAIL="admin@codingmon.dev"
PGADMIN_PASSWORD="changeme"

# Proxmox SSH 접속 함수
pve_ssh() {
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
}

# 컨테이너 내 명령 실행
pct_exec() {
    local ct_id="$1"; shift
    pve_ssh "sudo pct exec ${ct_id} -- sh -c '$*'"
}

# 파일 전송 (Mac → Proxmox /tmp → 컨테이너)
pct_push() {
    local ct_id="$1"
    local local_path="$2"
    local remote_path="$3"
    local tmp="/tmp/$(basename "${local_path}")"
    pve_ssh "sudo rm -f ${tmp}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "cat > ${tmp}" < "${local_path}"
    pve_ssh "sudo pct push ${ct_id} ${tmp} ${remote_path} && rm -f ${tmp}"
}

# heredoc 기반 다중 행 스크립트 실행 (stdin으로 전달)
pct_script() {
    local ct_id="$1"
    pve_ssh "sudo pct exec ${ct_id} -- sh -s"
}

# SCRIPT_DIR는 각 deploy.sh에서 source 전에 설정
