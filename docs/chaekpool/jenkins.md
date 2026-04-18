# Jenkins (CT 230)

## 개요

Jenkins CI/CD 서버. WAR 파일로 배포되며 OpenJDK 21에서 실행된다.

- **IP**: 10.1.0.130
- **포트**: 8080
- **Jenkins 버전**: 2.541.2
- **접속 URL**: `https://jenkins.cp.codingmon.dev`

## 배포

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-jenkins
```

배포 단계 (7단계):
1. OpenJDK 21 **전체 버전**, 폰트 패키지 설치, `jenkins` 시스템 사용자 생성
2. Jenkins WAR v2.541.2 다운로드 → `/opt/jenkins/jenkins.war`
3. 13개 플러그인 사전 설치 (jenkins-plugin-manager):
   - `oic-auth`, `configuration-as-code`
   - `workflow-aggregator`, `docker-workflow`, `git`
   - `credentials-binding`, `ssh-agent`
   - `pipeline-stage-view`, `timestamper`
   - `job-dsl`, `junit`, `ws-cleanup`, `ssh-slaves`
4. JCasC 설정 Jinja2 템플릿 렌더링 (vault 시크릿 자동 주입) 및 Wrapper 스크립트 배포
5. `jenkins-agent` 시스템 사용자 생성, SSH 키 생성 및 배포
6. Gradle 캐시 호스트 디렉토리 생성 (`/var/lib/jenkins-agent/.gradle`, `jenkins-agent` 소유)
7. OpenRC 서비스 배포, 시작 및 부팅 시 자동 시작 등록

### 주요 패키지

- **openjdk21**: 전체 JDK 패키지 (`openjdk21-jre-headless` 불가)
  - `jre-headless`는 `fontmanager` 라이브러리가 없어 Jenkins 초기화 실패
  - 전체 패키지는 GUI 라이브러리 포함 (X11, AWT 등)
- **fontconfig, freetype, ttf-dejavu**: 폰트 렌더링 지원

### Wrapper 스크립트

`supervise-daemon`은 OpenRC 파일의 `export` 명령을 지원하지 않음. 환경 변수 설정을 위해 wrapper 스크립트 사용:

**`/opt/jenkins/jenkins-wrapper.sh`**:
```sh
#!/bin/sh
export JENKINS_HOME="/var/lib/jenkins"
export JAVA_HOME="/usr/lib/jvm/java-21-openjdk"
export CASC_JENKINS_CONFIG="/var/lib/jenkins/casc.yaml"
cd "$JENKINS_HOME"
exec /usr/bin/java -Xmx1024m \
    -Djava.awt.headless=true \
    -Duser.timezone=Asia/Seoul \
    -Djenkins.install.runSetupWizard=false \
    -Djenkins.security.csp.CspHeader.headerName=Content-Security-Policy \
    -jar /opt/jenkins/jenkins.war --httpPort=8080
```

- `CASC_JENKINS_CONFIG`: JCasC 설정 파일 경로
- `-Djenkins.install.runSetupWizard=false`: 초기 설정 마법사 비활성화 (JCasC가 대체)
- OpenRC는 이 wrapper를 `command`로 호출함

## 설정

### 디렉토리 구조

| 경로 | 용도 |
|------|------|
| `/opt/jenkins/jenkins.war` | Jenkins WAR 파일 |
| `/opt/jenkins/jenkins-wrapper.sh` | 환경 변수 설정 wrapper |
| `/var/lib/jenkins/` | JENKINS_HOME (데이터, 플러그인, 작업) |
| `/var/lib/jenkins-agent/.gradle/` | Docker Pipeline Gradle 캐시 (호스트 마운트, `jenkins-agent` 소유) |
| `/var/lib/jenkins/casc.yaml` | JCasC 설정 (OIDC, Agent, Credentials, Job DSL) |
| `/var/lib/jenkins/plugins/` | 사전 설치된 플러그인 |
| `/var/lib/jenkins-agent/` | jenkins-agent 홈 (SSH permanent agent) |
| `/var/log/jenkins/` | 로그 |

### OIDC 인증 (Authelia)

Jenkins는 Authelia를 OIDC Provider로 사용하여 SSO 로그인을 수행한다. `oic-auth` 플러그인과 JCasC(`configuration-as-code`)로 구성된다.

**JCasC 설정** (`/var/lib/jenkins/casc.yaml`):
```yaml
jenkins:
  securityRealm:
    oic:
      clientId: "jenkins"
      clientSecret: "..."    # Ansible vault에서 주입
      serverConfiguration:
        wellKnown:
          wellKnownOpenIDConfigurationUrl: "https://authelia.cp.codingmon.dev/.well-known/openid-configuration"
      userNameField: "preferred_username"
      fullNameFieldName: "name"
      emailFieldName: "email"
      groupsFieldName: "groups"
      logoutFromOpenidProvider: true
      postLogoutRedirectUrl: "https://jenkins.cp.codingmon.dev/"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
```

**주의사항**:
- oic-auth 플러그인은 PKCE를 지원하지 않음 → Authelia에서 `require_pkce: false`
- oic-auth는 Authelia의 `scopes_supported`에 나열된 **모든 스코프**를 자동 요청 → Authelia 클라이언트 설정에 7개 스코프 모두 허용 필요
- `serverConfiguration.wellKnown`은 중첩 구조여야 함 (최상위에 `wellKnownOpenIDConfigurationUrl`을 쓰면 JCasC 파싱 실패)

OIDC 상세 설정 및 트러블슈팅: [authelia.md](authelia.md) 참조

## 검증

```bash
# 서비스 상태
ssh root@10.1.0.130 "rc-service jenkins status"

# HTTP 응답 확인
curl -s -o /dev/null -w "%{http_code}" http://10.1.0.130:8080/
```

웹 UI: `https://jenkins.cp.codingmon.dev`

## 운영

```bash
ssh root@10.1.0.130 "rc-service jenkins start"
ssh root@10.1.0.130 "rc-service jenkins stop"
ssh root@10.1.0.130 "rc-service jenkins restart"

# 로그 확인
ssh root@10.1.0.130 "tail -f /var/log/jenkins/jenkins.log"
```

## 트러블슈팅

**Jenkins 시작 느림**
- 첫 기동 시 **60초 이상** 소요 (WAR 압축 해제 + 초기화)
- 완전한 초기화까지 1~2분 대기 필요
- 메모리 부족 시 wrapper 스크립트에서 `-Xmx` 값 조정

**"Jenkins.instance is missing" 오류**
- 원인: `JENKINS_HOME` 환경 변수 미설정
- 해결: wrapper 스크립트가 올바르게 배포되었는지 확인
- 확인: `ssh root@10.1.0.130 "cat /opt/jenkins/jenkins-wrapper.sh | grep JENKINS_HOME"`

**"no fontmanager in system library path" 오류**
- 원인: `openjdk21-jre-headless` 사용 (GUI 라이브러리 없음)
- 해결: `openjdk21` 전체 패키지 설치 필요
- 확인: `ssh root@10.1.0.130 "apk list --installed | grep openjdk21"`

**포트 충돌**
- API(CT 240)도 8080 포트를 사용하지만 서로 다른 컨테이너이므로 충돌 없음

**플러그인 설치 실패**
- 인터넷 연결 확인: `ssh root@10.1.0.130 "wget -q -O /dev/null https://updates.jenkins.io/"`
- DNS 해석 확인: `ssh root@10.1.0.130 "nslookup updates.jenkins.io"`

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/ansible/roles/jenkins/` | Ansible 역할 |
| `service/chaekpool/ansible/roles/jenkins/templates/casc.yaml.j2` | JCasC 설정 (OIDC, Agent, Credentials, Job DSL) |
| `service/chaekpool/ansible/roles/jenkins/templates/jenkins.openrc.j2` | OpenRC 서비스 파일 |
| `service/chaekpool/ansible/roles/jenkins/templates/jenkins-wrapper.sh.j2` | 환경 변수 설정 wrapper |

## Pipeline & Docker Agent

Jenkins는 Controller + SSH Agent 아키텍처로 Docker 컨테이너 기반 빌드를 수행한다.

### 아키텍처

- **Controller** (`numExecutors: 0`): 빌드를 직접 실행하지 않고 오케스트레이션만 담당
- **`docker-agent`** (SSH permanent agent, `numExecutors: 2`): localhost SSH 접속, 실제 빌드 실행
  - `jenkins-agent` 시스템 사용자 (`password: "*"` 필수 — `!`는 sshd에서 account locked 거부)
  - `remoteFS: /var/lib/jenkins-agent`, docker 그룹 소속
  - `ssh-slaves` 플러그인 필요
- **Docker**: Jenkins VM에 설치된 Docker (Testcontainers + Docker Pipeline)
- **Gradle 캐시**: 호스트 디렉토리 `/var/lib/jenkins-agent/.gradle` (UID 104:106) → Docker 컨테이너 `/home/gradle/.gradle` 마운트. 컨테이너는 `-u 104:106 --group-add 104 -e HOME=/home/gradle`로 실행되어 호스트 권한과 일치하고 wrapper도 마운트된 캐시를 사용 (root 소유 산출물로 인한 워크스페이스 정리 실패 방지)

### Credentials (JCasC)

| ID | 유형 | 용도 |
|----|------|------|
| `api-deploy-ssh` | SSH Private Key | API 서버(CT 240) 배포용 |
| `jenkins-agent-ssh` | SSH Private Key | Agent SSH 접속 (자동 생성) |
| `api-env` | Secret File | API 환경변수 (.env) |

### 파이프라인 동작

1. `docker-agent`에서 Docker 컨테이너(`gradle:jdk25-alpine`) 빌드/테스트 수행
2. Gradle 캐시는 호스트 디렉토리로 마운트 (빌드 간 의존성 캐시 유지)
3. Deploy 단계에서 SSH로 API 서버(CT 240)에 JAR 배포
4. Job DSL로 `chaekpool-api` 파이프라인 자동 생성
5. 상세 내용: [jenkins-pipeline.md](jenkins-pipeline.md)
