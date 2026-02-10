# WireGuard VPN 설정 가이드

Mac에서 내부 네트워크(Management 10.0.0.0/24, Service 10.1.0.0/24)에 직접 접근할 수 있도록 OPNsense WireGuard VPN을 설정한다.

## 동기

기존 접근 방식은 SSH 체이닝이 필요:
```
Mac → SSH <PROXMOX_USER>@<PROXMOX_HOST> (Proxmox) → pct exec <CT_ID> -- <CMD>
```

WireGuard 설정 후:
```
Mac (10.0.1.2) → VPN 터널 → 10.0.0.0/24, 10.1.0.0/24 직접 접근
```

## 네트워크 설계

### 터널 네트워크

| 역할 | 터널 IP | 설명 |
|------|---------|------|
| OPNsense (서버) | 10.0.1.1 | WireGuard 게이트웨이 |
| Mac (클라이언트) | 10.0.1.2 | 기본 워크스테이션 |
| (예약) | 10.0.1.3-254 | 향후 클라이언트 |

### Split Tunnel

- **VPN 경유**: 10.0.0.0/24 (Management), 10.1.0.0/24 (Service), 10.0.1.0/24 (WireGuard)
- **일반 경로**: 인터넷 트래픽 (VPN 미경유)

### 아키텍처

```
Internet / LAN
  │
  ▼
[NAT Router] ── 포트포워딩: 80, 443, 51820(UDP) → <OPNSENSE_WAN_IP>
  │
  ▼
[OPNsense (VM 102)]
  │  <OPNSENSE_WAN_IP> (WAN)
  │  10.0.0.1 (Management)
  │  10.1.0.1 (Service)
  │  10.0.1.1 (WireGuard)
  │
  ├── HAProxy (TCP 80/443) ── SSL 종료, 라우팅 (기존)
  │
  └── WireGuard (UDP 51820)
        │
        └── Mac (10.0.1.2) ── Split Tunnel
              ├── 10.0.0.0/24 직접 접근 (Management)
              └── 10.1.0.0/24 직접 접근 (Service)
```

---

## Phase 0: 사전 준비 (Mac)

### 0.1 WireGuard 설치

```bash
brew install wireguard-tools
```

### 0.2 키페어 생성

```bash
mkdir -p ~/wireguard
wg genkey | tee ~/wireguard/privatekey | wg pubkey > ~/wireguard/publickey
chmod 600 ~/wireguard/privatekey
```

생성된 public key를 확인 (Phase 2에서 OPNsense에 등록):
```bash
cat ~/wireguard/publickey
```

---

## Phase 1: OPNsense WireGuard 서버 설정 (Web UI)

### 1.1 WireGuard 플러그인 설치

1. `System > Firmware > Plugins`
2. `os-wireguard` 검색 → 설치 (`+` 버튼)
3. 페이지 새로고침 후 `VPN > WireGuard` 메뉴 확인

### 1.2 WireGuard 활성화

1. `VPN > WireGuard > General`
2. **Enable WireGuard** 체크
3. **Save**

### 1.3 Local Instance 생성

1. `VPN > WireGuard > Instances` → `+` 추가
2. 설정:
   - **Name**: `wg0`
   - **Public Key**: (자동 생성됨, **이 값을 기록**)
   - **Private Key**: (자동 생성됨)
   - **Listen Port**: `51820`
   - **Tunnel Address**: `10.0.1.1/24`
   - **Peers**: (Phase 2 이후 추가)
3. **Save**

> **중요**: 서버의 Public Key를 기록해둔다. Mac 클라이언트 설정(`wg0.conf`)의 `[Peer] PublicKey`에 입력해야 한다.

---

## Phase 2: Peer 설정

### 2.1 Mac 피어 추가

1. `VPN > WireGuard > Peers` → `+` 추가
2. 설정:
   - **Name**: `mac-workstation`
   - **Public Key**: `<Mac의 ~/wireguard/publickey 값>`
   - **Allowed IPs**: `10.0.1.2/32`
   - **Keepalive Interval**: `25`
3. **Save**

### 2.2 Local Instance에 Peer 연결

1. `VPN > WireGuard > Instances` → `wg0` 편집
2. **Peers** 필드에서 `mac-workstation` 선택
3. **Save** → **Apply**

---

## Phase 3: 인터페이스 할당

### 3.1 WireGuard 인터페이스 할당

1. `Interfaces > Assignments`
2. 하단 "New interface" 드롭다운에서 WireGuard 디바이스 (`wg0`) 선택
3. `+` 버튼으로 추가 (OPT2 등으로 할당됨)

### 3.2 인터페이스 활성화

1. 새 인터페이스 (예: `Interfaces > [OPT2]`) 클릭
2. 설정:
   - **Enable Interface**: 체크
   - **Description**: `WireGuard`
   - **IPv4 Configuration Type**: `None`
   - **IPv6 Configuration Type**: `None`
3. **Save** → **Apply Changes**

> 터널 주소는 WireGuard가 관리하므로 IPv4/IPv6 설정은 `None`으로 둔다.

---

## Phase 4: 방화벽 규칙

### 4.1 WAN: WireGuard UDP 포트 허용

1. `Firewall > Rules > WAN` → `+` 추가
2. 설정:
   - **Action**: Pass
   - **Protocol**: UDP
   - **Destination**: WAN address
   - **Destination port range**: 51820
   - **Description**: `Allow WireGuard UDP`
3. **Save** → **Apply Changes**

### 4.2 WireGuard 인터페이스: 내부 네트워크 접근 허용

`Firewall > Rules > WireGuard` (Phase 3에서 할당한 인터페이스 이름)에 규칙 3개 추가:

| # | Source | Destination | Description |
|---|--------|-------------|-------------|
| 1 | WireGuard net | LAN net (10.0.0.0/24) | Allow WG to Management |
| 2 | WireGuard net | OPT1 net (10.1.0.0/24) | Allow WG to Service |
| 3 | WireGuard net | WireGuard net | Allow WG inter-peer |

모든 규칙: **Action**: Pass, **Protocol**: any

> `LAN net`, `OPT1 net` 등은 OPNsense의 인터페이스 별칭이다. 환경에 따라 실제 인터페이스 이름이 다를 수 있으니 `Interfaces > Assignments`에서 확인한다.

### 4.3 MSS Clamping (TCP 단편화 방지)

1. `Firewall > Settings > Normalization` → `+` 추가
2. 설정:
   - **Interface**: WireGuard
   - **Direction**: any
   - **Max MSS**: `1380`
3. **Save** → **Apply Changes**

---

## Phase 5: NAT Router 포트포워딩

NAT Router 관리페이지 (<GATEWAY_IP>) > 고급 설정 > NAT/라우터 관리 > 포트포워드 설정:

| 외부 포트 | 프로토콜 | 내부 IP | 내부 포트 | 설명 |
|-----------|---------|---------|-----------|------|
| 80 | TCP | <OPNSENSE_WAN_IP> | 80 | HTTP (기존) |
| 443 | TCP | <OPNSENSE_WAN_IP> | 443 | HTTPS (기존) |
| **51820** | **UDP** | **<OPNSENSE_WAN_IP>** | **51820** | **WireGuard VPN (신규)** |

---

## Phase 6: Mac 클라이언트 설정

### 6.1 설정 파일 수정

`~/wireguard/wg0.conf`에서 placeholder를 실제 값으로 교체:

```ini
[Interface]
PrivateKey = <~/wireguard/privatekey 내용>
Address = 10.0.1.2/24
MTU = 1420

[Peer]
PublicKey = <OPNsense 서버의 Public Key (Phase 1.3)>
Endpoint = <공인 IP 또는 DDNS>:51820
AllowedIPs = 10.0.0.0/24, 10.1.0.0/24, 10.0.1.0/24
PersistentKeepalive = 25
```

**설계 포인트**:
- **Split Tunnel**: AllowedIPs에 내부 서브넷만 지정 → 인터넷 트래픽은 VPN 미경유
- **DNS 미설정**: 내부 DNS 불필요 (IP 직접 접근)
- **MTU 1420**: WireGuard 오버헤드(80바이트)를 고려한 값

### 6.2 터널 관리

```bash
# 연결
sudo wg-quick up ~/wireguard/wg0.conf

# 상태 확인
sudo wg show

# 해제
sudo wg-quick down ~/wireguard/wg0.conf
```

---

## Phase 7: 검증

### 터널 상태

```bash
sudo wg show
# latest handshake가 표시되면 연결 성공
```

### Management 네트워크

```bash
ping 10.0.0.254   # Proxmox Host
ping 10.0.0.1     # OPNsense LAN
```

### Service 네트워크

```bash
ping 10.1.0.100   # CP Traefik
ping 10.1.0.110   # PostgreSQL
ping 10.1.0.111   # Valkey
ping 10.1.0.120   # Monitoring
ping 10.1.0.130   # Jenkins
ping 10.1.0.140   # Kopring
```

### 서비스 직접 접근

```bash
# SSH (체이닝 없이!)
ssh <PROXMOX_USER>@<PROXMOX_HOST>

# PostgreSQL 직접
psql -h 10.1.0.110 -U chaekpool

# Grafana 직접
curl http://10.1.0.120:3000
```

### Split Tunnel 확인

```bash
# 인터넷은 VPN 미경유 (일반 공인 IP 출력)
curl ifconfig.me
```

---

## 트러블슈팅

### 기본 문제 해결

**핸드셰이크가 되지 않는 경우**:
1. Mac의 public key가 OPNsense Peer에 정확히 등록되었는지 확인
2. Peer가 Local 인스턴스에 연결되었는지 확인 (`VPN > WireGuard > Local > wg0 > Peers`)
3. NAT Router 포트포워딩 확인: UDP 51820 → <OPNSENSE_WAN_IP>
4. OPNsense WAN 방화벽 규칙 확인: UDP 51820 Pass

**핸드셰이크는 되지만 ping이 안 되는 경우**:
1. WireGuard 방화벽 규칙 확인: `Firewall > Rules > WireGuard (Group)` → Pass 규칙 필요
2. WireGuard 인터페이스 활성화 확인: `Interfaces > Assignments` → wg0 Enable
3. Proxmox 정적 라우트 확인: `ip route | grep 10.0.1`

**MTU 문제 (큰 패킷 전송 실패)**:
```bash
# MTU 테스트
ping -s 1392 -D 10.0.0.254
```
실패 시 `wg0.conf`의 MTU를 1400으로 낮춤.

### 상세 트러블슈팅

더 자세한 문제 해결 방법은 **[VPN 운영 및 트러블슈팅 가이드](vpn-operations-guide.md)** 참고:
- 발생 가능한 9가지 문제와 해결 과정
- 증상별 진단 방법 및 체크리스트
- 자동 검증 스크립트
- VPN 클라이언트 관리 및 모니터링
