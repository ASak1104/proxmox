# OPNsense HAProxy 운영 가이드

> **작성일**: 2026-02-10
> **대상**: OPNsense HAProxy 기반 2-tier 리버스 프록시 운영 전반
> **범위**: 마이그레이션 과정 기록, 트러블슈팅, 향후 운영 가이드

---

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [마이그레이션 과정 기록](#2-마이그레이션-과정-기록)
3. [발생한 문제와 해결 과정](#3-발생한-문제와-해결-과정)
4. [OPNsense API 자동화 가이드](#4-opnsense-api-자동화-가이드)
5. [새 도메인 추가 절차](#5-새-도메인-추가-절차)
6. [새 네트워크/서비스 추가 절차](#6-새-네트워크서비스-추가-절차)
7. [인증서 관리](#7-인증서-관리)
8. [트러블슈팅 레퍼런스](#8-트러블슈팅-레퍼런스)
9. [현재 HAProxy 설정 상태](#9-현재-haproxy-설정-상태)
10. [OPNsense 접속 방법](#10-opnsense-접속-방법)

---

## 1. 아키텍처 개요

### 1.1 변경 전 (3-Tier)

```
Internet → NAT Router (포트포워딩 80,443 → 192.168.0.103)
  → Mgmt Traefik (CT 103, 192.168.0.103)  ← SSL 종료 (Let's Encrypt)
    → CP Traefik (CT 200, 10.1.0.100:80)   ← HTTP 라우팅
      → Backend Services (CT 210~240)
```

**문제점**: Traefik이 OPNsense 방화벽 외부에서 SSL을 종료하여 보안 경계가 불명확하고, 3단계 프록시로 인한 불필요한 복잡도.

### 1.2 변경 후 (2-Tier)

```
Internet → NAT Router (포트포워딩 80,443 → <OPNSENSE_WAN_IP>)
  → OPNsense HAProxy (VM 102, <OPNSENSE_WAN_IP>)  ← SSL 종료 + 방화벽
    ├─ pve.codingmon.dev       → Proxmox (10.0.0.254:8006, HTTPS 백엔드)
    ├─ opnsense.codingmon.dev  → OPNsense (127.0.0.1:443, HTTPS 백엔드)
    └─ *.cp.codingmon.dev      → CP Traefik (10.1.0.100:80, HTTP)
                                   → Backend Services (CT 210~240)
```

**장점**: 모든 외부 트래픽이 방화벽을 통과, SSL 종료가 방화벽 레벨에서 수행됨, CT 103 제거로 리소스 절약.

### 1.3 인증서 구조

단일 9-도메인 SAN 인증서가 아니라, **2개의 SAN 인증서**로 분리:

| 인증서 이름 | 포함 도메인 | 용도 |
|------------|-----------|------|
| `infra-multi-san` | pve.codingmon.dev, opnsense.codingmon.dev | 인프라 서비스 |
| `cp-multi-san` | postgres/redis/grafana/prometheus/jaeger/jenkins.cp.codingmon.dev | Chaekpool 서비스 |

**분리 이유**: Let's Encrypt HTTP-01 챌린지에서 도메인 수가 많을수록 실패 확률이 높음. 인프라와 서비스를 분리하면 독립적으로 갱신/재발급 가능.

---

## 2. 마이그레이션 과정 기록

### 2.1 1차 시도 (수동 Web UI, 실패)

**방법**: OPNsense Web UI에서 수동으로 HAProxy 설정.

**결과**: 실패. 근본 원인 4가지:

1. **UI 용어 불일치**: 문서상 "ACLs" 탭과 "Actions" 탭은 존재하지 않음. 실제 OPNsense HAProxy 플러그인 UI는:
   - "ACLs" → **Rules & Checks → Conditions**
   - "Actions" → **Rules & Checks → Rules**
   - Frontend에서는 "Select Rules" 드롭다운으로 참조

2. **haproxy.conf 직접 수정으로 파일 파손**: `/usr/local/etc/haproxy.conf`는 OPNsense가 자동 생성하는 파일. `cat >> haproxy.conf`로 직접 추가하면서 EOF 문자열이 삽입되어 HAProxy 재시작 실패.

3. **방화벽 규칙 오류**: NAT 규칙이 `10.0.0.2` (옛 CT 103)로 포워딩되어 있었음.

4. **Web UI 수동 설정의 한계**: 텍스트로 UI 지시를 전달하면 UI가 달라 사용자 혼란 가중.

### 2.2 2차 시도 (API 자동화, 성공)

**방법**: OPNsense REST API를 사용하여 SSH 경유로 자동화.

**접속 경로**:
```
로컬 Mac → SSH → Proxmox (<PROXMOX_HOST>) → SSH → OPNsense (root@10.0.0.1) → curl localhost API
```

**단계별 진행**:

#### Phase 0: 상태 확인
- API 키 생성 및 연결 테스트 (3번 시도 끝에 성공)
- 기존 HAProxy 설정 확인: Real Servers 4개, Backend Pools 4개, Frontends 2개, ACME 정의 2개
- Conditions/Rules는 미생성 상태 확인

#### Phase 1: Conditions + Rules 생성
- API로 `cond_pve`, `cond_opnsense` Condition 생성
- API로 `rule_pve`, `rule_opnsense`, `rule_https_redirect` Rule 생성
- Frontend에 Rules 연결
- `proxmox-pool`, `opnsense-pool`을 TCP → HTTP 모드로 변경
- HAProxy reconfigure 성공

#### Phase 2: 인증서 발급
- WAN 방화벽 "Block private networks" 비활성화 (아래 문제 #4 참조)
- SSH lockout 테이블에서 Proxmox IP 제거 (아래 문제 #3 참조)
- WAN 방화벽 규칙으로 포트 80, 443 허용
- `acme.sh` 수동 실행으로 infra-multi-san 인증서 발급 성공
- API로 cp-multi-san 인증서 발급 트리거 → 자동 성공
- 발급된 인증서를 Trust Store에 Python 스크립트로 import
- HTTPS Frontend의 `ssl_certificates`에 두 인증서 연결
- HAProxy reconfigure

#### Phase 3: 검증
- pve.codingmon.dev: Let's Encrypt 인증서로 HTTPS 정상 동작 확인
- opnsense.codingmon.dev: HTTPS 정상 동작 확인
- cp 도메인: SSL 인증서 정상, CP Traefik 백엔드 별도 이슈

#### Phase 4: CT 103 제거 및 코드 정리
- `core/terraform/main.tf`에서 CT 103 리소스 블록 제거
- `core/terraform/opnsense.tf` 메모리 2048 → 4096 반영
- `core/terraform/outputs.tf`에서 traefik 출력 제거
- `core/terraform/variables.tf`에서 template_id, ssh_public_key 변수 제거
- `core/scripts/` 디렉토리 전체 삭제 (deploy-traefik.sh, configure-traefik.sh 등)
- `scripts/` 루트 디렉토리 삭제 (마이그레이션 유틸리티)

#### Phase 5: 문서 업데이트
- docs/README.md, infra-deployment.md, network-architecture.md를 HAProxy 버전으로 교체
- 마이그레이션 임시 파일 정리

---

## 3. 발생한 문제와 해결 과정

### 문제 1: API 키 인증 실패 (401 Unauthorized)

**증상**: OPNsense API 호출 시 401 에러.

**원인**:
- 1차: 스크린샷에서 API 키를 읽을 때 빨간 점으로 가려진 문자가 있었음.
- 2차: 텍스트로 전달받은 키도 복사 과정에서 오류 발생.

**해결**: 사용자가 OPNsense Web UI에서 **새로운 API 키 쌍을 생성**하고 텍스트로 전달.

**교훈**: API 키는 반드시 텍스트로 전달받을 것. 스크린샷에서 읽지 말 것. 키 생성 경로: `System → Access → Users → root → API keys → + 버튼`.

---

### 문제 2: HAProxy 재시작 실패 (haproxy.conf 파손)

**증상**: `service haproxy restart` 실행 시 `failed precmd routine` 에러.

**원인**: 이전 세션에서 `/usr/local/etc/haproxy.conf`에 `cat >>`로 직접 내용을 추가하면서 bash heredoc의 `EOF` 문자열이 파일에 삽입됨. 이 파일은 OPNsense HAProxy 플러그인이 자동 생성하는 파일로, 수동 수정하면 안 됨.

**해결**:
```bash
# OPNsense 콘솔 (Proxmox Web UI → VM 102 → Console → 옵션 8 Shell)
cp /usr/local/etc/haproxy.conf.staging /usr/local/etc/haproxy.conf
service haproxy restart
```

**교훈**:
- `/usr/local/etc/haproxy.conf`는 절대 수동 수정하지 말 것
- `.staging` 파일이 마지막 정상 설정의 백업 역할을 함
- 모든 HAProxy 설정은 반드시 Web UI 또는 API를 통해 변경할 것
- API로 변경 후에는 `/api/haproxy/service/reconfigure`를 호출하면 conf 파일이 자동 재생성됨

---

### 문제 3: SSH lockout으로 Proxmox → OPNsense 전체 통신 차단

**증상**: Proxmox에서 OPNsense로의 모든 통신이 갑자기 차단됨. SSH, HTTP, API 모두 불통.

**원인**: OPNsense의 `sshlockout` 기능. 여러 번의 SSH 인증 실패 시도로 Proxmox IP (10.0.0.254)가 `sshlockout` pf 테이블에 추가됨. 이 테이블은 SSH뿐 아니라 **해당 IP의 모든 트래픽을 차단**함.

**해결**:
```bash
# OPNsense 콘솔 (Proxmox Web UI → VM 102 → Console → 옵션 8 Shell)
pfctl -t sshlockout -T show        # 차단된 IP 확인
pfctl -t sshlockout -T delete 10.0.0.254   # Proxmox IP 차단 해제
```

**교훈**:
- `sshlockout`은 SSH 실패뿐 아니라 **해당 IP의 모든 프로토콜을 차단**함
- Proxmox → OPNsense 통신이 갑자기 끊기면 가장 먼저 sshlockout 테이블 확인
- 복구는 반드시 Proxmox Web UI의 VM 콘솔에서 직접 접속해야 함 (네트워크 경유 불가)
- OPNsense SSH 인증 시 비밀번호 오류를 반복하지 말 것

---

### 문제 4: WAN "Block private networks" 설정이 로컬 트래픽 차단

**증상**: NAT Router에서 OPNsense WAN (<OPNSENSE_WAN_IP>)으로의 포트 80, 443 접근이 방화벽 규칙 추가 후에도 차단됨.

**원인**: OPNsense WAN 인터페이스의 기본 설정에 **"Block private networks"**가 활성화되어 있음. 이 설정은 RFC 1918 사설 IP 대역(10.0.0.0/8, 172.16.0.0/12, **192.168.0.0/16**)에서 오는 모든 트래픽을 차단함. OPNsense가 NAT Router 뒤 (<EXTERNAL_SUBNET>)에 있으므로, 외부에서 오는 트래픽도 NAT Router NAT 후 <EXTERNAL_SUBNET>.x 소스 IP로 도착하여 차단됨.

**해결**:
1. **Interfaces → WAN** 메뉴 접속
2. **"Block private networks"** 체크박스 해제
3. **Save** 클릭
4. OPNsense 콘솔에서 방화벽 규칙 리로드:
```bash
configctl filter reload
```

**교훈**:
- NAT 공유기 뒤에 OPNsense를 배치할 경우 "Block private networks"를 반드시 비활성화
- 이 설정은 WAN 인터페이스의 기본값으로 활성화되어 있음
- 방화벽 규칙(Pass)보다 이 설정이 **우선** 적용됨
- "Block bogon networks"는 유지해도 됨 (192.168.0.0/16은 bogon이 아님)

---

### 문제 5: 방화벽 자동화 필터 규칙이 저장 후 사라짐

**증상**: API로 `/api/firewall/filter/addRule` 호출하면 "saved" + UUID 반환되지만, 이후 `searchRule`로 조회하면 비어 있음.

**원인**: 문제 #3 (SSH lockout)과 문제 #4 (Block private networks)가 동시에 발생한 상태에서 API 호출이 비정상 상태였음. lockout 해제 및 Block private networks 비활성화 후 재시도하니 정상 저장됨.

**해결**: 문제 #3, #4 먼저 해결 후 규칙 재추가.

---

### 문제 6: ACME 인증서 발급 API 엔드포인트 찾기 실패

**증상**: ACME 인증서 발급을 위한 API 엔드포인트를 찾지 못함.

**시도한 엔드포인트 (모두 실패)**:
- `/api/acmeclient/service/sign/`
- `/api/acmeclient/service/signCertificate/`
- `/api/acmeclient/service/issueCert/`
- `/api/acmeclient/service/issueAllCertificates`

**정확한 엔드포인트**:
```
POST /api/acmeclient/certificates/sign/{uuid}
```

**교훈**: OPNsense 플러그인 API 문서가 불완전한 경우가 있음. 정확한 API 경로는 OPNsense 공식 문서 또는 소스 코드에서 확인할 것.

---

### 문제 7: ACME HTTP-01 챌린지 검증 실패

**증상**: 인증서 발급 시도 시 HTTP-01 챌린지가 실패.

**원인 (복합적)**:
1. HAProxy가 정상 실행 중이지 않았음 (문제 #2)
2. WAN 방화벽이 포트 80을 차단하고 있었음 (문제 #4)
3. OPNsense ACME 플러그인 API 발급이 statusCode 400을 반환 (원인 불명)

**해결**: 수동 `acme.sh` 명령으로 인증서 발급:
```bash
# OPNsense 콘솔에서 직접 실행
/usr/local/sbin/acme.sh \
  --home /var/etc/acme-client/home \
  --issue \
  -d pve.codingmon.dev \
  -d opnsense.codingmon.dev \
  --keylength ec-256 \
  -w /var/etc/acme-client/challenges \
  --server letsencrypt
```

cp-multi-san은 이후 API (`POST /api/acmeclient/certificates/sign/{uuid}`)로 정상 발급됨.

**교훈**:
- ACME 플러그인 API가 실패하면 `acme.sh` 직접 실행으로 우회 가능
- 인증서 파일 위치: `/var/etc/acme-client/home/{도메인}_ecc/`
- 수동 발급한 인증서는 OPNsense Trust Store에 자동 등록되지 않으므로 API로 import 필요

---

### 문제 8: Backend Pool 모드가 TCP로 설정되어 라우팅 불가

**증상**: HTTPS Frontend에서 ACL 기반 라우팅 룰이 적용되지 않음.

**원인**: `proxmox-pool`과 `opnsense-pool`이 **TCP (Layer 4)** 모드로 설정되어 있었음. TCP 모드에서는 HAProxy가 HTTP 헤더를 파싱하지 않으므로 Host 헤더 기반 ACL이 동작하지 않음.

**해결**: 두 Backend Pool의 모드를 **HTTP (Layer 7)**로 변경:
```bash
# API로 Backend Pool 모드 변경
POST /api/haproxy/settings/setBackend/{uuid}
{
  "backend": {
    "mode": "http"
  }
}
```

**교훈**:
- Host 헤더 기반 라우팅을 사용하려면 반드시 HTTP 모드 사용
- Backend Server에 `SSL: Enabled`를 설정하면 HAProxy가 백엔드에 HTTPS로 연결함 (SSL Pass-through와 다름)
- TCP 모드는 L4 로드밸런싱(IP/포트 기반)에만 사용할 것

---

### 문제 9: OPNsense 셸이 csh라서 bash 문법 사용 불가

**증상**: SSH 경유로 OPNsense에서 명령 실행 시 `2>/dev/null` 등 bash 리다이렉션이 `Ambiguous output redirect` 에러 발생.

**원인**: OPNsense (FreeBSD 기반)의 기본 셸은 `csh`로, bash와 문법이 다름.

**해결**: 복잡한 작업은 Python 스크립트로 작성하여 전송 후 실행:
```bash
# 로컬에서 Python 스크립트 작성 → Proxmox 전송 → OPNsense 전송 → 실행
scp script.py <PROXMOX_USER>@<PROXMOX_HOST>:/tmp/
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo scp -o StrictHostKeyChecking=no /tmp/script.py root@10.0.0.1:/tmp/"
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh root@10.0.0.1 'python3 /tmp/script.py'"
```

**교훈**:
- OPNsense에서 `2>/dev/null`, `;`, `&&` 등 bash 특유의 문법은 동작하지 않을 수 있음
- FreeBSD의 `sed`도 GNU 확장(`-i`, `:a;N;$!ba`)을 지원하지 않음
- 복잡한 자동화는 Python 스크립트가 가장 안정적

---

## 4. OPNsense API 자동화 가이드

### 4.1 API 키 생성

1. OPNsense Web UI → `System → Access → Users → root`
2. **API keys** 섹션에서 `+` 버튼 클릭
3. Key와 Secret이 포함된 파일이 다운로드됨
4. 키 형식: `key:secret` (Base64 인코딩하여 Basic Auth 헤더에 사용)

### 4.2 API 접속 패턴

```bash
# 이중 SSH 경유 (로컬 Mac → Proxmox → OPNsense)
ssh <PROXMOX_USER>@<PROXMOX_HOST> 'ssh -o StrictHostKeyChecking=no root@10.0.0.1 \
  "curl -sk -u KEY:SECRET https://localhost/api/..."'
```

**주의**: 이중 SSH에서 따옴표 이스케이프가 복잡하므로, JSON 바디가 필요한 POST 요청은 Python 스크립트 사용을 권장.

### 4.3 주요 API 엔드포인트

#### HAProxy

| 작업 | Method | Endpoint |
|------|--------|----------|
| 상태 확인 | GET | `/api/haproxy/service/status` |
| 설정 적용 (reconfigure) | POST | `/api/haproxy/service/reconfigure` (body 없음) |
| 설정 테스트 | GET | `/api/haproxy/service/configtest` |
| Frontend 목록 | GET | `/api/haproxy/settings/searchFrontends` |
| Frontend 상세 | GET | `/api/haproxy/settings/getFrontend/{uuid}` |
| Frontend 수정 | POST | `/api/haproxy/settings/setFrontend/{uuid}` |
| Backend 목록 | GET | `/api/haproxy/settings/searchBackends` |
| Backend 수정 | POST | `/api/haproxy/settings/setBackend/{uuid}` |
| Server 목록 | GET | `/api/haproxy/settings/searchServers` |
| Server 추가 | POST | `/api/haproxy/settings/addServer` |
| Condition 추가 | POST | `/api/haproxy/settings/addAcl` |
| Rule 추가 | POST | `/api/haproxy/settings/addAction` |

#### ACME Client

| 작업 | Method | Endpoint |
|------|--------|----------|
| 인증서 목록 | GET | `/api/acmeclient/certificates/search` |
| 인증서 발급 | POST | `/api/acmeclient/certificates/sign/{uuid}` |

#### Trust (인증서 저장소)

| 작업 | Method | Endpoint |
|------|--------|----------|
| 인증서 목록 | GET | `/api/trust/cert/search` |
| 인증서 import | POST | `/api/trust/cert/add` |

#### 방화벽

| 작업 | Method | Endpoint |
|------|--------|----------|
| 필터 규칙 추가 | POST | `/api/firewall/filter/addRule` |
| 필터 규칙 적용 | POST | `/api/firewall/filter/apply` |

### 4.4 HAProxy reconfigure 주의사항

```bash
# 올바른 호출 (body 없음)
curl -sk -u KEY:SECRET -X POST https://localhost/api/haproxy/service/reconfigure

# 잘못된 호출 (빈 JSON body → 400 에러)
curl -sk -u KEY:SECRET -X POST -d '{}' https://localhost/api/haproxy/service/reconfigure
```

### 4.5 인증서 import 예시 (Python)

```python
#!/usr/local/bin/python3
import json, ssl, urllib.request, base64

API_KEY = "YOUR_KEY"
API_SECRET = "YOUR_SECRET"
auth_b64 = base64.b64encode(f"{API_KEY}:{API_SECRET}".encode()).decode()

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def api_call(method, url, data=None):
    if data:
        data = json.dumps(data).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('Authorization', f'Basic {auth_b64}')
    resp = urllib.request.urlopen(req, context=ctx)
    return json.loads(resp.read().decode())

# 인증서 import
with open("/path/to/fullchain.cer") as f:
    cert_data = f.read()
with open("/path/to/domain.key") as f:
    key_data = f.read()

result = api_call("POST", "https://localhost/api/trust/cert/add", {
    "cert": {
        "action": "import",
        "descr": "my-certificate",
        "cert_type": "server_cert",
        "private_key_location": "firewall",
        "crt_payload": cert_data,
        "prv_payload": key_data,
        "csr_payload": ""
    }
})
print(result)  # {"result": "saved", "uuid": "..."}
```

---

## 5. 새 도메인 추가 절차

### 5.1 Chaekpool 서비스 도메인 추가 (*.cp.codingmon.dev)

CP Traefik이 HTTP 라우팅을 담당하므로 HAProxy에서는 추가 설정이 거의 필요 없음.

#### Step 1: CP Traefik에 라우팅 규칙 추가

`service/chaekpool/scripts/traefik/configs/services.yml`에 새 서비스 라우팅 추가:

```yaml
http:
  routers:
    new-service:
      rule: "Host(`newservice.cp.codingmon.dev`)"
      service: new-service-svc
  services:
    new-service-svc:
      loadBalancer:
        servers:
          - url: "http://10.1.0.XXX:PORT"
```

#### Step 2: 인증서에 도메인 추가

cp-multi-san 인증서에 새 도메인을 추가하고 재발급:

```bash
# OPNsense 콘솔에서 실행
/usr/local/sbin/acme.sh \
  --home /var/etc/acme-client/home \
  --issue \
  -d postgres.cp.codingmon.dev \
  -d redis.cp.codingmon.dev \
  -d grafana.cp.codingmon.dev \
  -d prometheus.cp.codingmon.dev \
  -d jaeger.cp.codingmon.dev \
  -d jenkins.cp.codingmon.dev \
  -d newservice.cp.codingmon.dev \
  --keylength ec-256 \
  -w /var/etc/acme-client/challenges \
  --server letsencrypt \
  --force
```

#### Step 3: 인증서 재import

새로 발급된 인증서를 Trust Store에 업데이트:

```python
# 기존 인증서를 SET으로 업데이트 (UUID는 기존 것 사용)
result = api_call("POST",
    f"https://localhost/api/trust/cert/set/{existing_cert_uuid}",
    {"cert": {"action": "import", ...}})
```

#### Step 4: HAProxy reconfigure

```bash
curl -sk -u KEY:SECRET -X POST https://localhost/api/haproxy/service/reconfigure
```

#### Step 5: DNS 레코드 확인

`newservice.cp.codingmon.dev`가 외부 IP로 올바르게 resolve되는지 확인.

### 5.2 인프라 도메인 추가 (*.codingmon.dev)

인프라 도메인은 HAProxy에서 직접 라우팅하므로 추가 설정이 더 필요함.

#### Step 1: Backend Server 추가

```bash
# API로 새 Real Server 추가
POST /api/haproxy/settings/addServer
{
  "server": {
    "name": "new-infra-backend",
    "address": "10.0.0.XXX",
    "port": "PORT",
    "mode": "active",
    "ssl": "1",           # HTTPS 백엔드인 경우
    "sslVerify": "0"      # 자체 서명 인증서인 경우
  }
}
```

#### Step 2: Backend Pool 추가

```bash
POST /api/haproxy/settings/addBackend
{
  "backend": {
    "name": "new-infra-pool",
    "mode": "http",            # 반드시 HTTP 모드
    "linkedServers": "SERVER_UUID"
  }
}
```

#### Step 3: Condition 추가

```bash
POST /api/haproxy/settings/addAcl
{
  "acl": {
    "name": "cond_new_infra",
    "expression": "hdr(host)",
    "value": "newinfra.codingmon.dev"
  }
}
```

#### Step 4: Rule 추가

```bash
POST /api/haproxy/settings/addAction
{
  "action": {
    "name": "rule_new_infra",
    "testType": "if",
    "linkedAcls": "CONDITION_UUID",
    "operator": "and",
    "actionName": "use_backend",
    "useBackend": "BACKEND_UUID"
  }
}
```

#### Step 5: HTTPS Frontend에 Rule 연결

```bash
# 기존 linkedActions에 새 Rule UUID 추가
POST /api/haproxy/settings/setFrontend/{https_frontend_uuid}
{
  "frontend": {
    "linkedActions": "existing_rule1_uuid,existing_rule2_uuid,new_rule_uuid"
  }
}
```

#### Step 6: 인증서에 도메인 추가 및 재발급

infra-multi-san 인증서에 새 도메인 추가:

```bash
/usr/local/sbin/acme.sh \
  --home /var/etc/acme-client/home \
  --issue \
  -d pve.codingmon.dev \
  -d opnsense.codingmon.dev \
  -d newinfra.codingmon.dev \
  --keylength ec-256 \
  -w /var/etc/acme-client/challenges \
  --server letsencrypt \
  --force
```

#### Step 7: 인증서 재import + reconfigure

```bash
# Trust Store 업데이트 (Python 스크립트)
# HAProxy reconfigure
curl -sk -u KEY:SECRET -X POST https://localhost/api/haproxy/service/reconfigure
```

---

## 6. 새 네트워크/서비스 추가 절차

### 6.1 새 LXC 컨테이너 추가 (Service Network)

1. `service/chaekpool/terraform/variables.tf`의 `containers` map에 항목 추가
2. `tofu apply`로 컨테이너 생성
3. 배포 스크립트 작성 (`service/chaekpool/scripts/<service>/deploy.sh`)
4. CP Traefik에 라우팅 규칙 추가 (위 5.1 참조)
5. 인증서에 도메인 추가 (위 5.1 참조)

### 6.2 새 네트워크 브리지 추가

OPNsense에서 새 네트워크를 인식하려면:

1. Proxmox에서 새 브리지 생성 (예: vmbr3)
2. OPNsense VM에 새 네트워크 인터페이스 추가
3. OPNsense Web UI → `Interfaces → Assignments`에서 새 인터페이스 할당
4. 새 인터페이스에 IP 주소 설정 및 방화벽 규칙 추가
5. NAT 규칙 추가 (필요 시)

### 6.3 새 Backend Server가 HTTPS인 경우

HAProxy에서 HTTPS 백엔드로 프록시할 때:

- Backend Server 설정에서 `SSL: Enabled`, `Verify SSL: Disabled` (자체 서명인 경우)
- Backend Pool 모드는 반드시 **HTTP** (TCP 아님)
- HAProxy가 프론트엔드에서 SSL 종료 후, 백엔드에 다시 SSL로 연결하는 구조

---

## 7. 인증서 관리

### 7.1 현재 인증서 구조

```
/var/etc/acme-client/home/
├── account.conf
├── ca/
├── pve.codingmon.dev_ecc/          ← infra-multi-san
│   ├── pve.codingmon.dev.cer       ← 서버 인증서
│   ├── pve.codingmon.dev.key       ← 개인 키
│   ├── fullchain.cer               ← 전체 체인 (서버 + 중간 CA)
│   ├── ca.cer                      ← 중간 CA 인증서
│   └── pve.codingmon.dev.conf      ← acme.sh 설정
└── postgres.cp.codingmon.dev_ecc/  ← cp-multi-san
    ├── postgres.cp.codingmon.dev.cer
    ├── postgres.cp.codingmon.dev.key
    ├── fullchain.cer
    ├── ca.cer
    └── postgres.cp.codingmon.dev.conf
```

### 7.2 인증서 자동 갱신

Let's Encrypt 인증서는 90일 유효. 현재 수동 발급이므로 자동 갱신 설정이 필요함.

**OPNsense cron 활용**:
```bash
# OPNsense 콘솔에서 crontab 추가
# System → Settings → Cron에서 추가
# 매주 월요일 03:00에 갱신 시도
0 3 * * 1 /usr/local/sbin/acme.sh --home /var/etc/acme-client/home --cron
```

또는 OPNsense ACME 플러그인의 자동 갱신 기능 활용:
- `Services → ACME Client → Settings → Update Schedule`
- ACME 플러그인 갱신이 정상 동작하면 Trust Store 자동 업데이트까지 처리됨

### 7.3 수동 인증서 갱신 절차

```bash
# 1. OPNsense 콘솔에서 갱신
/usr/local/sbin/acme.sh --home /var/etc/acme-client/home --renew -d pve.codingmon.dev --force

# 2. Trust Store에 재import (Python 스크립트)
# 기존 UUID를 사용하여 SET으로 업데이트

# 3. HAProxy reconfigure
curl -sk -u KEY:SECRET -X POST https://localhost/api/haproxy/service/reconfigure
```

### 7.4 인증서 상태 확인

```bash
# 외부에서 확인
echo | openssl s_client -connect pve.codingmon.dev:443 -servername pve.codingmon.dev 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates

# OPNsense 내부에서 확인
/usr/local/sbin/acme.sh --home /var/etc/acme-client/home --list

# Trust Store 확인 (API)
curl -sk -u KEY:SECRET https://localhost/api/trust/cert/search
```

---

## 8. 트러블슈팅 레퍼런스

### 8.1 빠른 진단 체크리스트

외부에서 서비스 접속 불가 시:

```
1. HAProxy 실행 중인가?
   → API: GET /api/haproxy/service/status
   → 콘솔: service haproxy status

2. WAN 방화벽이 80/443을 허용하는가?
   → 콘솔: pfctl -sr | grep "pass.*80\|pass.*443"

3. "Block private networks"가 비활성화되어 있는가?
   → Interfaces → WAN → Block private networks 체크 해제 확인

4. sshlockout 테이블에 차단된 IP가 있는가?
   → 콘솔: pfctl -t sshlockout -T show

5. Let's Encrypt 인증서가 유효한가?
   → 콘솔: /usr/local/sbin/acme.sh --home /var/etc/acme-client/home --list

6. Backend 서버가 UP 상태인가?
   → HAProxy stats 페이지 확인 (http://10.0.0.1:8404/haproxy-stats)

7. NAT Router 포트 포워딩이 <OPNSENSE_WAN_IP>를 가리키는가?
   → NAT Router 관리 페이지 확인
```

### 8.2 OPNsense 콘솔 접속 방법

네트워크 차단 상황에서 유일한 접속 방법:

1. Proxmox Web UI (https://10.0.0.254:8006 또는 https://pve.codingmon.dev) 접속
2. 좌측 메뉴에서 **VM 102 (opnsense)** 선택
3. **Console** 탭 클릭
4. OPNsense 메뉴에서 **8) Shell** 입력

### 8.3 HAProxy 설정 복구

haproxy.conf가 손상된 경우:

```bash
# staging 파일에서 복구
cp /usr/local/etc/haproxy.conf.staging /usr/local/etc/haproxy.conf
service haproxy restart

# 또는 API로 reconfigure (conf 파일 자동 재생성)
curl -sk -u KEY:SECRET -X POST https://localhost/api/haproxy/service/reconfigure
```

### 8.4 SSH lockout 해제

```bash
# 차단 목록 확인
pfctl -t sshlockout -T show

# 특정 IP 해제
pfctl -t sshlockout -T delete <IP>

# 전체 해제
pfctl -t sshlockout -T flush
```

### 8.5 인증서 긴급 재발급

```bash
# infra-multi-san
/usr/local/sbin/acme.sh \
  --home /var/etc/acme-client/home \
  --issue \
  -d pve.codingmon.dev \
  -d opnsense.codingmon.dev \
  --keylength ec-256 \
  -w /var/etc/acme-client/challenges \
  --server letsencrypt \
  --force

# cp-multi-san
/usr/local/sbin/acme.sh \
  --home /var/etc/acme-client/home \
  --issue \
  -d postgres.cp.codingmon.dev \
  -d redis.cp.codingmon.dev \
  -d grafana.cp.codingmon.dev \
  -d prometheus.cp.codingmon.dev \
  -d jaeger.cp.codingmon.dev \
  -d jenkins.cp.codingmon.dev \
  --keylength ec-256 \
  -w /var/etc/acme-client/challenges \
  --server letsencrypt \
  --force

# 발급 후 Trust Store import + HAProxy reconfigure 필요
```

---

## 9. 현재 HAProxy 설정 상태

### 9.1 Real Servers

| Name | IP:Port | SSL | 용도 |
|------|---------|-----|------|
| proxmox-backend | 10.0.0.254:8006 | Yes | Proxmox Web UI |
| opnsense-webui | 127.0.0.1:443 | Yes | OPNsense Web UI |
| cp-traefik-backend | 10.1.0.100:80 | No | CP Traefik HTTP |
| acme_challenge_host | (ACME용) | No | ACME 챌린지 |

### 9.2 Backend Pools

| Pool Name | Mode | Server | Health Check |
|-----------|------|--------|--------------|
| proxmox-pool | HTTP | proxmox-backend | TCP |
| opnsense-pool | HTTP | opnsense-webui | TCP |
| cp-traefik-pool | HTTP | cp-traefik-backend | HTTP GET |

### 9.3 Conditions (ACLs)

| Name | UUID (short) | Expression | Value |
|------|-------------|------------|-------|
| cond_pve | 042e676b | Host matches | pve.codingmon.dev |
| cond_opnsense | 8500959f | Host matches | opnsense.codingmon.dev |

### 9.4 Rules (Actions)

| Name | UUID (short) | Condition | Action | Target |
|------|-------------|-----------|--------|--------|
| rule_pve | 3be84b38 | cond_pve | use_backend | proxmox-pool |
| rule_opnsense | aebc38ca | cond_opnsense | use_backend | opnsense-pool |
| rule_https_redirect | f540830f | — | redirect https 301 | — |

### 9.5 Frontends

| Name | Bind | Mode | Default Backend | SSL | Linked Rules |
|------|------|------|-----------------|-----|--------------|
| http-frontend | <OPNSENSE_WAN_IP>:80 | HTTP | — | No | redirect_acme_challenges, rule_https_redirect |
| https-frontend | <OPNSENSE_WAN_IP>:443 | HTTP | cp-traefik-pool | Yes | rule_pve, rule_opnsense |

### 9.6 Trust Store 인증서

| Name | refid | 용도 |
|------|-------|------|
| infra-multi-san | 698b0846c3b2f | pve + opnsense SSL |
| cp-multi-san | 698b0846cee09 | 6개 cp 도메인 SSL |
| Web GUI TLS certificate (x2) | 690acde654bc5, 69884d1e511c4 | OPNsense 자체 WebUI |

---

## 10. OPNsense 접속 방법

### 10.1 Web UI

- 관리 네트워크에서: `https://10.0.0.1`
- 외부에서: `https://opnsense.codingmon.dev`

### 10.2 SSH (VPN 연결 후)

```bash
# Proxmox 경유 (VPN 필수)
ssh <PROXMOX_USER>@<PROXMOX_HOST>
sudo ssh root@10.0.0.1
```

### 10.3 API (이중 SSH)

```bash
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo ssh -o StrictHostKeyChecking=no root@10.0.0.1 \
  'curl -sk -u KEY:SECRET https://localhost/api/haproxy/service/status'"
```

### 10.4 콘솔 (네트워크 차단 시)

Proxmox Web UI → VM 102 → Console → 옵션 8 Shell

**이 방법은 sshlockout이나 방화벽 차단 상황에서 유일한 접속 방법.**
