# Proxmox Home Server Infrastructure

OpenTofu + Bash 기반 Proxmox 홈랩 인프라 자동화 프로젝트. OPNsense 방화벽 VM과 6개의 Alpine LXC 컨테이너로 구성된 2-tier 아키텍처를 코드로 관리하고 있음

## Architecture

```
Internet
  │
  ▼
NAT Router (port forwarding)
  │
  ▼
┌─────────────────────────────────────────────────────┐
│  Proxmox VE Host (192.168.0.100 / 10.0.0.254)       │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  OPNsense VM 102                              │  │
│  │  ├─ HAProxy (SSL termination)                 │  │
│  │  └─ WireGuard VPN (UDP 51820)                 │  │
│  └──────────────┬────────────────────────────────┘  │
│                 │                                   │
│    ┌────────────┼────────────────┐                  │
│    │            │                │                  │
│    ▼            ▼                ▼                  │
│  pve.*     opnsense.*      *.cp.codingmon.dev       │
│  :8006       :443               │                   │
│                                 ▼                   │
│                    ┌─────────────────────┐          │
│                    │ CP Traefik (CT 200) │          │
│                    │   HTTP routing      │          │
│                    └────────┬────────────┘          │
│                             │                       │
│          ┌──────┬──────┬───┴────┬─────────┐         │
│          ▼      ▼      ▼       ▼         ▼          │
│       CT 210 CT 211 CT 220  CT 230    CT 240        │
│       Postgres Valkey Monitor Jenkins  Kopring      │
│       pgAdmin  Redis  Grafana                       │
│                Cmdr   Prom/Loki                     │
│                       Jaeger                        │
└─────────────────────────────────────────────────────┘
```

## Networks

| Bridge | Purpose | Subnet | Gateway |
|--------|---------|--------|---------|
| vmbr0 | External (WAN) | 192.168.0.0/24 | NAT Router |
| vmbr1 | Management | 10.0.0.0/24 | 10.0.0.1 (OPNsense) |
| vmbr2 | Service | 10.1.0.0/24 | 10.1.0.1 (OPNsense) |
| wg0 | WireGuard VPN | 10.0.1.0/24 | 10.0.1.1 (OPNsense) |

## Services

VMID 규칙: `2GN` → IP `10.1.0.(100 + G×10 + N)`

| VMID | Service | IP | External | Resources |
|------|---------|----|----------|-----------|
| 200 | CP Traefik | 10.1.0.100 | — | 1 vCPU, 512MB, 5GB |
| 210 | PostgreSQL + pgAdmin | 10.1.0.110 | pgadmin.cp.codingmon.dev | 2 vCPU, 2GB, 20GB |
| 211 | Valkey + Redis Commander | 10.1.0.111 | — | 1 vCPU, 1GB, 10GB |
| 220 | Prometheus, Grafana, Loki, Jaeger | 10.1.0.120 | grafana.cp.codingmon.dev | 4 vCPU, 4GB, 30GB |
| 230 | Jenkins | 10.1.0.130 | jenkins.cp.codingmon.dev | 2 vCPU, 2GB, 20GB |
| 240 | Kopring (Spring Boot) | 10.1.0.140 | api.cp.codingmon.dev | 2 vCPU, 2GB, 10GB |

## Prerequisites

- [Proxmox VE](https://www.proxmox.com/) 호스트
- [OpenTofu](https://opentofu.org/) >= 1.6
- SSH agent 실행 (`ssh-add -l`로 확인)
- WireGuard VPN 클라이언트 (관리 네트워크 접근용)

## Quick Start

### 1. 환경 설정

```bash
# terraform.tfvars 생성 (각 레이어별)
cp core/terraform/terraform.tfvars.example core/terraform/terraform.tfvars
cp service/chaekpool/terraform/terraform.tfvars.example service/chaekpool/terraform/terraform.tfvars
# 환경에 맞게 값 수정
```

자세한 설정 방법은 [docs/getting-started.md](docs/getting-started.md) 참조.

### 2. 인프라 프로비저닝

```bash
# OPNsense VM 생성
cd core/terraform && tofu init && tofu plan && tofu apply

# LXC 컨테이너 6개 생성
cd service/chaekpool/terraform && tofu init && tofu plan && tofu apply
```

### 3. 서비스 배포

```bash
# 전체 배포 (의존성 순서 자동 처리)
bash service/chaekpool/scripts/deploy-all.sh

# 개별 배포
bash service/chaekpool/scripts/traefik/deploy.sh
bash service/chaekpool/scripts/postgresql/deploy.sh
bash service/chaekpool/scripts/valkey/deploy.sh
bash service/chaekpool/scripts/monitoring/deploy.sh
bash service/chaekpool/scripts/jenkins/deploy.sh
bash service/chaekpool/scripts/kopring/deploy.sh
```

배포 순서: Traefik → PostgreSQL, Valkey → Monitoring, Jenkins → Kopring (PostgreSQL + Valkey 의존)

### 4. 서비스 관리

```bash
# OpenRC 서비스 제어 (Alpine LXC)
ssh admin@10.0.0.254 "sudo pct exec <CT_ID> -- rc-service <service> status"
ssh admin@10.0.0.254 "sudo pct exec <CT_ID> -- rc-service <service> restart"
```

## Project Structure

```
.
├── core/
│   └── terraform/           # OPNsense VM (102) 프로비저닝
├── service/
│   └── chaekpool/
│       ├── terraform/       # LXC 컨테이너 6개 프로비저닝
│       └── scripts/
│           ├── common.sh    # SSH 헬퍼 함수 (pct_exec, pct_push, pct_script)
│           ├── deploy-all.sh
│           ├── traefik/     # CT 200 배포 스크립트 + 설정
│           ├── postgresql/  # CT 210
│           ├── valkey/      # CT 211
│           ├── monitoring/  # CT 220
│           ├── jenkins/     # CT 230
│           └── kopring/     # CT 240
└── docs/                    # 문서 (한국어)
    ├── README.md            # 문서 색인 및 읽기 순서
    ├── getting-started.md
    ├── network-architecture.md
    ├── network-setup.md
    ├── infra-deployment.md
    ├── opnsense-haproxy-operations-guide.md
    ├── vpn-setup.md
    ├── vpn-operations-guide.md
    ├── logging-guide.md
    └── chaekpool/           # 서비스별 배포 문서
```

## Tech Stack

| Category | Technology |
|----------|-----------|
| Hypervisor | Proxmox VE |
| IaC | OpenTofu + bpg/proxmox provider |
| Firewall / Router | OPNsense (FreeBSD) |
| SSL Termination | OPNsense HAProxy + Let's Encrypt |
| HTTP Routing | Traefik 3.x |
| VPN | WireGuard |
| Container OS | Alpine Linux 3.23 (LXC) |
| Init System | OpenRC (supervise-daemon) |
| Database | PostgreSQL 18, Valkey 9 |
| Monitoring | Prometheus, Grafana, Loki, Jaeger |
| CI/CD | Jenkins LTS |
| Application | Kotlin + Spring Boot (Kopring) |

## Documentation

전체 문서는 [docs/README.md](docs/README.md)에서 읽기 순서와 함께 확인할 수 있습니다.

| Document | Description |
|----------|-------------|
| [Getting Started](docs/getting-started.md) | 사전 요구사항 및 로컬 환경 설정 |
| [Network Architecture](docs/network-architecture.md) | 네트워크 구조 레퍼런스 |
| [Network Setup](docs/network-setup.md) | 도메인, DNS, 인증서, 정책 라우팅 |
| [Infra Deployment](docs/infra-deployment.md) | OPNsense VM 프로비저닝 |
| [HAProxy Operations](docs/opnsense-haproxy-operations-guide.md) | HAProxy 운영 가이드 (도메인/인증서 추가, API, 트러블슈팅) |
| [VPN Setup](docs/vpn-setup.md) | WireGuard VPN 초기 설정 |
| [VPN Operations](docs/vpn-operations-guide.md) | VPN 운영 및 트러블슈팅 |
| [Logging Guide](docs/logging-guide.md) | 로그 수집 및 조회 |
| [Chaekpool Services](docs/chaekpool/README.md) | 서비스 레이어 배포 가이드 |

## License

This project is licensed under the [MIT License](LICENSE).
