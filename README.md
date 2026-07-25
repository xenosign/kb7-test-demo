# kb7-test-demo

Spring Boot + MySQL 기반으로 두 가지 병목(인덱스 누락 풀 테이블 스캔, 커넥션 풀 고갈)을 의도적으로
재현하고, k6로 부하를 주면서 Prometheus/Grafana로 관찰 → 원인 파악 → 해결까지 진행하는 데모 프로젝트입니다.

## 구성 요소

| 구성 요소 | 설명 |
|---|---|
| Spring Boot App | `localhost:8080`, 병목 재현용 엔드포인트 2개 제공 |
| MySQL | Docker, `localhost:13306`, `orders` 테이블 100만 건 |
| Prometheus | Docker, `localhost:9090`, 앱의 `/actuator/prometheus` 스크레이핑 |
| Grafana | Docker, `localhost:3000`, `kb7 Bottleneck Demo` 대시보드 자동 프로비저닝 |
| k6 | 로컬 설치, `k6/` 디렉터리의 스크립트로 부하 생성 |

## 사전 준비

- JDK 17
- Docker Desktop (실행 중이어야 함)
- [k6](https://k6.io) 로컬 설치

> Windows/Hyper-V 환경에서는 일부 포트 대역(예: 3306, 3307)이 예약되어 바인딩이 안 될 수 있습니다.
> 그래서 이 프로젝트는 MySQL 호스트 포트를 `13306`으로 매핑합니다. 다른 포트도 충돌하면
> `docker-compose.yml`의 포트와 `application.properties`의 접속 정보를 함께 바꿔주세요.

## 1. 인프라 기동 (MySQL, Prometheus, Grafana)

```bash
docker compose up -d
```

`sql/01-schema.sql`, `sql/02-generate-data.sql`이 MySQL 컨테이너 최초 기동 시 자동 실행되어
인덱스 없는 `orders` 테이블과 더미 데이터 100만 건을 생성합니다. (최초 1회만 실행되며, 완료까지
수십 초 정도 걸릴 수 있습니다.)

데이터 생성이 끝났는지 확인:

```bash
docker exec kb7-mysql mysql -udemo -pdemo1234 kb7demo -e "SELECT COUNT(*) FROM orders;"
```

`1000001`이 나오면 완료된 것입니다.

## 2. 앱 실행

```bash
./gradlew bootRun
```

`http://localhost:8080` 에서 기동됩니다.

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

두 스크립트 모두 `BASE_URL` 환경변수로 대상 서버를 바꿀 수 있습니다.

```bash
BASE_URL=http://localhost:8080 k6 run k6/search-scan-test.js
```

## 5. Grafana에서 관찰

`http://localhost:3000` 접속 (익명 Viewer 접근 허용, 로그인 시 admin/admin) 후
`Dashboards > kb7 Bottleneck Demo`로 이동하면 다음을 확인할 수 있습니다.

- HTTP Requests/sec (uri, status별)
- HTTP p95 Latency
- HikariCP Active / Pending / Max Connections — pending이 올라가면 커넥션 대기가 발생 중이라는 신호
- JVM Heap Used

k6 실행 중 실시간(5초 refresh)으로 지표가 쌓이는 것을 볼 수 있습니다.

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
있습니다.

같은 k6 시나리오로 수정 전/후를 비교하는 것이 이 데모의 핵심입니다.

## 7. 정리

```bash
docker compose down        # 컨테이너만 제거 (데이터 볼륨 유지)
docker compose down -v     # 데이터 볼륨까지 제거 (다음 기동 시 더미데이터 재생성)
```
