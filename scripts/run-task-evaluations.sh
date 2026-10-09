#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-${TMPDIR:-/tmp}/ivy-task-evaluations.json}"
mkdir -p "$(dirname "$report")"
export IVY_EVALUATION_REPORT_PATH="$report"
swift test --filter Phase21TaskEvaluationTests
echo "Offline evaluation report: $report"
