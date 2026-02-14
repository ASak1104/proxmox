# Proxmox Homelab IaC

OpenTofu + Bash 스크립트 기반 Proxmox 홈랩 인프라 자동화 프로젝트.

**업데이트**: 2026-02-10 - OPNsense HAProxy 2-tier 아키텍처로 변경

## 프로젝트 구조

```
proxmox/
├── core/                           # 인프라 계층
│   └── terraform/                  # OpenTofu: OPNsense VM
│       ├── opnsense.tf             # OPNsense 방화벽 (VM 102)
│       ├── providers.tf            # bpg/proxmox provider 설정
│       └── variables.tf            # 인프라 변수 정의
├── service/
│   └── chaekpool/                  # Chaekpool 서비스 계층
│       ├── terraform/              # OpenTofu: 서비스 LXC 6개 일괄 생성
│       │   ├── main.tf             # for_each 패턴 컨테이너 정의
│       │   ├── providers.tf        # bpg/proxmox provider 설정
│       │   └── variables.tf        # 컨테이너 스펙 (VMID, IP, 리소스)
│       └── scripts/                # 서비스별 배포 스크립트
│           ├── common.sh           # 공용 변수/함수 (pct_exec, pct_push, pct_script)
│           ├── deploy-all.sh       # 전체 서비스 일괄 배포
│           ├── traefik/            # CP Traefik (CT 200)
│           ├── postgresql/         # PostgreSQL + pgAdmin (CT 210)
│           ├── valkey/             # Valkey + Redis Commander (CT 211)
│           ├── monitoring/         # Prometheus/Grafana/Loki/Jaeger (CT 220)
│           ├── jenkins/            # Jenkins (CT 230)
│           └── kopring/            # Kopring Spring Boot (CT 240)
└── docs/                           # 문서
```

## 아키텍처 (2-Tier)

```
인터넷
  │
  ▼
[NAT Router] ── 포트포워딩 (80, 443, 51820/UDP → <OPNSENSE_WAN_IP>)
  │
  ▼
[OPNsense (VM 102)] ── 🔒 SSL 종료, 🛡️  방화벽, 🔑 VPN
  │                     <OPNSENSE_WAN_IP> / 10.0.0.1 / 10.1.0.1 / 10.0.1.1
  │
  ├─── HAProxy (TCP 80/443)
  │     ├── pve.codingmon.dev         → Proxmox (10.0.0.254:8006, HTTPS)
  │     ├── opnsense.codingmon.dev    → OPNsense (127.0.0.1:443, HTTPS)
  │     └── *.cp.codingmon.dev        → CP Traefik (10.1.0.100:80, HTTP)
  │
  └─── WireGuard (UDP 51820) ── Split Tunnel VPN
        └── Mac (10.0.1.2) → 10.0.0.0/24, 10.1.0.0/24 직접 접근
                                          │
                                          ▼
                                    [CP Traefik (CT 200)] ── HTTP 라우팅
                                       │
                                       ├── api.cp.codingmon.dev       → Kopring (10.1.0.140:8080)
                                       ├── pgadmin.cp.codingmon.dev  → pgAdmin (10.1.0.110:5050)
                                       ├── grafana.cp.codingmon.dev   → Grafana (10.1.0.120:3000)
                                       └── jenkins.cp.codingmon.dev   → Jenkins (10.1.0.130:8080)
```

## VMID / IP 매핑

| VMID | 호스트명 | IP | 역할 |
|------|---------|-----|------|
| 102 | opnsense | <OPNSENSE_WAN_IP> | 방화벽/라우터/SSL 종료/HAProxy (VM) |
| ~~103~~ | ~~traefik~~ | ~~10.0.0.2~~ | ~~제거됨 (2026-02-10)~~ |
| 200 | cp-traefik | 10.1.0.100 | CP 리버스 프록시 (HTTP only) |
| 210 | cp-postgresql | 10.1.0.110 | PostgreSQL + pgAdmin |
| 211 | cp-valkey | 10.1.0.111 | Valkey + Redis Commander |
| 220 | cp-monitoring | 10.1.0.120 | Prometheus/Grafana/Loki/Jaeger |
| 230 | cp-jenkins | 10.1.0.130 | Jenkins CI/CD |
| 240 | cp-kopring | 10.1.0.140 | Kopring Spring Boot |

## 문서 읽기 순서

1. **[사전 요구사항](getting-started.md)** - Proxmox 호스트 준비, 로컬 머신 설정, 변수 설정
2. **[인프라 배포](infra-deployment.md)** - OPNsense + HAProxy 프로비저닝
3. **[OPNsense HAProxy 운영 가이드](opnsense-haproxy-operations-guide.md)** - HAProxy 전체 운영 가이드 (마이그레이션 기록, 트러블슈팅, 도메인/인증서 추가 절차)
4. **[Chaekpool 서비스 배포](chaekpool/README.md)** - 서비스 계층 배포 가이드
5. **[VPN 설정 가이드](vpn-setup.md)** - WireGuard VPN 초기 설정
   - **[VPN 운영 및 트러블슈팅 가이드](vpn-operations-guide.md)** - VPN 문제 해결, 클라이언트 관리, 모니터링, SSH/API 패턴
6. **[네트워크 아키텍처](network-architecture.md)** - 네트워크 구성 레퍼런스
7. **[네트워크 설정 가이드](network-setup.md)** - 도메인, 인증서, 정책 라우팅, 트러블슈팅
8. **[로깅 가이드](logging-guide.md)** - 로그 확인 및 관리

## 주요 변경 사항 (2026-02-10)

### Before (3-Tier)
```
Internet → NAT Router → Mgmt Traefik (CT 103) → CP Traefik (CT 200) → Services
```

### After (2-Tier)
```
Internet → NAT Router → OPNsense HAProxy (VM 102) → {Infrastructure, CP Traefik} → Services
```

### 장점
- ✅ **중앙 집중식 보안 관리**: 모든 외부 트래픽이 OPNsense 방화벽 통과
- ✅ **리소스 절약**: CT 103 제거 (CPU 2, RAM 1GB, Disk 10GB)
- ✅ **아키텍처 단순화**: 3-tier → 2-tier
- ✅ **보안 강화**: HAProxy WAF, Rate limiting, IP Geo-blocking 활용 가능
- ✅ **관심사 분리**: 인프라 (OPNsense) vs 서비스 (CP Traefik)

### 주의 사항
- ⚠️ OPNsense 부하 증가 (모든 HTTPS 트래픽 SSL 종료)
- ⚠️ 단일 장애점 (OPNsense 다운 시 모든 외부 접속 불가)
- ⚠️ OPNsense 메모리 증설 필요 (2GB → 4GB)
