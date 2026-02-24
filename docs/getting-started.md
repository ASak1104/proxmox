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
4. 생성된 토큰 값을 `core/.core.env`에 기록

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

## 3. 시크릿 파일 설정

시크릿 파일은 `.gitignore`에 포함되어 있으므로 각 환경에서 `.template` 파일을 복사하여 생성한다.

```bash
# 코어 인프라 시크릿
cp core/.core.env.template core/.core.env
# 편집하여 Proxmox API 토큰, SSH 공개키 등 실제 값 입력

# Chaekpool 서비스 시크릿 (ansible-vault 암호화)
# vault 비밀번호 파일 생성
echo "your-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
# 시크릿 편집
ansible-vault edit service/chaekpool/ansible/group_vars/all/vault.yml
```

### terraform.tfvars 설정

각 디렉토리의 `terraform.tfvars.template`을 참조하여 `terraform.tfvars`를 생성한다. 실제 값은 `core/.core.env`에서 가져온다.

#### 인프라 계층 (`core/terraform/terraform.tfvars`)

```hcl
proxmox_endpoint  = "https://10.0.0.254:8006"
proxmox_username  = "<PROXMOX_USERNAME from core/.core.env>"
proxmox_api_token = "<PROXMOX_API_TOKEN from core/.core.env>"
node_name         = "pve"
ssh_public_key    = "<SSH_PUBLIC_KEY from core/.core.env>"
```

변수 정의는 `core/terraform/variables.tf`를 참조한다.

#### 서비스 계층 (`service/chaekpool/terraform/terraform.tfvars`)

```hcl
proxmox_endpoint  = "https://10.0.0.254:8006"
proxmox_username  = "<PROXMOX_USERNAME from core/.core.env>"
proxmox_api_token = "<PROXMOX_API_TOKEN from core/.core.env>"
node_name         = "pve"
ssh_public_key    = "<SSH_PUBLIC_KEY from core/.core.env>"
```

변수 정의는 `service/chaekpool/terraform/variables.tf`를 참조한다. 컨테이너 스펙(VMID, IP, 리소스)은 `variables.tf`의 `containers` 변수에 기본값이 설정되어 있다.

## 4. 비밀번호 변경

`service/chaekpool/ansible/group_vars/all/vault.yml`에서 서비스 비밀번호를 관리한다. `ansible-vault edit`으로 편집한다.

주요 변수:

| 변수 | 용도 |
|------|------|
| `PG_PASSWORD` | PostgreSQL 사용자 비밀번호 |
| `VALKEY_PASSWORD` | Valkey 인증 비밀번호 |
| `PGADMIN_PASSWORD` | pgAdmin 관리자 비밀번호 |
| `GRAFANA_ADMIN_PASSWORD` | Grafana 관리자 비밀번호 |
| `AUTHELIA_*` | Authelia 시크릿 (JWT, 세션, OIDC 등) |

비밀번호를 변경하면 관련 설정 파일도 함께 수정해야 한다:

- Ansible vault에서 비밀번호를 변경하면 `ansible-playbook site.yml`로 전체 재배포 시 자동 반영

## 5. 사전 요구사항 체크리스트

- [ ] Proxmox VE 설치 완료 (`https://<PROXMOX_EXTERNAL_IP>:8006` 접속 확인)
- [ ] 네트워크 브리지 3개 생성 (vmbr0, vmbr1, vmbr2)
- [ ] Alpine 3.23 LXC 템플릿 다운로드
- [ ] API 토큰 생성 (`Datacenter > Permissions > API Tokens`)
- [ ] OpenTofu >= 1.5.0 설치
- [ ] SSH 키 생성 및 Proxmox 호스트에 등록
- [ ] SSH Agent 실행 확인 (`ssh-add -l`)
- [ ] DNS 설정 (`*.codingmon.dev → <OPNSENSE_WAN_IP>`)
- [ ] `core/.core.env` 생성 (`.core.env.template`에서 복사)
- [ ] `~/.vault_pass` 생성 (ansible-vault 비밀번호)
- [ ] `core/terraform/terraform.tfvars` 생성 (`terraform.tfvars.template`에서 복사)
- [ ] `service/chaekpool/terraform/terraform.tfvars` 생성 (`terraform.tfvars.template`에서 복사)
- [ ] `vault.yml` 비밀번호 변경 (`ansible-vault edit`)

모든 항목을 확인한 후 [인프라 배포](infra-deployment.md)로 진행한다.
