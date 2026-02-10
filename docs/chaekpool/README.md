# Chaekpool 서비스 배포

Chaekpool 프로젝트의 서비스 계층. 7개의 Alpine 3.23 LXC 컨테이너로 구성되며, 모두 서비스 네트워크(vmbr2, `10.1.0.0/24`)에 위치한다.

> **전제 조건**: [인프라 배포](../infra-deployment.md)가 완료되어 있어야 한다.

## 컨테이너 구성

| VMID | 호스트명 | IP | 코어 | 메모리 | 디스크 | 역할 |
|------|---------|-----|------|--------|--------|------|
| 200 | cp-traefik | 10.1.0.100 | 1 | 512MB | 5GB | HTTP 리버스 프록시 |
| 201 | cp-authelia | 10.1.0.101 | 1 | 512MB | 5GB | SSO/OIDC (Authelia) |
| 210 | cp-postgresql | 10.1.0.110 | 2 | 2GB | 20GB | PostgreSQL + pgAdmin |
| 211 | cp-valkey | 10.1.0.111 | 1 | 1GB | 10GB | Valkey + Redis Commander |
| 220 | cp-monitoring | 10.1.0.120 | 4 | 4GB | 30GB | Prometheus/Grafana/Loki/Jaeger |
| 230 | cp-jenkins | 10.1.0.130 | 2 | 2GB | 20GB | Jenkins CI/CD |
| 240 | cp-kopring | 10.1.0.140 | 2 | 2GB | 10GB | Kopring Spring Boot |

## OpenTofu 적용

```bash
cd service/chaekpool/terraform
tofu init
tofu plan
tofu apply
```

`for_each` 패턴으로 `variables.tf`의 `containers` 맵에 정의된 7개 컨테이너를 일괄 생성한다. 모든 컨테이너는 unprivileged 모드로 생성된다.

## 배포 방법

### 전체 배포

```bash
bash service/chaekpool/scripts/deploy-all.sh
```

7개 서비스를 순서대로 배포한다.

### 개별 배포

```bash
bash service/chaekpool/scripts/traefik/deploy.sh
bash service/chaekpool/scripts/authelia/deploy.sh
bash service/chaekpool/scripts/postgresql/deploy.sh
bash service/chaekpool/scripts/valkey/deploy.sh
bash service/chaekpool/scripts/monitoring/deploy.sh
bash service/chaekpool/scripts/jenkins/deploy.sh
bash service/chaekpool/scripts/kopring/deploy.sh
```

## 배포 순서 의존관계

```
1. Traefik (200)     ← 먼저 (리버스 프록시)
2. Authelia (201)    ← 독립 (SSO/OIDC)
3. PostgreSQL (210)  ← Kopring 이전
4. Valkey (211)      ← Kopring 이전
5. Monitoring (220)  ← 독립
6. Jenkins (230)     ← 독립
7. Kopring (240)     ← 마지막 (PostgreSQL + Valkey 필수)
```

- **Traefik**을 먼저 배포해야 다른 서비스에 도메인으로 접근 가능
- **Authelia**는 Traefik과 독립적으로 배포 가능 (ForwardAuth/OIDC 사용 서비스보다 먼저 배포)
- **PostgreSQL**과 **Valkey**는 Kopring보다 먼저 배포해야 함
- **Monitoring**과 **Jenkins**는 독립적으로 언제든 배포 가능
- **Kopring**은 PostgreSQL과 Valkey가 실행 중이어야 정상 기동

## 공통 헬퍼 함수

`service/chaekpool/scripts/common.sh`에 정의된 3개의 핵심 함수:

### `pct_exec <CT_ID> <COMMAND>`

단일 명령을 컨테이너 내에서 실행한다.

```bash
# 예시: CT 210에서 PostgreSQL 상태 확인
pct_exec 210 "rc-service postgresql status"
```

동작: `ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec <CT_ID> -- sh -c '<COMMAND>'"`

### `pct_push <CT_ID> <LOCAL_PATH> <REMOTE_PATH>`

로컬 파일을 컨테이너로 전송한다. 2단계로 진행된다:
1. 로컬 → Proxmox 호스트 `/tmp/`
2. Proxmox `/tmp/` → 컨테이너 대상 경로

```bash
# 예시: 설정 파일 전송
pct_push 210 "./configs/pg_hba.conf" "/var/lib/postgresql/16/data/pg_hba.conf"
```

### `pct_script <CT_ID>`

heredoc으로 전달받은 다중 행 스크립트를 컨테이너 내에서 실행한다.

```bash
# 예시: 여러 명령어 실행
pct_script 210 <<'SCRIPT'
set -e
apk update
apk add --no-cache postgresql
SCRIPT
```

동작: `ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec <CT_ID> -- sh -s"` (stdin으로 스크립트 전달)

## 공통 트러블슈팅

### OpenTofu 관련

**API 토큰 인증 실패**
```
Error: 401 Unauthorized
```
- `terraform.tfvars`의 `proxmox_username`과 `proxmox_api_token` 확인
- 토큰 형식: `<API_TOKEN_ID>` (username), 토큰 값은 UUID 형태

**SSH Agent 미실행**
```
Error: SSH agent requested but not running
```
- bpg/proxmox provider는 `ssh { agent = true }` 설정이 기본
- `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519` 실행

**템플릿 미발견**
```
Error: unable to find template
```
- `pveam list local`로 설치된 템플릿 확인
- `variables.tf`의 `template_id` 기본값과 실제 파일명 일치 확인

### 네트워크 관련

**컨테이너에서 인터넷 접속 불가**
```bash
# 컨테이너 내에서 확인
pct_exec <CT_ID> "ping -c 3 8.8.8.8"
pct_exec <CT_ID> "cat /etc/resolv.conf"
```
- OPNsense NAT 규칙 확인 (OPT1 → WAN 아웃바운드 NAT)
- OPNsense 방화벽 규칙 확인 (OPT1 트래픽 허용)
- 게이트웨이 설정 확인 (`10.1.0.1`)

**DNS 해석 실패**
- 컨테이너 DNS가 `10.1.0.1` (OPNsense)을 가리키는지 확인
- OPNsense DNS 설정 확인 (Unbound 또는 DNS 포워딩)

### 서비스 관리 (OpenRC)

```bash
# 서비스 상태 확인
pct_exec <CT_ID> "rc-service <서비스명> status"

# 서비스 시작/중지/재시작
pct_exec <CT_ID> "rc-service <서비스명> start"
pct_exec <CT_ID> "rc-service <서비스명> stop"
pct_exec <CT_ID> "rc-service <서비스명> restart"

# 부팅 시 자동 시작 등록/해제
pct_exec <CT_ID> "rc-update add <서비스명>"
pct_exec <CT_ID> "rc-update del <서비스명>"

# 등록된 서비스 목록
pct_exec <CT_ID> "rc-update show"
```

## 서비스별 문서

| 서비스 | 문서 |
|--------|------|
| CP Traefik (CT 200) | [traefik.md](traefik.md) |
| Authelia (CT 201) | [authelia.md](authelia.md) |
| PostgreSQL + pgAdmin (CT 210) | [postgresql.md](postgresql.md) |
| Valkey + Redis Commander (CT 211) | [valkey.md](valkey.md) |
| Monitoring Stack (CT 220) | [monitoring.md](monitoring.md) |
| Jenkins (CT 230) | [jenkins.md](jenkins.md) |
| Kopring (CT 240) | [kopring.md](kopring.md) |

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/terraform/main.tf` | 컨테이너 리소스 정의 (`for_each`) |
| `service/chaekpool/terraform/variables.tf` | 컨테이너 스펙 (VMID, IP, 리소스) |
| `service/chaekpool/scripts/common.sh` | 공용 변수/함수 |
| `service/chaekpool/scripts/deploy-all.sh` | 전체 배포 오케스트레이터 |
