# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenTofu + Ansible 기반 Proxmox homelab infrastructure automation. Three layers:
- **core/**: Foundation layer (OPNsense firewall VM with HAProxy for SSL termination and routing)
- **service/chaekpool/**: Service layer (6 LXC + 1 VM, Alpine 3.23 + Ansible 설정 관리)
  - `terraform/` — 인프라 프로비저닝 (LXC 6개 + Jenkins VM 1개)
  - `ansible/` — 설정 관리 (6개 서비스 배포 — Kopring 제외)

Documentation is in Korean. See `docs/README.md` for reading order.
For OPNsense HAProxy operations (troubleshooting, adding domains/certs, API automation), see `docs/opnsense-haproxy-operations-guide.md`.

## Commands

### OpenTofu (Infrastructure Provisioning)

```bash
# Infra layer: OPNsense VM (102)
cd core/terraform && tofu init && tofu plan && tofu apply

# Service layer: 6 LXC + 1 VM (200-240) + Ansible 부트스트랩
cd service/chaekpool/terraform && tofu init && tofu plan && tofu apply
```

Requires SSH agent running (`ssh-add -l` to verify). `terraform.tfvars` is gitignored and must be created per environment from `terraform.tfvars.template` — see `docs/getting-started.md`.

### VPN

```bash
# VPN 연결 (배포 전 필수)
bash scripts/vpn.sh up

# VPN 해제/상태/재연결
bash scripts/vpn.sh down|status|restart
```

### Ansible (Configuration Management)

```bash
# 사전 준비
cd service/chaekpool/ansible
ansible-galaxy collection install -r requirements.yml
ansible all -m ping  # 연결 확인

# 전체 배포
ansible-playbook site.yml

# 단일 서비스 배포
ansible-playbook site.yml -l cp-traefik
ansible-playbook site.yml -l cp-authelia
ansible-playbook site.yml -l cp-postgresql
ansible-playbook site.yml -l cp-valkey
ansible-playbook site.yml -l cp-monitoring
ansible-playbook site.yml -l cp-jenkins

# 드라이런 (변경 예정 사항 확인)
ansible-playbook site.yml --check --diff

# 시크릿 편집
ansible-vault edit group_vars/all/vault.yml
```

### Service Management (OpenRC on Alpine)

```bash
# Ansible 경유
ansible cp-<service> -m command -a "rc-service <service> status"

# 직접 SSH (VPN 필요)
ssh root@10.1.0.1xx "rc-service <service> status|start|stop|restart"
```

## Architecture

### Networks

| Bridge/Interface | Purpose | Subnet | Gateway |
|--------|---------|--------|---------|
| vmbr0 | External (WAN) | <EXTERNAL_SUBNET> | <GATEWAY_IP> (NAT Router) |
| vmbr1 | Management | 10.0.0.0/24 | 10.0.0.1 (OPNsense) |
| vmbr2 | Service | 10.1.0.0/24 | 10.1.0.1 (OPNsense) |
| wg0 | WireGuard VPN | 10.0.1.0/24 | 10.0.1.1 (OPNsense) |

### OPNsense HAProxy + CP Traefik (2-Tier)

OPNsense HAProxy (VM 102) terminates SSL via Let's Encrypt ACME, routes `pve.*` and `opnsense.*` directly to infrastructure services, and forwards `*.cp.codingmon.dev` to CP Traefik (CT 200) which does HTTP-only routing to Chaekpool backend services. This provides centralized security management with all external traffic passing through the firewall.

### WireGuard VPN

OPNsense WireGuard (UDP 51820) provides split-tunnel VPN access to internal networks. With VPN connected, access Management (10.0.0.0/24) and Service (10.1.0.0/24) networks directly without SSH chaining.

- **Setup guide**: `docs/vpn-setup.md`
- **Operations & troubleshooting**: `docs/vpn-operations-guide.md`

**Common Issues**:
- OPNsense 25.7+: WireGuard integrated in core (no plugin needed)
- Interface assignment required: `Interfaces > Assignments > wg0` → Enable
- Peer-Instance connection: `VPN > WireGuard > Local` → select peer
- Firewall rules: `Firewall > Rules > WireGuard (Group)` → Pass all
- Static routes: Proxmox needs `ip route add 10.0.1.0/24 via 10.0.0.1`

**SSH Access**: VPN required → `ssh <PROXMOX_USER>@<PROXMOX_HOST>` (Management network)

### VMID/IP Scheme

Rule: VMID `2GN` → IP `10.1.0.(100 + G×10 + N)`, where G = group (0=LB, 1=Data, 2=Monitoring, 3=CI/CD, 4=App), N = instance.

| VMID | Service | IP | Endpoint | External |
|------|---------|-----|----------|----------|
| 200 | CP Traefik | 10.1.0.100 | :80 | — |
| 201 | Authelia | 10.1.0.101 | :9091 | authelia.cp.codingmon.dev |
| 210 | PostgreSQL + pgAdmin | 10.1.0.110 | :5432, :5050 | pgadmin.cp.codingmon.dev |
| 211 | Valkey + Redis Commander | 10.1.0.111 | :6379, :8081 | — |
| 220 | Monitoring | 10.1.0.120 | :9090, :3000, :3100, :16686 | grafana.cp.codingmon.dev |
| 230 | Jenkins (VM) | 10.1.0.130 | :8080 | jenkins.cp.codingmon.dev |
| 240 | Kopring | 10.1.0.140 | :8080 | api.cp.codingmon.dev |

## Key Conventions

### Role-Based Deployment (Ansible)

역할 분리:
- **OpenTofu**: 인프라 생성 (VM, LXC, 네트워크). `null_resource`로 SSH+Python 부트스트랩
- **Ansible**: 설정 관리 (패키지, 설정파일, 서비스, 시크릿). 6개 서비스 역할 + common
- **Bash**: `scripts/vpn.sh`만 유지 (로컬 VPN 관리용)

연결 방식: Mac → VPN(10.1.0.x) → SSH 컨테이너 (root, 직접 접속)

### Ansible Directory Structure

```
service/chaekpool/ansible/
├── ansible.cfg              # 설정 (inventory 경로, vault 파일 등)
├── requirements.yml         # community.postgresql 컬렉션
├── site.yml                 # 전체 배포 오케스트레이션
├── inventory/hosts.yml      # 정적 인벤토리 (7 hosts)
├── group_vars/all/
│   ├── vars.yml             # 공통 변수 (IP, 포트, 버전)
│   └── vault.yml            # ansible-vault 암호화 시크릿
└── roles/
    ├── common/tasks/        # 재사용 태스크 (service_user, binary_download, openrc_service)
    ├── traefik/             # CP 리버스 프록시
    ├── authelia/            # SSO/OIDC (해시 생성 포함)
    ├── postgresql/          # DB + pgAdmin (pgAdmin 서버 자동 등록 포함)
    ├── valkey/              # 캐시 + Redis Commander
    ├── monitoring/          # Prometheus, Grafana, Loki, Jaeger
    └── jenkins/             # CI/CD
```

### Common Role Tasks

`include_role: name=common tasks_from=<task>`로 호출:

- `service_user`: 시스템 유저/그룹 생성 + 디렉토리 (vars: `svc_name`, `svc_dirs`)
- `binary_download`: 아카이브 다운로드 + 바이너리 설치 (vars: `bin_name`, `bin_url`, `bin_src_path`, `bin_dest`)
- `openrc_service`: OpenRC 서비스 파일 배포 + 활성화 + 시작 (vars: `openrc_name`, `openrc_src`)

### OpenTofu Patterns

- bpg/proxmox provider with SSH agent auth (`ssh { agent = true }`)
- Chaekpool containers use `for_each` over a `containers` map variable in `variables.tf`
- Jenkins: Alpine nocloud VM (`proxmox_virtual_environment_vm`) — Docker/Testcontainers 지원
- `null_resource` for Ansible bootstrap (openssh + python3 + sshd)
- Local state (no remote backend)
- Provider config is identical across both terraform directories

### Secrets Management

| File | Purpose |
|------|---------|
| `core/.core.env` | Proxmox API token, SSH public key |
| `service/chaekpool/ansible/group_vars/all/vault.yml` | 서비스 시크릿 (ansible-vault 암호화, git 커밋 가능) |

Vault 비밀번호: `~/.vault_pass` (repo 외부). `ansible.cfg`에서 참조.

### Adding a New Service

1. Add entry to `containers` map in `service/chaekpool/terraform/variables.tf`
2. `tofu apply` to create container (자동으로 SSH+Python 부트스트랩)
3. Create Ansible role in `service/chaekpool/ansible/roles/<service>/`
4. Add role to `service/chaekpool/ansible/site.yml`
5. Add Traefik route in `service/chaekpool/ansible/roles/traefik/templates/services.yml.j2`
6. Managed Traefik wildcard (`*.cp.codingmon.dev`) auto-forwards — no change needed there
