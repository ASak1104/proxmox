# PostgreSQL + pgAdmin (CT 210)

## 개요

PostgreSQL 16 데이터베이스 서버와 pgAdmin 4 웹 관리 도구.

- **IP**: 10.1.0.110
- **포트**: 5432 (PostgreSQL), 5050 (pgAdmin)
- **접속 URL**: `https://pgadmin.cp.codingmon.dev` (pgAdmin)

## 배포

```bash
bash service/chaekpool/scripts/postgresql/deploy.sh
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
| 비밀번호 | `common.sh`의 `PG_PASSWORD` |
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
- 이메일: `admin@codingmon.dev` (`common.sh`의 `PGADMIN_EMAIL`)
- 비밀번호: `common.sh`의 `PGADMIN_PASSWORD`

> pgAdmin 4는 Alpine에서 pip으로 설치한다. 설치 시 `build-base`, `python3-dev`, `cargo`, `rust` 등 빌드 의존성이 필요하며, 설치 완료 후 자동으로 제거된다.

## 검증

```bash
# PostgreSQL 상태
pct_exec 210 "rc-service postgresql status"

# DB 접속 테스트
pct_exec 210 "su - postgres -s /bin/sh -c 'psql -c \"\\l\"'"

# pgAdmin 상태
pct_exec 210 "rc-service pgadmin4 status"
```

pgAdmin 웹 UI: `https://pgadmin.cp.codingmon.dev`

## 운영

```bash
# PostgreSQL
pct_exec 210 "rc-service postgresql start"
pct_exec 210 "rc-service postgresql stop"
pct_exec 210 "rc-service postgresql restart"

# pgAdmin
pct_exec 210 "rc-service pgadmin4 start"
pct_exec 210 "rc-service pgadmin4 stop"
pct_exec 210 "rc-service pgadmin4 restart"

# PostgreSQL 로그
pct_exec 210 "tail -f /var/lib/postgresql/16/data/log/*.log"

# pgAdmin 로그
pct_exec 210 "tail -f /var/log/pgadmin/pgadmin.log"
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
- `common.sh`의 `PG_PASSWORD`와 실제 DB 사용자 비밀번호 일치 확인
- `pg_hba.conf`의 인증 방식 확인 (`scram-sha-256`)

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/scripts/postgresql/deploy.sh` | 배포 스크립트 |
| `service/chaekpool/scripts/postgresql/configs/pg_hba.conf` | 클라이언트 인증 설정 |
| `service/chaekpool/scripts/postgresql/configs/postgresql.openrc` | PostgreSQL OpenRC 서비스 |
| `service/chaekpool/scripts/postgresql/configs/pgadmin4.openrc` | pgAdmin OpenRC 서비스 |
