# 네트워크 설정 가이드

도메인, 인증서, 정책 라우팅 등 외부 접속에 필요한 네트워크 설정과 트러블슈팅을 다룬다.

> 네트워크 토폴로지와 IP 할당은 [네트워크 아키텍처](network-architecture.md) 참조.
> OPNsense HAProxy 설정 및 운영은 [운영 가이드](opnsense-haproxy-operations-guide.md) 참조.

## 도메인 구조

### DNS

`codingmon.dev` DNS에 다음이 등록되어 있다:

| 레코드 | 타입 | 값 | 비고 |
|--------|------|-----|------|
| `pve.codingmon.dev` | A | 공인 IP | Proxmox |
| `opnsense.codingmon.dev` | A | 공인 IP | OPNsense |
| `*.cp.codingmon.dev` | A | 공인 IP | Chaekpool 서비스 전체 (와일드카드) |

`*.cp.codingmon.dev` 와일드카드 DNS로 새 서비스 추가 시 DNS 변경 없이 바로 사용 가능하다.

### 2-tier 라우팅 경로 (OPNsense HAProxy + CP Traefik)

외부 요청이 백엔드에 도달하는 경로:

```
클라이언트 → NAT Router (:80/:443 포트포워딩) → OPNsense HAProxy (VM 102, <OPNSENSE_WAN_IP>)
  │
  ├─ pve.codingmon.dev        → 직접 라우팅 → Proxmox (10.0.0.254:8006)
  ├─ opnsense.codingmon.dev   → 직접 라우팅 → OPNsense (127.0.0.1:443)
  │
  └─ *.cp.codingmon.dev       → CP Traefik (10.1.0.100:80) → 각 서비스
```

- OPNsense HAProxy: SSL 종료 (acme.sh + Let's Encrypt) + SNI/Host 헤더 기반 라우팅
- CP Traefik: HTTP 전용, Host 헤더 기반 라우팅

## 인증서 (Let's Encrypt)

### 동작 방식

OPNsense에서 `acme.sh`를 통해 Let's Encrypt 인증서를 발급하고, HAProxy Trust Store에 등록한다.

1. OPNsense `os-acme-client` 플러그인이 인증서 발급 관리
2. HTTP-01 챌린지로 검증 (HAProxy가 `/.well-known/acme-challenge/` 경로 처리)
3. 발급된 인증서를 OPNsense Trust Store에 자동 임포트
4. HAProxy가 Trust Store의 인증서를 SSL 종료에 사용

HTTP-01 챌린지가 작동하려면:
- **NAT Router에서 포트 80 → <OPNSENSE_WAN_IP>** 포워딩 필수 (443뿐 아니라 80도)
- HAProxy의 HTTP 프론트엔드가 챌린지 경로를 ACME 백엔드로 전달해야 함

### SAN 인증서 구성

2개의 Multi-SAN 인증서로 관리:

| 인증서 | 도메인 |
|--------|--------|
| `infra-multi-san` | `pve.codingmon.dev`, `opnsense.codingmon.dev` |
| `cp-multi-san` | `api.cp.codingmon.dev`, `postgres.cp.codingmon.dev`, `redis.cp.codingmon.dev`, `grafana.cp.codingmon.dev`, `prometheus.cp.codingmon.dev`, `jaeger.cp.codingmon.dev`, `jenkins.cp.codingmon.dev` |

### 새 서비스 추가 시 인증서 업데이트 절차

1. OPNsense Web UI > Services > ACME Client > Certificates에서 `cp-multi-san` 인증서 편집
2. Subject Alternative Names에 새 도메인 추가
3. "Issue/Renew" 클릭하여 재발급
4. HAProxy > Settings > SSL Offloading에서 새 인증서가 반영되었는지 확인
5. Apply Changes로 HAProxy 재시작

API를 통한 인증서 관리는 [운영 가이드](opnsense-haproxy-operations-guide.md) 참조.

> **주의**: Let's Encrypt에는 [Rate Limit](https://letsencrypt.org/docs/rate-limits/)이 있다.
> 동일 도메인 조합에 대해 주당 5회까지 발급 가능. 테스트 시 주의.

## 정책 라우팅

> **해결됨**: 구 아키텍처(CT 103)에서는 LXC 컨테이너가 3개 네트워크에 연결되어 비대칭 라우팅 문제가 있었다.
> 현재 아키텍처에서는 OPNsense VM이 직접 외부 트래픽을 수신하므로 이 문제가 발생하지 않는다.
> OPNsense는 WAN(<OPNSENSE_WAN_IP>)으로 들어온 트래픽의 응답을 동일한 인터페이스로 반환한다.

## NAT Router 포트포워딩

NAT Router에서 다음 포트포워딩이 필수:

| 외부 포트 | 프로토콜 | 내부 IP | 내부 포트 | 용도 |
|-----------|---------|---------|-----------|------|
| 80 | TCP | <OPNSENSE_WAN_IP> | 80 | HTTP (Let's Encrypt 챌린지 + HTTPS 리다이렉트) |
| 443 | TCP | <OPNSENSE_WAN_IP> | 443 | HTTPS (실제 서비스 트래픽) |
| 51820 | UDP | <OPNSENSE_WAN_IP> | 51820 | WireGuard VPN |

설정 위치: NAT Router 관리페이지 (<GATEWAY_IP>) > 고급 설정 > NAT/라우터 관리 > 포트포워드 설정

> 포트 80이 빠지면 Let's Encrypt HTTP-01 챌린지가 실패하여 인증서가 발급되지 않는다.

## 트러블슈팅

### 인증서가 발급되지 않을 때

1. **포트 80 포워딩 확인**: NAT Router에서 80 → <OPNSENSE_WAN_IP> 설정 여부
2. **ACME 클라이언트 로그 확인**: OPNsense Web UI > Services > ACME Client > Log
3. **외부에서 HTTP 접근 테스트**:
   ```bash
   curl -I http://pve.codingmon.dev/.well-known/acme-challenge/test
   # 404 Not Found → 정상 (HAProxy가 응답하고 있음)
   # 연결 실패 → 포트포워딩 문제
   ```
4. **HAProxy 로그 확인**: OPNsense Web UI > Services > HAProxy > Log File
5. **Rate Limit**: 같은 도메인 조합으로 주 5회 이상 발급 시도 시 1주일 대기 필요

### 502 Bad Gateway

CP 서비스 접속 시 502가 발생하면:

1. **백엔드 서비스 실행 확인**: 해당 CT에서 서비스 상태 확인
   ```bash
   pct_exec <CT_ID> "rc-service <service> status"
   ```
2. **CP Traefik 라우팅 확인**: `service/chaekpool/scripts/traefik/configs/services.yml`에 해당 서비스의 라우터/서비스 정의가 있는지 확인
3. **네트워크 연결 확인**: CT 200에서 백엔드로 접근 가능한지 테스트
   ```bash
   pct_exec 200 "wget -qO- http://10.1.0.120:3100/ready"
   ```

### 인증서 오류 (NET::ERR_CERT_COMMON_NAME_INVALID)

브라우저에서 인증서 오류가 표시되면:

1. **SAN 목록 확인**: OPNsense Web UI > Services > ACME Client > Certificates에서 해당 도메인이 SAN에 포함되어 있는지 확인
2. 빠졌으면 위 "새 서비스 추가 시 인증서 업데이트 절차" 따라 진행
3. **현재 인증서 도메인 확인**: OPNsense Web UI > System > Trust > Certificates에서 인증서 상세 확인
