import http from 'k6/http';
import { check, sleep } from 'k6';

// HikariCP maximum-pool-size=5 로 설정된 상태에서 동시 요청 수를 풀 크기 이상으로 올려
// 커넥션 대기/타임아웃(500 에러)이 발생하는 것을 재현하는 시나리오.
export const options = {
  stages: [
    { duration: '20s', target: 5 },   // 풀 크기 이내: 대기 없이 처리되어야 함
    { duration: '20s', target: 15 },  // 풀 크기 초과: 대기 및 타임아웃 발생 구간
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<1'], // 실패율 자체를 관찰하는 것이 목적이므로 강하게 실패시키지 않음
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const SLEEP_SECONDS = __ENV.SLEEP_SECONDS || 3;

export default function () {
  const res = http.get(`${BASE_URL}/api/orders/slow?seconds=${SLEEP_SECONDS}`, {
    tags: { name: 'slow' },
  });

  check(res, {
    'status is 200': (r) => r.status === 200,
    'status is 500 (pool exhausted)': (r) => r.status === 500,
  });

  sleep(1);
}
