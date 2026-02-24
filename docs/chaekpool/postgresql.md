# PostgreSQL + pgAdmin (CT 210)

## 개요

PostgreSQL 16 데이터베이스 서버와 pgAdmin 4 웹 관리 도구.

- **IP**: 10.1.0.110
- **포트**: 5432 (PostgreSQL), 5050 (pgAdmin)
- **접속 URL**: `https://pgadmin.cp.codingmon.dev` (pgAdmin)

## 배포

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-postgresql
```

배포 단계:
1. PostgreSQL 패키지 설치 및 데이터 디렉토리 초기화 (`initdb`)
2. `pg_hba.conf` 배포 (클라이언트 인증 설정)
3. PostgreSQL OpenRC 서비스 배포
4. PostgreSQL 시작, 사용자(`chaekpool`) 및 데이터베이스(`chaekpool`) 생성
5. pgAdmin 4 설치 (Python virtualenv + pip)
6. pgAdmin OpenRC 서비스 배포 및 시작

## 설정

### PostgreSQL

**데이터 디렉토리**: `/var/lib/postgresql/16/data/`

**주요 설정** (`postgresql.conf`):
- `listen_addresses = '*'` - 모든 인터페이스에서 수신
- `port = 5432`

**클라이언트 인증** (`pg_hba.conf`):
```
local   all    postgres                    peer
local   all    all                         peer
host    all    all       127.0.0.1/32      scram-sha-256
host    all    all       ::1/128           scram-sha-256
host    chaekpool chaekpool 10.1.0.0/24    scram-sha-256
host    all    all       10.1.0.0/24       scram-sha-256
```

서비스 네트워크(`10.1.0.0/24`)에서 `scram-sha-256` 인증으로 접근 가능하다.

### 기본 데이터베이스

| 항목 | 값 |
|------|-----|
| 데이터베이스명 | `chaekpool` |
| 사용자 | `chaekpool` |
| 비밀번호 | `vault.yml`의 `vault_pg_password` |
| 인코딩 | UTF-8 |

### pgAdmin 4

**설치 경로**: `/opt/pgadmin4/venv/` (Python virtualenv)

**설정** (`/opt/pgadmin4/config_local.py`):
- `SERVER_MODE = True`
- `DEFAULT_SERVER = "0.0.0.0"` (모든 인터페이스 수신)
- `DEFAULT_SERVER_PORT = 5050`
- 데이터: `/var/lib/pgadmin/`
- 로그: `/var/log/pgadmin/pgadmin.log`

**관리자 계정**:
- 이메일: `admin@codingmon.dev` (`vars.yml`의 `pgadmin_email`)
- 비밀번호: `vault.yml`의 `vault_pgadmin_password`

> pgAdmin 4는 Alpine에서 pip으로 설치한다. 설치 시 `build-base`, `python3-dev`, `cargo`, `rust` 등 빌드 의존성이 필요하며, 설치 완료 후 자동으로 제거된다.

**OIDC 인증 (Authelia)**:

pgAdmin은 Authelia OIDC를 통한 SSO 로그인을 지원한다.

```python
AUTHENTICATION_SOURCES = ['oauth2', 'internal']  # OAuth2 우선, 내부 인증 폴백
OAUTH2_AUTO_CREATE_USER = True                    # 첫 OIDC 로그인 시 사용자 자동 생성
MASTER_PASSWORD_REQUIRED = False                  # 서비스 네트워크 trust 인증이므로 불필요
OAUTH2_CONFIG = [{
    'OAUTH2_NAME': 'authelia',
    'OAUTH2_DISPLAY_NAME': 'Authelia SSO',
    'OAUTH2_CLIENT_ID': 'pgadmin',
    'OAUTH2_CLIENT_SECRET': '<vault_authelia_oidc_pgadmin_secret>',
    'OAUTH2_TOKEN_URL': 'https://authelia.cp.codingmon.dev/api/oidc/token',
    'OAUTH2_AUTHORIZATION_URL': 'https://authelia.cp.codingmon.dev/api/oidc/authorization',
    'OAUTH2_USERINFO_ENDPOINT': 'https://authelia.cp.codingmon.dev/api/oidc/userinfo',
    'OAUTH2_SERVER_METADATA_URL': 'https://authelia.cp.codingmon.dev/.well-known/openid-configuration',
    'OAUTH2_SCOPE': 'openid email profile',
}]
```

- `AUTHENTICATION_SOURCES`에서 `oauth2`가 `internal`보다 앞에 있으므로 로그인 화면에서 OIDC가 기본 옵션으로 표시된다
- OIDC 클라이언트 시크릿은 `vault.yml`의 `vault_authelia_oidc_pgadmin_secret` (평문, Authelia 측은 PBKDF2 해시)
- 소스: `roles/postgresql/templates/pgadmin_config_local.py.j2`

**PostgreSQL 서버 자동 등록**:

pgAdmin 배포 시 `servers.json`으로 CP PostgreSQL 서버가 자동 등록된다.

```json
{
  "Servers": {
    "1": {
      "Name": "CP PostgreSQL",
      "Group": "Servers",
      "Host": "10.1.0.110",
      "Port": 5432,
      "MaintenanceDB": "chaekpool",
      "Username": "chaekpool",
      "SSLMode": "prefer",
      "Shared": true
    }
  }
}
```

- `Shared: true`로 설정되어 모든 pgAdmin 사용자가 별도 등록 없이 서버에 접근 가능
- Ansible이 `pgadmin setup load-servers` CLI로 pgAdmin DB에 주입
- 소스: `roles/postgresql/templates/pgadmin_servers.json.j2`

## 검증

```bash
# PostgreSQL 상태
ssh root@10.1.0.110 "rc-service postgresql status"

# DB 접속 테스트
ssh root@10.1.0.110 "su - postgres -s /bin/sh -c 'psql -c \"\\l\"'"

# pgAdmin 상태
ssh root@10.1.0.110 "rc-service pgadmin4 status"
```

pgAdmin 웹 UI: `https://pgadmin.cp.codingmon.dev`

## 운영

```bash
# PostgreSQL
ssh root@10.1.0.110 "rc-service postgresql start"
ssh root@10.1.0.110 "rc-service postgresql stop"
ssh root@10.1.0.110 "rc-service postgresql restart"

# pgAdmin
ssh root@10.1.0.110 "rc-service pgadmin4 start"
ssh root@10.1.0.110 "rc-service pgadmin4 stop"
ssh root@10.1.0.110 "rc-service pgadmin4 restart"

# PostgreSQL 로그
ssh root@10.1.0.110 "tail -f /var/lib/postgresql/16/data/log/*.log"

# pgAdmin 로그
ssh root@10.1.0.110 "tail -f /var/log/pgadmin/pgadmin.log"
```

## 트러블슈팅

**pgAdmin pip 설치 실패**
- 메모리 부족일 수 있음 (최소 2GB RAM 권장)
- `cargo`/`rust` 패키지가 설치되어 있는지 확인

**외부에서 DB 접속 불가**
- `pg_hba.conf`에 클라이언트 IP 대역이 허용되어 있는지 확인
- `listen_addresses = '*'` 설정 확인
- `rc-service postgresql status`로 서비스 상태 확인

**인증 실패**
- `vault.yml`의 `vault_pg_password`와 실제 DB 사용자 비밀번호 일치 확인
- `pg_hba.conf`의 인증 방식 확인 (`scram-sha-256`)

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/ansible/roles/postgresql/` | Ansible 역할 |
| `service/chaekpool/ansible/roles/postgresql/templates/pg_hba.conf.j2` | 클라이언트 인증 설정 |
| `service/chaekpool/ansible/roles/postgresql/templates/postgresql.openrc.j2` | PostgreSQL OpenRC 서비스 |
| `service/chaekpool/ansible/roles/postgresql/templates/pgadmin4.openrc.j2` | pgAdmin OpenRC 서비스 |
| `service/chaekpool/ansible/roles/postgresql/templates/pgadmin_config_local.py.j2` | pgAdmin 설정 (OIDC 포함) |
| `service/chaekpool/ansible/roles/postgresql/templates/pgadmin_servers.json.j2` | pgAdmin 서버 자동 등록 |
