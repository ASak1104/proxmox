# Authelia (CT 201)

## 개요

Chaekpool 서비스의 중앙 인증/인가(IAM) 서비스. OIDC Provider와 ForwardAuth 미들웨어를 통해 모든 `*.cp.codingmon.dev` 서비스에 SSO를 제공한다.

- **IP**: 10.1.0.101
- **포트**: 9091
- **Authelia 버전**: 4.39.15 (musl static binary)
- **접속 URL**: `https://authelia.cp.codingmon.dev`

## 인증 아키텍처

서비스별로 두 가지 인증 방식을 사용한다:

### OIDC 네이티브 인증

자체적으로 OIDC를 지원하는 서비스는 Authelia를 OIDC Provider로 사용한다. Traefik 미들웨어 없이 서비스가 직접 Authelia와 OAuth2 플로우를 수행한다.

```
사용자 → Grafana → Authelia (OIDC 인증) → Grafana (토큰 발급)
```

| 서비스 | OIDC Client ID | PKCE | Scopes |
|--------|---------------|------|--------|
| Grafana | `grafana` | S256 | openid, profile, email, groups |
| Jenkins | `jenkins` | 없음 | openid, offline_access, profile, email, groups, address, phone |
| pgAdmin | `pgadmin` | 없음 | openid, profile, email |

### ForwardAuth 보호

OIDC를 지원하지 않는 서비스는 Traefik ForwardAuth 미들웨어로 보호한다. 사용자가 서비스에 접근하면 Traefik이 Authelia에 인증 확인 요청을 보낸다.

```
사용자 → Traefik → [ForwardAuth → Authelia 확인] → Backend 서비스
```

대상 서비스: Prometheus, Jaeger, Redis Commander

ForwardAuth 미들웨어 설정 (`services.yml`):
```yaml
middlewares:
  authelia:
    forwardAuth:
      address: "http://10.1.0.101:9091/api/authz/forward-auth"
      trustForwardHeader: true
      authResponseHeaders:
        - "Remote-User"
        - "Remote-Groups"
        - "Remote-Email"
        - "Remote-Name"
```

### 접근 제어 정책

```yaml
access_control:
  default_policy: "deny"
  rules:
    - domain: "api.cp.codingmon.dev"       # Kopring API — bypass (자체 인증)
      policy: "bypass"
    - domain: "authelia.cp.codingmon.dev"   # Authelia 포탈 — bypass
      policy: "bypass"
    - domain: "*.cp.codingmon.dev"          # 나머지 — 1단계 인증
      policy: "one_factor"
```

## 배포

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-authelia
```

배포 단계 (5단계):
1. Authelia v4.39.15 musl 바이너리 다운로드 → `/usr/local/bin/authelia`
2. 비밀번호 해시(argon2id) 및 OIDC 클라이언트 시크릿 해시(pbkdf2) 생성, RSA 4096 JWKS 키 생성
3. 설정 파일 배포 (`configuration.yml`, `users_database.yml`, wrapper, OpenRC)
4. Python 기반 시크릿 주입 (플레이스홀더 치환)
5. 서비스 시작 및 부팅 시 자동 시작 등록

### 시크릿 주입 방식

해시 값에 `$` 문자가 포함되어 bash 변수로 치환되는 문제를 방지하기 위해 Python 기반 치환을 사용한다:

1. 시크릿을 임시 env 파일로 작성
2. 컨테이너에 push
3. 컨테이너 내부 Python으로 `__PLACEHOLDER__` → 실제 값 치환
4. 임시 파일 삭제

### JWKS 키 보존

OIDC 클라이언트는 Authelia의 JWKS 공개 키를 캐싱한다. 배포 시 키가 재생성되면 클라이언트의 캐싱된 키와 불일치하여 `bad_signature` 오류가 발생한다. Ansible 역할은 키가 없을 때만 생성한다:

```bash
[ -f /etc/authelia/oidc.jwks.rsa.4096.pem ] || { openssl genrsa ... }
```

키를 재생성해야 하는 경우, 모든 OIDC 클라이언트 서비스(Grafana, Jenkins, pgAdmin)를 재시작하여 JWKS 캐시를 초기화해야 한다.

## 설정

### 디렉토리 구조

| 경로 | 용도 |
|------|------|
| `/etc/authelia/configuration.yml` | 메인 설정 (서버, 인증, OIDC, 접근 제어) |
| `/etc/authelia/users_database.yml` | 사용자 목록 (이름, 해시, 그룹) |
| `/etc/authelia/oidc.jwks.rsa.4096.pem` | OIDC JWT 서명 RSA 키 |
| `/var/lib/authelia/db.sqlite3` | 세션/OIDC 상태 저장 (SQLite) |
| `/var/lib/authelia/notification.txt` | 알림 출력 (파일 기반, SMTP 미사용) |
| `/var/log/authelia/authelia.log` | 로그 파일 |
| `/opt/authelia/authelia-wrapper.sh` | Wrapper 스크립트 |

### Wrapper 스크립트

Authelia는 `--config.experimental.filters template` 옵션으로 설정 파일에서 Go 템플릿 필터를 지원한다. JWKS 키를 파일에서 읽어 YAML에 인라인 삽입하는 데 사용한다:

```sh
exec /usr/local/bin/authelia --config /etc/authelia/configuration.yml \
    --config.experimental.filters template
```

설정 파일의 JWKS 참조:
```yaml
key: {{ secret "/etc/authelia/oidc.jwks.rsa.4096.pem" | mindent 10 "|" }}
```

### 사용자 관리

`users_database.yml`에 파일 기반으로 사용자를 관리한다:

| 사용자 | 그룹 | 용도 |
|--------|------|------|
| `cpadmin` | admins | 관리자 (Grafana Admin 등) |
| `cpuser` | users | 일반 사용자 (Grafana Viewer 등) |

비밀번호는 `group_vars/all/vault.yml`에서 관리하며, Ansible 역할이 argon2id 해시를 생성하여 주입한다.

사용자 추가 시:
1. `users_database.yml`에 항목 추가 (해시 플레이스홀더 사용)
2. `vault.yml`에 비밀번호 변수 추가
3. Ansible 역할에 해시 생성 로직 추가
4. 재배포

### OIDC 클라이언트 설정

#### Grafana

```yaml
- client_id: "grafana"
  require_pkce: true
  pkce_challenge_method: "S256"
  redirect_uris:
    - "https://grafana.cp.codingmon.dev/login/generic_oauth"
  scopes: [openid, profile, email, groups]
  token_endpoint_auth_method: "client_secret_basic"
```

Grafana 측 설정 (`grafana.ini`):
- `[auth.generic_oauth]`에서 `use_pkce = true`
- `role_attribute_path`로 그룹 기반 역할 매핑 (`admins` → Admin, 나머지 → Viewer)
- `oauth_allow_insecure_email_lookup = true` (이메일 기반 사용자 매칭 허용)

#### Jenkins

```yaml
- client_id: "jenkins"
  require_pkce: false     # oic-auth 플러그인은 PKCE 미지원
  redirect_uris:
    - "https://jenkins.cp.codingmon.dev/securityRealm/finishLogin"
  scopes: [openid, offline_access, profile, email, groups, address, phone]
  token_endpoint_auth_method: "client_secret_basic"
```

Jenkins 측 설정 (JCasC `casc.yaml`):
- `oic-auth` + `configuration-as-code` 플러그인 사전 설치 필요
- `serverConfiguration.wellKnown.wellKnownOpenIDConfigurationUrl` (중첩 구조)
- oic-auth는 `scopes_supported`에 나열된 **모든 스코프**를 요청하므로, Authelia 클라이언트 설정에 7개 스코프 모두 허용 필요

#### pgAdmin

```yaml
- client_id: "pgadmin"
  require_pkce: false     # Authlib(pgAdmin 백엔드)는 PKCE 미지원
  redirect_uris:
    - "https://pgadmin.cp.codingmon.dev/oauth2/authorize"
  scopes: [openid, profile, email]
  token_endpoint_auth_method: "client_secret_basic"
```

pgAdmin 측 설정 (`config_local.py`):
- `OAUTH2_SERVER_METADATA_URL`로 자동 검색
- `AUTHENTICATION_SOURCES = ['oauth2', 'internal']`

## 검증

```bash
# 서비스 상태
ssh root@10.1.0.101 "rc-service authelia status"

# HTTP 응답 확인
curl -s -o /dev/null -w "%{http_code}" http://10.1.0.101:9091/api/health

# OIDC Discovery 엔드포인트
curl -s http://10.1.0.101:9091/.well-known/openid-configuration | python3 -m json.tool
```

웹 UI: `https://authelia.cp.codingmon.dev`

## 운영

```bash
ssh root@10.1.0.101 "rc-service authelia start"
ssh root@10.1.0.101 "rc-service authelia stop"
ssh root@10.1.0.101 "rc-service authelia restart"

# 로그 확인
ssh root@10.1.0.101 "tail -f /var/log/authelia/authelia.log"

# 디버그 모드 (임시)
# configuration.yml의 log.level을 "debug"로 변경 후 재시작
```

## 트러블슈팅

### ForwardAuth 400 Bad Request

**증상**: ForwardAuth로 보호된 서비스(Prometheus, Jaeger, Redis Commander) 접근 시 400 에러.

**원인**: OPNsense HAProxy가 SSL을 종료하지만, 백엔드(CP Traefik)로 전달할 때 `X-Forwarded-Proto: https` 헤더를 추가하지 않음. Authelia가 요청을 HTTP로 판단하여 `authelia_url`(HTTPS)과의 스킴 불일치로 400을 반환.

**해결**: Traefik 정적 설정에서 OPNsense(10.1.0.1)의 프록시 헤더를 신뢰하도록 설정:

```yaml
# traefik.yml
entryPoints:
  web:
    address: ":80"
    forwardedHeaders:
      trustedIPs:
        - "10.1.0.1"
```

이 설정으로 HAProxy가 보내는 `X-Forwarded-Proto: https`를 Traefik이 Authelia에 전달한다.

### OIDC bad_signature 오류

**증상**: pgAdmin 등에서 OIDC 로그인 시 `bad_signature` JSON 에러.

**원인**: Authelia 재배포 시 JWKS RSA 키가 재생성되어 클라이언트가 캐싱한 공개 키와 불일치.

**해결**:
1. Ansible 역할의 키 생성 로직이 기존 키가 있을 때 재생성하지 않는지 확인
2. 이미 키가 재생성된 경우, OIDC 클라이언트 서비스를 모두 재시작:
```bash
ssh root@10.1.0.120 "rc-service grafana restart"
ssh root@10.1.0.130 "rc-service jenkins restart"
ssh root@10.1.0.110 "rc-service pgadmin4 restart"
```

### OIDC invalid_scope 오류

**증상**: Jenkins 등에서 `The OAuth 2.0 Client is not allowed to request scope 'xxx'` 에러.

**원인**: 클라이언트가 요청하는 스코프가 Authelia 클라이언트 설정의 `scopes` 목록에 없음. oic-auth(Jenkins)는 Authelia의 `scopes_supported`에 나열된 **모든 7개 스코프**를 자동으로 요청한다.

**해결**: Authelia `configuration.yml`의 해당 클라이언트 `scopes`에 누락된 스코프를 추가. Authelia가 지원하는 전체 스코프: `openid`, `offline_access`, `profile`, `email`, `groups`, `address`, `phone`.

### OIDC PKCE code_challenge 오류

**증상**: `Clients must include a 'code_challenge' when performing the authorize code flow, but it is missing`.

**원인**: Authelia 클라이언트 설정에서 `require_pkce: true`이나, 클라이언트 라이브러리가 PKCE를 지원하지 않음. Jenkins(oic-auth)와 pgAdmin(Authlib)은 PKCE를 지원하지 않는다.

**해결**: 해당 클라이언트의 `require_pkce`를 `false`로 설정. PKCE를 지원하는 클라이언트(Grafana)만 `true`로 유지.

### Grafana User sync failed 오류

**증상**: Grafana에서 OIDC 로그인 시 "User sync failed" 에러.

**원인**: Grafana가 OIDC userinfo의 이메일로 기존 사용자를 찾을 때, 보안상 기본적으로 차단함.

**해결**: `grafana.ini`에 두 설정 추가:
```ini
[users]
allow_sign_up = true

[auth]
oauth_allow_insecure_email_lookup = true
```

### Jenkins JCasC 부팅 실패

**증상**: Jenkins 시작 시 `ConfigurationAsCodeBootFailure`, "Invalid configuration elements" 에러.

**원인**: oic-auth 플러그인의 JCasC 스키마가 일반적인 OIDC 설정과 다름. `wellKnownOpenIDConfigurationUrl`은 `serverConfiguration.wellKnown` 하위에 중첩되어야 하며, `pkceEnabled`, `scopes`, `escapeHatchEnabled` 등은 유효하지 않은 속성.

**해결**: 올바른 JCasC 구조:
```yaml
jenkins:
  securityRealm:
    oic:
      clientId: "jenkins"
      clientSecret: "..."
      serverConfiguration:
        wellKnown:
          wellKnownOpenIDConfigurationUrl: "https://authelia.cp.codingmon.dev/.well-known/openid-configuration"
      userNameField: "preferred_username"
      fullNameFieldName: "name"
      emailFieldName: "email"
      groupsFieldName: "groups"
```

### jenkins-plugin-manager 옵션 오류

**증상**: `--plugin-dir` is not a valid option.

**원인**: jenkins-plugin-manager는 긴 옵션(`--war`, `--plugin-dir`, `--plugins`)이 아닌 짧은 옵션(`-w`, `-d`, `-p`)을 사용한다.

**해결**:
```bash
java -jar /tmp/jenkins-plugin-manager.jar \
    -w /opt/jenkins/jenkins.war \
    -d /var/lib/jenkins/plugins \
    -p oic-auth configuration-as-code
```

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/ansible/roles/authelia/` | Ansible 역할 |
| `service/chaekpool/ansible/roles/authelia/templates/configuration.yml.j2` | Authelia 메인 설정 |
| `service/chaekpool/ansible/roles/authelia/templates/users_database.yml.j2` | 사용자 데이터베이스 |
| `service/chaekpool/ansible/roles/authelia/templates/authelia-wrapper.sh.j2` | Wrapper 스크립트 |
| `service/chaekpool/ansible/roles/authelia/templates/authelia.openrc.j2` | OpenRC 서비스 파일 |
| `service/chaekpool/ansible/group_vars/all/vault.yml` | 시크릿 (ansible-vault 암호화) |
| `service/chaekpool/ansible/roles/traefik/templates/services.yml.j2` | ForwardAuth 미들웨어 + 라우팅 |
