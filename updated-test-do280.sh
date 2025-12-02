#!/usr/bin/env bash
# test-do280.sh — Robust, fast, parallel lab tester

set -euo pipefail
IFS=$'\n\t'

COURSE_SKU="DO280"
PR_PACKAGE="${1:-4.18.0.dev0+pr.1981}"  # allow override: ./test-do280.sh 4.18.0.dev0+pr.XXXX

LAB_LIST="labs.txt"
LOG_DIR="/tmp/log/labs"
MAX_PARALLEL=${MAX_PARALLEL:-4}         # adjust to your workstation capacity
LOG_LEVEL="debug"

# Colors for pretty output
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

mkdir -p "${LOG_DIR}"
exec > >(tee "${LOG_DIR}/test-${COURSE_SKU,,}.log") 2>&1

echo "=== DO280 Lab Regression Test ==="
echo "Package: ${PR_PACKAGE}"
echo "Parallel jobs: ${MAX_PARALLEL}"
echo "Log dir: ${LOG_DIR}"
date

# ------------------------------------------------------------------
# 1. Prepare environment once
# ------------------------------------------------------------------
echo -e "${YELLOW}Installing/Upgrading ${COURSE_SKU} ${PR_PACKAGE}${NC}"
if ! lab force "${COURSE_SKU,,}=${PR_PACKAGE}"; then
  echo -e "${RED}Failed to install package${NC}" >&2
  exit 1
fi

# Wait for cluster to be actually ready (instead of blind sleep)
echo -e "${YELLOW}Waiting for cluster readiness${NC}"
if ! lab start wait-cluster; then
  echo -e "${RED}wait-cluster failed — cluster never became ready${NC}" >&2
  exit 1
fi

# Set grading log level
sed -i.bak "s/level: error/level: ${LOG_LEVEL}/g" ~/.grading/config.yaml || true
export LOGGING__LEVEL="${LOG_LEVEL}"

# ------------------------------------------------------------------
# 2. Read lab list properly (skip empty lines and full-line comments)
# ------------------------------------------------------------------
mapfile -t LAB_SCRIPTS < <(grep -vE '^\s*$|^\s*#' "${LAB_LIST}" | sort)

echo "Found ${#LAB_SCRIPTS[@]} labs to execute"

# ------------------------------------------------------------------
# 3. Core execution function (used by GNU parallel)
# ------------------------------------------------------------------
run_lab() {
  local lab="$1"
  local start_time end_time elapsed

  echo "########################################"
  echo "# Starting lab: ${lab}"
  echo "########################################"

  start_time=$(date +%s)

  # start
  if ! lab start "${lab}"; then
    echo "❌ [${lab}] START FAILED"
    return 1
  fi

  # grade only if a grading script actually exists
  if lab info "${lab}" | grep -q "Grading:* yes"; then
    echo "Grading ${lab}..."
    if lab grade "${lab}"; then
      echo "✅ [${lab}] GRADED SUCCESS"
    else
      echo "❌ [${lab}] GRADING FAILED"
      return 1
    fi
  else
    echo "ℹ️  [${lab}] No grading defined — skipping grade"
  fi

  # finish
  if ! lab finish "${lab}"; then
    echo "⚠️  [${lab}] FINISH FAILED (continuing anyway)"
  fi

  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))
  echo "⏱️  [${lab}] completed in ${elapsed}s"
  return 0
}
export -f run_lab
export LOG_DIR COURSE_SKU

# ------------------------------------------------------------------
# 4. Run in parallel (fallback to sequential if parallel not installed)
# ------------------------------------------------------------------
if command -v parallel >/dev/null; then
  echo -e "${GREEN}Running labs in parallel (${MAX_PARALLEL} jobs)${NC}"
  parallel -j "${MAX_PARALLEL}" --eta --joblog "${LOG_DIR}/parallel.log" run_lab ::: "${LAB_SCRIPTS[@]}"
  exit_code=${PIPESTATUS[0]}
else
  echo -e "${YELLOW}GNU parallel not found — running sequentially${NC}"
  for lab in "${LAB_SCRIPTS[@]}"; do
    run_lab "${lab}" || true
  done
  exit_code=0
fi

# ------------------------------------------------------------------
# 5. Final summary
# ------------------------------------------------------------------
failed=$(grep -c "FAILED" "${LOG_DIR}/parallel.log" 2>/dev/null || echo 0)
total=${#LAB_SCRIPTS[@]}

echo "============================================"
if (( failed == 0 )); then
  echo -e "${GREEN}ALL ${total} LABS PASSED!${NC}"
  exit 0
else
  echo -e "${RED}${failed}/${total} LABS FAILED${NC}"
  echo "Check logs in ${LOG_DIR}"
  exit 1
fi