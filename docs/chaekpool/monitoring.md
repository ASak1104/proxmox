# Monitoring Stack (CT 220)

## 개요

4개의 모니터링 서비스를 단일 LXC 컨테이너에서 네이티브 바이너리로 실행한다.

- **IP**: 10.1.0.120
- **서비스**:

| 서비스 | 버전 | 포트 | 접속 URL |
|--------|------|------|----------|
| Prometheus | v3.9.1 | 9090 | `http://10.1.0.120:9090` (VPN) |
| Grafana | v12.3.2 | 3000 | `https://grafana.cp.codingmon.dev` |
| Loki | v3.6.5 | 3100 | (내부 전용) |
| Jaeger | v2.15.0 | 16686 (UI), 4317 (gRPC), 4318 (HTTP) | `http://10.1.0.120:16686` (VPN) |

## 배포

```bash
cd service/chaekpool/ansible
ansible-playbook site.yml -l cp-monitoring
```

배포 단계 (8단계):
1. Prometheus 바이너리 설치 (`/opt/prometheus/`)
2. Prometheus 설정 배포 + 로그 파일 생성 + 서비스 시작
3. Grafana 바이너리 설치 (`/opt/grafana/`)
4. Grafana 설정 + 데이터소스 프로비저닝 배포 + 서비스 시작
5. Loki static 바이너리 설치 (`/opt/loki/`)
6. Loki 설정 배포 + 로그 파일 생성 + 서비스 시작
7. Jaeger v2 바이너리 설치 (`/opt/jaeger/`)
8. Jaeger 설정 배포 + 로그 파일 생성 + 서비스 시작

### 주의사항

- **Prometheus v3**: Console template 디렉토리가 릴리즈에서 제거됨. OpenRC에 `--web.console.*` 플래그 사용 불가
- **Loki**: 반드시 `loki-linux-amd64.zip`의 static 바이너리 사용 (gzip 타르볼 아님)
- **Jaeger v2**: OTEL Collector 기반. 설정 형식이 v1과 다름
- **로그 파일**: 모든 서비스는 `supervise-daemon` 사용. 서비스 시작 전 로그 파일을 미리 생성해야 함

## 설정

### Prometheus (`/etc/prometheus/prometheus.yml`)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "kopring-actuator"
    metrics_path: "/actuator/prometheus"
    static_configs:
      - targets: ["10.1.0.140:8080"]

  - job_name: "loki"
    static_configs:
      - targets: ["localhost:3100"]

  - job_name: "grafana"
    static_configs:
      - targets: ["localhost:3000"]
```

- 15초 간격으로 스크레이핑
- Kopring의 Spring Boot Actuator (`/actuator/prometheus`) 메트릭 수집
- 로컬 Loki, Grafana 자체 메트릭 수집

### Grafana (`/etc/grafana/grafana.ini`)

```ini
[server]
http_port = 3000
root_url = https://grafana.cp.codingmon.dev

[security]
admin_user = admin
admin_password = changeme
```

- 기본 관리자: `admin` / `changeme` (변경 권장)
- 로그: `/var/log/grafana/`
- 데이터: `/var/lib/grafana/`

**OIDC 인증 (Authelia)**:

Grafana는 Authelia OIDC를 통한 SSO 로그인을 지원한다.

```ini
[users]
allow_sign_up = true                    # OIDC 사용자 자동 생성

[auth]
oauth_allow_insecure_email_lookup = true # 이메일 기반 기존 사용자 매칭

[auth.generic_oauth]
enabled = true
allow_sign_up = true
name = Authelia
client_id = grafana
client_secret = <vault_authelia_oidc_grafana_secret>
scopes = openid profile email groups
auth_url = https://authelia.cp.codingmon.dev/api/oidc/authorization
token_url = https://authelia.cp.codingmon.dev/api/oidc/token
api_url = https://authelia.cp.codingmon.dev/api/oidc/userinfo
login_attribute_path = preferred_username
email_attribute_path = email
groups_attribute_path = groups
name_attribute_path = name
use_pkce = true
role_attribute_path = contains(groups[*], 'admins') && 'Admin' || 'Viewer'
```

- `use_pkce = true`: PKCE(Proof Key for Code Exchange) 활성화로 보안 강화
- `role_attribute_path`: Authelia groups 기반 역할 자동 매핑 — `admins` 그룹이면 Admin, 나머지는 Viewer
- `oauth_allow_insecure_email_lookup`: 이메일이 일치하는 기존 로컬 사용자와 OIDC 계정을 자동 연결
- OIDC 클라이언트 시크릿은 `vault.yml`의 `vault_authelia_oidc_grafana_secret` (평문, Authelia 측은 PBKDF2 해시)
- 소스: `roles/monitoring/templates/grafana.ini.j2`

### Grafana 데이터소스 (`/etc/grafana/provisioning/datasources/datasources.yml`)

3개 데이터소스가 자동 프로비저닝된다:
- **Prometheus** (`http://localhost:9090`) - 기본 데이터소스
- **Loki** (`http://localhost:3100`)
- **Jaeger** (`http://localhost:16686`)

### Loki (`/etc/loki/loki.yml`)

- HTTP 포트: 3100
- 스토리지: TSDB + 로컬 파일시스템
- 보관 기간: 30일 (`retention_period: 30d`)
- 자동 압축: 10분 간격
- 데이터: `/var/lib/loki/`

### Jaeger (`/etc/jaeger/jaeger.yml`)

```yaml
service:
  extensions: [jaeger_storage, jaeger_query]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [jaeger_storage_exporter]

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"

processors:
  batch: {}

exporters:
  jaeger_storage_exporter:
    trace_storage: badger_store

extensions:
  jaeger_storage:
    backends:
      badger_store:
        badger:
          directories:
            keys: /var/lib/jaeger/keys
            values: /var/lib/jaeger/values
          ephemeral: false

  jaeger_query:
    storage:
      traces: badger_store
    ui:
      config_file: ""
```

**Jaeger v2 특징** (OTEL Collector 기반):
- `service.extensions`에 사용할 extension 명시 필수
- `jaeger_query`의 storage는 `storage.traces` 구조 사용 (v1의 `trace_storage` 아님)
- OTLP 수신: gRPC(`:4317`), HTTP(`:4318`)
- 스토리지: BadgerDB (로컬 KV 스토어)
- 쿼리 UI: `:16686`

## 검증

```bash
# 전체 서비스 상태
ssh root@10.1.0.120 "rc-service prometheus status"
ssh root@10.1.0.120 "rc-service grafana status"
ssh root@10.1.0.120 "rc-service loki status"
ssh root@10.1.0.120 "rc-service jaeger status"

# Prometheus 타겟 확인
curl -s http://10.1.0.120:9090/api/v1/targets | jq '.data.activeTargets[].health'

# Loki readiness
curl -s http://10.1.0.120:3100/ready
```

웹 UI:
- Grafana: `https://grafana.cp.codingmon.dev`
- Prometheus: `http://10.1.0.120:9090` (VPN 직접 접근)
- Jaeger: `http://10.1.0.120:16686` (VPN 직접 접근)

## 운영

```bash
# Prometheus
ssh root@10.1.0.120 "rc-service prometheus start|stop|restart"

# Grafana
ssh root@10.1.0.120 "rc-service grafana start|stop|restart"

# Loki
ssh root@10.1.0.120 "rc-service loki start|stop|restart"

# Jaeger
ssh root@10.1.0.120 "rc-service jaeger start|stop|restart"
```

### 로그 확인

```bash
# Prometheus
ssh root@10.1.0.120 "tail -f /var/log/prometheus.log"

# Grafana
ssh root@10.1.0.120 "tail -f /var/log/grafana/grafana.log"

# Loki
ssh root@10.1.0.120 "tail -f /var/log/loki.log"

# Jaeger
ssh root@10.1.0.120 "tail -f /var/log/jaeger.log"
```

## 트러블슈팅

**Prometheus 타겟 DOWN**
- 타겟 서비스가 실행 중인지 확인
- Prometheus UI > Status > Targets에서 에러 메시지 확인
- 네트워크 연결 확인 (특히 Kopring `10.1.0.140:8080`)

**Grafana 데이터소스 연결 실패**
- Grafana UI > Configuration > Data Sources에서 테스트
- 동일 컨테이너의 로컬 서비스이므로 `localhost` 접근이 실패하면 해당 서비스 상태 확인

**Loki 디스크 사용량 증가**
- 보관 기간: 30일 (변경: `loki.yml`의 `retention_period`)
- 압축 간격: 10분 (`compaction_interval`)
- 데이터 위치: `/var/lib/loki/`

**Jaeger 시작 실패**
- 디스크 공간 확인 (`/var/lib/jaeger/`)
- 키/밸류 디렉토리 권한 확인 (`jaeger:jaeger` 소유)
- 로그에서 config 에러 확인: `service.extensions` 누락 시 extension이 활성화되지 않음

**Prometheus 즉시 종료**
- Prometheus v3부터 console template이 제거됨
- OpenRC에 `--web.console.templates` 또는 `--web.console.libraries` 플래그가 있으면 제거
- 로그 파일이 없으면 supervise-daemon이 프로세스를 시작하지 못할 수 있음 → 사전 생성 필요

**Loki "Not a valid dynamic program"**
- 잘못된 바이너리 (glibc vs musl 불일치)
- 해결: `loki-linux-amd64.zip`에서 static 바이너리 재설치

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/ansible/roles/monitoring/` | Ansible 역할 |
| `service/chaekpool/ansible/roles/monitoring/templates/prometheus.yml.j2` | Prometheus 설정 |
| `service/chaekpool/ansible/roles/monitoring/templates/grafana.ini.j2` | Grafana 설정 |
| `service/chaekpool/ansible/roles/monitoring/templates/datasources.yml.j2` | Grafana 데이터소스 |
| `service/chaekpool/ansible/roles/monitoring/templates/loki.yml.j2` | Loki 설정 |
| `service/chaekpool/ansible/roles/monitoring/templates/jaeger.yml.j2` | Jaeger 설정 |
