#!/usr/bin/env python3
# -I safe: run as `python3 -I data/prepare_datasets.py ...`. Only stdlib is
# imported at module load; the optional `datasets` dependency is imported lazily
# inside a function so that `--from-local` works with no third-party packages.
"""Materialize the three SWE-bench Live splits into the JSONL the benchmark
engine consumes.

NVIDIA-1535 — "Multi-Tenant Autonomous Coding Agents on a Shared GPU Cluster".

Three data-science squads each drive the AMI agent against a different split:

    Squad A -> lite    (SWE-bench Lite,  Python)
    Squad B -> cpp     (SWE-bench C/C++)
    Squad C -> csharp  (SWE-bench C#)

For each split this script writes:

    <out-dir>/swebench-multilang-<split>.jsonl

which the proven engine reads at ``/workspace/data/swebench-multilang-<split>.jsonl``
(see benchmark/run-instance-k8s.sh and benchmark/eval-instance-k8s.sh; the repo's
data/ directory is rsynced into the shared PVC by benchmark/setup-workspace.sh).

The output rows carry exactly the fields the engine reads via `jq`:

    instance_id      str   — selector key; also seeds the docker_image fallback
    repo             str   — "owner/name"
    problem_statement str  — the GitHub issue text handed to the agent
    test_patch       str   — unified diff that adds/activates the failing tests
    hints_text       str   — optional extra context (may be "")
    FAIL_TO_PASS     [str] — tests that must flip fail->pass to count as resolved
    PASS_TO_PASS     [str] — regression guard tests (consumed by the eval Job)
    rebuild_cmds     [str] — engine uses element [0]; build after applying patches
    test_cmds        [str] — engine uses element [0]; command that runs the tests
    print_cmds       [str] — engine uses element [0]; eval-only result dump cmd
    log_parser       str   — eval-only hint for parse_results.py (may be "")
    docker_image     str   — prebuilt eval image; "" lets the engine derive it

docker_image derivation (mirrors run-instance-k8s.sh / eval-instance-k8s.sh):
when docker_image is empty the engine falls back to
    starryzhang/sweb.eval.x86_64.<instance_id | s/__/_1776_/g | lowercase>
so leaving it "" is safe for any instance that has a published starryzhang image.

IMPORTANT — DATASET IDS ARE UNVERIFIED DEFAULTS. The Hugging Face repo ids and
split names in SPLIT_SOURCES below are best-known guesses, NOT confirmed. SWE-bench
Live (the monthly-refreshed Python benchmark) and the multilingual C/C++ & C# sets
live in different repos with different schemas. Verify every id/split against the
live Hub before trusting a run, and override with the CLI flags if they differ.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Default output directory = this repo's data/ dir (where this script lives).
DEFAULT_OUT_DIR = Path(__file__).resolve().parent

# Squad -> split mapping (keep in lockstep with config/env.sh SQUAD_SPLIT).
SQUAD_FOR_SPLIT = {"lite": "a", "cpp": "b", "csharp": "c"}

# ── Per-split upstream source (BEST-KNOWN DEFAULTS — MUST VERIFY) ──────────────
# `dataset` is the Hugging Face repo id; `hf_split` is the split/config to load.
# These are deliberately overridable per split via CLI flags so you can correct
# them without editing code once the real ids are confirmed on the Hub.
#
#   lite   : SWE-bench Live publishes a "lite" Python slice that refreshes monthly.
#            Confirm the id (e.g. "SWE-bench-Live/SWE-bench-Live" vs the classic
#            "princeton-nlp/SWE-bench_Lite") and the split name before a real run.
#   cpp /  : The multilingual C/C++ and C# instances are NOT part of SWE-bench Live
#   csharp : today; they come from a multi-language benchmark (e.g. Multi-SWE-bench
#            with per-language configs "cpp" / "csharp"). Verify repo id + configs.
SPLIT_SOURCES: dict[str, dict[str, str]] = {
    "lite": {"dataset": "SWE-bench-Live/SWE-bench-Live", "hf_split": "lite"},
    "cpp": {"dataset": "SWE-bench-Live/SWE-bench-Live", "hf_split": "cpp"},
    "csharp": {"dataset": "SWE-bench-Live/SWE-bench-Live", "hf_split": "csharp"},
}

# The engine's generic test-status parser special-cases "go"/"java" and treats
# everything else generically; "cpp"/"csharp"/"lite" all take the generic path.
ALL_SPLITS = list(SPLIT_SOURCES)


def _first(raw: dict[str, Any], *keys: str, default: Any = None) -> Any:
    """Return the first present, non-null value among `keys`."""
    for key in keys:
        if key in raw and raw[key] is not None:
            return raw[key]
    return default


def _as_str(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return value if isinstance(value, str) else str(value)


def _as_str_list(value: Any) -> list[str]:
    """Coerce a field into a list[str].

    Upstream datasets encode test-id lists either as a real JSON array or as a
    JSON-encoded string; handle both, plus a bare string -> single-element list.
    """
    if value is None:
        return []
    if isinstance(value, list):
        return [_as_str(v) for v in value]
    if isinstance(value, str):
        text = value.strip()
        if text.startswith("[") and text.endswith("]"):
            try:
                parsed = json.loads(text)
                if isinstance(parsed, list):
                    return [_as_str(v) for v in parsed]
            except json.JSONDecodeError:
                pass
        return [text] if text else []
    return [_as_str(value)]


def normalize_record(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Map one upstream dataset record to the engine's JSONL schema.

    Field name variants below cover the common SWE-bench / Multi-SWE-bench
    spellings. These mappings are best-effort and MUST be verified against the
    actual schema of whichever dataset you point this at — print one raw record
    with `--limit 1 --dump-raw` and reconcile the keys if anything lands empty.
    """
    instance_id = _as_str(_first(raw, "instance_id", "id", "instance"))
    if not instance_id:
        # Multi-SWE-bench style: synthesize owner__repo-number if no explicit id.
        org = _as_str(_first(raw, "org", "owner"))
        repo_name = _as_str(_first(raw, "repo_name", "name"))
        number = _as_str(_first(raw, "number", "pr", "pull_number"))
        if org and repo_name and number:
            instance_id = f"{org}__{repo_name}-{number}"
    if not instance_id:
        return None  # cannot be selected by the engine without an id

    repo = _as_str(_first(raw, "repo", "repository"))
    if not repo:
        org = _as_str(_first(raw, "org", "owner"))
        repo_name = _as_str(_first(raw, "repo_name", "name"))
        if org and repo_name:
            repo = f"{org}/{repo_name}"

    return {
        "instance_id": instance_id,
        "repo": repo,
        "problem_statement": _as_str(
            _first(raw, "problem_statement", "issue", "issue_body", "description")
        ),
        "test_patch": _as_str(_first(raw, "test_patch", "test_diff")),
        "hints_text": _as_str(_first(raw, "hints_text", "hints")),
        "FAIL_TO_PASS": _as_str_list(
            _first(raw, "FAIL_TO_PASS", "fail_to_pass", "f2p")
        ),
        "PASS_TO_PASS": _as_str_list(
            _first(raw, "PASS_TO_PASS", "pass_to_pass", "p2p")
        ),
        "rebuild_cmds": _as_str_list(
            _first(raw, "rebuild_cmds", "build_cmds", "install_cmds")
        ),
        "test_cmds": _as_str_list(_first(raw, "test_cmds", "test_cmd", "test_command")),
        "print_cmds": _as_str_list(_first(raw, "print_cmds", "print_cmd")),
        "log_parser": _as_str(_first(raw, "log_parser", "parser")),
        # Empty string is intentional: the engine derives a starryzhang image when
        # docker_image is "". Pass through an explicit image only if upstream has one.
        "docker_image": _as_str(_first(raw, "docker_image", "image", "eval_image")),
    }


def load_from_local(local_dir: Path, split: str) -> list[dict[str, Any]]:
    """Load raw records for `split` from a local directory.

    Looks for, in order: swebench-multilang-<split>.jsonl, <split>.jsonl,
    <split>.json. Supports JSONL (one object per line) and a JSON array file.
    """
    candidates = [
        local_dir / f"swebench-multilang-{split}.jsonl",
        local_dir / f"{split}.jsonl",
        local_dir / f"{split}.json",
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        raise FileNotFoundError(
            f"No local source for split '{split}' in {local_dir}. "
            f"Expected one of: {', '.join(p.name for p in candidates)}"
        )
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".json":
        data = json.loads(text)
        if not isinstance(data, list):
            raise ValueError(f"{path} must contain a JSON array of records")
        return data
    rows: list[dict[str, Any]] = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{line_no}: invalid JSON line: {exc}") from exc
    return rows


def load_from_hf(dataset_id: str, hf_split: str) -> list[dict[str, Any]]:
    """Load raw records from the Hugging Face Hub via the `datasets` library.

    Fails with an actionable message if the library or the network is missing;
    callers should then fall back to --from-local.
    """
    try:
        from datasets import load_dataset  # type: ignore
    except Exception as exc:  # ImportError or a broken install
        raise RuntimeError(
            "The 'datasets' library is not available "
            f"({type(exc).__name__}: {exc}).\n"
            "Install it (`pip install datasets`) or re-run with "
            "--from-local <dir> to use pre-fetched JSONL files offline."
        ) from exc

    try:
        ds = load_dataset(dataset_id, split=hf_split)
    except Exception as exc:
        raise RuntimeError(
            f"Failed to load '{dataset_id}' split '{hf_split}' from Hugging Face "
            f"({type(exc).__name__}: {exc}).\n"
            "Common causes: the repo id/split is wrong (these defaults are "
            "UNVERIFIED — see SPLIT_SOURCES), the repo is gated (set HF_TOKEN), "
            "or there is no network. Re-run with the correct --<split>-dataset / "
            "--<split>-hf-split, or use --from-local <dir>."
        ) from exc

    return [dict(row) for row in ds]


def build_split(
    split: str,
    out_dir: Path,
    *,
    dataset_id: str,
    hf_split: str,
    from_local: Path | None,
    limit: int | None,
    dump_raw: bool,
) -> int:
    squad = SQUAD_FOR_SPLIT.get(split, "?")
    if from_local is not None:
        print(f"[{split}] squad {squad}: loading from local dir {from_local}")
        raw_rows = load_from_local(from_local, split)
    else:
        print(
            f"[{split}] squad {squad}: loading HF dataset "
            f"'{dataset_id}' split '{hf_split}'"
        )
        raw_rows = load_from_hf(dataset_id, hf_split)

    if dump_raw and raw_rows:
        print(f"[{split}] raw record[0] keys: {sorted(raw_rows[0])}")
        print(f"[{split}] raw record[0]: {json.dumps(raw_rows[0], default=str)[:2000]}")

    normalized: list[dict[str, Any]] = []
    skipped = 0
    for raw in raw_rows:
        record = normalize_record(raw)
        if record is None:
            skipped += 1
            continue
        normalized.append(record)

    # Deterministic output: stable order + stable key order, independent of the
    # upstream row order so repeated runs produce byte-identical files.
    normalized.sort(key=lambda r: r["instance_id"])
    # Guard against duplicate instance_ids (jq `head -1` would hide them silently).
    seen: set[str] = set()
    deduped: list[dict[str, Any]] = []
    for record in normalized:
        if record["instance_id"] in seen:
            continue
        seen.add(record["instance_id"])
        deduped.append(record)
    dropped_dups = len(normalized) - len(deduped)
    normalized = deduped

    if limit is not None:
        normalized = normalized[:limit]

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"swebench-multilang-{split}.jsonl"
    with out_path.open("w", encoding="utf-8") as stream:
        for record in normalized:
            stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    notes = []
    if skipped:
        notes.append(f"{skipped} skipped (no instance_id)")
    if dropped_dups:
        notes.append(f"{dropped_dups} duplicate id(s) dropped")
    suffix = f" ({'; '.join(notes)})" if notes else ""
    print(f"[{split}] wrote {len(normalized)} instances -> {out_path}{suffix}")
    return len(normalized)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="Directory for the swebench-multilang-<split>.jsonl files "
        f"(default: {DEFAULT_OUT_DIR}).",
    )
    parser.add_argument(
        "--splits",
        default=",".join(ALL_SPLITS),
        help="Comma-separated splits to build (default: all three). "
        "Mapping: lite=Squad A, cpp=Squad B, csharp=Squad C.",
    )
    parser.add_argument(
        "--from-local",
        type=Path,
        default=None,
        help="Load raw records from this local directory instead of Hugging "
        "Face (expects <split>.jsonl / swebench-multilang-<split>.jsonl). Use "
        "this when the datasets library or network is unavailable.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Cap each split to the first N instances (after sort) for smoke "
        "tests. Deterministic.",
    )
    parser.add_argument(
        "--dump-raw",
        action="store_true",
        help="Print the keys and first raw record per split (schema debugging).",
    )
    # Per-split dataset id / HF split overrides so unverified defaults can be
    # corrected without editing the file.
    for split in ALL_SPLITS:
        parser.add_argument(
            f"--{split}-dataset",
            default=SPLIT_SOURCES[split]["dataset"],
            help=f"HF dataset id for the '{split}' split "
            f"(UNVERIFIED default: {SPLIT_SOURCES[split]['dataset']}).",
        )
        parser.add_argument(
            f"--{split}-hf-split",
            default=SPLIT_SOURCES[split]["hf_split"],
            help=f"HF split/config name for '{split}' "
            f"(UNVERIFIED default: {SPLIT_SOURCES[split]['hf_split']}).",
        )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    requested = [s.strip() for s in args.splits.split(",") if s.strip()]
    unknown = [s for s in requested if s not in SPLIT_SOURCES]
    if unknown:
        print(
            f"ERROR: unknown split(s) {unknown}. Valid: {ALL_SPLITS}",
            file=sys.stderr,
        )
        return 2

    total = 0
    for split in requested:
        dataset_id = getattr(args, f"{split}_dataset")
        hf_split = getattr(args, f"{split}_hf_split")
        total += build_split(
            split,
            args.out_dir,
            dataset_id=dataset_id,
            hf_split=hf_split,
            from_local=args.from_local,
            limit=args.limit,
            dump_raw=args.dump_raw,
        )

    print(f"Done. {total} instances across {len(requested)} split(s) in {args.out_dir}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (RuntimeError, FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
