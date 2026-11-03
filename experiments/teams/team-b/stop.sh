#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/_common.sh"
echo ">> team-b stop: LoRA jobs + workspace"
del_by_prefix team-b-lora-ft
del_by_prefix team-b-workbench-ws
del_by_prefix team-b-victim
