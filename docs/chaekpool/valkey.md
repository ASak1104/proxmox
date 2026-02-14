# Valkey + Redis Commander (CT 211)

## 개요

Valkey 인메모리 데이터 스토어와 Redis Commander 웹 관리 도구.

- **IP**: 10.1.0.111
- **포트**: 6379 (Valkey), 8081 (Redis Commander)
- **접속 URL**: `http://10.1.0.111:8081` (Redis Commander, VPN 직접 접근)

## 배포

```bash
bash service/chaekpool/scripts/valkey/deploy.sh
```

배포 단계:
1. Valkey 패키지 설치 (`apk add valkey`)
2. Valkey 설정 파일 및 OpenRC 서비스 배포
3. Valkey 서비스 시작
4. Redis Commander 설치 (npm global install)
5. Redis Commander OpenRC 서비스 배포 및 시작

## 설정

### Valkey (`/etc/valkey/valkey.conf`)

주요 설정:

```conf
# 네트워크
bind 10.1.0.111 127.0.0.1
port 6379
protected-mode yes

# 인증
requirepass changeme

# 스냅샷
save 900 1
save 300 10
save 60 10000
dbfilename dump.rdb
dir /var/lib/valkey

# 메모리
maxmemory 256mb
maxmemory-policy allkeys-lru

# AOF
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
```

- `bind`: 서비스 네트워크 IP와 localhost에만 바인딩
- `requirepass`: `common.sh`의 `VALKEY_PASSWORD`와 동기화 필요
- `maxmemory`: 256MB 제한, LRU 정책으로 오래된 키 자동 삭제
- AOF + 스냅샷 이중 영속화

### Redis Commander

- **설치 경로**: `/usr/local/lib/node_modules/redis-commander/`
- **포트**: 8081

## 검증

```bash
# Valkey 상태
pct_exec 211 "rc-service valkey status"

# Valkey 접속 테스트
pct_exec 211 "valkey-cli -a <비밀번호> ping"

# Redis Commander 상태
pct_exec 211 "rc-service redis-commander status"
```

Redis Commander 웹 UI: `http://10.1.0.111:8081` (VPN 직접 접근)

## 운영

```bash
# Valkey
pct_exec 211 "rc-service valkey start"
pct_exec 211 "rc-service valkey stop"
pct_exec 211 "rc-service valkey restart"

# Redis Commander
pct_exec 211 "rc-service redis-commander start"
pct_exec 211 "rc-service redis-commander stop"
pct_exec 211 "rc-service redis-commander restart"

# Valkey 로그
pct_exec 211 "tail -f /var/log/valkey/valkey.log"

# Valkey CLI 모니터링
pct_exec 211 "valkey-cli -a <비밀번호> monitor"
pct_exec 211 "valkey-cli -a <비밀번호> info memory"
```

## 트러블슈팅

**Redis Commander 실행 안 됨**
- Node.js 설치 확인: `pct_exec 211 "node --version"`
- npm 글로벌 패키지 확인: `pct_exec 211 "npm list -g redis-commander"`
- 로그 확인: `/var/log/redis-commander.log`

**Valkey 접속 실패**
- `bind` 설정에 클라이언트가 접근하는 IP가 포함되어 있는지 확인
- `requirepass`가 설정되어 있으므로 인증 필수
- `protected-mode yes` 상태에서 비밀번호 없이 접속 불가

**메모리 초과**
- `valkey-cli info memory`로 현재 사용량 확인
- `maxmemory-policy allkeys-lru`에 의해 자동으로 오래된 키 삭제

## 참조 파일

| 파일 | 설명 |
|------|------|
| `service/chaekpool/scripts/valkey/deploy.sh` | 배포 스크립트 |
| `service/chaekpool/scripts/valkey/configs/valkey.conf` | Valkey 설정 |
| `service/chaekpool/scripts/valkey/configs/valkey.openrc` | Valkey OpenRC 서비스 |
| `service/chaekpool/scripts/valkey/configs/redis-commander.openrc` | Redis Commander OpenRC 서비스 |
