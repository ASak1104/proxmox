# CP Traefik (CT 200)

## 개요

Chaekpool 서비스 계층의 HTTP 리버스 프록시. SSL 처리는 OPNsense HAProxy(VM 102)에서 수행하고, CP Traefik은 HTTP(`:80`)만 수신하여 백엔드 서비스로 라우팅한다.

- **IP**: 10.1.0.100
- **포트**: 80 (HTTP)
- **Traefik 버전**: v3.6.7

## 배포

```bash
bash service/chaekpool/scripts/traefik/deploy.sh
```

배포 단계:
1. Traefik v3.6.7 바이너리 다운로드 → `/usr/local/bin/traefik`
2. `traefik` 시스템 사용자/그룹 생성
3. 정적 설정 (`traefik.yml`) 배포
4. 동적 설정 (`services.yml`) + OpenRC 서비스 배포
5. 서비스 시작 및 부팅 시 자동 시작 등록

## 설정

### 정적 설정 (`/etc/traefik/traefik.yml`)

```yaml
entryPoints:
  web:
    address: ":80"

ping:
  entryPoint: web

providers:
  file:
    directory: "/etc/traefik/conf.d"
    watch: true

api:
  dashboard: true
  insecure: true
```

- HTTP(`:80`) 단일 엔트리포인트
- `/etc/traefik/conf.d/` 디렉토리의 파일 변경을 자동 감지
- 대시보드: `http://10.1.0.100:8080/dashboard/`

### 라우팅 규칙 (`/etc/traefik/conf.d/services.yml`)

| 도메인 | 백엔드 | 포트 |
|--------|--------|------|
| `api.cp.codingmon.dev` | Kopring (10.1.0.140) | 8080 |
| `pgadmin.cp.codingmon.dev` | pgAdmin (10.1.0.110) | 5050 |
| `grafana.cp.codingmon.dev` | Grafana (10.1.0.120) | 3000 |
| `jenkins.cp.codingmon.dev` | Jenkins (10.1.0.130) | 8080 |

### 새 서비스 추가

`service/chaekpool/scripts/traefik/configs/services.yml`에 라우터와 서비스를 추가한다:

```yaml
http:
  routers:
    new-service:
      rule: "Host(`newservice.cp.codingmon.dev`)"
      service: new-service
      entryPoints:
        - web

  services:
    new-service:
      loadBalancer:
        servers:
          - url: "http://<IP>:<PORT>"
```

추가 후 설정을 다시 배포하거나, Traefik이 `watch: true`로 파일 변경을 감지하므로 컨테이너에 직접 파일을 수정해도 자동 반영된다.

OPNsense HAProxy(VM 102)의 와일드카드 라우팅(`*.cp.codingmon.dev`)이 모든 `*.cp` 서브도메인을 CP Traefik으로 전달하므로, HAProxy 설정은 수정할 필요 없다.

## 검증

```bash
# 서비스 상태 확인
pct_exec 200 "rc-service traefik status"

# HTTP 응답 확인 (서비스 네트워크 내에서)
curl -H "Host: api.cp.codingmon.dev" http://10.1.0.100/
```

## 운영

```bash
pct_exec 200 "rc-service traefik start"
pct_exec 200 "rc-service traefik stop"
pct_exec 200 "rc-service traefik restart"

# 로그 확인
pct_exec 200 "tail -f /var/log/traefik/traefik.log"
pct_exec 200 "tail -f /var/log/traefik/access.log"
```

## 트러블슈팅

**502 Bad Gateway**
- 백엔드 서비스가 실행 중인지 확인
- `services.yml`의 백엔드 IP/포트가 올바른지 확인

**라우팅이 안 됨**
- `services.yml`의 `Host()` 규칙이 정확한지 확인
- OPNsense HAProxy에서 `*.cp.codingmon.dev` 와일드카드 라우팅이 동작하는지 확인

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/scripts/traefik/deploy.sh` | 배포 스크립트 |
| `service/chaekpool/scripts/traefik/configs/traefik.yml` | 정적 설정 |
| `service/chaekpool/scripts/traefik/configs/services.yml` | 동적 라우팅 규칙 |
| `service/chaekpool/scripts/traefik/configs/traefik.openrc` | OpenRC 서비스 파일 |
