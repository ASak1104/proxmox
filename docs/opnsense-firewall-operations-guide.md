# OPNsense 방화벽 운영 가이드

> **작성일**: 2026-04-11
> **대상**: OPNsense pf 방화벽 계층 (L3/L4, NAT, ruleset, state table)
> **범위**: pf 룰셋 장애 진단·복구 매뉴얼, 발생한 문제 기록, 진단 체크리스트
> **관련 문서**: L7 리버스 프록시(HAProxy) 관련은 [opnsense-haproxy-operations-guide.md](opnsense-haproxy-operations-guide.md) 참조

---

## 목차

1. [개요](#1-개요)
2. [빠른 복구 매뉴얼](#2-빠른-복구-매뉴얼)
3. [발생한 문제와 해결 과정](#3-발생한-문제와-해결-과정)
4. [진단 체크리스트](#4-진단-체크리스트)
5. [참고 자료](#5-참고-자료)

---

## 1. 개요

### 1.1 OPNsense 계층 분리

OPNsense VM(102)은 홈랩의 방화벽·라우터·SSL 종료점·VPN 서버 네 가지 역할을 겸한다. 본 가이드는 이 중 **방화벽(pf ruleset, NAT, state table)** 계층만 다룬다. HAProxy(L7 리버스 프록시) 관련 운영은 별도 가이드를 참조.

```
[클라이언트]
    │
    ▼
[OPNsense VM 102]
 ├─ pf (L3/L4)         ← 본 가이드 범위
 │   ├─ ruleset: /tmp/rules.debug (자동 생성)
 │   ├─ NAT outbound: cp LAN → WAN 자동 룰
 │   ├─ tables: bogons, bogonsv6, sshlockout, ...
 │   └─ state table: stateful inspection
 │
 ├─ HAProxy (L7)       ← opnsense-haproxy-operations-guide.md
 ├─ Unbound (DNS)      ← pf ruleset 로드 여부와 무관하게 동작
 └─ WireGuard (VPN)    ← docs/vpn-operations-guide.md
```

### 1.2 pf 룰셋 전체 로드 실패의 영향

OPNsense 는 `config.xml` → `/tmp/rules.debug` → `pfctl -f` 경로로 pf 룰을 적용한다. 이 과정에서 **단 한 줄이라도 syntax error 가 발생하면 전체 ruleset 이 rollback** 되고 pf 는 기본 default-deny 상태로 구동된다.

영향 범위:
- 사용자 정의 NAT 아웃바운드 룰 **전부 미적용** (cp LAN 10.1.0.0/24 → WAN NAT 불가)
- 사용자 정의 pass 룰 **전부 미적용** (모든 forward 트래픽 drop)
- 단, **Unbound(DNS)는 pf 와 독립적으로 동작** → DNS 질의는 정상 응답. 이 점이 진단을 혼란스럽게 만든다.

### 1.3 bogons / bogonsv6 테이블

OPNsense `Interfaces → WAN → Block bogon networks` 를 켜면 pf 룰셋에 아래 구문이 삽입된다:

```
table <bogons>   persist file "/usr/local/etc/bogons"
table <bogonsv6> persist file "/usr/local/etc/bogonsv6"
```

| 파일 | 내용 | 관리 주체 |
|---|---|---|
| `/usr/local/etc/bogons.sample` | 패키지 동봉 IPv4 bogons 기본 리스트 | OPNsense 패키지 |
| `/usr/local/etc/bogonsv6.sample` | 패키지 동봉 IPv6 bogons 기본 리스트 (76줄) | OPNsense 패키지 |
| `/usr/local/etc/bogons` | 런타임 IPv4 bogons (firmware/bogons.sh 가 갱신) | 갱신 스크립트 |
| `/usr/local/etc/bogonsv6` | 런타임 IPv6 bogons (firmware/bogons.sh 가 갱신) | 갱신 스크립트 |

**핵심**: `.sample` 파일은 패키지 설치 시 배포되며, 런타임 갱신 파일이 손상되어도 sample 은 건드리지 않는다. 따라서 **복구 시 항상 사용 가능한 fallback** 이다.

---

## 2. 빠른 복구 매뉴얼

> **재발 시 이 섹션만 보면 5분 내 복구 가능.**

### 2.1 증상 인식 (30초)

아래 패턴이 2개 이상 겹치면 [문제 #1](#문제-1-bogonsv6-파일-손상으로-인한-pf-룰셋-로드-실패) 의심:

- cp LAN 컨테이너(`10.1.0.0/24`)에서 **외부 HTTPS 전체 실패** (curl/wget timeout)
- `nslookup` 은 되는데 `curl` 은 안 됨 → DNS 는 정상, TCP 는 불통
- 브라우저에서 **여러 서비스가 동시에 이상** (Grafana OIDC, pgAdmin 504, API 외부 호출 실패)
- OPNsense Web UI 의 Gateways/NAT/Firewall Rules 는 전부 **녹색/정상**으로 보임
- 직전 재부팅 이후 첫 개발 세션

### 2.2 30초 확정 진단

OPNsense Web UI → `System → Log Files → General` (또는 `Firewall → Log Files → General`)

- Severity 필터 `Error` 적용
- Process 필터 `firewall` 적용
- 아래 메시지가 보이면 **확정**:

```
There were error(s) loading the rules:
/tmp/rules.debug: cannot load "/usr/local/etc/bogonsv6": Invalid argument
/usr/local/etc/rc.filter_configure: The command </sbin/pfctl -f '/tmp/rules.debug.old'>
  returned exit code 1 and the output was
  "pfctl: Syntax error in config file: pf rules not loaded"
```

확정되면 바로 2.3 으로.

### 2.3 5분 복구

**OPNsense 쉘 진입**: Proxmox Web UI → VM 102 (`opnsense`) → Console → 메뉴에서 `8` 입력 → root 쉘

```sh
# 손상된 파일 백업
cp /usr/local/etc/bogonsv6 /usr/local/etc/bogonsv6.broken
# 패키지 동봉 sample 을 런타임 파일로 복사
cp /usr/local/etc/bogonsv6.sample /usr/local/etc/bogonsv6
# pf 룰셋 재적재
configctl filter reload
```

기대 결과: 마지막 명령이 `OK` 출력 후 조용히 프롬프트 복귀.

다시 에러가 뜨면 중단하고 파일 내용 재확인:
```sh
head -c 16 /usr/local/etc/bogonsv6 | od -An -c
wc -l /usr/local/etc/bogonsv6
```

### 2.4 복구 검증

cp LAN 컨테이너에서 외부 TCP 도달 확인 (VPN 연결된 상태의 로컬 쉘에서):

```sh
ssh root@10.1.0.120 "nc -zv 1.1.1.1 443"
# 기대 출력: "1.1.1.1 (1.1.1.1:443) open"
```

브라우저로 end-to-end 확인:
- `https://grafana.cp.codingmon.dev` → OIDC 로그인 성공
- `https://pgadmin.cp.codingmon.dev` → 로그인 화면 정상 (504 아님)
- `https://api.cp.codingmon.dev/swagger-ui/...` → Kakao 로그인 성공

추가로 `System → Log Files → General` 에 새 rule load 에러가 없는지 마지막 확인.

---

## 3. 발생한 문제와 해결 과정

### 문제 1: bogonsv6 파일 손상으로 인한 pf 룰셋 로드 실패

**발생**: 2026-04-01 03:13 (OPNsense 재부팅 중)
**발견**: 2026-04-11 (개발 세션 재개 시)
**복구**: 2026-04-11 동일 세션

#### 증상

컨테이너별 외부 증상은 서로 달랐지만 근본 원인은 하나였다:

| 서비스 | 외부 증상 | 근본 원인 |
|---|---|---|
| Grafana | 로그인 시 `Login failed / Failed to get token from provider` | Grafana → `authelia.cp.codingmon.dev`(외부 hairpin) TCP timeout |
| pgAdmin | HTTP `504 Gateway Time-out` | gunicorn worker 가 OIDC discovery(외부 HTTPS) 중 block → Traefik timeout |
| API Swagger | `Connect timed out executing POST https://kauth.kakao.com/oauth/token` | API 컨테이너 → 카카오 OAuth 엔드포인트 TCP timeout |

**공통점**: 전부 **cp LAN → 외부 HTTPS** 아웃바운드 경로. DNS(UDP 53)는 정상 — Unbound 가 pf 룰셋과 무관하게 응답하기 때문. 이 비대칭 때문에 "DNS는 되는데 외부 접속은 안 됨" 이라는 비직관적 상태가 만들어진다.

#### 원인

**OPNsense `firmware/bogons.sh` 의 파일 쓰기 경로가 파일시스템 경계를 넘는 `mv` 를 사용하며, 이는 atomic 하지 않다.**

스크립트 관련 부분 (`/usr/local/opnsense/scripts/firmware/bogons.sh`):

```sh
WORKDIR="/tmp/bogons"       # tmpfs (RAM)
DESTDIR="/usr/local/etc"    # UFS (disk)

update_bogons() {
    ...
    cat ${WORKDIR}/${SRC} >> ${WORKDIR}/${DST}
    mv ${WORKDIR}/${DST} ${DESTDIR}/${DST}   # ← tmpfs → UFS 경계
}
```

서로 다른 파일시스템 간 `mv` 는 `rename(2)` 가 아니라 **copy + unlink** 로 폴백한다. copy 도중 시스템이 재부팅/종료되면:

1. UFS 저널이 **파일 크기(metadata)** 는 반영
2. 데이터 블록 내용은 `fsync` 이전이라 디스크에 flush 되지 않음
3. 재부팅 후 파일을 읽으면 "크기는 잡혔는데 내용은 전부 null byte"

우리 케이스에서 확인된 손상 파일:

```sh
# ls -la /usr/local/etc/bogonsv6
-rw-r----- 1 root wheel 393216 Apr  1 03:13 /usr/local/etc/bogonsv6
# wc -l /usr/local/etc/bogonsv6
       0 /usr/local/etc/bogonsv6
# head -c 16 /usr/local/etc/bogonsv6 | od -An -c
   \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0  \0
```

이후 pf 가 룰셋을 로드할 때 `table <bogonsv6> persist file "/usr/local/etc/bogonsv6"` 구문의 파일 내용이 유효한 CIDR 이 아니므로 `pfctl` 이 `Invalid argument` 로 거부 → **전체 ruleset 로드 실패** → pf 는 default-deny 최소 상태로 구동 → 사용자 정의 NAT·pass 룰이 전부 없음 → cp LAN 아웃바운드 전면 차단.

**알려진 intermittent issue**: pfSense 2.7 과 OPNsense 여러 버전에서 동일 증상이 여러 해에 걸쳐 보고되었다. Netgate 운영자는 "부팅 초기화 타이밍 문제" 로 규정했고, 업스트림 근본 수정은 2026-04 현재 존재하지 않는다.

#### 진단 과정 (실제 수행 순서)

이번 세션에서 밟은 순서를 그대로 기록 — **다음 세션에서는 7번으로 바로 점프** 할 것.

1. **서비스 레이어 확인**: 7개 호스트 OpenRC 상태 일괄 점검 → 전부 10일간 `started`, crashed 0개 → 서비스는 아무 문제 없음
2. **백엔드 직결 probe**: Traefik(10.1.0.100) 에서 `http://10.1.0.110:5050`(pgAdmin), `http://10.1.0.120:3000`(Grafana) → 둘 다 `200 OK` → 백엔드 살아있음
3. **로그 상관 분석**: Grafana/pgAdmin/API 에러가 전부 "외부 HTTPS 연결 timeout" 으로 수렴하는 패턴 발견
4. **외부 TCP 교차 검증**:
   - cp-monitoring(10.1.0.120) 에서 `nc -zv 1.1.1.1 443` / `8.8.8.8 53` / `kauth.kakao.com:443` → **전부 timeout**
   - Proxmox 호스트(vmbr0 직결) 에서 동일 테스트 → **전부 OK**
   - 결론: 상위 회선·인터넷은 건강, **OPNsense cp LAN → WAN forwarding 만 깨짐**
5. **OPNsense Web UI 설정 확인**:
   - `System → Gateways → Status`: WAN online, packet loss 0%
   - `Interfaces → Assignments`: vtnet0(WAN) / vtnet1(LAN) / vtnet2(SERVICE_CP) 정상
   - `Firewall → NAT → Outbound`: Automatic 모드, SERVICE_CP networks 자동 룰 존재
   - `Firewall → Rules → SERVICE_CP`: `pass SERVICE_CP net → any` 룰 존재
   - **UI 상으로는 완벽** — 여기서 초반 시간 낭비
6. **잘못된 가설 (pf state 꼬임)**: `configctl filter reload` 시도 → `OK` 떴지만 증상 그대로. 이 시점에서 "설정은 맞는데 런타임이 이상하다" 라는 가설로 이동
7. **결정적 단서**: `System → Log Files → General` 에서 rule load 에러 발견
   ```
   /tmp/rules.debug:24: cannot load "/usr/local/etc/bogonsv6": Invalid argument
   pfctl: Syntax error in config file: pf rules not loaded
   ```
8. **파일 확인**: 위의 "원인" 섹션 `od` 출력 — 전부 null byte 로 확정

#### 해결

OPNsense 패키지 동봉 `bogonsv6.sample` 파일을 런타임 파일로 복사:

```sh
cp /usr/local/etc/bogonsv6.sample /usr/local/etc/bogonsv6
configctl filter reload
```

선택 근거:
- `bogonsv6.sample` 은 76줄의 유효한 IETF/IANA 예약 IPv6 블록 리스트 (2000::/16, 2001:1000::/23, ...)
- 네트워크 의존성 0 → 재현성 100%
- Team Cymru 풀 리스트보다는 작지만 bogon 차단 효과 충분
- 다음 firmware set 동기화 시 자연스럽게 최신화될 것

진단 과정에서 `WAN → Block bogon networks` 를 임시 해제했던 경우, 복구 후 **반드시 재체크 → Save → Apply Changes** 로 되돌릴 것.

#### 검증

1. 파일 상태:
   ```sh
   ls -la /usr/local/etc/bogonsv6   # 약 860 bytes
   wc -l /usr/local/etc/bogonsv6    # 76
   head -3 /usr/local/etc/bogonsv6  # 2000::/16 / 2001:1000::/23 / 2001:100::/24
   ```
2. pf 리로드: `configctl filter reload` → `OK`
3. cp LAN 아웃바운드:
   ```sh
   ssh root@10.1.0.120 "nc -zv 1.1.1.1 443"
   ```
4. End-to-end:
   - `curl -fsS https://grafana.cp.codingmon.dev/api/health` → `200 OK`
   - 브라우저 Grafana OIDC / pgAdmin / Swagger Kakao 로그인 성공
5. `System → Log Files → General` 에 새 rule load 에러 없음 확인

#### 교훈

- **진단 첫 확인처는 `System → Log Files → General` 의 rule load 에러**. UI 설정은 정상인데 forward 트래픽이 전부 막히면 거의 이 케이스. Gateways/NAT/Rules 보는 것보다 **로그를 먼저** 볼 것.
- **Unbound 가 DNS 를 계속 응답하므로 DNS 테스트만으로는 절대 감지 불가**. `nslookup` 성공은 "OPNsense 가 살아있다" 는 증거가 아니다. TCP probe (`nc -zv`, `curl`) 가 필수.
- **`configctl filter reload` 는 손상된 파일을 수리하지 않는다**. 룰셋 재컴파일만 할 뿐. 원본 파일이 여전히 깨진 상태면 같은 에러로 끝남. 파일 내용을 먼저 고쳐야 한다.
- **`.sample` 파일은 패키지 업그레이드 후에도 유지되는 영구 fallback**. 복구는 2줄이면 끝. 이 복구 경로를 알고 있는 것과 모르는 것의 차이는 수십 분.
- "UI 설정 정상 + 외부 TCP 불통" 패턴을 보면 pf state 꼬임 가설로 빠지지 말고 바로 로그 확인으로 점프할 것.

---

## 4. 진단 체크리스트

cp LAN 컨테이너의 외부 HTTPS 가 안 될 때 순서대로 1분씩 질답:

| # | 확인 | 명령 | 해석 |
|---|---|---|---|
| 1 | 컨테이너 프로세스 상태 | `ssh root@<host> "rc-status default"` | `started` 아니면 OpenRC 쪽 문제로 분기 |
| 2 | 컨테이너 DNS | `ssh root@<host> "nslookup kauth.kakao.com 10.1.0.1"` | 실패 시 Unbound 문제로 분기 |
| 3 | 컨테이너 외부 TCP | `ssh root@<host> "nc -zv 1.1.1.1 443"` | open 이면 이 가이드 대상 아님 |
| 4 | Proxmox 호스트 외부 TCP | Proxmox 에서 `timeout 3 nc -zv 1.1.1.1 443` | fail 이면 상위 회선 문제 (이 가이드 대상 아님) |
| 5 | OPNsense rule load 에러 | Web UI `System → Log Files → General`, filter `Error` | 있으면 [문제 #1](#문제-1-bogonsv6-파일-손상으로-인한-pf-룰셋-로드-실패) 확정 |

**판정**: (1)(2) OK + (3) FAIL + (4) OK + (5) 에러 발견 → 문제 #1. [2.3 복구](#23-5분-복구) 로 이동.

---

## 5. 참고 자료

### 5.1 OPNsense 내부 파일 / 스크립트

- `/usr/local/opnsense/scripts/firmware/bogons.sh` — bogons 갱신 스크립트 (atomic-aware 가 아님)
- `/usr/local/etc/bogons.sample` — 패키지 동봉 IPv4 bogons 기본 리스트
- `/usr/local/etc/bogonsv6.sample` — 패키지 동봉 IPv6 bogons 기본 리스트 (76줄)
- `/tmp/rules.debug` — OPNsense 가 자동 생성하는 pf 룰셋 (직접 편집 금지)
- `configctl filter reload` — pf 룰셋 재컴파일·재적재 커맨드

### 5.2 OPNsense 쉘 접속 방법

1. Proxmox Web UI → VM 102 (`opnsense`) → Console (noVNC)
2. 콘솔 메뉴에서 `8` 입력 → root 쉘 (csh)
3. 주의: OPNsense 쉘은 **csh**. `2>/dev/null`, `2>&1 |` 같은 bash 리다이렉트 문법 불가. 필요 시 `|& head`, `>& /dev/null` 사용.

### 5.3 외부 레퍼런스 (유사 이슈)

- [Netgate Forum — cannot load /etc/bogonsv6: Invalid argument](https://forum.netgate.com/topic/182876/cannot-load-etc-bogonsv6-invalid-argument) — pfSense 2.7 동일 증상, "부팅 초기화 타이밍 문제" 로 규정
- [OPNsense Forum — New/Updated Bogons list breaks all sorts of stuff](https://forum.opnsense.org/index.php?topic=47827.0) — "bogonsv6 is, as always, broken" 코멘트
- [OPNsense GitHub Issue #6534 — v6 BOGONs list out of date](https://github.com/opnsense/core/issues/6534) — Team Cymru 소스 + 주간 갱신 정책 확인
