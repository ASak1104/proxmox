# WireGuard VPN 운영 및 트러블슈팅 가이드

> **작성일**: 2026-02-10
> **대상**: OPNsense 25.7+ WireGuard VPN
> **범위**: VPN 배포 과정 기록, 트러블슈팅, 클라이언트 관리, 모니터링

---

## 목차

1. [VPN 아키텍처 개요](#1-vpn-아키텍처-개요)
2. [배포 과정 기록 (2026-02-10)](#2-배포-과정-기록-2026-02-10)
3. [발생한 문제와 해결 과정](#3-발생한-문제와-해결-과정)
4. [VPN 클라이언트 관리](#4-vpn-클라이언트-관리)
5. [모니터링 및 상태 확인](#5-모니터링-및-상태-확인)
6. [트러블슈팅 레퍼런스](#6-트러블슈팅-레퍼런스)
7. [보안 권장사항](#7-보안-권장사항)
8. [SSH 연결 및 API 사용 패턴](#8-ssh-연결-및-api-사용-패턴)
9. [FAQ](#9-faq)

---

## 1. VPN 아키텍처 개요

### 1.1 네트워크 토폴로지

```
Internet
  │
  ▼
[NAT Router] ── 포트포워딩: UDP 51820 → <OPNSENSE_WAN_IP>
  │
  ▼
[OPNsense (VM 102)]
  │  <OPNSENSE_WAN_IP> (WAN)
  │  10.0.0.1 (Management LAN)
  │  10.1.0.1 (Service OPT1)
  │  10.0.1.1 (WireGuard wg0)
  │
  └── WireGuard (UDP 51820)
        │
        └── Mac Client (10.0.1.2)
              ├── 10.0.0.0/24 (Management) - Proxmox, OPNsense
              ├── 10.0.1.0/24 (WireGuard Tunnel)
              └── 10.1.0.0/24 (Service) - CP Containers
```

### 1.2 네트워크 서브넷

| Bridge/Interface | Purpose | Subnet | Gateway | 용도 |
|------------------|---------|--------|---------|------|
| vmbr0 | External (WAN) | <EXTERNAL_SUBNET> | <GATEWAY_IP> (NAT Router) | 외부 연결 |
| vmbr1 | Management | 10.0.0.0/24 | 10.0.0.1 (OPNsense) | 인프라 관리 |
| vmbr2 | Service | 10.1.0.0/24 | 10.1.0.1 (OPNsense) | Chaekpool 서비스 |
| wg0 | WireGuard VPN | 10.0.1.0/24 | 10.0.1.1 (OPNsense) | VPN 터널 |

### 1.3 Split Tunnel 설계

**AllowedIPs 설정**:
- `10.0.0.0/24` (Management 네트워크)
- `10.0.1.0/24` (WireGuard 터널 네트워크)
- `10.1.0.0/24` (Service 네트워크)

**트래픽 분리**:
- VPN 경유: 위 3개 서브넷에 대한 트래픽
- 일반 경로: 인터넷 트래픽 (0.0.0.0/0은 AllowedIPs에 미포함)

**장점**:
- 내부 네트워크 접근 시에만 VPN 사용
- 인터넷 트래픽은 일반 라우팅 (성능 최적화)
- 클라이언트 DNS 설정 불필요

### 1.4 라우팅 흐름

```
Mac (10.0.1.2)
  │
  ├── ping 8.8.8.8           → 일반 게이트웨이 (VPN 미경유)
  │
  ├── ssh <PROXMOX_USER>@<PROXMOX_HOST>   → WireGuard → OPNsense → Proxmox
  │
  ├── curl 10.1.0.100        → WireGuard → OPNsense → Service 네트워크
  │                                                   → Proxmox 라우팅
  │                                                   → CT 200 (Traefik)
  └── curl ifconfig.me       → 일반 게이트웨이 (공인 IP 출력)
```

**핵심 라우팅 규칙**:
1. Mac → OPNsense (10.0.1.1): WireGuard 터널 직접
2. Mac → 10.0.0.0/24: WireGuard → OPNsense (이미 게이트웨이)
3. Mac → 10.1.0.0/24: WireGuard → OPNsense → Proxmox (정적 라우트) → 컨테이너

---

## 2. 배포 과정 기록 (2026-02-10)

### 2.1 배포 동기

기존 SSH 체이닝 방식의 한계:
```bash
# 기존: 2-hop SSH 필요
Mac → ssh <PROXMOX_USER>@<PROXMOX_HOST> → pct exec 200 -- <cmd>

# VPN 후: 직접 접근 가능
Mac → curl http://10.1.0.100/ping
```

네트워크 서브넷 마이그레이션 (10.0.1.0/24 → 10.1.0.0/24)과 함께 WireGuard VPN을 구성하여 외부에서 내부 네트워크에 안전하게 접근.

### 2.2 초기 계획

**Phase 순서**:
1. Phase 0: Mac 키페어 생성
2. Phase 1: OPNsense WireGuard 서버 설정
3. Phase 2: Peer 등록
4. Phase 3: 인터페이스 할당
5. Phase 4: 방화벽 규칙
6. Phase 5: NAT Router 포트포워딩
7. Phase 6: Mac 클라이언트 설정
8. Phase 7: 검증

**예상 소요 시간**: 1-2시간

### 2.3 실제 발생 사항

**총 소요 시간**: 약 4시간 (예상의 2배)

**주요 병목**:
1. WireGuard 플러그인 위치 찾기 (25.7에서 코어 통합)
2. 인터페이스 할당 누락으로 인한 방화벽 규칙 오류
3. Peer와 Local 인스턴스 연결 누락
4. WireGuard (Group) 방화벽 규칙 개념 이해
5. Proxmox 정적 라우트 추가 필요성 발견

**긍정적 발견**:
- VPN 연결 후 Management 네트워크 직접 접근 가능 (10.0.0.254)
- SSH 체이닝 없이 서비스 직접 접근 가능
- Split Tunnel로 성능 영향 최소화

### 2.4 타임라인

| 시간 | 단계 | 결과 |
|------|------|------|
| 0:00 | Phase 0-1: Mac 키 생성, OPNsense 설정 시도 | 플러그인 미발견 |
| 0:20 | 문제 #1 해결: 코어 통합 확인 | Local 인스턴스 생성 성공 |
| 0:30 | Phase 2-3: Peer 등록, 인터페이스 할당 시도 | 방화벽 규칙 오류 |
| 0:50 | 문제 #2, #3 해결: 인터페이스 Enable | 방화벽 규칙 생성 성공 |
| 1:10 | Phase 4-6: 방화벽, 포트포워딩, 클라이언트 설정 | 핸드셰이크 실패 |
| 1:40 | 문제 #4 해결: Peer-Instance 연결 | 핸드셰이크 성공 |
| 2:00 | Phase 7: 검증 (ping 10.0.0.1) | ping 타임아웃 |
| 2:30 | 문제 #5 해결: WireGuard Group 규칙 | OPNsense ping 성공 |
| 3:00 | 검증 (ping 10.1.0.100) | ping 타임아웃 |
| 3:40 | 문제 #6 해결: Proxmox 정적 라우트 | 모든 네트워크 접근 성공 |
| 4:00 | 문서 작성, SSH 패턴 변경 준비 | 완료 |

---

## 3. 발생한 문제와 해결 과정

### 문제 1: os-wireguard 플러그인이 System > Firmware > Plugins에 없음

**증상**: OPNsense Web UI에서 `System > Firmware > Plugins` 검색 시 `os-wireguard` 플러그인이 표시되지 않음.

**원인**: OPNsense **24.1** 버전부터 WireGuard가 **FreeBSD 커널에 통합**됨. 별도 플러그인 설치가 불필요. 현재 버전은 25.7.11이므로 이미 코어에 포함됨.

**해결**:
1. `VPN > WireGuard` 메뉴 직접 접근 (플러그인 설치 없이)
2. WireGuard 메뉴가 있으면 이미 사용 가능

**교훈**:
- OPNsense 버전에 따라 플러그인 필요 여부가 다름
- 24.1+ 버전에서는 WireGuard가 기본 제공
- 공식 문서가 구 버전 기준일 수 있으므로 UI 직접 확인 필요

---

### 문제 2: "Enable WireGuard" 옵션이 General 탭에 없음

**증상**: `VPN > WireGuard > General` 탭에 "Enable WireGuard" 체크박스가 표시되지 않음.

**원인**: OPNsense 최신 버전(25.7)에서는 General 탭 자체가 제공되지 않음. Local 인스턴스를 생성하면 자동으로 WireGuard가 활성화됨.

**해결**:
1. General 탭 찾지 말 것
2. `VPN > WireGuard > Local` 탭에서 바로 Local 인스턴스 생성
3. 인스턴스 생성 시 자동으로 WireGuard 서비스 시작

**교훈**:
- 공식 문서의 UI 경로와 실제 UI가 다를 수 있음
- 버전별 UI 차이 확인 필요
- Local 인스턴스가 없으면 WireGuard는 실행되지 않음

---

### 문제 3: Listen Port 필드에 기본값 51820이 자동 입력되지 않음

**증상**: Local 인스턴스 생성 시 Listen Port 필드가 비어 있음. 빈 상태로 저장하면 WireGuard가 임의 포트를 사용.

**원인**: OPNsense UI에서 Listen Port 기본값을 자동 설정하지 않음 (버전별 동작 차이 가능).

**해결**:
1. Listen Port 필드에 **51820** 명시적으로 입력
2. 저장 전 모든 필드 검증

**교훈**:
- 필수 필드라도 기본값이 자동 입력된다고 가정하지 말 것
- 포트를 표준 51820으로 고정하면 방화벽 규칙 관리가 간편
- 설정 저장 전 입력값 재확인 필수

---

### 문제 4: 방화벽 규칙 생성 시 "opt2ip is not a valid address" 오류

**증상**: `Firewall > Rules > WireGuard` 인터페이스에 규칙 추가 시 "opt2ip" alias 오류 발생.

**원인**: WireGuard 인터페이스(`wg0`)가 `Interfaces > Assignments`에 **할당되지 않았거나**, 할당은 되었지만 **Enable 체크가 안 되어 있음**. OPNsense는 활성화된 인터페이스에 대해서만 alias를 생성함.

**해결**:
1. `Interfaces > Assignments` 접속
2. 하단 "New interface" 드롭다운에서 `wg0` 선택
3. `+` 버튼으로 추가 (OPT2 등으로 할당됨)
4. 새 인터페이스 (예: `Interfaces > [OPT2]`) 클릭
5. **Enable Interface** 체크
6. **Description**: `WireGuard`
7. **IPv4/IPv6 Configuration Type**: `None` (터널 주소는 WireGuard가 관리)
8. **Save** → **Apply Changes**
9. 방화벽 규칙 재생성

**교훈**:
- 인터페이스 할당과 활성화는 별개 단계
- 활성화하지 않으면 alias/방화벽 규칙에서 인식 안 됨
- WireGuard는 터널 주소를 자체 관리하므로 IP 설정 불필요

---

### 문제 5: WireGuard 핸드셰이크가 발생하지 않음 (latest handshake 없음)

**증상**: Mac에서 `sudo wg show` 실행 시 `latest handshake` 항목이 표시되지 않음. ping 타임아웃.

**원인**: OPNsense에서 Peer가 생성되었지만 **Local 인스턴스에 연결되지 않음**. OPNsense WireGuard UI에서 Peer와 Local은 별도 생성 후 **명시적으로 연결**해야 함.

**해결**:
1. `VPN > WireGuard > Endpoints` 탭 확인 (Peer 존재 확인)
2. `VPN > WireGuard > Local` 탭 접속
3. Local 인스턴스 편집
4. **Peers** 필드에서 `mac-workstation` (Peer 이름) 선택
5. **Save** → **Apply**
6. Mac에서 `sudo wg-quick down ~/wireguard/wg0.conf && sudo wg-quick up ~/wireguard/wg0.conf` 재연결
7. `sudo wg show` 확인: `latest handshake: X seconds ago` 출력

**교훈**:
- Peer 등록과 Local-Peer 연결은 별개 작업
- Endpoints 탭에서 Peer 생성만으로는 불충분
- Local 탭에서 명시적으로 Peer 선택 필요
- 핸드셰이크가 없으면 방화벽 규칙이 올바라도 통신 불가

---

### 문제 6: 핸드셰이크는 성공하지만 ping 타임아웃 (OPNsense 10.0.1.1)

**증상**: `sudo wg show`에서 `latest handshake: 2 seconds ago` 정상, `ping 10.0.1.1` (OPNsense WireGuard 게이트웨이) 타임아웃.

**원인**: WireGuard 방화벽 규칙이 없음. OPNsense 방화벽은 기본적으로 **Deny All** 정책이므로, 명시적인 Pass 규칙이 없으면 터널 트래픽도 차단됨.

**진단**:
```bash
# Mac에서
traceroute 10.0.1.1  # 패킷이 전송되지만 응답 없음

# OPNsense 콘솔에서 (Proxmox WebUI → VM 102 → Console → 8)
wg show  # peer가 표시되고 최근 핸드셰이크 확인
pfctl -sr | grep wg  # WireGuard 관련 규칙 없음
```

**해결**:
1. `Firewall > Rules > WireGuard (Group)` 접속
   - 주의: 개별 인터페이스(OPT2) 탭이 아니라 **WireGuard (Group)** 탭 사용
2. `+` 버튼으로 규칙 3개 추가:

| # | Action | Protocol | Source | Destination | Description |
|---|--------|----------|--------|-------------|-------------|
| 1 | Pass | any | WireGuard net | LAN net (10.0.0.0/24) | Allow WG to Management |
| 2 | Pass | any | WireGuard net | OPT1 net (10.1.0.0/24) | Allow WG to Service |
| 3 | Pass | any | WireGuard net | WireGuard net | Allow WG inter-peer |

3. **Save** → **Apply Changes**
4. Mac에서 `ping 10.0.1.1` 재시도: 성공

**교훈**:
- WireGuard 인터페이스 규칙은 **WireGuard (Group)** 탭에서 관리
- 개별 인터페이스(OPT2) 탭에 추가하면 적용 안 될 수 있음
- 핸드셰이크 성공 ≠ 방화벽 통과
- 최소 권한 원칙: 필요한 네트워크만 허용 (Pass 규칙 3개)

---

### 문제 7: OPNsense ping 성공, Proxmox/컨테이너 ping 실패

**증상**:
- `ping 10.0.1.1` (OPNsense): 성공
- `ping 10.0.0.254` (Proxmox Management IP): 타임아웃
- `ping 10.1.0.100` (Traefik Service IP): 타임아웃

**원인**: Proxmox가 게이트웨이가 아닌 일반 호스트이므로, **WireGuard 네트워크(10.0.1.0/24)로 가는 라우팅 경로**를 모름. OPNsense는 알고 있지만, Proxmox는 10.0.1.0/24로 응답을 보낼 방법이 없음.

**진단**:
```bash
# Mac에서
traceroute 10.0.0.254
# 1  10.0.1.1 (OPNsense)  # 첫 홉 성공
# 2  * * *               # 이후 응답 없음

# Proxmox 콘솔에서 (ssh <PROXMOX_USER>@<PROXMOX_HOST>)
ip route | grep 10.0.1
# (결과 없음)
```

Proxmox가 10.0.1.2로 응답 패킷을 보낼 때, 라우팅 테이블에 10.0.1.0/24 경로가 없어서 패킷을 버림.

**해결**:
```bash
# 1. Proxmox에 정적 라우트 추가 (일시적)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ip route add 10.0.1.0/24 via 10.0.0.1"

# 2. 영구 설정 (/etc/network/interfaces)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo bash -c 'cat >> /etc/network/interfaces <<EOF

# WireGuard 네트워크 라우팅 (VPN 클라이언트 응답용)
post-up ip route add 10.0.1.0/24 via 10.0.0.1 || true
post-down ip route del 10.0.1.0/24 || true
EOF'"

# 3. 검증
ping 10.0.0.254  # 성공
ping 10.1.0.100  # 성공
```

**교훈**:
- VPN 게이트웨이가 아닌 호스트에도 정적 라우트 필요
- 라우팅 흐름: Mac → OPNsense (wg0) → Proxmox (vmbr1) → 응답 → OPNsense (10.0.0.1) → WireGuard (wg0) → Mac
- Proxmox가 "응답을 어디로 보낼지" 알아야 함 (10.0.1.0/24 → 10.0.0.1)
- `/etc/network/interfaces`의 `post-up` 스크립트로 재부팅 대응
- `|| true`로 중복 추가 시 에러 방지

---

### 문제 8: 재부팅 후 라우트 손실

**증상**: Proxmox 재부팅 후 `ip route | grep 10.0.1` 결과 없음. VPN에서 다시 ping 실패.

**원인**: `ip route add` 명령은 휘발성이며, 재부팅 시 소실됨. `/etc/network/interfaces`에 영구 설정이 없었음.

**해결**: 문제 #7에서 `post-up` 스크립트 추가로 해결.

**검증**:
```bash
# Proxmox 재부팅
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo reboot"

# 재부팅 후 (5분 대기)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "ip route | grep 10.0.1"
# 10.0.1.0/24 via 10.0.0.1 dev vmbr1  # 자동 생성 확인

# VPN에서
ping 10.0.0.254  # 성공
```

**교훈**:
- 라우팅 설정은 반드시 영구 저장
- Debian/Ubuntu: `/etc/network/interfaces`의 `post-up`
- 다른 배포판: `/etc/sysconfig/network-scripts/route-*`, netplan 등
- 재부팅 테스트 필수

---

### 문제 9: LAN에서 VPN 연결 불가 (NAT hairpin 미지원)

**증상**: 외부(모바일 데이터)에서는 VPN 연결 성공, 동일 LAN(<EXTERNAL_SUBNET>)에서는 핸드셰이크 실패.

**원인**: NAT Router가 **NAT hairpin (NAT loopback)**을 지원하지 않음. LAN 내부 클라이언트가 공인 IP + 포트로 OPNsense에 접근 시, NAT Router이 패킷을 라우팅하지 못함.

**해결**:
1. LAN 전용 설정 파일 생성:
```bash
# ~/wireguard/wg0-lan.conf
[Interface]
PrivateKey = (동일)
Address = 10.0.1.2/24
MTU = 1420

[Peer]
PublicKey = (OPNsense 공개키)
Endpoint = <OPNSENSE_WAN_IP>:51820  # LAN IP 직접 사용
AllowedIPs = 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24
PersistentKeepalive = 25
```

2. 사용:
```bash
# LAN에서 연결 시
sudo wg-quick up ~/wireguard/wg0-lan.conf

# 외부에서 연결 시
sudo wg-quick up ~/wireguard/wg0.conf  # 공인 IP/DDNS 사용
```

**교훈**:
- NAT hairpin 지원 여부는 공유기마다 다름
- 환경에 따라 별도 설정 파일 준비
- 스크립트로 자동 선택 가능:
```bash
if ip route get 1.1.1.1 | grep -q <GATEWAY_IP>; then
    sudo wg-quick up ~/wireguard/wg0-lan.conf
else
    sudo wg-quick up ~/wireguard/wg0.conf
fi
```

---

## 4. VPN 클라이언트 관리

### 4.1 새 클라이언트 추가 절차

#### Step 1: 클라이언트에서 키페어 생성

```bash
# Mac/Linux
wg genkey | tee privatekey | wg pubkey > publickey
chmod 600 privatekey

# 공개키 확인 (OPNsense에 입력할 값)
cat publickey
```

#### Step 2: OPNsense에 Peer 등록

1. `VPN > WireGuard > Endpoints` → `+` 추가
2. 설정:
   - **Enabled**: 체크
   - **Name**: `client-name` (예: `laptop-john`)
   - **Public Key**: `<클라이언트의 publickey 값>`
   - **Allowed IPs**: `10.0.1.X/32` (IP 할당 관리표 참고)
   - **Endpoint Address**: (비워둠 - 클라이언트가 서버에 연결)
   - **Endpoint Port**: (비워둠)
   - **Keepalive Interval**: `25` (NAT 통과 유지)
3. **Save**

#### Step 3: Local 인스턴스에 Peer 연결

1. `VPN > WireGuard > Local` → `wg0` 편집
2. **Peers** 필드에서 `client-name` 선택 (기존 Peer들과 함께 다중 선택)
3. **Save** → **Apply**

#### Step 4: 클라이언트 설정 파일 생성

```ini
# ~/wireguard/wg0.conf (또는 클라이언트별 이름)
[Interface]
PrivateKey = <클라이언트의 privatekey 내용>
Address = 10.0.1.X/24
MTU = 1420

[Peer]
PublicKey = <OPNsense 서버의 Public Key>
Endpoint = <공인 IP 또는 DDNS>:51820
AllowedIPs = 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24
PersistentKeepalive = 25
```

**OPNsense 공개키 확인**: `VPN > WireGuard > Local` → `wg0` 상세보기 → Public Key

#### Step 5: 연결 테스트

```bash
# 연결
sudo wg-quick up ~/wireguard/wg0.conf

# 상태 확인
sudo wg show

# 네트워크 테스트
ping 10.0.1.1      # OPNsense
ping 10.0.0.254    # Proxmox
ping 10.1.0.100    # Traefik
```

### 4.2 클라이언트 IP 할당 관리

**IP 범위**: 10.0.1.0/24 (256개 주소)

| IP 범위 | 용도 | 예시 |
|---------|------|------|
| 10.0.1.1 | OPNsense (서버) | 게이트웨이 |
| 10.0.1.2-10 | 개인 워크스테이션 | mac-workstation (10.0.1.2) |
| 10.0.1.11-50 | 모바일 기기 | iphone-john, android-jane |
| 10.0.1.51-100 | 서버/CI | jenkins-runner, build-server |
| 10.0.1.101-254 | 예약 | 향후 사용 |

**할당 추적 방법** (스프레드시트 또는 docs/vpn-clients.md):

| IP | 이름 | Public Key (마지막 8자) | 할당일 | 상태 |
|----|------|-------------------------|--------|------|
| 10.0.1.2 | mac-workstation | ...Abc1234= | 2026-02-10 | Active |
| 10.0.1.3 | laptop-john | ...Def5678= | 2026-02-11 | Active |
| 10.0.1.4 | iphone-john | ...Ghi9012= | 2026-02-11 | Inactive |

### 4.3 클라이언트 제거 절차

#### Step 1: OPNsense에서 Peer 비활성화

1. `VPN > WireGuard > Endpoints` → 해당 Peer 편집
2. **Enabled** 체크 해제
3. **Save**

#### Step 2: Local 인스턴스에서 Peer 연결 해제

1. `VPN > WireGuard > Local` → `wg0` 편집
2. **Peers** 필드에서 해당 Peer 선택 해제
3. **Save** → **Apply**

#### Step 3: (선택) Peer 완전 삭제

1. `VPN > WireGuard > Endpoints` → 해당 Peer 삭제
2. IP 할당 관리표에서 상태를 "Inactive" 또는 삭제

#### Step 4: 클라이언트에서 연결 해제

```bash
sudo wg-quick down ~/wireguard/wg0.conf
```

### 4.4 클라이언트 키 로테이션 (분기별 권장)

#### Step 1: 새 키 생성

```bash
wg genkey | tee privatekey-new | wg pubkey > publickey-new
chmod 600 privatekey-new
```

#### Step 2: OPNsense에서 Peer Public Key 업데이트

1. `VPN > WireGuard > Endpoints` → 해당 Peer 편집
2. **Public Key** 필드에 `publickey-new` 내용 붙여넣기
3. **Save** → **Apply**

#### Step 3: 클라이언트 설정 업데이트

```bash
# wg0.conf의 PrivateKey를 새 키로 변경
sed -i.bak "s|^PrivateKey = .*|PrivateKey = $(cat privatekey-new)|" ~/wireguard/wg0.conf

# 재연결
sudo wg-quick down ~/wireguard/wg0.conf
sudo wg-quick up ~/wireguard/wg0.conf
```

#### Step 4: 검증

```bash
sudo wg show
# latest handshake가 갱신되면 성공
```

---

## 5. 모니터링 및 상태 확인

### 5.1 클라이언트에서 상태 확인

#### 기본 상태

```bash
# WireGuard 인터페이스 상태
sudo wg show

# 출력 예시:
# interface: utun3
#   public key: AbCdEfGhIjKlMnOpQrStUvWxYz1234567890=
#   private key: (hidden)
#   listening port: 12345
#
# peer: XyZ9876543210ZyXwVuTsRqPoNmLkJiHgFeDcBa=
#   endpoint: 123.456.789.012:51820
#   allowed ips: 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24
#   latest handshake: 5 seconds ago      # 중요: 2분 이내면 정상
#   transfer: 1.23 MiB received, 456.78 KiB sent
```

**핵심 지표**:
- `latest handshake`: 2분 이내면 정상 (PersistentKeepalive 25초)
- `transfer`: 트래픽이 흐르는지 확인
- `endpoint`: 서버 주소가 올바른지 확인

#### 연결 테스트

```bash
# 1. OPNsense 게이트웨이
ping -c 3 10.0.1.1

# 2. Management 네트워크
ping -c 3 10.0.0.254  # Proxmox
ping -c 3 10.0.0.1    # OPNsense LAN

# 3. Service 네트워크
ping -c 3 10.1.0.100  # Traefik
ping -c 3 10.1.0.110  # PostgreSQL

# 4. 라우팅 경로 추적
traceroute 10.1.0.120  # Grafana
# 1  10.0.1.1 (OPNsense WireGuard)
# 2  10.1.0.120 (Grafana)
```

#### 트래픽 모니터링

```bash
# 실시간 통계 (1초마다 갱신)
watch -n 1 "sudo wg show | grep -A 5 peer"

# 전송량 누적 확인
sudo wg show all dump
```

### 5.2 OPNsense 서버에서 상태 확인

#### SSH 접속 (VPN 연결 필요)

```bash
# VPN 연결 후
ssh root@10.0.0.1
```

#### WireGuard 상태

```bash
# 전체 상태
wg show

# 특정 인터페이스
wg show wg0

# Peer별 통계
wg show wg0 dump

# 출력 예시:
# interface: wg0
#   public key: XyZ9876543210ZyXwVuTsRqPoNmLkJiHgFeDcBa=
#   private key: (hidden)
#   listening port: 51820
#
# peer: AbCdEfGhIjKlMnOpQrStUvWxYz1234567890=    # mac-workstation
#   endpoint: 123.456.789.012:54321
#   allowed ips: 10.0.1.2/32
#   latest handshake: 10 seconds ago
#   transfer: 456.78 KiB received, 1.23 MiB sent
#
# peer: PqRsTuVwXyZ0123456789AbCdEfGhIjKlMnOp=    # laptop-john
#   endpoint: 234.567.890.123:43210
#   allowed ips: 10.0.1.3/32
#   latest handshake: 1 minute ago
#   transfer: 100.50 KiB received, 200.75 KiB sent
```

#### 인터페이스 상태

```bash
# wg0 인터페이스 정보
ifconfig wg0

# 출력:
# wg0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> metric 0 mtu 1420
#     options=80000<LINKSTATE>
#     inet 10.0.1.1 netmask 0xffffff00
#     groups: wg
#     nd6 options=29<PERFORMNUD,IFDISABLED,AUTO_LINKLOCAL>
```

#### 라우팅 테이블

```bash
# WireGuard 관련 라우트
netstat -rn | grep -E "10\.0\.1|wg0"

# 출력 예시:
# 10.0.1.0/24        link#10            UGS         wg0
# 10.0.1.2           link#10            UH          wg0
# 10.0.1.3           link#10            UH          wg0
```

### 5.3 로그 확인

#### OPNsense 시스템 로그

```bash
# Web UI에서:
# System → Log Files → General
# 필터: "wireguard"

# 콘솔에서:
grep -i wireguard /var/log/system.log | tail -20

# 예시 로그:
# Feb 10 15:30:45 opnsense /usr/local/sbin/wireguard: Starting WireGuard interface wg0
# Feb 10 15:30:46 opnsense kernel: wg0: link state changed to UP
```

#### WireGuard 서비스 로그

```bash
# 서비스 상태
service wireguard status

# 최근 로그
tail -f /var/log/wireguard.log  # (존재하는 경우)
```

#### 방화벽 로그 (연결 실패 시)

```bash
# Web UI에서:
# Firewall → Log Files → Live View
# 필터: Source IP = 10.0.1.X

# 콘솔에서:
tcpdump -i wg0 -n
# 실시간 패킷 확인
```

### 5.4 성능 측정

#### 대역폭 테스트

```bash
# iperf3 서버 (Proxmox 또는 컨테이너에서)
iperf3 -s

# iperf3 클라이언트 (VPN 연결 후 Mac에서)
iperf3 -c 10.0.0.254 -t 30

# 예상 결과:
# [ ID] Interval           Transfer     Bitrate
# [  5]   0.00-30.00  sec  1.5 GBytes   430 Mbits/sec  sender
# [  5]   0.00-30.00  sec  1.5 GBytes   428 Mbits/sec  receiver
```

#### 레이턴시 테스트

```bash
# ICMP ping
ping -c 100 10.0.0.254 | tail -5

# 예상 결과:
# rtt min/avg/max/mdev = 1.234/2.345/5.678/0.789 ms

# TCP ping (nc 사용)
for i in {1..10}; do
  time nc -zv 10.1.0.100 80 2>&1 | grep succeeded
done
```

### 5.5 자동 모니터링 설정 (선택)

#### Grafana + Prometheus 연동

1. Prometheus에서 WireGuard Exporter 설정
2. Grafana 대시보드 import (Dashboard ID: 15857)
3. 메트릭:
   - Peer 연결 상태
   - 전송 속도 (bps)
   - 핸드셰이크 간격
   - 패킷 손실률

#### 간단한 상태 확인 스크립트

```bash
#!/bin/bash
# ~/check-vpn.sh

GATEWAY="10.0.1.1"
PROXMOX="10.0.0.254"

if ping -c 1 -W 1 $GATEWAY &>/dev/null; then
    echo "✓ VPN connected"
    if ping -c 1 -W 1 $PROXMOX &>/dev/null; then
        echo "✓ Management network OK"
    else
        echo "✗ Management network unreachable"
    fi
else
    echo "✗ VPN disconnected"
fi
```

---

## 6. 트러블슈팅 레퍼런스

### 6.1 빠른 진단 체크리스트

VPN 연결 문제 발생 시 순차 확인:

```
□ 1. WireGuard 서비스 실행 중?
   Mac: sudo wg show (인터페이스 표시 확인)
   OPNsense: wg show wg0

□ 2. Peer가 OPNsense에 등록됨?
   Web UI: VPN → WireGuard → Endpoints

□ 3. Peer가 Local 인스턴스에 연결됨?
   Web UI: VPN → WireGuard → Local → wg0 → Peers 필드

□ 4. 핸드셰이크 최근? (< 2분)
   sudo wg show | grep "latest handshake"

□ 5. WireGuard 인터페이스 활성화?
   OPNsense Web UI: Interfaces → Assignments → wg0 → Enable 체크

□ 6. 방화벽 규칙 있음? (WireGuard Group)
   Firewall → Rules → WireGuard (Group) → Pass 규칙 확인

□ 7. NAT Router 포트포워딩 설정?
   UDP 51820 → <OPNSENSE_WAN_IP>

□ 8. Proxmox 라우팅 경로 있음?
   ssh <PROXMOX_USER>@<PROXMOX_HOST> "ip route | grep 10.0.1"

□ 9. NAT 설정 확인?
   Firewall → NAT → Outbound → Mode: Automatic
```

### 6.2 증상별 해결 가이드

#### 증상 1: 핸드셰이크 실패 (latest handshake 없음)

**진단**:
```bash
# 포트 도달 테스트
nc -vzu <공인IP> 51820

# Mac에서 WireGuard 로그
sudo wg-quick down ~/wireguard/wg0.conf
sudo wg-quick up ~/wireguard/wg0.conf
# 오류 메시지 확인
```

**원인 1: NAT Router 포트포워딩 미설정**
- 해결: NAT Router 관리페이지 → 포트포워드 설정 → UDP 51820 추가

**원인 2: OPNsense WAN 방화벽 차단**
```bash
# OPNsense 콘솔에서
pfctl -sr | grep 51820

# 규칙이 없으면 추가:
# Firewall → Rules → WAN → Pass UDP 51820
```

**원인 3: Peer 미등록**
- 해결: VPN → WireGuard → Endpoints 확인 → Local에 연결 (문제 #5 참조)

**원인 4: 키 불일치**
```bash
# Mac 공개키
cat ~/wireguard/publickey

# OPNsense Peer 설정과 비교
# 정확히 일치하는지 확인 (공백, 줄바꿈 주의)
```

---

#### 증상 2: 핸드셰이크 OK, ping 타임아웃 (OPNsense 10.0.1.1)

**진단**:
```bash
sudo wg show
# latest handshake: 5 seconds ago  # 정상

ping 10.0.1.1  # 타임아웃

traceroute 10.0.1.1
# 패킷 전송은 되지만 응답 없음
```

**원인 1: WireGuard 방화벽 규칙 없음**
- 해결: Firewall → Rules → WireGuard (Group) → Pass any 추가 (문제 #6 참조)

**원인 2: 인터페이스 미할당 또는 비활성화**
- 해결: Interfaces → Assignments → wg0 할당 → Enable 체크 (문제 #4 참조)

---

#### 증상 3: OPNsense ping OK, 내부 네트워크 ping 실패 (Proxmox, 컨테이너)

**진단**:
```bash
ping 10.0.1.1   # 성공
ping 10.0.0.254 # 타임아웃
ping 10.1.0.100 # 타임아웃

traceroute 10.0.0.254
# 1  10.0.1.1  # OPNsense
# 2  * * *     # Proxmox 응답 없음
```

**원인: Proxmox 라우팅 경로 없음**
- 해결: Proxmox에 정적 라우트 추가 (문제 #7 참조)

```bash
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ip route add 10.0.1.0/24 via 10.0.0.1"

# 영구 설정
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo bash -c 'echo \"post-up ip route add 10.0.1.0/24 via 10.0.0.1 || true\" >> /etc/network/interfaces'"
```

---

#### 증상 4: 특정 네트워크만 접근 불가

**진단**:
```bash
ping 10.0.0.254 # 성공 (Management)
ping 10.1.0.100 # 타임아웃 (Service)

traceroute 10.1.0.100
# 1  10.0.1.1
# 2  * * *
```

**원인 1: AllowedIPs 누락**
- 해결: `~/wireguard/wg0.conf` 확인
```ini
[Peer]
AllowedIPs = 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24  # 10.1.0.0/24 있는지 확인
```

**원인 2: 방화벽 규칙 범위 제한**
- 해결: Firewall → Rules → WireGuard (Group) 확인
  - Destination: "OPT1 net (10.1.0.0/24)" 규칙 있는지 확인

---

#### 증상 5: 연결 후 인터넷 불가 (Full Tunnel 오류)

**증상**: VPN 연결 후 모든 인터넷 트래픽이 실패.

**원인**: `AllowedIPs = 0.0.0.0/0`로 설정하여 Full Tunnel이 됨.

**해결**:
```ini
# wg0.conf 수정
[Peer]
AllowedIPs = 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24  # 0.0.0.0/0 제거
```

**검증**:
```bash
# VPN 연결 후
curl ifconfig.me  # 공인 IP 출력되면 정상 (Split Tunnel)
```

---

#### 증상 6: 재부팅 후 VPN 연결 실패

**원인 1: Proxmox 라우트 손실**
- 해결: `/etc/network/interfaces`에 `post-up` 스크립트 추가 (문제 #8 참조)

**원인 2: OPNsense WireGuard 서비스 미시작**
```bash
# OPNsense 콘솔에서
service wireguard status

# 시작 안 되어 있으면
service wireguard start

# 부팅 시 자동 시작 확인
sysrc wireguard_enable=YES
```

---

#### 증상 7: LAN에서만 VPN 연결 불가 (NAT hairpin)

**증상**: 외부에서는 VPN 정상, 동일 LAN(<EXTERNAL_SUBNET>)에서는 실패.

**원인**: NAT Router NAT hairpin 미지원 (문제 #9 참조).

**해결**: LAN 전용 설정 파일 사용
```bash
# ~/wireguard/wg0-lan.conf
[Peer]
Endpoint = <OPNSENSE_WAN_IP>:51820  # LAN IP 직접
```

---

#### 증상 8: MTU 문제 (큰 패킷 전송 실패)

**증상**: ping 성공, SSH 성공, 하지만 HTTP 다운로드 중 멈춤.

**진단**:
```bash
# MTU 테스트 (1392 = 1420 - 28 IP/ICMP 헤더)
ping -s 1392 -D 10.0.0.254

# 실패하면 MTU가 너무 높음
```

**해결**:
```ini
# wg0.conf
[Interface]
MTU = 1400  # 1420에서 낮춤
```

**OPNsense MSS Clamping 조정**:
- Firewall → Settings → Normalization → WireGuard 규칙
- Max MSS: 1360 (1400 - 40 TCP/IP 헤더)

---

### 6.3 OPNsense 설정 검증 스크립트

로컬에서 실행하여 OPNsense WireGuard 설정을 자동 검증:

```bash
#!/bin/bash
# wg-verify.sh - WireGuard 설정 자동 검증

OPNSENSE_IP="10.0.0.1"

echo "=== WireGuard 설정 검증 (OPNsense) ==="

ssh root@${OPNSENSE_IP} << 'EOF'
echo ""
echo "1. WireGuard 인터페이스 상태"
echo "-----------------------------"
ifconfig wg0 | grep -E "inet|UP|flags" || echo "✗ wg0 인터페이스 없음"

echo ""
echo "2. WireGuard 서비스 상태"
echo "------------------------"
wg show wg0 | head -5 || echo "✗ WireGuard 서비스 실행 안 됨"

echo ""
echo "3. Peer 등록 확인"
echo "-----------------"
PEERS=$(wg show wg0 peers | wc -l)
echo "등록된 Peer 수: $PEERS"
wg show wg0 peers

echo ""
echo "4. 라우팅 테이블"
echo "----------------"
netstat -rn | grep -E "10\.0\.1|10\.1\.0" || echo "✗ 라우트 없음"

echo ""
echo "5. 방화벽 규칙 (WireGuard)"
echo "-------------------------"
pfctl -sr | grep -i wg | head -5 || echo "✗ WireGuard 방화벽 규칙 없음"

echo ""
echo "6. 포트 리스닝"
echo "-------------"
sockstat -l | grep 51820 || echo "✗ UDP 51820 리스닝 없음"

echo ""
echo "=== 검증 완료 ==="
EOF
```

**사용**:
```bash
chmod +x wg-verify.sh
./wg-verify.sh
```

---

### 6.4 클라이언트 설정 검증 스크립트

Mac에서 실행하여 클라이언트 설정 자동 검증:

```bash
#!/bin/bash
# wg-client-verify.sh - 클라이언트 설정 검증

CONF_FILE="${1:-$HOME/wireguard/wg0.conf}"

echo "=== WireGuard 클라이언트 검증 ==="
echo "설정 파일: $CONF_FILE"
echo ""

# 1. 설정 파일 존재 확인
if [ ! -f "$CONF_FILE" ]; then
    echo "✗ 설정 파일 없음: $CONF_FILE"
    exit 1
fi
echo "✓ 설정 파일 존재"

# 2. PrivateKey 확인
if grep -q "^PrivateKey" "$CONF_FILE"; then
    echo "✓ PrivateKey 설정됨"
else
    echo "✗ PrivateKey 없음"
fi

# 3. Address 확인
ADDRESS=$(grep "^Address" "$CONF_FILE" | awk '{print $3}')
if [ -n "$ADDRESS" ]; then
    echo "✓ Address: $ADDRESS"
else
    echo "✗ Address 없음"
fi

# 4. Peer PublicKey 확인
if grep -q "^PublicKey" "$CONF_FILE"; then
    echo "✓ Peer PublicKey 설정됨"
else
    echo "✗ Peer PublicKey 없음"
fi

# 5. Endpoint 확인
ENDPOINT=$(grep "^Endpoint" "$CONF_FILE" | awk '{print $3}')
if [ -n "$ENDPOINT" ]; then
    echo "✓ Endpoint: $ENDPOINT"

    # 포트 도달 테스트
    HOST=$(echo $ENDPOINT | cut -d: -f1)
    PORT=$(echo $ENDPOINT | cut -d: -f2)
    if nc -vzu "$HOST" "$PORT" 2>&1 | grep -q succeeded; then
        echo "  ✓ 포트 도달 가능"
    else
        echo "  ✗ 포트 도달 불가 (방화벽 또는 포트포워딩 확인)"
    fi
else
    echo "✗ Endpoint 없음"
fi

# 6. AllowedIPs 확인
ALLOWED=$(grep "^AllowedIPs" "$CONF_FILE" | cut -d= -f2 | tr -d ' ')
if [ -n "$ALLOWED" ]; then
    echo "✓ AllowedIPs: $ALLOWED"

    # Split Tunnel 확인
    if echo "$ALLOWED" | grep -q "0.0.0.0/0"; then
        echo "  ⚠ Full Tunnel (모든 트래픽 VPN 경유)"
    else
        echo "  ✓ Split Tunnel"
    fi
else
    echo "✗ AllowedIPs 없음"
fi

# 7. 현재 연결 상태
echo ""
echo "현재 연결 상태:"
if sudo wg show 2>/dev/null | grep -q interface; then
    echo "✓ VPN 연결됨"
    sudo wg show | grep -E "interface|peer|latest handshake"
else
    echo "✗ VPN 연결 안 됨"
fi

echo ""
echo "=== 검증 완료 ==="
```

**사용**:
```bash
chmod +x wg-client-verify.sh
./wg-client-verify.sh ~/wireguard/wg0.conf
```

---

## 7. 보안 권장사항

### 7.1 키 관리

**DO**:
- ✓ Peer별 고유 키페어 사용
- ✓ 개인키는 600 권한 (`chmod 600 privatekey`)
- ✓ 개인키는 절대 공유하지 않음
- ✓ 분기별 키 로테이션 (4.4 절차 참고)
- ✓ 퇴사/기기 분실 시 즉시 Peer 비활성화

**DON'T**:
- ✗ 여러 기기에서 동일 키 재사용
- ✗ 개인키를 클라우드 스토리지에 백업 (평문)
- ✗ 공개키와 개인키 혼동

### 7.2 Allowed IPs (최소 권한 원칙)

**Split Tunnel 유지**:
```ini
# 권장: 내부 네트워크만
AllowedIPs = 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24

# 비권장: Full Tunnel (필요한 경우만)
AllowedIPs = 0.0.0.0/0, ::/0
```

**이유**:
- Full Tunnel: 모든 트래픽이 VPN 경유 → 성능 저하, 로그 집중
- Split Tunnel: 내부 접근만 VPN → 성능 최적화, 로그 최소화

### 7.3 방화벽 규칙 최소화

**현재 규칙** (적절함):
```
WireGuard (Group) → LAN net (10.0.0.0/24): Pass
WireGuard (Group) → OPT1 net (10.1.0.0/24): Pass
WireGuard (Group) → WireGuard net: Pass
```

**향후 세분화 가능**:
```
# 특정 Peer만 특정 네트워크 접근
Source: Peer Alias (admin-workstation) → LAN net: Pass
Source: Peer Alias (dev-laptop) → OPT1 net: Pass (Service만)
```

### 7.4 PersistentKeepalive 설정

**권장**: 25초
```ini
PersistentKeepalive = 25
```

**이유**:
- NAT 테이블 타임아웃 방지 (대부분 공유기 60-120초)
- 너무 짧으면 (< 10초): 트래픽 낭비
- 너무 길면 (> 60초): NAT 테이블 만료로 연결 끊김

### 7.5 로그 모니터링

**OPNsense 로그 정기 확인**:
```bash
# 비정상 접속 시도 탐지
grep -i "wireguard" /var/log/system.log | grep -i "fail\|error\|deny"

# 알 수 없는 Peer 핸드셰이크 시도
wg show wg0 | grep "peer:" | while read peer; do
    # 등록된 Peer 목록과 비교
done
```

**Grafana 대시보드 알림 설정**:
- Peer 연결 상태 변화 (Connected → Disconnected)
- 비정상 트래픽 급증 (> 1 Gbps)
- 핸드셰이크 실패 반복

### 7.6 네트워크 분리 (향후 고려)

현재: 모든 VPN 클라이언트가 Management + Service 네트워크 모두 접근 가능.

**향후 개선**:
1. VPN Peer를 역할별로 분리
   - `wg-admin`: Management 네트워크만 (10.0.0.0/24)
   - `wg-dev`: Service 네트워크만 (10.1.0.0/24)
2. 각 역할별 방화벽 규칙 적용
3. OPNsense Aliases로 Peer 그룹 관리

### 7.7 2FA (Two-Factor Authentication)

WireGuard 자체는 2FA를 지원하지 않지만, 추가 보안 계층 가능:

**옵션 1: 포트 Knocking**
- VPN 연결 전 특정 포트 시퀀스 knock
- 성공 시에만 UDP 51820 개방 (일시적)

**옵션 2: 클라이언트 인증서 (TLS)**
- WireGuard와 별도로 VPN 게이트웨이에 TLS 인증 추가
- 인증 성공 후 WireGuard 키 교환

### 7.8 정기 보안 점검 체크리스트

**월별**:
- [ ] 비활성 Peer 제거 (3개월 미사용)
- [ ] 로그에서 비정상 접속 시도 확인
- [ ] OPNsense 펌웨어 업데이트 확인

**분기별**:
- [ ] Peer 키 로테이션 (활성 Peer)
- [ ] Let's Encrypt 인증서 갱신 (OPNsense 도메인)
- [ ] 방화벽 규칙 검토 (불필요한 Pass 규칙 제거)

**반기별**:
- [ ] 전체 VPN 설정 백업 (`/etc/wireguard/` 또는 OPNsense 백업)
- [ ] 재해 복구 절차 테스트
- [ ] 보안 감사 (침투 테스트, 로그 분석)

---

## 8. SSH 연결 및 API 사용 패턴

### 8.1 프로젝트에서 사용하는 SSH 연결 구조

#### 기본 SSH 패턴

**네트워크 계층**:
```
Mac (로컬)
  │
  ├─ 외부 접속 (VPN 미연결)
  │  └─ ssh <PROXMOX_USER>@<PROXMOX_EXTERNAL_IP> (Proxmox External IP)
  │
  └─ VPN 접속 (권장)
     ├─ sudo wg-quick up ~/wireguard/wg0.conf
     └─ ssh <PROXMOX_USER>@<PROXMOX_HOST> (Proxmox Management IP)
```

**2026-02-10 변경사항**:
- 기존: External IP (External 네트워크) 직접 접속
- 변경 후: **VPN 연결 필수**, 10.0.0.254 (Management 네트워크) 접속
- 이유: 보안 강화, VPN을 기본 접근 방법으로 전환

---

#### 패턴 1: Proxmox 접속 (VPN 필수)

```bash
# 1. VPN 연결 (사전 요구사항)
sudo wg-quick up ~/wireguard/wg0.conf

# 2. Proxmox 호스트 접속 (Management 네트워크)
ssh <PROXMOX_USER>@<PROXMOX_HOST>

# 3. 단일 명령 실행
ssh <PROXMOX_USER>@<PROXMOX_HOST> "command"

# 예시: Proxmox 상태 확인
ssh <PROXMOX_USER>@<PROXMOX_HOST> "pveversion"
ssh <PROXMOX_USER>@<PROXMOX_HOST> "pct list"
```

**예외: VPN 문제 해결 시**
```bash
# VPN 연결 불가 시 외부 IP 사용 (긴급 복구용)
ssh <PROXMOX_USER>@<PROXMOX_EXTERNAL_IP>
```

---

#### 패턴 2: OPNsense 접속 (VPN 필요)

**방법 1: VPN 연결 후 직접 접속 (1-hop, 권장)**
```bash
# VPN 연결 후
ssh root@10.0.0.1

# 단일 명령 실행
ssh root@10.0.0.1 "wg show"
ssh root@10.0.0.1 "pfctl -sr | grep -i wg"
```

**방법 2: Proxmox 경유 (2-hop)**
```bash
# VPN 미연결 또는 SSH 키 미설정 시
ssh <PROXMOX_USER>@<PROXMOX_HOST>
sudo ssh root@10.0.0.1

# 단일 명령 실행 (체이닝)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'command'"

# 예시: WireGuard 상태 확인
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'wg show wg0'"
```

**OPNsense 콘솔 접속 (네트워크 차단 시 최후 수단)**
```
1. Proxmox Web UI (https://pve.codingmon.dev) 접속
2. 좌측 메뉴: VM 102 (opnsense) 선택
3. Console 탭 클릭
4. 옵션 8 (Shell) 입력
```

---

#### 패턴 3: LXC 컨테이너 접속 (pct exec, VPN + Proxmox 경유)

**기본 패턴**: Proxmox → pct exec
```bash
# VPN 연결 필수
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec <CT_ID> -- command"

# 예시: Traefik 로그 확인 (CT 200)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec 200 -- tail -20 /var/log/traefik.log"

# 예시: PostgreSQL 상태 확인 (CT 210)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec 210 -- rc-service postgresql status"

# 예시: Valkey CLI (CT 211)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec 211 -- valkey-cli ping"
```

**대화형 셸**:
```bash
ssh <PROXMOX_USER>@<PROXMOX_HOST>
sudo pct enter 200  # Traefik 컨테이너 진입
```

---

#### 패턴 4: VPN 연결 후 서비스 직접 접근

**HTTP/HTTPS 서비스**:
```bash
# Traefik 직접 (HTTP)
curl http://10.1.0.100/ping

# Grafana 직접 (HTTP)
curl http://10.1.0.120:3000

# PostgreSQL 직접 (TCP)
psql -h 10.1.0.110 -U chaekpool -d chaekpool

# Valkey 직접 (TCP)
valkey-cli -h 10.1.0.111 -a changeme PING
```

**장점**:
- SSH 체이닝 불필요
- 네이티브 클라이언트 도구 사용 가능
- 개발 환경과 동일한 접근 방식

---

### 8.2 프로젝트에서 사용하는 API

#### OPNsense HAProxy API

**접속 패턴**: Proxmox SSH → OPNsense SSH → localhost API

```bash
# 기본 패턴 (2-hop)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'curl -sk -u KEY:SECRET https://localhost/api/...'"

# 예시: HAProxy 재설정
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'curl -sk -X POST -u KEY:SECRET https://localhost/api/haproxy/service/reconfigure'"

# 예시: HAProxy 상태 확인
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'curl -sk -u KEY:SECRET https://localhost/api/haproxy/service/status'"
```

**VPN 연결 후 (1-hop, 권장)**:
```bash
ssh root@10.0.0.1 "curl -sk -u KEY:SECRET https://localhost/api/haproxy/service/status"
```

**주요 엔드포인트**:
```bash
# 방화벽 규칙 조회
curl -sk -u KEY:SECRET https://localhost/api/firewall/filter/searchRule

# 방화벽 재로드
curl -sk -X POST -u KEY:SECRET https://localhost/api/firewall/filter/apply

# ACME 인증서 조회
curl -sk -u KEY:SECRET https://localhost/api/acme/certificates/get

# ACME 인증서 갱신
curl -sk -X POST -u KEY:SECRET https://localhost/api/acme/certificates/renew/UUID
```

---

#### Proxmox VE API

**API 토큰 방식** (OpenTofu, Ansible 등에서 사용):

```bash
# 기본 인증 헤더
Authorization: PVEAPIToken=admin@pam!TOKEN_NAME=UUID

# 예시: 컨테이너 목록 조회 (VPN 연결 후)
curl -k -H "Authorization: PVEAPIToken=<API_TOKEN_ID>=<API_TOKEN_VALUE>..." \
  https://10.0.0.254:8006/api2/json/nodes/pve/lxc

# 예시: 노드 상태 확인
curl -k -H "Authorization: PVEAPIToken=..." \
  https://10.0.0.254:8006/api2/json/nodes/pve/status
```

**외부에서 접속 시** (VPN 미연결, 긴급 복구용):
```bash
curl -k -H "Authorization: PVEAPIToken=..." \
  https://<PROXMOX_EXTERNAL_IP>:8006/api2/json/nodes/pve/status
```

---

### 8.3 배포 스크립트에서 사용하는 SSH 헬퍼 함수

**위치**: `service/chaekpool/scripts/common.sh`

**2026-02-10 변경사항**:
```bash
# Before
PROXMOX_HOST="<PROXMOX_HOST>"

# After (VPN 필수)
PROXMOX_HOST="<PROXMOX_HOST>"
```

**3가지 핵심 함수**:

```bash
# 1. pct_exec: 컨테이너 내 명령 실행
pct_exec() {
    local ct_id="$1"; shift
    ssh admin@${PROXMOX_HOST} "sudo pct exec ${ct_id} -- sh -c '$*'"
}

# 사용 예시
pct_exec 200 "rc-service traefik status"
pct_exec 210 "psql -U postgres -c 'SELECT version()'"

# 2. pct_push: 파일 전송 (Mac → Proxmox /tmp → 컨테이너)
pct_push() {
    local ct_id="$1"
    local local_path="$2"
    local remote_path="$3"
    local tmp="/tmp/$(basename "${local_path}")"
    ssh admin@${PROXMOX_HOST} "sudo rm -f ${tmp}"
    ssh admin@${PROXMOX_HOST} "cat > ${tmp}" < "${local_path}"
    ssh admin@${PROXMOX_HOST} "sudo pct push ${ct_id} ${tmp} ${remote_path} && rm -f ${tmp}"
}

# 사용 예시
pct_push 200 ./configs/traefik.yml /etc/traefik/traefik.yml
pct_push 210 ./configs/pg_hba.conf /etc/postgresql/18/main/pg_hba.conf

# 3. pct_script: Heredoc 스크립트 실행 (stdin으로 전달)
pct_script() {
    local ct_id="$1"
    ssh admin@${PROXMOX_HOST} "sudo pct exec ${ct_id} -- sh -s"
}

# 사용 예시
pct_script 200 <<'SCRIPT'
set -e
apk update
apk add traefik
rc-update add traefik
SCRIPT
```

**배포 스크립트 실행 시 VPN 필수**:
```bash
# 1. VPN 연결 확인
ping -c 1 10.0.0.254 || (echo "VPN 연결 필요" && exit 1)

# 2. 배포 실행
bash service/chaekpool/scripts/traefik/deploy.sh
```

---

### 8.4 API 키 및 인증 정보 관리

#### Proxmox API 토큰

**생성 위치**: Proxmox Web UI → `Datacenter > Permissions > API Tokens`

**형식**:
```
TOKEN_ID: <API_TOKEN_ID>
UUID: abc123-def456-ghi789-jkl012
```

**사용처**:
- OpenTofu (`core/terraform/terraform.tfvars`)
- Ansible Playbooks
- 모니터링 도구 (Prometheus Proxmox Exporter)

**보안**:
- `terraform.tfvars`는 `.gitignore`에 포함
- 토큰은 로컬에만 저장 (클라우드 백업 금지)

---

#### OPNsense API 키

**생성 위치**: OPNsense Web UI → `System > Access > Users > root > API keys`

**형식**:
```
KEY: AbCdEfGh1234567890
SECRET: IjKlMnOpQrStUvWxYz0987654321
```

**사용처**:
- HAProxy 자동화 스크립트
- ACME 인증서 갱신 스크립트
- 방화벽 규칙 관리

**보안**:
- API 키는 코드에 하드코딩 금지
- 환경 변수 또는 로컬 파일로 관리
```bash
# ~/.opnsense-api
export OPNSENSE_KEY="AbCdEfGh1234567890"
export OPNSENSE_SECRET="IjKlMnOpQrStUvWxYz0987654321"

# 사용
source ~/.opnsense-api
curl -u $OPNSENSE_KEY:$OPNSENSE_SECRET ...
```

---

#### SSH 키 관리

**Mac → Proxmox**:
```bash
# 공개키 등록 (초기 1회)
ssh-copy-id <PROXMOX_USER>@<PROXMOX_EXTERNAL_IP>

# 이후 비밀번호 없이 접속
ssh <PROXMOX_USER>@<PROXMOX_HOST>  # (VPN 연결 후)
```

**Proxmox → OPNsense**:
- 현재: 비밀번호 방식 (`sudo ssh root@10.0.0.1`)
- 향후 개선: SSH 키 등록으로 자동화 강화

**WireGuard 키**:
- 위치: `~/wireguard/privatekey` (600 권한)
- 백업: 로컬 암호화 백업만 (예: KeePass, 1Password)
- 공유 금지

---

## 9. FAQ

### Q1: WireGuard를 완전히 재시작하려면?

**OPNsense에서**:
```bash
ssh root@10.0.0.1 '/usr/local/sbin/pluginctl -s wireguard restart'

# 또는
service wireguard restart
```

**Mac에서**:
```bash
sudo wg-quick down ~/wireguard/wg0.conf
sudo wg-quick up ~/wireguard/wg0.conf
```

---

### Q2: 클라이언트가 여러 개일 때 IP 관리는?

**방법 1: 스프레드시트**
- Google Sheets, Excel 등
- 컬럼: IP, 이름, Public Key, 할당일, 상태

**방법 2: 문서 파일** (`docs/vpn-clients.md`)
```markdown
| IP | 이름 | Public Key (마지막 8자) | 할당일 | 상태 |
|----|------|-------------------------|--------|------|
| 10.0.1.2 | mac-workstation | ...Abc123= | 2026-02-10 | Active |
| 10.0.1.3 | laptop-john | ...Def456= | 2026-02-11 | Active |
```

**방법 3: Git 레포지토리**
- `vpn-clients.yml` 파일로 관리
- Git으로 버전 관리 (변경 이력 추적)

---

### Q3: Split Tunnel vs Full Tunnel 차이는?

**Split Tunnel** (권장):
```ini
AllowedIPs = 10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24
```
- 내부 네트워크만 VPN 경유
- 인터넷 트래픽은 일반 게이트웨이 사용
- 성능 최적화, 로그 최소화

**Full Tunnel**:
```ini
AllowedIPs = 0.0.0.0/0, ::/0
```
- 모든 트래픽이 VPN 경유
- VPN 서버가 인터넷 게이트웨이 역할
- 성능 저하, 대역폭 소모

**검증**:
```bash
# Split Tunnel: 공인 IP 출력
curl ifconfig.me

# Full Tunnel: OPNsense WAN IP 출력
curl ifconfig.me
```

---

### Q4: VPN 없이 OPNsense API를 호출하려면?

**방법 1: Proxmox SSH 경유 (2-hop)**
```bash
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'curl -sk -u KEY:SECRET https://localhost/api/...'"
```

**방법 2: VPN 연결 후 직접 (1-hop, 권장)**
```bash
ssh root@10.0.0.1 "curl -sk -u KEY:SECRET https://localhost/api/..."
```

**방법 3: 외부에서 OPNsense Web UI 노출 (비권장)**
- OPNsense 도메인 (`opnsense.codingmon.dev`)이 이미 HAProxy로 노출
- API도 동일 URL로 접근 가능하지만 보안 리스크 높음

---

### Q5: pct_exec과 pct exec의 차이는?

**`pct_exec`**: `common.sh`의 헬퍼 함수
```bash
# 정의
pct_exec() {
    ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec ${ct_id} -- sh -c '$*'"
}

# 사용
pct_exec 200 "rc-service traefik status"
```

**`pct exec`**: Proxmox 명령어
```bash
# Proxmox 호스트에서 직접 실행
pct exec 200 -- rc-service traefik status

# 원격에서 실행 (SSH 경유)
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec 200 -- rc-service traefik status"
```

**관계**: `pct_exec` 함수가 내부적으로 `pct exec`를 호출.

---

### Q6: VPN 연결 후 외부 도메인 접근이 안 되는 경우?

**증상**: `curl google.com` 타임아웃

**원인 1: Full Tunnel 오류**
- `AllowedIPs = 0.0.0.0/0`로 설정되어 DNS가 VPN 경유
- 해결: Split Tunnel로 변경 (FAQ #3 참조)

**원인 2: DNS 설정 문제**
```bash
# DNS 확인
cat /etc/resolv.conf

# DNS 테스트
nslookup google.com
```

**해결**: wg0.conf에 DNS 미설정 (시스템 DNS 사용)
```ini
[Interface]
# DNS = 1.1.1.1  # 추가하지 말 것 (Split Tunnel에서 불필요)
```

---

### Q7: 컨테이너를 재생성하면 VPN 접근이 안 되는 경우?

**증상**: 기존에는 접근 가능했던 10.1.0.100이 갑자기 불통.

**원인**: 컨테이너 재생성 시 IP가 변경되었거나, 방화벽 규칙이 초기화됨.

**진단**:
```bash
# 컨테이너 IP 확인
ssh <PROXMOX_USER>@<PROXMOX_HOST> "pct config 200 | grep net0"

# Proxmox 라우팅 확인
ssh <PROXMOX_USER>@<PROXMOX_HOST> "ip route | grep 10.0.1"
```

**해결**:
- Proxmox 라우팅 재추가 (문제 #7 참조)
- 컨테이너 방화벽 확인 (iptables)

---

### Q8: Mac에서 여러 WireGuard 터널을 동시에 사용할 수 있나?

**답변**: 가능하지만 라우팅 충돌 주의.

**예시**: 회사 VPN + 홈랩 VPN
```bash
# 회사 VPN (10.20.0.0/16)
sudo wg-quick up ~/wireguard/work-vpn.conf

# 홈랩 VPN (10.0.0.0/24, 10.0.1.0/24, 10.1.0.0/24)
sudo wg-quick up ~/wireguard/homelab-vpn.conf
```

**조건**:
- AllowedIPs가 겹치지 않아야 함
- 인터페이스 이름이 달라야 함 (utun3, utun4 등 자동 할당)

**확인**:
```bash
sudo wg show  # 두 터널 모두 표시
netstat -rn | grep utun  # 라우팅 테이블 확인
```

---

### Q9: VPN 연결 상태를 Mac 메뉴바에 표시하려면?

**도구**: Tunnelblick, WireGuard GUI App

**WireGuard 공식 앱**:
- https://apps.apple.com/app/wireguard/id1451685025
- wg0.conf import → 메뉴바 아이콘으로 연결/해제

**스크립트 + BitBar** (고급):
- BitBar 플러그인으로 VPN 상태 표시
- 클릭으로 연결/해제 자동화

---

### Q10: Proxmox가 재부팅될 때 VPN 통신이 일시적으로 끊기는 이유?

**원인**: Proxmox 재부팅 중 컨테이너가 모두 종료되어 Service 네트워크(10.1.0.0/24)가 비활성화됨. OPNsense는 정상이지만, Proxmox가 부팅 완료될 때까지 응답 불가.

**타임라인**:
```
1. Proxmox 재부팅 시작
2. 컨테이너 종료 (10.1.0.0/24 비활성화)
3. vmbr1/vmbr2 네트워크 다운
4. OPNsense는 정상 (10.0.1.1 ping 가능)
5. Proxmox 부팅 완료 (1-2분)
6. 네트워크 복구 (10.0.0.254, 10.1.0.0/24 접근 가능)
```

**대응**:
- 정상 동작 (Proxmox 부팅 대기)
- 급한 경우: OPNsense 직접 접속 (ssh root@10.0.0.1)

---

## 10. 참고 자료

### 10.1 공식 문서

- **WireGuard**: https://www.wireguard.com/
- **OPNsense WireGuard**: https://docs.opnsense.org/manual/vpnet.html#wireguard
- **OPNsense Firewall**: https://docs.opnsense.org/manual/firewall.html

### 10.2 프로젝트 내 관련 문서

- **VPN 초기 설정 가이드**: `docs/vpn-setup.md`
- **네트워크 아키텍처**: `docs/network-architecture.md`
- **OPNsense HAProxy 운영 가이드**: `docs/opnsense-haproxy-operations-guide.md`
- **Proxmox 배포 가이드**: `docs/infra-deployment.md`

### 10.3 커뮤니티 자료

- **WireGuard Subreddit**: https://www.reddit.com/r/WireGuard/
- **OPNsense Forum**: https://forum.opnsense.org/
- **Proxmox Forum**: https://forum.proxmox.com/

---

**이 문서는 2026-02-10 배포 과정에서 발생한 모든 문제와 해결 과정을 기록한 것입니다. 향후 VPN 관련 문제 발생 시 이 가이드를 먼저 참고하십시오.**
