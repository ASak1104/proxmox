# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenTofu + Bash script-based Proxmox homelab infrastructure automation. Two layers:
- **core/**: Foundation layer (OPNsense firewall VM with HAProxy for SSL termination and routing)
- **service/chaekpool/**: Service layer (7 Alpine 3.23 LXC containers on service network)

Documentation is in Korean. See `docs/README.md` for reading order.
For OPNsense HAProxy operations (troubleshooting, adding domains/certs, API automation), see `docs/opnsense-haproxy-operations-guide.md`.

## Commands

### OpenTofu (Infrastructure Provisioning)

```bash
# Infra layer: OPNsense VM (102)
cd core/terraform && tofu init && tofu plan && tofu apply

# Service layer: 7 LXC containers (200-240)
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

### Deploy Scripts

```bash
# Infra: OPNsense HAProxy configuration managed via Web UI
# See docs/opnsense-haproxy-operations-guide.md for details

# Services: all at once (respects dependency order)
bash service/chaekpool/scripts/deploy-all.sh

# Services: individual
bash service/chaekpool/scripts/traefik/deploy.sh
bash service/chaekpool/scripts/authelia/deploy.sh
bash service/chaekpool/scripts/postgresql/deploy.sh
bash service/chaekpool/scripts/valkey/deploy.sh
bash service/chaekpool/scripts/monitoring/deploy.sh
bash service/chaekpool/scripts/jenkins/deploy.sh
bash service/chaekpool/scripts/kopring/deploy.sh
```

Deploy order matters: (Traefik, Authelia independently) → PostgreSQL → Valkey → (Monitoring, Jenkins independently) → Kopring last (requires PostgreSQL + Valkey).

### Service Management (OpenRC on Alpine)

```bash
pct_exec <CT_ID> "rc-service <service> status|start|stop|restart"
pct_exec <CT_ID> "rc-update add|del <service>"
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

| VMID | Service | IP | Domain |
|------|---------|-----|--------|
| 200 | CP Traefik | 10.1.0.100 | — |
| 201 | Authelia | 10.1.0.101 | authelia.cp.codingmon.dev |
| 210 | PostgreSQL + pgAdmin | 10.1.0.110 | postgres.cp.codingmon.dev |
| 211 | Valkey + Redis Commander | 10.1.0.111 | redis.cp.codingmon.dev |
| 220 | Monitoring (Prometheus/Grafana/Loki/Jaeger) | 10.1.0.120 | {grafana,prometheus,jaeger}.cp.codingmon.dev |
| 230 | Jenkins | 10.1.0.130 | jenkins.cp.codingmon.dev |
| 240 | Kopring | 10.1.0.140 | api.cp.codingmon.dev |

## Key Conventions

### Deploy Script Pattern

All scripts use `set -euo pipefail`. Each service deploy script follows phases: package install → config deploy → service start. Scripts source `common.sh` for shared variables and three core SSH helper functions:

- `pct_exec <CT_ID> <CMD>`: Execute command in container via SSH → pct exec
- `pct_push <CT_ID> <LOCAL> <REMOTE>`: Transfer file (local → Proxmox /tmp → container)
- `pct_script <CT_ID> <<'SCRIPT'...SCRIPT`: Execute heredoc script in container via stdin

### OpenTofu Patterns

- bpg/proxmox provider with SSH agent auth (`ssh { agent = true }`)
- Chaekpool containers use `for_each` over a `containers` map variable in `variables.tf`
- Local state (no remote backend)
- Provider config is identical across both terraform directories

### OpenRC Service Files

All services use `supervise-daemon` with consistent structure: `command`, `command_args`, `command_user`, `pidfile`, `output_log`/`error_log`, and `depend()` block. Config files live in `scripts/<service>/configs/*.openrc`.

### Secrets Management

Secrets are managed through two env files (gitignored, create from `.template` files):

| File | Purpose |
|------|---------|
| `core/.core.env` | Proxmox API token, SSH public key |
| `service/chaekpool/.chaekpool.env` | Service passwords, Authelia secrets, OIDC client secrets |

Default passwords in `service/chaekpool/scripts/common.sh` are `changeme`. `.chaekpool.env`에서 override. When changing, sync across: `common.sh`, `valkey.conf` (requirepass), `application.yml` (spring datasource/redis), `grafana.ini` (admin_password).

### Adding a New Service

1. Add entry to `containers` map in `service/chaekpool/terraform/variables.tf`
2. `tofu apply` to create container
3. Create deploy script in `service/chaekpool/scripts/<service>/`
4. Add Traefik route in `service/chaekpool/scripts/traefik/configs/services.yml`
5. Managed Traefik wildcard (`*.cp.codingmon.dev`) auto-forwards — no change needed there
