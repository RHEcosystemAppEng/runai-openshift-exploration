#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path

def load_log_parser(parser_file):
    """Load the instance-specific log parser function."""
    if not os.path.exists(parser_file):
        return None

    try:
        with open(parser_file, 'r', encoding='utf-8') as f:
            parser_code = f.read()

        namespace = {}
        exec(parser_code, namespace)
        # Try both 'parse_log' and 'parser' function names
        return namespace.get('parse_log') or namespace.get('parser')
    except Exception as e:
        print(f"  ⚠️  Parser load error: {e}")
        return None

def parse_and_evaluate(instance_dir, eval_staging_dir):
    """Parse test results and generate evaluation report."""
    instance_dir = Path(instance_dir)
    eval_staging_dir = Path(eval_staging_dir)

    # Load parser function from -eval directory
    parser_file = eval_staging_dir / 'log_parser.py'
    parser_func = load_log_parser(str(parser_file))

    if not parser_func:
        return {
            "resolved": False,
            "error": "no_log_parser",
            "FAIL_TO_PASS": {"success": [], "failure": []},
            "PASS_TO_PASS": {"success": [], "failure": []},
        }

    # Load test output
    test_output = ""
    for candidate in [
        instance_dir / 'eval-results' / 'go-test-results.json',
        instance_dir / 'eval-results' / 'test-output.log',
        instance_dir / 'eval-results' / 'reports' / 'go-test-results.json',  # Alternative location
    ]:
        if candidate.exists() and candidate.stat().st_size > 0:
            test_output = candidate.read_text(encoding='utf-8', errors='replace')
            # Strip ANSI codes
            test_output = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', test_output)
            break

    if not test_output.strip():
        return {
            "resolved": False,
            "error": "no_test_output",
            "FAIL_TO_PASS": {"success": [], "failure": []},
            "PASS_TO_PASS": {"success": [], "failure": []},
        }

    # Load golden test lists from -eval directory
    fail_to_pass = []
    pass_to_pass = []
    
    f2p_file = eval_staging_dir / 'fail_to_pass.json'
    p2p_file = eval_staging_dir / 'pass_to_pass.json'
    
    if f2p_file.exists():
        fail_to_pass = json.loads(f2p_file.read_text())
    if p2p_file.exists():
        pass_to_pass = json.loads(p2p_file.read_text())

    # Parse test results
    try:
        parsed_results = parser_func(test_output)
    except Exception as e:
        return {
            "resolved": False,
            "error": f"parser_error: {str(e)}",
            "FAIL_TO_PASS": {"success": [], "failure": list(fail_to_pass)},
            "PASS_TO_PASS": {"success": [], "failure": []},
        }

    # Evaluate FAIL_TO_PASS tests
    f2p_success = []
    f2p_failure = []
    for test_name in fail_to_pass:
        result = parsed_results.get(test_name, "skip")
        if result == "pass":
            f2p_success.append(test_name)
        else:
            f2p_failure.append(test_name)

    # Evaluate PASS_TO_PASS tests (regression check)
    p2p_success = []
    p2p_failure = []
    for test_name in pass_to_pass:
        result = parsed_results.get(test_name)
        if result == "pass":
            p2p_success.append(test_name)
        elif result is not None:
            p2p_failure.append(test_name)

    # Determine if instance is resolved
    resolved = (
        len(f2p_success) > 0 and
        len(f2p_failure) == 0 and
        len(p2p_failure) == 0
    )

    print(f"  F2P: {len(f2p_success)}/{len(fail_to_pass)} pass, P2P regressions: {len(p2p_failure)}")

    return {
        "resolved": resolved,
        "FAIL_TO_PASS": {
            "success": f2p_success,
            "failure": f2p_failure,
        },
        "PASS_TO_PASS": {
            "success": p2p_success,
            "failure": p2p_failure,
        },
    }

def main():
    base_dir = Path('/workspace/verified/go/qwen-qwen3.8-27b')
    staging_base = Path('/workspace/staging/go')

    fixed = 0
    failed = 0
    resolved_count = 0

    # Process ALL instances (not just Sept 7)
    for instance_dir in sorted(base_dir.iterdir()):
        if not instance_dir.is_dir():
            continue

        instance_name = instance_dir.name
        report_file = instance_dir / 'eval-results' / 'report.json'

        # Skip if no test results
        test_exists = (
            (instance_dir / 'eval-results' / 'go-test-results.json').exists() or
            (instance_dir / 'eval-results' / 'reports' / 'go-test-results.json').exists()
        )
        if not test_exists:
            continue

        # Use -eval staging directory
        eval_staging_dir = staging_base / f"{instance_name}-eval"
        if not eval_staging_dir.exists():
            # Fallback to non-eval directory
            eval_staging_dir = staging_base / instance_name
            
        if not eval_staging_dir.exists():
            print(f"⚠️  {instance_name}: No staging directory")
            failed += 1
            continue

        print(f"Regenerating: {instance_name}")

        try:
            report = parse_and_evaluate(instance_dir, eval_staging_dir)
            report_file.write_text(json.dumps(report, indent=2))
            
            if report.get("resolved"):
                print(f"  ✅ RESOLVED!")
                resolved_count += 1
            else:
                error = report.get("error", "tests_failed")
                print(f"  ❌ Not resolved ({error})")
            fixed += 1
        except Exception as e:
            print(f"  ❌ Failed: {e}")
            import traceback
            traceback.print_exc()
            failed += 1

    print(f"\nSummary:")
    print(f"  ✅ Generated: {fixed} reports")
    print(f"  🎯 Resolved: {resolved_count} instances")
    print(f"  ❌ Failed: {failed} reports")

if __name__ == '__main__':
    main()
