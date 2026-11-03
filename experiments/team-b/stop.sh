#!/usr/bin/env bash
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
echo ">> team-b stop: LoRA jobs + workspace"
del_by_prefix team-b-lora-ft
del_by_prefix team-b-workbench-ws
