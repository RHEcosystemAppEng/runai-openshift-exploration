# SWE-bench Live splits — squad mapping and engine contract

This document describes the three SWE-bench Live splits used by NVIDIA-1535
("Multi-Tenant Autonomous Coding Agents on a Shared GPU Cluster"), how each squad
maps to a split, the JSONL schema the proven benchmark engine consumes, and how
the per-instance `docker_image` is derived.

The data files are produced by [`prepare_datasets.py`](./prepare_datasets.py) and
consumed by the engine scripts in [`../benchmark/`](../benchmark/) (verbatim copies
of the proven `superinference/challenges/ocp_cluster` engine).

## Squads and splits

Each of the three data-science squads sharing the GPU cluster drives the AMI agent
against a different split. The mapping matches `config/env.sh` (`SQUAD_SPLIT`):

| Squad | Namespace        | Split    | Benchmark                | Priority            |
| ----- | ---------------- | -------- | ------------------------ | ------------------- |
| A     | `squad-a-lite`   | `lite`   | SWE-bench Lite (Python)  | `squad-high-priority` |
| B     | `squad-b-cpp`    | `cpp`    | SWE-bench C/C++          | `squad-standard`    |
| C     | `squad-c-csharp` | `csharp` | SWE-bench C#             | `squad-standard`    |

Each squad's dataset is written to:

```
<out-dir>/swebench-multilang-<split>.jsonl
```

and is read by the engine at `/workspace/data/swebench-multilang-<split>.jsonl`
(the repo's `data/` directory is rsynced into the shared PVC by
`benchmark/setup-workspace.sh`). The `<split>` token is passed to the engine as its
`<language>` argument (`run-instance-k8s.sh <language> <instance-id>`).

## Expected instance counts (VERIFY)

The counts below are placeholders. SWE-bench Live refreshes monthly and the
multilingual sets evolve, so confirm the real counts after materializing the data
(`wc -l data/swebench-multilang-*.jsonl`) and update this table.

| Split    | Expected instances | Status   |
| -------- | ------------------ | -------- |
| `lite`   | ~300               | *verify* |
| `cpp`    | *verify*           | *verify* |
| `csharp` | *verify*           | *verify* |

## Source datasets (UNVERIFIED defaults)

`prepare_datasets.py` pulls each split from Hugging Face with the `datasets`
library. The repo ids and split names are **best-known guesses, not confirmed** —
they are CLI-overridable per split and must be verified against the live Hub.

- `lite` — SWE-bench Live publishes a monthly-refreshed Python "lite" slice.
  Confirm whether the correct id is `SWE-bench-Live/SWE-bench-Live` (split `lite`)
  or the classic `princeton-nlp/SWE-bench_Lite` (split `test`).
- `cpp` / `csharp` — the multilingual C/C++ and C# instances are **not** part of
  SWE-bench Live today. They come from a multi-language benchmark (for example
  Multi-SWE-bench, with per-language configs `cpp` / `csharp`). Verify the repo id
  and config names.

Override any of these without editing code:

```bash
python3 -I data/prepare_datasets.py \
  --lite-dataset princeton-nlp/SWE-bench_Lite --lite-hf-split test \
  --cpp-dataset  <org>/<multilang-repo>       --cpp-hf-split  cpp \
  --csharp-dataset <org>/<multilang-repo>     --csharp-hf-split csharp
```

Use `--dump-raw` to print each source's real field keys so you can reconcile the
schema mapping in `normalize_record()` if any field lands empty.

### Offline / air-gapped

If the `datasets` library or network is unavailable, the script fails with an
explicit message and supports pre-fetched local files:

```bash
python3 -I data/prepare_datasets.py --from-local /path/to/raw
# expects /path/to/raw/<split>.jsonl or swebench-multilang-<split>.jsonl
```

## JSONL schema the engine consumes

Each output line is one instance. The engine selects an instance with
`jq 'select(.instance_id == "<id>")'` and reads these fields (see
`benchmark/run-instance-k8s.sh` and `benchmark/eval-instance-k8s.sh`):

| Field               | Type    | Consumed by      | Notes |
| ------------------- | ------- | ---------------- | ----- |
| `instance_id`       | string  | run + eval       | Selector key; also seeds the `docker_image` fallback. Unique per split. |
| `repo`              | string  | run + eval       | `owner/name`. Shown in the prompt and the result record. |
| `problem_statement` | string  | run              | The GitHub issue text handed to the agent. |
| `test_patch`        | string  | run + eval       | Unified diff that adds/activates the failing tests; applied before the agent runs and before eval. |
| `hints_text`        | string  | run              | Optional extra context; `""`/absent is fine (added to the prompt only when non-empty). |
| `FAIL_TO_PASS`      | [string]| run + eval       | Tests that must flip fail→pass to count as resolved. The run prompt lists the first 10; eval checks all. |
| `PASS_TO_PASS`      | [string]| eval             | Regression-guard tests that must stay passing. |
| `rebuild_cmds`      | [string]| run + eval       | Engine uses element `[0]`; build command run after applying patches. `[]` → skipped. |
| `test_cmds`         | [string]| run + eval       | Engine uses element `[0]`; command that runs the tests. `[]` → omitted from prompt. |
| `print_cmds`        | [string]| eval             | Engine uses element `[0]`; eval-only command to dump results. |
| `log_parser`        | string  | eval             | Hint passed to `parse_results.py` for test-status parsing. |
| `docker_image`      | string  | run + eval       | Prebuilt eval image. `""` → the engine derives one (see below). |

`FAIL_TO_PASS` and `PASS_TO_PASS` accept either a real JSON array or a
JSON-encoded string upstream; `prepare_datasets.py` normalizes both to a JSON
array so the engine's `jq -c '.FAIL_TO_PASS'` works unchanged.

Output is deterministic: rows are sorted by `instance_id`, duplicate ids are
dropped, and keys are emitted in sorted order, so repeated runs produce
byte-identical files.

## How `docker_image` is derived

`docker_image` is optional. When a row's value is `""` (or absent), both
`run-instance-k8s.sh` and `eval-instance-k8s.sh` fall back to a published
`starryzhang` eval image, deriving the tag from the instance id:

```
starryzhang/sweb.eval.x86_64.<instance_id | s/__/_1776_/g | lowercase>
```

For example `foo__bar-2` → `starryzhang/sweb.eval.x86_64.foo_1776_bar-2`. Leaving
`docker_image` empty is therefore safe for any instance that has a published
`starryzhang` image; set an explicit `docker_image` only to pin a different or
locally built image.

## References

- Engine scripts: [`../benchmark/run-instance-k8s.sh`](../benchmark/run-instance-k8s.sh),
  [`../benchmark/eval-instance-k8s.sh`](../benchmark/eval-instance-k8s.sh).
- Central config / squad→split mapping: [`../config/env.sh`](../config/env.sh).
- [SWE-bench](https://www.swebench.com/) and the SWE-bench Live / multilingual
  dataset cards on Hugging Face (verify ids before a run).
