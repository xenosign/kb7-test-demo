#!/usr/bin/env bash
# 세 가지 병목 시나리오(k6/*-test.js)를 순서대로 하나씩 실행한다.
# 동시에 돌리면 시나리오끼리 서로의 지표(커넥션 풀, 캐시 등)에 간섭하므로 반드시 순차 실행한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
BASE_URL="${BASE_URL:-http://localhost:8080}"

TESTS=(
  "search-scan-test.js"
  "pool-exhaustion-test.js"
  "cache-hit-test.js"
)

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6가 설치되어 있지 않습니다. https://k6.io 를 참고해 설치해주세요." >&2
  exit 1
fi

mkdir -p "${RESULTS_DIR}"

timestamp="$(date +%Y%m%d-%H%M%S)"
failed=()

for test_file in "${TESTS[@]}"; do
  name="${test_file%.js}"
  summary_file="${RESULTS_DIR}/${name}-${timestamp}.json"

  echo ""
  echo "==================================================================="
  echo "▶ ${name} 실행 (BASE_URL=${BASE_URL})"
  echo "==================================================================="

  BASE_URL="${BASE_URL}" k6 run \
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
