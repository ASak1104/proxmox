# 인프라 계층 배포 가이드 (OPNsense HAProxy)

인프라 계층은 OPNsense 방화벽(VM 102)으로 구성된다. OPNsense HAProxy가 SSL 종료 및 라우팅을 담당하며, 모든 외부 트래픽이 방화벽을 거치도록 중앙 집중식 보안 관리가 가능하다.

## 개요

| 리소스 | VMID | 유형 | 사양 | 역할 |
|--------|------|------|------|------|
| OPNsense | 102 | VM | 2코어 / 4GB RAM / 20GB 디스크 | 방화벽, 라우터, NAT, SSL 종료, 리버스 프록시 |

**변경 사항 (2026-02-10)**:
- ❌ **제거**: Mgmt Traefik (CT 103) - 리소스 절약 및 아키텍처 단순화
- ✅ **추가**: OPNsense HAProxy - 중앙 집중식 보안 관리
- 📈 **증설**: OPNsense 메모리 2GB → 4GB (HAProxy SSL 종료 부하 대응)

## Step 1: OpenTofu 적용

```bash
cd core/terraform
tofu init
tofu plan
tofu apply
```

### 생성되는 리소스

**OPNsense (VM 102)** (`opnsense.tf`):
- 2코어 / 4GB RAM / 20GB SATA 디스크 (qcow2)
- 네트워크: vmbr0 (WAN), vmbr1 (관리), vmbr2 (서비스)
- UEFI 부팅 (OVMF + q35)
- OPNsense ISO에서 수동 설치 필요

## Step 2: OPNsense 초기 설정

OPNsense는 VM만 생성되고 OS 설치는 수동으로 진행한다. Proxmox 콘솔에서 OPNsense ISO로 부팅 후 설치한다.

### 인터페이스 할당

| 인터페이스 | 브리지 | 역할 | IP |
|-----------|--------|------|-----|
| vtnet0 (WAN) | vmbr0 | 외부 네트워크 | <OPNSENSE_WAN_IP>/24 |
| vtnet1 (LAN) | vmbr1 | 관리 네트워크 | 10.0.0.1/24 |
| vtnet2 (OPT1) | vmbr2 | 서비스 네트워크 | 10.1.0.1/24 |

### 주요 설정 항목

1. **WAN 게이트웨이**: 공유기 IP (예: `<GATEWAY_IP>`)
2. **DNS 서버**: 공유기 또는 공용 DNS (예: `8.8.8.8`)
3. **NAT 규칙**: LAN/OPT1 → WAN 아웃바운드 NAT (컨테이너 인터넷 접속용)
4. **방화벽 규칙**:
   - LAN: 모든 트래픽 허용 (관리 네트워크)
   - OPT1: 모든 트래픽 허용 (서비스 네트워크)
   - WAN: 포트 80, 443 허용 (HAProxy 접근)

## Step 3: OPNsense HAProxy 설정

HAProxy 설정은 **OPNsense 웹 UI를 통해 수동으로 진행**한다.

상세 가이드: [`docs/opnsense-haproxy-operations-guide.md`](opnsense-haproxy-operations-guide.md)

### 설정 개요

1. **HAProxy 플러그인 설치** (`os-haproxy`)
2. **Let's Encrypt ACME 설정** (2개 SAN 인증서: infra + cp)
3. **Backend Servers** (Real Servers):
   - Proxmox: `10.0.0.254:8006` (HTTPS)
   - OPNsense: `127.0.0.1:443` (HTTPS)
   - CP Traefik: `10.1.0.100:80` (HTTP)
4. **Backend Pools** (Health Check 포함):
   - `proxmox-pool` (HTTP)
   - `opnsense-pool` (HTTP)
   - `cp-traefik-pool` (HTTP)
5. **Frontends**:
   - HTTP (`:80`): ACME challenge + HTTPS 리다이렉트
   - HTTPS (`:443`): SSL 종료 + 도메인별 라우팅
6. **방화벽 규칙**: WAN 포트 80, 443 허용

### 라우팅 규칙

| 도메인 | Backend Pool | 최종 목적지 |
|--------|--------------|-----------|
| `pve.codingmon.dev` | `proxmox-pool` | 10.0.0.254:8006 |
| `opnsense.codingmon.dev` | `opnsense-pool` | 127.0.0.1:443 |
| `*.cp.codingmon.dev` | `cp-traefik-pool` | 10.1.0.100:80 → CP Traefik → Services |

## Step 4: NAT Router 포트 포워딩 설정

NAT Router 관리 페이지 (http://<GATEWAY_IP>):

```
고급 설정 → NAT/라우터 관리 → 포트 포워딩

HTTP:
  외부 포트: 80
  내부 IP: <OPNSENSE_WAN_IP>
  내부 포트: 80

HTTPS:
  외부 포트: 443
  내부 IP: <OPNSENSE_WAN_IP>
  내부 포트: 443
```

⚠️ 이 설정 후 모든 외부 트래픽이 OPNsense로 라우팅된다.

## Step 5: Let's Encrypt 인증서 발급

OPNsense 웹 UI:
1. **Services → ACME Client → Certificates**
2. `codingmon-multi-san` 인증서 선택
3. **Actions → Issue/Renew** 클릭
4. 로그에서 9개 도메인 검증 성공 확인

발급된 인증서는 HAProxy에서 자동으로 사용된다.

## 검증

모든 배포가 완료되면 다음 URL에 접속하여 확인한다:

- `https://pve.codingmon.dev` - Proxmox 웹 UI
- `https://opnsense.codingmon.dev` - OPNsense 웹 UI
- `https://pgadmin.cp.codingmon.dev` - pgAdmin (Chaekpool)
- `https://grafana.cp.codingmon.dev` - Grafana (Chaekpool)

정상 작동이 확인되면 [Chaekpool 서비스 배포](chaekpool/README.md)로 진행한다.

## 참조 파일

| 파일 | 설명 |
|------|------|
| `core/terraform/opnsense.tf` | OPNsense VM 정의 |
| `core/terraform/providers.tf` | bpg/proxmox provider 설정 |
| `core/terraform/variables.tf` | 인프라 변수 정의 |
| `docs/opnsense-haproxy-operations-guide.md` | HAProxy 운영 가이드 |

## 마이그레이션 노트

이전 3-tier 아키텍처 (Mgmt Traefik CT 103 사용)에서 2-tier로 변경:

**Before**:
```
Internet → NAT Router → Mgmt Traefik (CT 103) → CP Traefik (CT 200) → Services
```

**After**:
```
Internet → NAT Router → OPNsense HAProxy (VM 102) → {Infrastructure, CP Traefik} → Services
```

**장점**:
- 중앙 집중식 보안 관리 (모든 외부 트래픽이 OPNsense 통과)
- 리소스 절약 (CT 103 제거: CPU 2, RAM 1GB, Disk 10GB)
- 아키텍처 단순화 (3-tier → 2-tier)
- HAProxy WAF, Rate limiting, IP 차단 활용 가능

운영 가이드: [`docs/opnsense-haproxy-operations-guide.md`](opnsense-haproxy-operations-guide.md)
