# Kopring (CT 240)

## 개요

Kotlin + Spring Boot 애플리케이션. Git 저장소에서 소스를 클론하고 Gradle로 빌드 후 JAR로 실행한다.

- **IP**: 10.1.0.140
- **포트**: 8080
- **접속 URL**: `https://api.cp.codingmon.dev`
- **의존성**: PostgreSQL (CT 210) + Valkey (CT 211) 실행 필수

## 배포 전 준비

### GIT_REPO 변경 (필수)

`group_vars/all/vars.yml`의 `kopring_git_repo` 변수를 실제 저장소 URL로 변경해야 한다.

### 의존 서비스 확인

Kopring은 PostgreSQL과 Valkey에 연결하므로 두 서비스가 먼저 실행 중이어야 한다:

```bash
ssh root@10.1.0.110 "rc-service postgresql status"
ssh root@10.1.0.111 "rc-service valkey status"
```

## 배포

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-kopring
```

배포 단계:
1. OpenJDK 17, Git 설치
2. Git 저장소 클론 (또는 `git pull`로 업데이트)
3. Gradle wrapper로 `bootJar` 빌드 → `/opt/kopring/app.jar`
4. `application.yml` 및 OpenRC 서비스 배포
5. 서비스 시작

## 설정

### application.yml (`/opt/kopring/application.yml`)

```yaml
server:
  port: 8080

spring:
  datasource:
    url: jdbc:postgresql://10.1.0.110:5432/chaekpool
    username: chaekpool
    password: changeme
    driver-class-name: org.postgresql.Driver
    hikari:
      maximum-pool-size: 10
      minimum-idle: 5

  jpa:
    hibernate:
      ddl-auto: validate
    open-in-view: false

  data:
    redis:
      host: 10.1.0.111
      port: 6379
      password: changeme
```

- PostgreSQL: `10.1.0.110:5432` (CT 210)
- Valkey: `10.1.0.111:6379` (CT 211)
- 비밀번호는 `vault.yml`의 값과 동기화 필요

### 디렉토리 구조

| 경로 | 용도 |
|------|------|
| `/opt/kopring/src/` | Git 소스 코드 |
| `/opt/kopring/app.jar` | 빌드된 JAR |
| `/opt/kopring/application.yml` | 외부 설정 |

## 검증

```bash
# 서비스 상태
ssh root@10.1.0.140 "rc-service kopring status"

# 헬스체크
curl -s http://10.1.0.140:8080/actuator/health

# Prometheus 메트릭 확인
curl -s http://10.1.0.140:8080/actuator/prometheus | head -20
```

웹 UI: `https://api.cp.codingmon.dev`

## 운영

```bash
ssh root@10.1.0.140 "rc-service kopring start"
ssh root@10.1.0.140 "rc-service kopring stop"
ssh root@10.1.0.140 "rc-service kopring restart"
```

### 재빌드 및 재배포

소스 코드가 변경된 경우 Ansible 배포를 다시 실행하면 `git pull` → `gradlew bootJar` → JAR 교체 → 서비스 재시작이 수행된다.

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-kopring
```

## 트러블슈팅

**빌드 실패**
- `GIT_REPO`가 올바른 URL인지 확인
- 인터넷 연결 확인 (Gradle 의존성 다운로드 필요)
- 메모리 부족 시 Gradle 빌드 실패 가능 (최소 2GB RAM 권장)

**시작 시 DB 연결 실패**
```
Connection refused: 10.1.0.110:5432
```
- PostgreSQL(CT 210)이 실행 중인지 확인
- `application.yml`의 `spring.datasource.url`, 사용자/비밀번호 확인
- `pg_hba.conf`에서 `10.1.0.140` (Kopring IP) 접근이 허용되어 있는지 확인

**Valkey 연결 실패**
```
Unable to connect to Redis: 10.1.0.111:6379
```
- Valkey(CT 211)가 실행 중인지 확인
- `application.yml`의 `spring.data.redis.password`와 Valkey의 `requirepass` 일치 확인

**JAR 파일 없음**
```
ERROR: No JAR found
```
- Gradle 빌드 로그 확인
- `/opt/kopring/src/build/libs/` 디렉토리에 JAR가 생성되었는지 확인
- `-plain.jar`는 제외되므로 `bootJar` 태스크가 성공했는지 확인

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/ansible/roles/kopring/` | Ansible 역할 |
| `service/chaekpool/ansible/roles/kopring/templates/application.yml.j2` | Spring Boot 설정 |
| `service/chaekpool/ansible/roles/kopring/templates/kopring.openrc.j2` | OpenRC 서비스 파일 |
