# 네트워크 아키텍처 (OPNsense HAProxy)

**업데이트**: 2026-02-10 - OPNsense HAProxy 2-tier 아키텍처로 변경

## 네트워크 브리지 구성

| 브리지/인터페이스 | 용도 | 대역 | 게이트웨이 |
|--------|------|------|-----------|
| vmbr0 | External (WAN) | <EXTERNAL_SUBNET> | <GATEWAY_IP> (NAT Router) |
| vmbr1 | Management | 10.0.0.0/24 | 10.0.0.1 (OPNsense) |
| vmbr2 | Service | 10.1.0.0/24 | 10.1.0.1 (OPNsense) |
| wg0 | WireGuard VPN | 10.0.1.0/24 | 10.0.1.1 (OPNsense) |

## VMID / IP 할당 규칙

VMID `2GN` → IP `10.1.0.(100 + G×10 + N)`

- G: 그룹 번호 (0=LB, 1=Data, 2=Monitoring, 3=CI/CD, 4=App)
- N: 그룹 내 인스턴스 번호

---

## vmbr0 — External Network (<EXTERNAL_SUBNET>)

| 인스턴스 | VMID | IP | 포트 | 비고 |
|----------|------|----|------|------|
| NAT Router Router | — | <GATEWAY_IP> | — | 기본 게이트웨이 |
| Proxmox Host | — | <PROXMOX_EXTERNAL_IP> | 8006 | 호스트 (Terraform API) |
| **OPNsense** | **102** | **<OPNSENSE_WAN_IP>** | **80, 443** | **WAN 진입점, SSL 종료, HAProxy** |
| ~~Traefik (관리)~~ | ~~103~~ | ~~192.168.0.103~~ | ~~80, 443~~ | ~~제거됨 (2026-02-10)~~ |

## vmbr1 — Management Network (10.0.0.0/24)

| 인스턴스 | VMID | IP | 포트 | 비고 |
|----------|------|----|------|------|
| OPNsense | 102 | 10.0.0.1 | 443 | 관리 네트워크 게이트웨이 |
| Proxmox Host | — | 10.0.0.254 | 8006 | 웹 콘솔 |

## vmbr2 — Service Network (10.1.0.0/24)

| 인스턴스 | VMID | IP | 서비스 포트 | 비고 |
|----------|------|----|-----------|------|
| OPNsense | 102 | 10.1.0.1 | — | 서비스 네트워크 게이트웨이 |
| **CP Traefik** | **200** | **10.1.0.100** | 80 | CP 전용 리버스 프록시 (HTTP only) |
| **PostgreSQL** | **210** | **10.1.0.110** | 5432 (DB), 5050 (pgAdmin) | DB + 웹 관리 |
| **Valkey** | **211** | **10.1.0.111** | 6379 (Valkey), 8081 (Redis Commander) | 캐시 + 웹 관리 |
| **Monitoring** | **220** | **10.1.0.120** | 9090 (Prometheus), 3000 (Grafana), 3100 (Loki), 16686 (Jaeger UI), 4317 (OTLP gRPC), 4318 (OTLP HTTP) | 통합 모니터링 |
| **Jenkins** | **230** | **10.1.0.130** | 8080 | CI/CD |
| **Kopring** | **240** | **10.1.0.140** | 8080 | 애플리케이션 서버 |

---

## 트래픽 흐름 (2-Tier: OPNsense HAProxy + CP Traefik)

```
Internet
  │
  ▼
NAT Router (<GATEWAY_IP>) - 포트 포워딩: 80, 443, 51820(UDP) → <OPNSENSE_WAN_IP>
  │
  ▼
OPNsense (VM 102, <OPNSENSE_WAN_IP>)
  │  🔒 SSL 종료 (Let's Encrypt 인증서 2개)
  │  🛡️  방화벽 + 중앙 집중식 보안 관리
  │
  ├─── HAProxy (TCP 80/443) ── 웹 트래픽
  │     │
  │     ├─── 인프라 라우팅 (직접)
  │     │     ├─ pve.codingmon.dev        ──▶ Proxmox (10.0.0.254:8006, HTTPS)
  │     │     └─ opnsense.codingmon.dev   ──▶ OPNsense (127.0.0.1:443, HTTPS)
  │     │
  │     └─── 서비스 라우팅 (CP Traefik 경유)
  │           └─ *.cp.codingmon.dev       ──▶ CP Traefik (10.1.0.100:80, HTTP)
  │                                             │  Host 헤더 기반 라우팅
  │                                             ├─ api.cp.codingmon.dev        ──▶ 10.1.0.140:8080  (Kopring)
  │                                             ├─ pgadmin.cp.codingmon.dev   ──▶ 10.1.0.110:5050  (pgAdmin)
  │                                             ├─ grafana.cp.codingmon.dev    ──▶ 10.1.0.120:3000  (Grafana)
  │                                             └─ jenkins.cp.codingmon.dev    ──▶ 10.1.0.130:8080  (Jenkins)
  │
  └─── WireGuard (UDP 51820) ── VPN 접근
        │  10.0.1.0/24 터널 네트워크
        │  Split Tunnel (내부 트래픽만 VPN 경유)
        │
        └─ Mac (10.0.1.2)
              ├─ 10.0.0.0/24 직접 접근 (Management)
              └─ 10.1.0.0/24 직접 접근 (Service)
```

## 도메인 → 백엔드 매핑

| 도메인 | SSL 종료 | 경유 | 최종 목적지 | 프로토콜 |
|--------|---------|------|-----------|---------|
| pve.codingmon.dev | OPNsense HAProxy (102) | 직접 | 10.0.0.254:8006 | HTTPS |
| opnsense.codingmon.dev | OPNsense HAProxy (102) | 직접 | 127.0.0.1:443 | HTTPS |
| api.cp.codingmon.dev | OPNsense HAProxy (102) | CP Traefik (200) | 10.1.0.140:8080 | HTTP |
| pgadmin.cp.codingmon.dev | OPNsense HAProxy (102) | CP Traefik (200) | 10.1.0.110:5050 | HTTP |
| grafana.cp.codingmon.dev | OPNsense HAProxy (102) | CP Traefik (200) | 10.1.0.120:3000 | HTTP |
| jenkins.cp.codingmon.dev | OPNsense HAProxy (102) | CP Traefik (200) | 10.1.0.130:8080 | HTTP |

## OPNsense HAProxy 설정

### Backend Servers

| Name | IP:Port | SSL | Health Check | 용도 |
|------|---------|-----|--------------|------|
| `proxmox-backend` | 10.0.0.254:8006 | ✅ | TCP | Proxmox 웹 UI |
| `opnsense-webui` | 127.0.0.1:443 | ✅ | TCP | OPNsense 자체 웹 UI |
| `cp-traefik-backend` | 10.1.0.100:80 | ❌ | HTTP `/ping` | CP Traefik |

### Backend Pools

| Pool Name | Mode | Servers | Health Check |
|-----------|------|---------|--------------|
| `proxmox-pool` | HTTP | proxmox-backend | TCP |
| `opnsense-pool` | HTTP | opnsense-webui | TCP |
| `cp-traefik-pool` | HTTP | cp-traefik-backend | HTTP GET /ping |

### Frontends

#### HTTP Frontend (`:80`)
- **용도**: ACME HTTP-01 Challenge + HTTPS 리다이렉트
- **Custom Options**:
  ```
  http-request redirect scheme https code 301 if !{ path_beg /.well-known/acme-challenge/ }
  ```

#### HTTPS Frontend (`:443`)
- **SSL Offloading**: ✅ (Let's Encrypt 9-도메인 SAN)
- **ACLs**:
  - `acl_pve`: Host matches `pve.codingmon.dev`
  - `acl_opnsense`: Host matches `opnsense.codingmon.dev`
  - `acl_cp_wildcard`: Host matches (regex) `^[a-z0-9-]+\.cp\.codingmon\.dev$`
- **Actions**:
  - `acl_pve` → `proxmox-pool`
  - `acl_opnsense` → `opnsense-pool`
  - Default → `cp-traefik-pool`

## 보안 계층

### 1단계: 외부 → OPNsense (방화벽)
- 모든 외부 트래픽이 OPNsense 통과
- WAN 방화벽 규칙으로 포트 80, 443만 허용
- SSL 종료 (TLS 1.2+, Let's Encrypt 인증서)
- 향후 확장 가능: WAF, Rate limiting, IP Geo-blocking

### 2단계: OPNsense → Backend
- **인프라 서비스**: HTTP 프록시 (Proxmox, OPNsense 백엔드로 HTTPS 전달)
- **Chaekpool 서비스**: HTTP로 CP Traefik에 전달 (내부 네트워크, SSL 불필요)

### 3단계: CP Traefik → Service
- Host 헤더 기반 라우팅
- 서비스별 HTTP 백엔드 연결

## WireGuard VPN

OPNsense의 내장 WireGuard를 통해 외부에서 내부 네트워크에 직접 접근할 수 있다.

- **터널 네트워크**: 10.0.1.0/24
- **서버**: OPNsense (10.0.1.1), 포트 UDP 51820
- **접근 가능 네트워크**: Management (10.0.0.0/24), Service (10.1.0.0/24)
- **Split Tunnel**: 인터넷 트래픽은 VPN 미경유

설정 가이드: [`docs/vpn-setup.md`](vpn-setup.md)

## 변경 이력

### 2026-02-10: WireGuard VPN 추가
- **추가**: OPNsense WireGuard VPN (UDP 51820)
- **목적**: SSH 체이닝 없이 내부 네트워크 직접 접근
- **네트워크**: 10.0.2.0/24 (터널), Split Tunnel

### 2026-02-10: OPNsense HAProxy 마이그레이션
- **제거**: Mgmt Traefik (CT 103) - 3-tier → 2-tier
- **추가**: OPNsense HAProxy - 중앙 집중식 보안 관리
- **리소스 절약**: CPU 2코어, RAM 1GB, Disk 10GB
- **보안 강화**: 모든 외부 트래픽이 방화벽 통과

운영 가이드: [`docs/opnsense-haproxy-operations-guide.md`](opnsense-haproxy-operations-guide.md)
