# Jenkins Pipeline (chaekpool-api)

## 아키텍처

```
[GitHub Push (main)] → [Jenkins Webhook] → [Docker Agent: gradle:jdk25-alpine]
                                                    │
                                    ┌───────────────┼───────────────┐
                                    ▼               ▼               ▼
                                 Build           Test           Deploy
                              (bootJar)     (test + JUnit)   (SSH → CT 240)
```

- **빌드 환경**: Docker 컨테이너 (`gradle:jdk25-alpine`, `-u 104:106 --group-add 104 -e HOME=/home/gradle` 실행 — 호스트 `jenkins-agent` UID 일치)
- **캐시**: 호스트 디렉토리 `/var/lib/jenkins-agent/.gradle` → `/home/gradle/.gradle` 마운트
- **배포**: SSH agent (`api-deploy-ssh` credential) → SCP + 원격 스크립트

## 파이프라인 스테이지

### 1. Build
- `.gradle` → `/home/gradle/.gradle/chaekpool-api` 심볼릭 링크 (Gradle 캐시 + Configuration Cache 보존)
- `./gradlew assemble --no-daemon`
- Fat JAR 생성 (`build/libs/chaekpool-*.jar`)

### 2. Test
- `./gradlew cleanTest test --no-daemon`
- JUnit 결과 수집 (`**/build/test-results/test/*.xml`)
- Testcontainers: Docker socket 마운트 (`/var/run/docker.sock`)

### 3. Deploy
- `withCredentials([file(...)])`: `api-env` credential → 임시 파일 경로를 `API_ENV_FILE` 환경변수로 전달
- `ci/deploy.sh` 스크립트 실행:
  1. `build/libs/chaekpool-*.jar` → SCP → `/opt/api/api.jar.new`
  2. `$API_ENV_FILE` → SCP → `/etc/api/.env` (권한 0600, api:api)
  3. `rc-service api stop`
  4. 기존 JAR 백업 (`.bak`)
  5. Atomic swap (`mv .new → .jar`)
  6. `rc-service api start`
  7. 헬스체크 (10회, 6초 간격, `/actuator/health`)
  8. 실패 시 자동 롤백

## 사전 준비

### 1. SSH 키쌍 생성

```bash
ssh-keygen -t ed25519 -f jenkins-deploy-key -C "jenkins-deploy@cp"
```

### 2. vault.yml에 시크릿 추가

```bash
cd service/chaekpool/ansible
ansible-vault edit group_vars/all/vault.yml
```

추가할 변수:
```yaml
# API 서비스 시크릿
vault_api_jwt_secret: "<JWT 시크릿>"
vault_api_crypto_secret_key: "<암호화 키>"
vault_api_kakao_client_id: "<카카오 클라이언트 ID>"
vault_api_kakao_client_secret: "<카카오 클라이언트 시크릿>"

# Jenkins deploy SSH 키
vault_jenkins_deploy_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  <개인키 내용>
  -----END OPENSSH PRIVATE KEY-----
vault_jenkins_deploy_public_key: "ssh-ed25519 AAAA... jenkins-deploy@cp"
```

### 3. Ansible 배포

```bash
# API 인프라 (Java, 사용자, SSH키, 환경변수, OpenRC)
ansible-playbook site.yml -l cp-api

# Jenkins (플러그인 + JCasC credential)
ansible-playbook site.yml -l cp-jenkins
```

### 4. Jenkins Pipeline Job 생성

Jenkins UI (`https://jenkins.cp.codingmon.dev`)에서:
1. **New Item** → Pipeline → "chaekpool-api"
2. **Pipeline** → Definition: "Pipeline script from SCM"
3. **SCM**: Git → Repository URL: `https://github.com/<org>/chaekpool-api.git`
4. **Branch Specifier**: `*/main`
5. **Script Path**: `Jenkinsfile`

## 시크릿 관리

| 시크릿 | 저장 위치 | 용도 |
|--------|-----------|------|
| `vault_jenkins_deploy_private_key` | vault.yml → JCasC | Jenkins → API SSH 배포 |
| `vault_jenkins_deploy_public_key` | vault.yml → authorized_keys | API 서버 SSH 접근 허용 |
| `api-env` | vault.yml → JCasC → Jenkins Secret file | API 환경변수 (.env 전체) |

### 시크릿 흐름

```
vault.yml → Ansible → casc.yaml → Jenkins Secret file credential (api-env)
                                        │
                                        ▼
                              Jenkins Pipeline (withCredentials)
                                        │
                                        ▼
                              deploy.sh → SCP → /etc/api/.env (CT 240)
```

### 환경변수 변경 방법

1. Jenkins UI → Manage Jenkins → Credentials → `api-env` → Update
2. `.env` 파일 내용 수정 후 저장
3. chaekpool-api 파이프라인 재실행 → 변경된 `.env`가 서버에 배포됨

> **주의**: `ansible-playbook site.yml -l cp-jenkins` 재실행 시 JCasC가 `vault.yml` 값으로 credential을 덮어쓴다.
> Jenkins UI에서 수정한 값을 유지하려면 `vault.yml`도 동기화해야 한다.

## 트러블슈팅

**Pipeline 실행 안 됨 (executor 부족)**
- Controller `numExecutors: 0`은 정상 (빌드는 agent에서 실행)
- `docker-agent` 노드가 온라인 상태인지 확인: Jenkins UI → Manage Jenkins → Nodes

**Docker agent 시작 실패**
```bash
ssh root@10.1.0.130 "docker ps -a"
ssh root@10.1.0.130 "docker images | grep gradle"
```
- Docker 서비스 실행 확인: `rc-service docker status`
- Jenkins 사용자가 docker 그룹에 있는지 확인: `id jenkins`

**Gradle 빌드 느림 (캐시 없음)**
```bash
ssh root@10.1.0.130 "ls -la /var/lib/jenkins-agent/.gradle/"
```
- 호스트 Gradle 캐시 디렉토리가 존재하고 `jenkins-agent:jenkins-agent` 소유인지 확인
- Ansible이 자동 생성 (`ansible-playbook site.yml -l cp-jenkins`)

**워크스페이스 정리 실패 (`Operation not permitted`)**
- 증상: git checkout 단계에서 `Files.setPosixFilePermissions ... EPERM` → "Maximum checkout retry attempts reached"
- 원인: 컨테이너가 호스트 `jenkins-agent` UID(104)와 다른 UID로 실행 → 워크스페이스 산출물이 타 사용자 소유로 남음
- 확인: `ssh root@10.1.0.130 "find /var/lib/jenkins-agent/workspace -not -user jenkins-agent | head"`
- 일회성 복구: `ssh root@10.1.0.130 "chown -R jenkins-agent:jenkins-agent /var/lib/jenkins-agent/workspace"`
- 항구 대책: `ci/Jenkinsfile`의 docker agent `args`에 `-u 104:106 --group-add 104 -e HOME=/home/gradle` 유지

**Gradle wrapper `Could not create parent directory for lock file /.gradle/...`**
- 원인: 컨테이너 `/etc/passwd`에 UID 104 entry가 없어 `$HOME`이 `/`로 fallback → wrapper가 `/.gradle/wrapper/...`에 락 파일 생성 실패
- 해결: docker `args`에 `-e HOME=/home/gradle` 명시 (이미 적용됨)

**Deploy SSH 연결 실패**
```
Permission denied (publickey)
```
- API 서버 authorized_keys 확인: `ssh root@10.1.0.140 "cat /root/.ssh/authorized_keys"`
- JCasC credential 확인: Jenkins UI → Manage Jenkins → Credentials
- 키쌍 일치 확인 (공개키 ↔ 개인키)

**헬스체크 실패 (롤백 발생)**
- 로그 확인: `ssh root@10.1.0.140 "tail -50 /var/log/api/api.log"`
- 환경변수 확인: `ssh root@10.1.0.140 "cat /etc/api/.env"`
- 의존 서비스 확인: PostgreSQL(CT 210), Valkey(CT 211) 실행 상태

## 참조 파일

| 파일 | 위치 | 설명 |
|------|------|------|
| `Jenkinsfile` | chaekpool-api 프로젝트 | 파이프라인 정의 |
| `ci/deploy.sh` | chaekpool-api 프로젝트 | 배포 스크립트 |
| `roles/api/` | proxmox 프로젝트 | API 인프라 Ansible 역할 |
| `roles/jenkins/templates/casc.yaml.j2` | proxmox 프로젝트 | JCasC (credential, views) |
