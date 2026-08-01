# kb7-test-demo

## 구성 요소

| 구성 요소 | 설명 |
|---|---|
| Spring Boot App | Docker(기본) 또는 로컬, `localhost:8080`, 병목 재현/해결 엔드포인트 3개 제공 |
| MySQL | Docker, `localhost:13306`, `orders` 테이블 100만 건 |
| Redis | Docker, `localhost:16379`, 캐싱 데모용 |
| Prometheus | Docker, `localhost:9090`, 앱의 `/actuator/prometheus` 스크레이핑 + k6 remote-write 수신 |
| InfluxDB | Docker, `localhost:8086`, k6 결과 저장용 DB(`k6`) |
| Grafana | Docker, `localhost:3000`, `kb7 Bottleneck Demo` + `k6 Load Testing Results` 대시보드 자동 프로비저닝 |
| k6 | 로컬 설치, `k6/` 디렉터리의 스크립트로 부하 생성, 실행 중 Prometheus·InfluxDB로 동시 전송 |

## 사전 준비

- Docker Desktop (실행 중이어야 함) — MySQL/Redis/InfluxDB/Prometheus/Grafana뿐 아니라
  Spring Boot 앱도 기본적으로 Docker로 빌드/실행됩니다.
- [k6](https://k6.io) 로컬 설치
- JDK 17 — 앱을 Docker 없이 로컬에서 직접 실행/디버깅하고 싶을 때만 필요

> Windows/Hyper-V 환경에서는 일부 포트 대역(예: 3306, 3307)이 예약되어 바인딩이 안 될 수 있고,
> 로컬에 이미 다른 MySQL/Redis가 떠 있으면 기본 포트가 충돌할 수 있습니다. 그래서 이 프로젝트는
> MySQL을 `13306`, Redis를 `16379` 호스트 포트로 매핑합니다. 다른 포트도 충돌하면
> `docker-compose.yml`의 포트와 `application.properties`의 접속 정보를 함께 바꿔주세요.

## 1. 인프라 + 앱 기동 (MySQL, Redis, InfluxDB, Prometheus, Grafana, App)

```bash
docker compose up -d --build
```

Spring Boot 앱은 `Dockerfile`로 빌드되어 `app` 서비스로 함께 뜨고, `http://localhost:8080`에서
응답합니다. `sql/01-schema.sql`, `sql/02-generate-data.sql`이 MySQL 컨테이너 최초 기동 시 자동
실행되어 인덱스 없는 `orders` 테이블과 더미 데이터 100만 건을 생성하고(최초 1회만, 완료까지
수십 초~1분 정도 걸릴 수 있음), 앱은 MySQL/Redis가 healthy 상태가 된 뒤에 시작됩니다.

데이터 생성이 끝났는지 확인:

```bash
docker exec kb7-mysql mysql -udemo -pdemo1234 kb7demo -e "SELECT COUNT(*) FROM orders;"
```

`1000001`이 나오면 완료된 것입니다. 앱이 떴는지는 아래로 확인:

```bash
curl http://localhost:8080/actuator/health
```

## 2. (선택) 앱을 로컬에서 직접 실행

코드를 수정하며 반복 실행/디버깅하고 싶다면 Docker 컨테이너 대신 로컬에서 바로 띄울 수 있습니다.
이 경우 먼저 컨테이너 쪽 앱을 내려서 8080 포트 충돌을 피해주세요.

```bash
docker compose stop app
./gradlew bootRun
```

`application.properties`의 기본값(`localhost:13306`, `localhost:16379`)은 로컬 실행을 기준으로
되어 있어 별도 설정 없이 그대로 동작합니다.

## 3. 병목 엔드포인트

### 3-1. 풀 테이블 스캔 (인덱스 누락)

`orders.customer_email`에 인덱스가 없어 조회 시 100만 건을 풀 스캔합니다.

```bash
curl "http://localhost:8080/api/orders/search?email=target@example.com"
```

확인용 EXPLAIN (컨테이너 안에서 실행):

```bash
docker exec kb7-mysql mysql -udemo -pdemo1234 kb7demo -e \
  "EXPLAIN SELECT * FROM orders WHERE customer_email='target@example.com';"
```

`type=ALL`, `key=NULL`이면 인덱스를 안 타고 풀 스캔 중이라는 뜻입니다.

### 3-2. 커넥션 풀 고갈

`application.properties`에서 HikariCP `maximum-pool-size=5`, `connection-timeout=3000`(ms)로
의도적으로 작게 설정했습니다. `/api/orders/slow`는 `SELECT SLEEP(seconds)`로 커넥션을 오래 점유합니다.

```bash
curl "http://localhost:8080/api/orders/slow?seconds=3"
```

동시에 풀 크기(5개)를 초과하는 요청을 보내면 뒤로 밀린 요청은 커넥션 대기 후
`connection-timeout`(3초)을 넘기면 `500 Internal Server Error`가 발생합니다.

### 3-3. Redis 캐싱을 통한 완화

`/api/orders/search`와 동일하게 인덱스 없는 풀 스캔을 쓰지만, 조회 결과를 Redis에 30초간 캐싱합니다.
"인덱스를 안 고쳐도, 반복 조회되는 인기 데이터라면 캐싱만으로 DB 부하를 크게 줄일 수 있다"는 것을
보여주는 엔드포인트입니다.

```bash
curl -i "http://localhost:8080/api/orders/search-cached?email=user1@example.com"
```

응답 헤더 `X-Cache: MISS|HIT`, `X-Took-Ms`로 캐시 적중 여부와 소요 시간을 바로 확인할 수 있습니다.
같은 이메일로 다시 요청하면 `HIT`으로 바뀌면서 응답 시간이 수백 ms에서 1ms 내외로 떨어집니다.

## 4. k6 부하 테스트

### 4-1. 풀 테이블 스캔 시나리오

```bash
k6 run k6/search-scan-test.js
```

- 0~30초: 10 VU, 30~90초: 30 VU로 증가, 이후 감소
- 매 요청마다 무작위 이메일로 조회하여 매번 풀 스캔을 유발
- `http_req_duration` p95가 부하 증가에 따라 나빠지는지 관찰

### 4-2. 커넥션 풀 고갈 시나리오

```bash
k6 run k6/pool-exhaustion-test.js
```

- 0~20초: 5 VU(풀 크기 이내), 20~40초: 15 VU(풀 크기 초과), 이후 감소
- `status is 500 (pool exhausted)` 체크 비율과 `http_req_duration`이 대기 구간에서 급증하는지 관찰

### 4-3. Redis 캐싱 히트율 시나리오

```bash
k6 run k6/cache-hit-test.js
```

- 20 VU가 30초간, 실제 존재하는 이메일 5개(`user1`~`user5`@example.com)만 무작위로 반복 조회
- `X-Cache` 헤더를 기준으로 `cache_hit_rate`, `cache_hit_latency_ms`, `cache_miss_latency_ms` 커스텀
  지표를 집계 — 인덱스가 없어도(3-1과 동일한 풀 스캔 쿼리) 캐시 히트율이 높으면 지연시간이 얼마나
  줄어드는지 확인 가능

모든 스크립트는 `BASE_URL` 환경변수로 대상 서버를 바꿀 수 있습니다.

```bash
BASE_URL=http://localhost:8080 k6 run k6/search-scan-test.js
```

### 4-4. 결과를 Prometheus + InfluxDB 양쪽으로 동시에 전송

`k6 run`은 기본적으로 터미널에 진행 상황과 최종 요약을 실시간으로 보여줍니다. 여기에 더해
`--out` 플래그를 두 번 넘기면 같은 실행 결과를 Prometheus(remote-write)와 InfluxDB에 동시에
기록할 수 있습니다.

```bash
K6_PROMETHEUS_RW_TREND_STATS="avg,min,med,max,p(90),p(95)" k6 run \
  --out experimental-prometheus-rw \
  --out influxdb=http://localhost:8086/k6 \
  k6/search-scan-test.js
```

> `K6_PROMETHEUS_RW_TREND_STATS`를 안 주면 k6가 기본적으로 `p99` 하나만 Prometheus로 보내서
> `kb7 Bottleneck Demo` 대시보드의 avg/min/med/p90/p95/max 패널이 비어 보입니다.

- **터미널** — 실행 중 진행 상황/최종 요약 (기존과 동일, 별도 설정 불필요)
- **Prometheus** (`experimental-prometheus-rw`) → `kb7 Bottleneck Demo` 대시보드의
  "k6 Load Test - http_req_duration (client-side)" 섹션에서 앱 지표(HikariCP, JVM 등)와
  나란히 확인
- **InfluxDB** (`influxdb=...`) → 아래 5번에서 설명하는 `k6 Load Testing Results` 대시보드에서
  VU/RPS/에러율/지표별 percentile을 k6 표준 대시보드 형태로 확인

`k6/run-all-tests.sh`는 세 시나리오를 순차 실행하면서 이 두 `--out`을 이미 포함하고 있으므로
별도 설정 없이 바로 두 대시보드 모두에서 결과를 볼 수 있습니다.

### 4-5. 전체 시나리오 순차 실행

세 시나리오를 동시에 돌리면 커넥션 풀/캐시 등 서로의 지표에 간섭하므로, 아래 스크립트로
하나씩 순서대로(풀 스캔 → 커넥션 풀 고갈 → 캐싱) 실행하고 각 결과를 `k6/results/`에 저장할 수
있습니다.

```bash
./k6/run-all-tests.sh
```

- `docker compose up -d --build`로 인프라 + 앱을 먼저 기동합니다(이미 떠있으면 그대로 재사용).
- `BASE_URL`(기본 `http://localhost:8080`)의 `/actuator/health`가 응답할 때까지 최대 180초
  대기한 뒤 테스트를 시작합니다.
- `BASE_URL` 환경변수로 대상 서버를, `INFLUXDB_URL` 환경변수로 InfluxDB 엔드포인트를 바꿀 수
  있습니다 (기본값: `http://localhost:8086/k6`).
- 각 실행에 `testid=<시나리오>-<타임스탬프>` 태그가 붙어 Prometheus/InfluxDB에서 실행 회차를
  구분할 수 있습니다.
- 테스트 중 하나라도 threshold를 만족하지 못하면 스크립트 종료 코드가 1이 되며 마지막에 실패한
  테스트 목록을 출력합니다.

## 5. Grafana에서 관찰

`http://localhost:3000` 접속 (익명 Viewer 접근 허용, 로그인 시 admin/admin) 후 `Dashboards`에서
두 대시보드를 확인할 수 있습니다.

### 5-1. kb7 Bottleneck Demo (Prometheus)

- HTTP Requests/sec (uri, status별)
- HTTP p95 Latency
- HikariCP Active / Pending / Max Connections — pending이 올라가면 커넥션 대기가 발생 중이라는 신호
- JVM Heap Used
- k6 Load Test - http_req_duration (client-side) — k6가 `experimental-prometheus-rw`로 보낸
  클라이언트 측 지표(avg/min/med/p90/p95/max)를 앱 지표와 나란히 확인

### 5-2. k6 Load Testing Results (InfluxDB)

k6가 `influxdb=http://localhost:8086/k6`로 보낸 결과를 보여주는 전용 대시보드입니다.

- Virtual Users / HTTP Requests (per interval) / Error Rate % / Checks Pass Rate % (시계열)
- req_duration Avg / Min / Median / p90 / p95 / Max (stat 패널)

> 기본 범위는 최근 15분입니다. 최근에 돌린 테스트가 없으면 비어 보이니, 시간 범위를 넓히거나
> `k6/run-all-tests.sh`를 한 번 실행해보세요. 여러 시나리오를 연달아 돌리면 같은 시간대에 값이
> 섞여 보일 수 있습니다 — 특정 실행만 보고 싶다면 InfluxDB에 `testid` 태그로 구분되어 있으니
> (`SHOW TAG VALUES FROM "http_reqs" WITH KEY = "testid"`) 필요 시 쿼리에 필터를 추가하세요.

두 대시보드 모두 k6 실행 중 실시간(5초 refresh)으로 지표가 쌓이는 것을 볼 수 있습니다.

## 6. 병목 해결 후 Before/After 비교

### 6-1. 인덱스 추가

```sql
ALTER TABLE orders ADD INDEX idx_orders_customer_email (customer_email);
```

추가 후 다시 `EXPLAIN`을 실행하면 `type=ref`, `key=idx_orders_customer_email`로 바뀌는 것을
확인할 수 있고, `k6 run k6/search-scan-test.js`를 재실행하면 p95 지연시간이 크게 줄어듭니다.

### 6-2. 커넥션 풀 크기 조정

`application.properties`의 `spring.datasource.hikari.maximum-pool-size`를 늘리고 앱을 재시작한 뒤
`k6 run k6/pool-exhaustion-test.js`를 재실행하면 500 에러 비율과 대기 지연이 줄어드는 것을 확인할 수
있습니다. 앱을 Docker로 띄운 상태라면 이미지에 코드가 빌드되어 있으므로 재빌드 후 재시작이
필요합니다.

```bash
docker compose up -d --build app
```

로컬에서 `./gradlew bootRun`으로 띄운 경우에는 그냥 재시작(Ctrl+C 후 재실행)하면 됩니다.

같은 k6 시나리오로 수정 전/후를 비교하는 것이 이 데모의 핵심입니다.

### 6-3. 캐싱으로 완화 (인덱스를 고치지 않고)

인덱스를 추가하는 게 근본 해결책이지만, "스키마를 못 건드리는 상황"이거나 "조회 패턴이 소수의
핫 데이터에 몰려있는 경우"의 대안으로 캐싱을 보여줍니다. `k6/cache-hit-test.js`를 실행하면
인덱스가 없는 상태에서도 첫 요청(MISS) 이후로는 대부분 캐시에서 응답해 지연시간이 크게 줄어드는
것을 확인할 수 있습니다. 단, 캐싱은 반복되지 않는 임의 조회(예: 3-1의 무작위 이메일 테스트)에는
효과가 없다는 점도 같이 보여주면 좋습니다 — 캐시 적중률은 트래픽 패턴에 달려 있다는 것이 포인트입니다.

### 6-4. 실측 결과 예시

이 저장소에서 실제로 측정한 수치입니다 (환경에 따라 달라질 수 있습니다).

**풀 테이블 스캔 (`k6 run k6/search-scan-test.js`, 최대 30 VU)**

| 지표 | Before (인덱스 없음) | After (인덱스 추가) |
|---|---|---|
| p95 지연시간 | 1.4s | 6.09ms |
| 평균 지연시간 | 783ms | 3.55ms |
| 처리량 | 11.6 req/s | 29.6 req/s |

**커넥션 풀 고갈 (`k6 run k6/pool-exhaustion-test.js`, 최대 15 VU)**

| 지표 | Before (풀 크기 5) | After (풀 크기 20) |
|---|---|---|
| 500 에러(풀 고갈) 비율 | 약 90% | 0% |
| http_req_failed | 9.75% | 0.00% |
| p95 지연시간 | 5.99s (대기 큐 발생) | 3.01s (SLEEP 시간만, 대기 없음) |

**Redis 캐싱 (`k6 run k6/cache-hit-test.js`, 20 VU, 인기 이메일 5개 반복 조회, 인덱스는 없는 상태)**

| 지표 | 캐시 MISS (DB 풀 스캔) | 캐시 HIT |
|---|---|---|
| 평균 지연시간 | 958.8ms | 1.16ms |
| 캐시 적중률 | - | 99.98% |

### 6-5. 현재 저장소 상태

이 README의 예시를 그대로 재현해보고 싶다면 참고하세요. 현재 저장소는 다음 상태로 맞춰져 있습니다.

- 인덱스: 제거됨 (`idx_orders_customer_email` 없음, 3-1/6-3의 풀 스캔 데모 가능)
- 커넥션 풀: `maximum-pool-size=20` (해결된 상태, 3-2/6-2 데모를 원하면 5로 되돌리고 앱 재시작)
- Redis 캐싱: 적용됨 (`/api/orders/search-cached`)

## 7. 정리

```bash
docker compose down        # 컨테이너만 제거 (데이터 볼륨 유지)
docker compose down -v     # 데이터 볼륨까지 제거 (다음 기동 시 더미데이터 재생성)
```
