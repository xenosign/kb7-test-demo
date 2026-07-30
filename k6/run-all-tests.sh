#!/usr/bin/env bash
# 세 가지 병목 시나리오(k6/*-test.js)를 순서대로 하나씩 실행한다.
# 동시에 돌리면 시나리오끼리 서로의 지표(커넥션 풀, 캐시 등)에 간섭하므로 반드시 순차 실행한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
BASE_URL="${BASE_URL:-http://localhost:8080}"
INFLUXDB_URL="${INFLUXDB_URL:-http://localhost:8086/k6}"

TESTS=(
  "search-scan-test.js"
  "pool-exhaustion-test.js"
  "cache-hit-test.js"
)

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6가 설치되어 있지 않습니다. https://k6.io 를 참고해 설치해주세요." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker가 설치되어 있지 않습니다. Docker Desktop을 설치해주세요." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl이 설치되어 있지 않습니다." >&2
  exit 1
fi

mkdir -p "${RESULTS_DIR}"

echo "인프라 + 앱(MySQL, Redis, InfluxDB, Prometheus, Grafana, App) 기동 확인 중..."
echo "(최초 실행 시 app 이미지 빌드와 MySQL 더미데이터 생성으로 몇 분 걸릴 수 있습니다)"
if ! (cd "${PROJECT_ROOT}" && docker compose up -d --build); then
  echo "docker compose up -d 실패. Docker Desktop이 실행 중인지 확인해주세요." >&2
  exit 1
fi

echo -n "앱이 준비될 때까지 대기 중 (${BASE_URL}/actuator/health)"
ready=false
for _ in $(seq 1 90); do
  if curl -sf "${BASE_URL}/actuator/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [ "${ready}" != "true" ]; then
  echo "앱이 제한 시간(180초) 안에 준비되지 않았습니다. 'docker compose logs app'으로 확인해주세요." >&2
  exit 1
fi
echo "앱 기동 완료."

timestamp="$(date +%Y%m%d-%H%M%S)"
failed=()

for test_file in "${TESTS[@]}"; do
  name="${test_file%.js}"
  testid="${name}-${timestamp}"
  summary_file="${RESULTS_DIR}/${testid}.json"

  echo ""
  echo "==================================================================="
  echo "▶ ${name} 실행 (BASE_URL=${BASE_URL})"
  echo "  실시간 진행 상황: 터미널 출력 + Prometheus remote-write (kb7 Bottleneck Demo 대시보드)"
  echo "  결과 기록: InfluxDB (${INFLUXDB_URL}) → k6 Load Testing Results 대시보드"
  echo "==================================================================="

  BASE_URL="${BASE_URL}" \
  K6_PROMETHEUS_RW_TREND_STATS="avg,min,med,max,p(90),p(95)" \
  k6 run \
    --tag testid="${testid}" \
    --out experimental-prometheus-rw \
    --out "influxdb=${INFLUXDB_URL}" \
    --summary-export="${summary_file}" \
    "${SCRIPT_DIR}/${test_file}"

  if [ $? -eq 0 ]; then
    echo "✔ ${name} 통과 (요약: ${summary_file})"
  else
    echo "✘ ${name} 실패 또는 threshold 미달 (요약: ${summary_file})"
    failed+=("${name}")
  fi
done

echo ""
echo "==================================================================="
echo "전체 결과"
echo "==================================================================="
if [ ${#failed[@]} -eq 0 ]; then
  echo "모든 테스트 통과 (${#TESTS[@]}/${#TESTS[@]})"
  exit 0
else
  echo "실패한 테스트: ${failed[*]}"
  exit 1
fi
