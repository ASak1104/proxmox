# Jenkins (CT 230)

## 개요

Jenkins CI/CD 서버. WAR 파일로 배포되며 OpenJDK 17에서 실행된다.

- **IP**: 10.1.0.130
- **포트**: 8080
- **Jenkins 버전**: 2.541.1
- **접속 URL**: `https://jenkins.cp.codingmon.dev`

## 배포

```bash
bash service/chaekpool/scripts/jenkins/deploy.sh
```

배포 단계 (4단계):
1. OpenJDK 17 **전체 버전**, 폰트 패키지 설치
2. `jenkins` 시스템 사용자/그룹 생성, 디렉토리 생성
3. Jenkins WAR v2.541.1 다운로드 → `/opt/jenkins/jenkins.war`
4. **Wrapper 스크립트** 배포 → `/opt/jenkins/jenkins-wrapper.sh`
5. OpenRC 서비스 배포, 시작 및 부팅 시 자동 시작 등록

### 주요 패키지

- **openjdk17**: 전체 JDK 패키지 (`openjdk17-jre-headless` 불가)
  - `jre-headless`는 `fontmanager` 라이브러리가 없어 Jenkins 초기화 실패
  - 전체 패키지는 GUI 라이브러리 포함 (X11, AWT 등)
- **fontconfig, freetype, ttf-dejavu**: 폰트 렌더링 지원

### Wrapper 스크립트

`supervise-daemon`은 OpenRC 파일의 `export` 명령을 지원하지 않음. 환경 변수 설정을 위해 wrapper 스크립트 사용:

**`/opt/jenkins/jenkins-wrapper.sh`**:
```sh
#!/bin/sh
export JENKINS_HOME="/var/lib/jenkins"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
cd "$JENKINS_HOME"
exec /usr/bin/java -Xmx1024m -Djava.awt.headless=true -jar /opt/jenkins/jenkins.war --httpPort=8080
```

OpenRC는 이 wrapper를 `command`로 호출함

## 설정

### 디렉토리 구조

| 경로 | 용도 |
|------|------|
| `/opt/jenkins/jenkins.war` | Jenkins WAR 파일 |
| `/opt/jenkins/jenkins-wrapper.sh` | 환경 변수 설정 wrapper |
| `/var/lib/jenkins/` | JENKINS_HOME (데이터, 플러그인, 작업) |
| `/var/log/jenkins/` | 로그 |

### 초기 관리자 비밀번호

첫 기동 시 초기 관리자 비밀번호가 자동 생성된다:

```bash
pct_exec 230 "cat /var/lib/jenkins/secrets/initialAdminPassword"
```

웹 UI에서 이 비밀번호로 초기 설정 마법사를 진행한다.

## 검증

```bash
# 서비스 상태
pct_exec 230 "rc-service jenkins status"

# HTTP 응답 확인
curl -s -o /dev/null -w "%{http_code}" http://10.1.0.130:8080/
```

웹 UI: `https://jenkins.cp.codingmon.dev`

## 운영

```bash
pct_exec 230 "rc-service jenkins start"
pct_exec 230 "rc-service jenkins stop"
pct_exec 230 "rc-service jenkins restart"

# 로그 확인
pct_exec 230 "tail -f /var/log/jenkins/jenkins.log"
```

## 트러블슈팅

**Jenkins 시작 느림**
- 첫 기동 시 **60초 이상** 소요 (WAR 압축 해제 + 초기화)
- 완전한 초기화까지 1~2분 대기 필요
- 메모리 부족 시 wrapper 스크립트에서 `-Xmx` 값 조정

**"Jenkins.instance is missing" 오류**
- 원인: `JENKINS_HOME` 환경 변수 미설정
- 해결: wrapper 스크립트가 올바르게 배포되었는지 확인
- 확인: `pct_exec 230 "cat /opt/jenkins/jenkins-wrapper.sh | grep JENKINS_HOME"`

**"no fontmanager in system library path" 오류**
- 원인: `openjdk17-jre-headless` 사용 (GUI 라이브러리 없음)
- 해결: `openjdk17` 전체 패키지 설치 필요
- 확인: `pct_exec 230 "apk list --installed | grep openjdk17"`

**포트 충돌**
- Kopring(CT 240)도 8080 포트를 사용하지만 서로 다른 컨테이너이므로 충돌 없음

**플러그인 설치 실패**
- 인터넷 연결 확인: `pct_exec 230 "wget -q -O /dev/null https://updates.jenkins.io/"`
- DNS 해석 확인: `pct_exec 230 "nslookup updates.jenkins.io"`

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/scripts/jenkins/deploy.sh` | 배포 스크립트 |
| `service/chaekpool/scripts/jenkins/configs/jenkins.openrc` | OpenRC 서비스 파일 |
| `service/chaekpool/scripts/jenkins/configs/jenkins-wrapper.sh` | 환경 변수 설정 wrapper |
