# API (CT 240)

## 개요

Kotlin + Spring Boot 애플리케이션. Jenkins 파이프라인을 통해 빌드 및 배포되며, OpenJDK 25 JRE에서 실행된다.

- **IP**: 10.1.0.140
- **포트**: 8080
- **접속 URL**: `https://api.cp.codingmon.dev`
- **의존성**: PostgreSQL (CT 210) + Valkey (CT 211) 실행 필수

## Ansible 배포 (인프라 설정)

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-api
```

배포 단계:
1. OpenJDK 25 JRE 설치
2. `api` 시스템 사용자 생성 + 디렉토리 구조
3. Jenkins deploy SSH 공개키 배포 (`/root/.ssh/authorized_keys`)
4. Wrapper 스크립트 배포 (`/opt/api/api-wrapper.sh`)
5. OpenRC 서비스 등록 (enable만, start 안 함 — 첫 배포 시 JAR 없음)

### 주의사항

- **첫 배포 시**: JAR 파일이 없으므로 서비스가 시작되지 않음. Jenkins 파이프라인 실행 후 정상 동작
- **환경변수 관리**: Jenkins Secret file credential (`api-env`)에서 관리. 변경 시 Jenkins UI → Credentials에서 수정 후 파이프라인 재실행

## 애플리케이션 배포 (Jenkins 파이프라인)

JAR 배포는 Jenkins 파이프라인이 수행한다. 상세 내용: [jenkins-pipeline.md](jenkins-pipeline.md)

```
Jenkins (CT 230) → SSH (root@10.1.0.140) → JAR 업로드 → 서비스 재시작 → 헬스체크
```

## 설정

### 디렉토리 구조

| 경로 | 용도 |
|------|------|
| `/opt/api/api.jar` | 애플리케이션 JAR |
| `/opt/api/api-wrapper.sh` | JVM wrapper 스크립트 |
| `/etc/api/.env` | 환경변수 (DB, 캐시, OAuth 등) — Jenkins credential에서 배포 |
| `/var/lib/api/` | 애플리케이션 홈 |
| `/var/log/api/api.log` | 로그 |

### 환경변수 (`/etc/api/.env`)

> **시크릿 관리**: Jenkins UI → Manage Jenkins → Credentials → `api-env`에서 직접 수정 가능.
> 수정 후 파이프라인을 재실행하면 변경된 환경변수가 서버에 배포된다.
>
> **주의**: `ansible-playbook site.yml -l cp-jenkins` 재실행 시 JCasC가 `vault.yml` 값으로 credential을 덮어쓴다.
> Jenkins UI에서 수정한 값을 유지하려면 `vault.yml`도 동기화해야 한다.

| 변수 | 설명 |
|------|------|
| `SPRING_PROFILES_ACTIVE` | 프로파일 (`dev`) |
| `SERVER_PORT` | 서버 포트 (8080) |
| `POSTGRES_HOST/PORT/DB/USER/PASSWORD` | PostgreSQL 연결 |
| `CACHE_HOST/PORT/PASSWORD` | Valkey 연결 |
| `JWT_SECRET`, `CRYPTO_SECRET_KEY` | 인증 시크릿 |
| `KAKAO_CLIENT_ID/SECRET/REDIRECT_URI` | OAuth (Kakao) |
| `CORS_ALLOWED_ORIGINS` | CORS 허용 도메인 |
| `LOKI_URL`, `OTLP_ENDPOINT` | Observability |

## 검증

```bash
# 서비스 상태
ssh root@10.1.0.140 "rc-service api status"

# 헬스체크
curl -s http://10.1.0.140:8080/actuator/health

# Prometheus 메트릭 확인
curl -s http://10.1.0.140:8080/actuator/prometheus | head -20
```

웹 UI: `https://api.cp.codingmon.dev`

## 운영

```bash
ssh root@10.1.0.140 "rc-service api start"
ssh root@10.1.0.140 "rc-service api stop"
ssh root@10.1.0.140 "rc-service api restart"

# 로그 확인
ssh root@10.1.0.140 "tail -f /var/log/api/api.log"
```

## 트러블슈팅

**시작 시 DB 연결 실패**
```
Connection refused: 10.1.0.110:5432
```
- PostgreSQL(CT 210)이 실행 중인지 확인
- `/etc/api/.env`의 DB 관련 환경변수 확인
- `pg_hba.conf`에서 `10.1.0.140` (API IP) 접근이 허용되어 있는지 확인

**Valkey 연결 실패**
```
Unable to connect to Redis: 10.1.0.111:6379
```
- Valkey(CT 211)가 실행 중인지 확인
- `.env`의 `CACHE_PASSWORD`와 Valkey의 `requirepass` 일치 확인

**JAR 파일 없음 (첫 배포)**
- Ansible 배포는 인프라 설정만 수행. JAR은 Jenkins 파이프라인이 배포
- Jenkins에서 chaekpool-api 파이프라인 실행 필요

**서비스 시작 실패 (wrapper 오류)**
```bash
ssh root@10.1.0.140 "cat /opt/api/api-wrapper.sh"
ssh root@10.1.0.140 "java -version"
```
- Java 25 JRE 경로 확인: `/usr/lib/jvm/java-25-openjdk/bin/java`

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/ansible/roles/api/` | Ansible 역할 |
| `service/chaekpool/ansible/roles/api/templates/api-wrapper.sh.j2` | JVM wrapper |
| `service/chaekpool/ansible/roles/api/files/api.openrc` | OpenRC 서비스 파일 |
| `service/chaekpool/ansible/roles/jenkins/templates/casc.yaml.j2` | JCasC (api-env credential) |
