#!/usr/bin/env bash
# Team B batch: N real LoRA fine-tuning jobs (Train, GPU) via the Run:ai API.
# Mounts the existing source + CA configmaps; runs Training Hub LoRA SFT on Qwen2.5-1.5B.
# Same workload as ./post-training/ (the standalone RHOAI baseline), now Run:ai-native.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
N="${1:-2}"
echo ">> team-b submit: $N LoRA fine-tuning job(s) (Train, GPU)"
for n in $(seq 1 "$N"); do
  export LORA_NAME="team-b-lora-ft-$n"
  if [ -n "$(workload_id "$LORA_NAME")" ]; then echo "   $LORA_NAME exists, skip"; continue; fi
  render "$HERE/team-b-lora.json" | api POST /api/v1/workloads/trainings --data-binary @-     | python3 -I -c "import sys,json;d=json.load(sys.stdin);print('   $LORA_NAME ->',d.get('workloadId','ERR')[:12])"
done
