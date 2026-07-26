import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// 인덱스는 여전히 없는 상태(풀 스캔)지만, 소수의 "인기" 이메일만 반복 조회되는
// 실제 트래픽 패턴에서는 Redis 캐싱만으로도 DB 부하를 크게 줄일 수 있음을 보여주는 시나리오.
const cacheHitRate = new Rate('cache_hit_rate');
const hitLatencyMs = new Trend('cache_hit_latency_ms');
const missLatencyMs = new Trend('cache_miss_latency_ms');

export const options = {
  vus: 20,
  duration: '30s',
  thresholds: {
    cache_hit_rate: ['rate>0.8'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// 실제로 존재하는 이메일 5개만 반복 조회 (더미데이터 생성 규칙: user{n}@example.com)
const HOT_EMAILS = [
  'user1@example.com',
  'user2@example.com',
  'user3@example.com',
  'user4@example.com',
  'user5@example.com',
];

export default function () {
  const email = HOT_EMAILS[Math.floor(Math.random() * HOT_EMAILS.length)];
  const res = http.get(`${BASE_URL}/api/orders/search-cached?email=${email}`);

  const isHit = res.headers['X-Cache'] === 'HIT';
  cacheHitRate.add(isHit);

  const tookMs = Number(res.headers['X-Took-Ms'] || 0);
  if (isHit) {
    hitLatencyMs.add(tookMs);
  } else {
    missLatencyMs.add(tookMs);
  }

  check(res, {
    'status is 200': (r) => r.status === 200,
  });
}
