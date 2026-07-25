import http from 'k6/http';
import { check, sleep } from 'k6';

// 인덱스 없는 orders.customer_email 풀 테이블 스캔 병목 재현 시나리오.
// 서버 부하 아래에서 p95 지연시간이 얼마나 나빠지는지 관찰하는 것이 목적이다.
export const options = {
  stages: [
    { duration: '30s', target: 10 },
    { duration: '1m', target: 30 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
  // 100만 건 중 임의의 이메일로 조회해 매번 다른 값으로 풀스캔을 유발한다.
  const randomId = Math.floor(Math.random() * 1000000);
  const email = `user${randomId}@example.com`;

  const res = http.get(`${BASE_URL}/api/orders/search?email=${email}`);

  check(res, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(0.5);
}
