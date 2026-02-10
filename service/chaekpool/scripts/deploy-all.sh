#!/bin/bash
# Chaekpool 전체 배포 오케스트레이터 (병렬 실행)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo " Chaekpool - Parallel Deployment"
echo "=========================================="
echo

# Wave 1: 독립적인 서비스들을 병렬로 배포
echo "=== Wave 1: Deploying independent services in parallel ==="
echo

(
  echo "[1/5] CP Traefik (CT 200)"
  echo "------------------------------------------"
  bash "${SCRIPT_DIR}/traefik/deploy.sh"
  echo "✓ Traefik deployed"
) &
TRAEFIK_PID=$!

(
  echo "[2/5] PostgreSQL + pgAdmin (CT 210)"
  echo "------------------------------------------"
  bash "${SCRIPT_DIR}/postgresql/deploy.sh"
  echo "✓ PostgreSQL deployed"
) &
POSTGRES_PID=$!

(
  echo "[3/5] Valkey + Redis Commander (CT 211)"
  echo "------------------------------------------"
  bash "${SCRIPT_DIR}/valkey/deploy.sh"
  echo "✓ Valkey deployed"
) &
VALKEY_PID=$!

(
  echo "[4/5] Monitoring Stack (CT 220)"
  echo "------------------------------------------"
  bash "${SCRIPT_DIR}/monitoring/deploy.sh"
  echo "✓ Monitoring deployed"
) &
MONITORING_PID=$!

(
  echo "[5/5] Jenkins (CT 230)"
  echo "------------------------------------------"
  bash "${SCRIPT_DIR}/jenkins/deploy.sh"
  echo "✓ Jenkins deployed"
) &
JENKINS_PID=$!

# 모든 Wave 1 서비스가 완료될 때까지 대기
echo "Waiting for Wave 1 services to complete..."
WAVE1_FAILED=0

wait $TRAEFIK_PID || WAVE1_FAILED=1
wait $POSTGRES_PID || WAVE1_FAILED=1
wait $VALKEY_PID || WAVE1_FAILED=1
wait $MONITORING_PID || WAVE1_FAILED=1
wait $JENKINS_PID || WAVE1_FAILED=1

if [ $WAVE1_FAILED -eq 1 ]; then
  echo "❌ Wave 1 deployment failed. Aborting."
  exit 1
fi

echo
echo "✓ Wave 1 completed successfully"
echo

# Wave 2: PostgreSQL과 Valkey에 의존하는 서비스 배포
echo "=== Wave 2: Deploying dependent services ==="
echo

echo "[6/6] Kopring (CT 240)"
echo "------------------------------------------"
if bash "${SCRIPT_DIR}/kopring/deploy.sh"; then
  echo "✓ Kopring deployed"
else
  echo "⚠️  Kopring deployment failed (check if app.jar exists)"
fi
echo

echo "=========================================="
echo " All services deployed successfully"
echo "=========================================="
