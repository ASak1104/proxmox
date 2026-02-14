#!/bin/bash
# WireGuard VPN 연결 관리 스크립트
set -euo pipefail

# === 설정 ===
WG_CONF="$HOME/wireguard/wg0.conf"
PROXMOX_MGMT_IP="10.0.0.254"
SERVICE_IP="10.1.0.100"

# === 헬퍼 ===
is_connected() {
    sudo wg show 2>/dev/null | grep -q "interface"
}

check_network() {
    local label="$1" ip="$2"
    if ping -c 1 -W 2 "$ip" &>/dev/null; then
        echo "  [OK] $label ($ip)"
        return 0
    else
        echo "  [FAIL] $label ($ip)"
        return 1
    fi
}

# === 명령어 ===
cmd_up() {
    if is_connected; then
        echo "VPN이 이미 연결되어 있습니다."
        sudo wg show | grep -E "interface|endpoint|latest handshake"
        return 0
    fi

    echo "VPN 연결 중..."
    sudo wg-quick up "$WG_CONF"

    echo ""
    echo "네트워크 검증 중..."
    sleep 1
    if check_network "Management" "$PROXMOX_MGMT_IP"; then
        echo ""
        echo "VPN 연결 완료"
    else
        echo ""
        echo "VPN 터널은 생성되었으나 Management 네트워크 접근 불가"
        echo "트러블슈팅: docs/vpn-operations-guide.md 참고"
    fi
}

cmd_down() {
    if ! is_connected; then
        echo "VPN이 연결되어 있지 않습니다."
        return 0
    fi

    echo "VPN 해제 중..."
    sudo wg-quick down "$WG_CONF"
    echo "VPN 해제 완료"
}

cmd_status() {
    if ! is_connected; then
        echo "VPN 연결 안 됨"
        return 0
    fi

    echo "=== WireGuard 상태 ==="
    sudo wg show
    echo ""
    echo "=== 네트워크 접근 ==="
    check_network "Management (Proxmox)" "$PROXMOX_MGMT_IP" || true
    check_network "Service (Traefik)" "$SERVICE_IP" || true
}

cmd_restart() {
    cmd_down
    echo ""
    cmd_up
}

# === 메인 ===
case "${1:-}" in
    up)      cmd_up ;;
    down)    cmd_down ;;
    status)  cmd_status ;;
    restart) cmd_restart ;;
    *)
        echo "Usage: $0 {up|down|status|restart}"
        exit 1
        ;;
esac
