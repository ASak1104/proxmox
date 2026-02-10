# 사전 요구사항 및 초기 설정

이 문서는 프로젝트를 처음 시작할 때 필요한 모든 준비 사항을 다룬다.

## 1. Proxmox 호스트 준비

### Proxmox VE 설치

Proxmox VE를 설치한다. 설치 후 웹 UI는 `https://<PROXMOX_EXTERNAL_IP>:8006`에서 접근 가능하다.

> **참고**: 초기 설치 시에는 External IP로 접근한다. VPN 설정 후에는 Management IP (`<PROXMOX_HOST>`)로 접근한다. VPN 설정은 [vpn-setup.md](vpn-setup.md) 참조.

### 네트워크 브리지 생성

Proxmox 호스트에 3개의 네트워크 브리지를 생성한다:

| 브리지 | 용도 | 서브넷 |
|-------|------|--------|
| vmbr0 | 외부 네트워크 (WAN) | <EXTERNAL_SUBNET> |
| vmbr1 | 관리 네트워크 | 10.0.0.0/24 |
| vmbr2 | 서비스 네트워크 | 10.1.0.0/24 |

Proxmox 웹 UI > 노드 > Network에서 생성하거나 `/etc/network/interfaces`를 직접 편집한다.

### LXC 템플릿 다운로드

```bash
# Proxmox 호스트에서 실행
pveam update
pveam download local alpine-3.23-default_20260116_amd64.tar.xz
```

템플릿이 `local:vztmpl/alpine-3.23-default_20260116_amd64.tar.xz` 경로에 있어야 한다. 파일명이 다를 경우 `terraform.tfvars`의 `template_id` 값을 수정한다.

### API 토큰 생성

Proxmox 웹 UI에서 API 토큰을 생성한다:
1. `Datacenter > Permissions > API Tokens` → Add
2. User: `admin@pam`, Token ID: 원하는 이름
3. **Privilege Separation** 체크 해제 (사용자와 동일 권한)
4. 생성된 토큰 값을 `secrets.env`에 기록

## 2. 로컬 개발 머신 설정

### OpenTofu 설치

OpenTofu >= 1.5.0이 필요하다.

```bash
# macOS (Homebrew)
brew install opentofu
tofu version
```

### SSH 키 생성 및 등록

```bash
# 키 생성 (없는 경우)
ssh-keygen -t ed25519 -C "your-email@example.com"

# Proxmox 호스트에 공개키 등록 (초기 설치 시 External IP 사용)
ssh-copy-id <PROXMOX_USER>@<PROXMOX_EXTERNAL_IP>
# VPN 설정 후에는 <PROXMOX_USER>@<PROXMOX_HOST>로 접근
```

### SSH Agent 실행

bpg/proxmox provider는 SSH Agent를 통한 인증이 필수이다. OpenTofu 실행 전 반드시 SSH Agent가 활성화되어 있어야 한다.

```bash
# SSH Agent 확인
ssh-add -l

# Agent가 실행 중이 아니면
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

### DNS 설정

`*.codingmon.dev` 도메인이 OPNsense 외부 IP(`<OPNSENSE_WAN_IP>`)를 가리키도록 DNS를 설정한다. 실제 환경에서는 공인 IP에 대한 A 레코드를 등록한다.

## 3. terraform.tfvars 설정

`terraform.tfvars`는 `.gitignore`에 포함되어 있으므로 각 환경에서 직접 생성해야 한다.

각 디렉토리의 `terraform.tfvars.example`을 참조하여 `terraform.tfvars`를 생성한다. 실제 값은 `secrets.env`에서 가져온다.

### 인프라 계층 (`core/terraform/terraform.tfvars`)

```hcl
proxmox_endpoint  = "https://10.0.0.254:8006"
proxmox_username  = "<PROXMOX_USERNAME from secrets.env>"
proxmox_api_token = "<PROXMOX_API_TOKEN from secrets.env>"
node_name         = "pve"
ssh_public_key    = "<SSH_PUBLIC_KEY from secrets.env>"
```

변수 정의는 `core/terraform/variables.tf`를 참조한다.

### 서비스 계층 (`service/chaekpool/terraform/terraform.tfvars`)

```hcl
proxmox_endpoint  = "https://10.0.0.254:8006"
proxmox_username  = "<PROXMOX_USERNAME from secrets.env>"
proxmox_api_token = "<PROXMOX_API_TOKEN from secrets.env>"
node_name         = "pve"
ssh_public_key    = "<SSH_PUBLIC_KEY from secrets.env>"
```

변수 정의는 `service/chaekpool/terraform/variables.tf`를 참조한다. 컨테이너 스펙(VMID, IP, 리소스)은 `variables.tf`의 `containers` 변수에 기본값이 설정되어 있다.

## 4. 비밀번호 변경

`service/chaekpool/scripts/common.sh`에 기본 비밀번호가 `changeme`로 설정되어 있다. **배포 전에 반드시 변경한다.**

변경 대상:

| 변수 | 용도 | 위치 |
|------|------|------|
| `PG_PASSWORD` | PostgreSQL 사용자 비밀번호 | `common.sh:46` |
| `VALKEY_PASSWORD` | Valkey 인증 비밀번호 | `common.sh:47` |
| `PGADMIN_PASSWORD` | pgAdmin 관리자 비밀번호 | `common.sh:51` |

비밀번호를 변경하면 관련 설정 파일도 함께 수정해야 한다:

- `service/chaekpool/scripts/valkey/configs/valkey.conf` - `requirepass` 항목
- `service/chaekpool/scripts/kopring/configs/application.yml` - `spring.datasource.password`, `spring.data.redis.password`
- `service/chaekpool/scripts/monitoring/configs/grafana.ini` - `admin_password` (Grafana는 별도 비밀번호)

## 5. 사전 요구사항 체크리스트

- [ ] Proxmox VE 설치 완료 (`https://<PROXMOX_EXTERNAL_IP>:8006` 접속 확인)
- [ ] 네트워크 브리지 3개 생성 (vmbr0, vmbr1, vmbr2)
- [ ] Alpine 3.23 LXC 템플릿 다운로드
- [ ] API 토큰 생성 (`Datacenter > Permissions > API Tokens`)
- [ ] OpenTofu >= 1.5.0 설치
- [ ] SSH 키 생성 및 Proxmox 호스트에 등록
- [ ] SSH Agent 실행 확인 (`ssh-add -l`)
- [ ] DNS 설정 (`*.codingmon.dev → <OPNSENSE_WAN_IP>`)
- [ ] `core/terraform/terraform.tfvars` 생성
- [ ] `service/chaekpool/terraform/terraform.tfvars` 생성
- [ ] `common.sh` 비밀번호 변경 (`changeme` → 실제 비밀번호)
- [ ] 관련 설정 파일 비밀번호 동기화

모든 항목을 확인한 후 [인프라 배포](infra-deployment.md)로 진행한다.
