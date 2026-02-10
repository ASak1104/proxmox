# 서비스별 로그 확인 가이드

Proxmox 호스트에서 `pct exec`로 각 컨테이너에 접근하여 로그를 확인한다. VPN 연결 필수.

```bash
# 기본 접근 패턴
ssh <PROXMOX_USER>@<PROXMOX_HOST> "sudo pct exec <VMID> -- <명령>"
```

---

## CT 200 — CP Traefik

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/traefik/traefik.log` | Traefik 시작/오류/라우팅 로그 |
| 접근 로그 | `/var/log/traefik/access.log` | HTTP 요청별 접근 기록 |

```bash
# 실시간 서비스 로그
pct exec 200 -- tail -f /var/log/traefik/traefik.log

# 실시간 접근 로그
pct exec 200 -- tail -f /var/log/traefik/access.log

# 서비스 상태 확인
pct exec 200 -- rc-service traefik status
```

---

## CT 210 — PostgreSQL + pgAdmin

### PostgreSQL

| 로그 | 경로 | 설명 |
|------|------|------|
| DB 로그 | `/var/lib/postgresql/16/data/log/` | 쿼리, 에러, 슬로우 쿼리 로그 |

```bash
# PostgreSQL 로그 (로그 디렉토리가 활성화된 경우)
pct exec 210 -- ls /var/lib/postgresql/16/data/log/
pct exec 210 -- tail -f /var/lib/postgresql/16/data/log/postgresql-*.log

# 기본 출력 로그 (logging_collector 비활성 시)
pct exec 210 -- su - postgres -s /bin/sh -c "pg_ctl -D /var/lib/postgresql/16/data status"

# 활성 연결 확인
pct exec 210 -- su - postgres -s /bin/sh -c "psql -c 'SELECT * FROM pg_stat_activity;'"

# 서비스 상태
pct exec 210 -- rc-service postgresql status
```

### pgAdmin 4

| 로그 | 경로 | 설명 |
|------|------|------|
| 애플리케이션 로그 | `/var/log/pgadmin/pgadmin.log` | 웹 UI 요청 및 에러 |

```bash
# 실시간 로그
pct exec 210 -- tail -f /var/log/pgadmin/pgadmin.log

# 서비스 상태
pct exec 210 -- rc-service pgadmin4 status
```

---

## CT 211 — Valkey + Redis Commander

### Valkey

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/valkey/valkey.log` | 시작, 연결, 메모리, 지속성 이벤트 |

```bash
# 실시간 로그
pct exec 211 -- tail -f /var/log/valkey/valkey.log

# 실시간 명령 모니터링 (주의: 프로덕션에서 부하 발생 가능)
pct exec 211 -- valkey-cli -a changeme MONITOR

# 슬로우 쿼리 확인
pct exec 211 -- valkey-cli -a changeme SLOWLOG GET 10

# 메모리 사용량
pct exec 211 -- valkey-cli -a changeme INFO memory

# 서비스 상태
pct exec 211 -- rc-service valkey status
```

### Redis Commander

| 로그 | 경로 | 설명 |
|------|------|------|
| 애플리케이션 로그 | `/var/log/redis-commander.log` | 웹 UI 및 연결 로그 |

```bash
# 실시간 로그
pct exec 211 -- tail -f /var/log/redis-commander.log

# 서비스 상태
pct exec 211 -- rc-service redis-commander status
```

---

## CT 220 — Monitoring (Prometheus / Grafana / Loki / Jaeger)

### Prometheus

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/prometheus.log` | 스크레이프 상태, 타겟 에러, TSDB 상태 |

```bash
# 실시간 로그
pct exec 220 -- tail -f /var/log/prometheus.log

# 타겟 상태 확인 (API)
pct exec 220 -- wget -qO- http://localhost:9090/api/v1/targets | head -100

# TSDB 상태
pct exec 220 -- wget -qO- http://localhost:9090/api/v1/status/tsdb

# 서비스 상태
pct exec 220 -- rc-service prometheus status
```

### Grafana

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/grafana/grafana.log` | 대시보드, 데이터소스, 인증 로그 |

```bash
# 실시간 로그
pct exec 220 -- tail -f /var/log/grafana/grafana.log

# 에러만 필터
pct exec 220 -- grep -i "error\|warn" /var/log/grafana/grafana.log | tail -20

# 헬스체크
pct exec 220 -- wget -qO- http://localhost:3000/api/health

# 서비스 상태
pct exec 220 -- rc-service grafana status
```

### Loki

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/loki.log` | 인제스터, 컴팩터, 스토리지 상태 |

```bash
# 실시간 로그
pct exec 220 -- tail -f /var/log/loki.log

# 레디니스 확인
pct exec 220 -- wget -qO- http://localhost:3100/ready

# 서비스 상태
pct exec 220 -- rc-service loki status
```

### Jaeger

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/jaeger.log` | 수신기, 프로세서, Badger 스토리지 상태 |

```bash
# 실시간 로그
pct exec 220 -- tail -f /var/log/jaeger.log

# 헬스체크
pct exec 220 -- wget -qO- http://localhost:16686/

# 서비스 상태
pct exec 220 -- rc-service jaeger status
```

### CT 220 전체 서비스 한번에 확인

```bash
# 모든 모니터링 서비스 상태
pct exec 220 -- rc-status

# 모든 로그 동시 확인 (멀티 tail)
pct exec 220 -- tail -f /var/log/prometheus.log /var/log/grafana/grafana.log /var/log/loki.log /var/log/jaeger.log
```

---

## CT 230 — Jenkins

| 로그 | 경로 | 설명 |
|------|------|------|
| 서비스 로그 | `/var/log/jenkins/jenkins.log` | Jenkins 시작, 플러그인, 빌드 로그 |

```bash
# 실시간 로그
pct exec 230 -- tail -f /var/log/jenkins/jenkins.log

# 초기 관리자 비밀번호 확인
pct exec 230 -- cat /var/lib/jenkins/secrets/initialAdminPassword

# 서비스 상태
pct exec 230 -- rc-service jenkins status
```

---

## CT 240 — Kopring

| 로그 | 경로 | 설명 |
|------|------|------|
| 애플리케이션 로그 | `/var/log/kopring/kopring.log` | Spring Boot 요청, 에러, SQL 로그 |

```bash
# 실시간 로그
pct exec 240 -- tail -f /var/log/kopring/kopring.log

# 에러만 필터
pct exec 240 -- grep -i "error\|exception" /var/log/kopring/kopring.log | tail -20

# 액추에이터 헬스
pct exec 240 -- wget -qO- http://localhost:8080/actuator/health

# 서비스 상태
pct exec 240 -- rc-service kopring status
```

---

## 로그 집중화 (Loki 연동)

각 서비스의 로그를 Loki로 전송하려면 **Promtail** 또는 **Grafana Alloy**를 각 컨테이너에 설치한다.

```
각 CT의 로그 파일 → Promtail/Alloy → Loki (10.1.0.120:3100) → Grafana 대시보드
```

Grafana에서 `grafana.cp.codingmon.dev` 접속 후 Explore > Loki 데이터소스에서 로그를 검색할 수 있다.
