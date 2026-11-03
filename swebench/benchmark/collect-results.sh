#!/usr/bin/env bash
# Collect and summarize SWE-bench results for Qwen3-27B runs across all languages.
#
# Usage: ./collect-results.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEBENCH_DIR="$(cd "$SCRIPT_DIR/../../swebench" && pwd)"
MODEL_SLUG="qwen3-27b"

echo "=== SWE-bench Results: Qwen3-27B (self-hosted vLLM / MI300X) ==="
echo ""

for LANG in go java rust ts-js cpp cs; do
  RESULTS_DIR="$SWEBENCH_DIR/$LANG/results/$MODEL_SLUG"
  EVAL_DIR="$SWEBENCH_DIR/$LANG/eval-results/$MODEL_SLUG"
  DATA_FILE="$SWEBENCH_DIR/$LANG/data/swebench-multilang-${LANG}.jsonl"

  [[ ! -d "$RESULTS_DIR" ]] && continue

  TOTAL_DATASET=0
  [[ -f "$DATA_FILE" ]] && TOTAL_DATASET=$(wc -l < "$DATA_FILE")

  ATTEMPTED=$(find "$RESULTS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
  WITH_PATCH=0
  EMPTY_PATCH=0
  TOTAL_COST=0
  TOTAL_TURNS=0
  TOTAL_TOKENS=0

  for d in "$RESULTS_DIR"/*/; do
    [[ ! -d "$d" ]] && continue
    instance=$(basename "$d")
    patch="$d/ami-${MODEL_SLUG}-diff.patch"
    json="$d/ami-${MODEL_SLUG}.json"

    if [[ -f "$patch" && -s "$patch" ]]; then
      WITH_PATCH=$((WITH_PATCH + 1))
    else
      EMPTY_PATCH=$((EMPTY_PATCH + 1))
    fi

    if [[ -f "$json" ]]; then
      cost=$(jq -r '.estimatedCost // 0' "$json" 2>/dev/null || echo 0)
      turns=$(jq -r '.turns // 0' "$json" 2>/dev/null || echo 0)
      tokens=$(jq -r '.tokens.total // 0' "$json" 2>/dev/null || echo 0)
      TOTAL_COST=$(python3 -c "print($TOTAL_COST + $cost)" 2>/dev/null || echo "$TOTAL_COST")
      TOTAL_TURNS=$((TOTAL_TURNS + turns))
      TOTAL_TOKENS=$((TOTAL_TOKENS + tokens))
    fi
  done

  EVAL_RESOLVED=0
  EVAL_TOTAL=0
  if [[ -d "$EVAL_DIR" ]]; then
    for r in "$EVAL_DIR"/*/report.json; do
      [[ -f "$r" ]] || continue
      EVAL_TOTAL=$((EVAL_TOTAL + 1))
      is_resolved=$(python3 -c "import json; print(json.load(open('$r')).get('resolved', False))" 2>/dev/null)
      [[ "$is_resolved" == "True" ]] && EVAL_RESOLVED=$((EVAL_RESOLVED + 1))
    done
  fi

  EVAL_PCT=0
  [[ "$EVAL_TOTAL" -gt 0 ]] && EVAL_PCT=$(python3 -c "print(f'{$EVAL_RESOLVED/$EVAL_TOTAL*100:.1f}')")
  AVG_COST=0
  [[ "$ATTEMPTED" -gt 0 ]] && AVG_COST=$(python3 -c "print(f'{$TOTAL_COST/$ATTEMPTED:.2f}')")
  AVG_TURNS=0
  [[ "$ATTEMPTED" -gt 0 ]] && AVG_TURNS=$(python3 -c "print(f'{$TOTAL_TURNS/$ATTEMPTED:.0f}')")

  echo "── $LANG ──────────────────────────────────"
  echo "  Dataset:     $TOTAL_DATASET instances"
  echo "  Attempted:   $ATTEMPTED"
  echo "  With patch:  $WITH_PATCH (empty: $EMPTY_PATCH)"
  if [[ "$EVAL_TOTAL" -gt 0 ]]; then
    echo "  Evaluated:   $EVAL_RESOLVED / $EVAL_TOTAL resolved ($EVAL_PCT%)"
  else
    echo "  Evaluated:   not yet (run evaluation)"
  fi
  echo "  Avg cost:    \$$AVG_COST per instance"
  echo "  Avg turns:   $AVG_TURNS"
  echo "  Total cost:  \$$TOTAL_COST"
  echo ""
done

echo "==========================================="
