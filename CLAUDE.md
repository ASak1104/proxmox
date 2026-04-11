# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenTofu + Ansible 기반 Proxmox homelab infrastructure automation. Three layers:
- **core/**: Foundation layer (OPNsense firewall VM with HAProxy for SSL termination and routing)
- **service/chaekpool/**: Service layer (6 LXC + 1 VM, Alpine 3.23 + Ansible 설정 관리)
  - `terraform/` — 인프라 프로비저닝 (LXC 6개 + Jenkins VM 1개)
  - `ansible/` — 설정 관리 (7개 서비스 배포)

Documentation is in Korean. See `docs/README.md` for reading order.
For OPNsense HAProxy operations (troubleshooting, adding domains/certs, API automation), see `docs/opnsense-haproxy-operations-guide.md`.
For OPNsense firewall-level incidents (pf ruleset load failure, bogons corruption, cp LAN outbound blockage), see `docs/opnsense-firewall-operations-guide.md`.

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
ansible-playbook site.yml -l cp-api

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
| 240 | API | 10.1.0.140 | :8080 | api.cp.codingmon.dev |

## Key Conventions

### Role-Based Deployment (Ansible)

역할 분리:
- **OpenTofu**: 인프라 생성 (VM, LXC, 네트워크). `null_resource`로 SSH+Python 부트스트랩
- **Ansible**: 설정 관리 (패키지, 설정파일, 서비스, 시크릿). 7개 서비스 역할 + common
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
    ├── jenkins/             # CI/CD
    └── api/                 # Spring Boot API (Jenkins 파이프라인 배포)
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

## Important Rules

### 절대 금지 사항

1. **Co-Authored-By 금지** - 커밋 메시지에 공동 작성자/협력자 표기 절대 추가 금지
2. **비밀 정보 커밋 금지** - API 토큰, 비밀번호, SSH 키, 실제 IP 등 민감정보 커밋 금지 (`.*.env`, `terraform.tfvars`, `vault.yml` 평문)
3. **추측으로 진행 금지** - "아마 이럴 것 같다"는 금물, 반드시 확인 후 진행

### 필수 준수 사항

1. **한국어 커밋** - Angular Conventional Commits 한국어 (`type(scope): 설명`), scope: `core`/`service`/`docs` 또는 생략
2. **기존 패턴 준수** - 새 코드는 반드시 기존 코드 패턴과 디렉토리 구조 따름
3. **BP/레퍼런스 조사 (필수)** - 구현 전 **WebSearch 도구 사용 필수**
   - 공식 문서 최신 버전 확인 (OpenTofu, bpg/proxmox provider, Ansible module 등)
   - Best Practice 검색 (예: "Ansible role best practices 2026")
   - 레퍼런스 구현 확인 (GitHub 검색, Stack Overflow)
   - 보안 가이드라인 확인 (방화벽 룰, 시크릿 관리, OWASP 등)
   - **구현 후가 아닌 설계 단계에서 조사 수행**
4. **모호한 사항 즉시 질의 (추측 금지)** - 불확실한 사항은 구현 전 **반드시** 사용자에게 질문
   - **네이밍**: 리소스명, 변수명, 역할명이 애매할 때
   - **네트워크**: IP 할당, 서브넷, 방화벽 룰, 라우팅
   - **시크릿**: 어떤 값을 vault에 넣을지, 환경변수 vs 파일
   - **인프라 변경**: 기존 리소스 수정/삭제 시 영향 범위
   - **설정 값**: 기본값, 리소스 크기, 포트 번호 등
   - **AskUserQuestion 도구 적극 활용**
5. **경고 제거** - `tofu validate`, `ansible-lint`, `yamllint` 등에서 발생하는 warning, deprecated 경고 해결
6. **문서 동기화 (작업 중 + 종료 시 필수)** - 모든 작업 **과정 중 그리고 종료 시점에** CLAUDE.md, MEMORY.md, `docs/` 문서를 검토하고 실제 코드/인프라와 불일치가 있으면 사용자에게 질문 후 최신 정보로 업데이트
   - 아키텍처, 버전, 포트, IP, 디렉토리 구조, 컨벤션 등이 변경되었으면 즉시 업데이트
   - "불일치 발견 시"가 아니라 **매 작업 종료 시 능동적으로 검토**
   - 업데이트 대상: 소프트웨어 버전, 서비스 구성, 파이프라인 구조, 배포 방식, `docs/` 내 테이블/다이어그램 등 모든 사실 정보
   - 불확실한 사항은 사용자에게 질문 후 업데이트
