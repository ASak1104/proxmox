# Proxmox Home Server Infrastructure

OpenTofu + Ansible 기반 Proxmox 홈랩 인프라 자동화 프로젝트. OPNsense 방화벽 VM과 6개의 Alpine LXC 컨테이너 + 1 VM으로 구성된 2-tier 아키텍처를 코드로 관리하고 있음

## Architecture

```
Internet
  │
  ▼
NAT Router (port forwarding)
  │
  ▼
┌──────────────────────────────────────────────────────────┐
│  Proxmox VE Host (192.168.0.100 / 10.0.0.254)            │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  OPNsense VM 102                                   │  │
│  │  ├─ HAProxy (SSL termination)                      │  │
│  │  └─ WireGuard VPN (UDP 51820)                      │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │                                │
│        ┌────────────────┼────────────────┐               │
│        │                │                │               │
│        ▼                ▼                ▼               │
│      pve.*         opnsense.*    *.cp.codingmon.dev      │
│      :8006           :443              │                 │
│                                        ▼                 │
│                           ┌─────────────────────┐        │
│                           │ CP Traefik (CT 200) │        │
│                           │   HTTP routing      │        │
│                           └────────┬────────────┘        │
│                                    │                     │
│     ┌────────┬────────┬────────┬───┴────┬────────┐       │
│     ▼        ▼        ▼        ▼        ▼        ▼       │
│  CT 201   CT 210   CT 211   CT 220   CT 230   CT 240     │
│  Authelia Postgres Valkey   Monitor  Jenkins  Kopring    │
│           pgAdmin  Redis    Grafana                      │
│                    Cmdr     Prom/Loki                    │
│                             Jaeger                       │
└──────────────────────────────────────────────────────────┘
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
| 201 | Authelia (SSO) | 10.1.0.101 | authelia.cp.codingmon.dev | 1 vCPU, 256MB, 2GB |
| 210 | PostgreSQL + pgAdmin | 10.1.0.110 | pgadmin.cp.codingmon.dev | 2 vCPU, 2GB, 20GB |
| 211 | Valkey + Redis Commander | 10.1.0.111 | — | 1 vCPU, 1GB, 10GB |
| 220 | Prometheus, Grafana, Loki, Jaeger | 10.1.0.120 | grafana.cp.codingmon.dev | 4 vCPU, 4GB, 30GB |
| 230 | Jenkins | 10.1.0.130 | jenkins.cp.codingmon.dev | 2 vCPU, 2GB, 20GB |
| 240 | Kopring (Spring Boot) | 10.1.0.140 | api.cp.codingmon.dev | 2 vCPU, 2GB, 10GB |

## Service Links

| Service | URL | Note |
|---------|-----|------|
| Proxmox WebUI | https://pve.codingmon.dev | 인프라 관리 |
| OPNsense WebUI | https://opnsense.codingmon.dev | 방화벽/라우터 관리 |
| Authelia | https://authelia.cp.codingmon.dev | SSO/OIDC |
| pgAdmin | https://pgadmin.cp.codingmon.dev | DB 관리 |
| Grafana | https://grafana.cp.codingmon.dev | 모니터링 대시보드 |
| Jenkins | https://jenkins.cp.codingmon.dev | CI/CD |
| Kopring API | https://api.cp.codingmon.dev | 애플리케이션 |
| Prometheus | http://10.1.0.120:9090 | VPN 전용 |
| Jaeger | http://10.1.0.120:16686 | VPN 전용 |
| Redis Commander | http://10.1.0.111:8081 | VPN 전용 |

## Prerequisites

- [Proxmox VE](https://www.proxmox.com/) 호스트
- [OpenTofu](https://opentofu.org/) >= 1.6
- SSH agent 실행 (`ssh-add -l`로 확인)
- WireGuard VPN 클라이언트 (관리 네트워크 접근용)

## Quick Start

### 1. 환경 설정

```bash
# terraform.tfvars 생성 (각 레이어별)
cp core/terraform/terraform.tfvars.template core/terraform/terraform.tfvars
cp service/chaekpool/terraform/terraform.tfvars.template service/chaekpool/terraform/terraform.tfvars
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
# VPN 연결
bash scripts/vpn.sh up

# Ansible 사전 준비
cd service/chaekpool/ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping

# 전체 배포
ansible-playbook site.yml

# 개별 배포
ansible-playbook site.yml -l cp-traefik
ansible-playbook site.yml -l cp-authelia
ansible-playbook site.yml -l cp-postgresql
ansible-playbook site.yml -l cp-valkey
ansible-playbook site.yml -l cp-monitoring
ansible-playbook site.yml -l cp-jenkins
```

### 4. 서비스 관리

```bash
# VPN 연결 후 직접 SSH (OpenRC)
ssh root@10.1.0.1xx "rc-service <service> status|start|stop|restart"
```

## Project Structure

```
.
├── core/
│   └── terraform/           # OPNsense VM (102) 프로비저닝
├── service/
│   └── chaekpool/
│       ├── terraform/       # LXC 6개 + VM 1개 프로비저닝
│       └── ansible/         # 설정 관리 (7 roles)
│           ├── site.yml
│           ├── inventory/
│           ├── group_vars/
│           └── roles/       # common, traefik, authelia, postgresql, valkey, monitoring, jenkins
├── scripts/
│   └── vpn.sh              # WireGuard VPN 관리
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
