#!/usr/bin/env python3
"""
SWE-bench evaluation parser for Kubernetes jobs.
Handles patch sanitization and test result parsing.

Usage:
  python3 eval_parse.py --sanitize-patch PATCH_FILE    # Clean binary diffs from patch
  python3 eval_parse.py                                # Parse test results and generate report
"""

import argparse
import json
import os
import re
import sys


def sanitize_patch(patch_file):
    """Remove binary diffs and other non-text content from patch file."""
    if not os.path.exists(patch_file):
        return

    with open(patch_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    # Strip binary file markers
    lines = []
    skip_binary = False
    for line in content.split('\n'):
        if line.startswith('diff --git'):
            skip_binary = False
        if 'GIT binary patch' in line or 'Binary files' in line:
            skip_binary = True
            continue
        if not skip_binary:
            lines.append(line)

    sanitized = '\n'.join(lines)

    with open(patch_file, 'w', encoding='utf-8') as f:
        f.write(sanitized)


def builtin_pytest_parser(log: str) -> dict:
    """Parse pytest output — matches upstream swebench pytest log parser."""
    test_status_map = {}
    for line in log.split('\n'):
        line = line.strip()
        if line.startswith(('PASSED', 'FAILED', 'ERROR', 'XFAIL', 'XPASS')):
            clean = line.replace(' - ', ' ')
            parts = clean.split()
            if len(parts) >= 2:
                status_word = parts[0]
                test_name = parts[1]
                if status_word in ('PASSED', 'XFAIL', 'XPASS'):
                    status = 'pass'
                elif status_word in ('FAILED', 'ERROR'):
                    status = 'fail'
                else:
                    continue
                test_status_map[test_name] = status
        elif line.startswith('SKIPPED'):
            clean = line.replace(' - ', ' ')
            parts = clean.split()
            if len(parts) >= 2:
                test_status_map[parts[1]] = 'skip'
        # pytest -rA format: "test_file.py::TestClass::test_method PASSED"
        elif '::' in line:
            if line.startswith(('File ', 'E ', '> ', 'INTERNALERROR')):
                continue
            for marker, status in [(' PASSED', 'pass'), (' FAILED', 'fail'), (' ERROR', 'fail'), (' XFAIL', 'pass'), (' XPASS', 'pass'), (' SKIPPED', 'skip')]:
                idx = line.find(marker)
                if idx > 0:
                    test_name = line[:idx].strip()
                    if '::' in test_name:
                        test_status_map[test_name] = status
                    break

    return test_status_map


BUILTIN_PARSERS = {
    'pytest': builtin_pytest_parser,
}


def load_log_parser():
    """Load the instance-specific log parser function."""
    parser_file = '/staging/log_parser.py'
    if not os.path.exists(parser_file):
        return None

    with open(parser_file, 'r', encoding='utf-8') as f:
        parser_code = f.read()

    parser_code = parser_code.strip()

    # Handle builtin parser names (e.g., "pytest" stored as a plain string)
    if parser_code in BUILTIN_PARSERS:
        return BUILTIN_PARSERS[parser_code]

    namespace = {}
    try:
        exec(parser_code, namespace)
    except SyntaxError:
        # If the file contains just a parser name string, try it as a builtin
        clean = parser_code.strip("'\"")
        if clean in BUILTIN_PARSERS:
            return BUILTIN_PARSERS[clean]
        return None
    return namespace.get('parser')


def _has_test_markers(content):
    """Check if content contains actual pytest result markers."""
    for marker in ('PASSED', 'FAILED', 'ERROR', 'XFAIL', 'XPASS', 'SKIPPED',
                   '::',  'passed', 'failed', 'error'):
        if marker in content:
            return True
    return False


def load_test_output():
    """Load test output from various possible locations."""
    candidates = [
        '/eval-results/test-output.log',
        '/eval-results/go-test-results.json',
        '/eval-results/test-results.json',
        '/eval-results/test-stdout.log',
    ]

    for path in candidates:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            with open(path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
            content = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', content)
            if _has_test_markers(content) or path == candidates[-1]:
                return content

    return ""


def load_golden_tests():
    """Load FAIL_TO_PASS and PASS_TO_PASS test lists."""
    fail_to_pass = []
    pass_to_pass = []

    f2p_file = '/staging/fail_to_pass.json'
    p2p_file = '/staging/pass_to_pass.json'

    if os.path.exists(f2p_file):
        with open(f2p_file, 'r', encoding='utf-8') as f:
            fail_to_pass = json.load(f)

    if os.path.exists(p2p_file):
        with open(p2p_file, 'r', encoding='utf-8') as f:
            pass_to_pass = json.load(f)

    return fail_to_pass, pass_to_pass


def load_baseline_failures(parser_func):
    """Load baseline test output and return set of tests that already fail."""
    baseline_file = '/eval-results/test-baseline.log'
    if not os.path.exists(baseline_file) or os.path.getsize(baseline_file) == 0:
        return set()
    with open(baseline_file, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    content = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', content)
    try:
        baseline_results = parser_func(content)
    except Exception:
        return set()
    return {name for name, status in baseline_results.items() if status == 'fail'}


def parse_and_evaluate():
    """Parse test results and generate evaluation report."""
    # Load parser function
    parser_func = load_log_parser()
    if not parser_func:
        report = {
            "resolved": False,
            "error": "no_log_parser",
            "FAIL_TO_PASS": {"success": [], "failure": []},
            "PASS_TO_PASS": {"success": [], "failure": []},
        }
        with open("/eval-results/report.json", "w") as f:
            json.dump(report, f, indent=2)
        return

    # Load test output
    test_output = load_test_output()
    if not test_output.strip():
        report = {
            "resolved": False,
            "error": "no_test_output",
            "FAIL_TO_PASS": {"success": [], "failure": []},
            "PASS_TO_PASS": {"success": [], "failure": []},
        }
        with open("/eval-results/report.json", "w") as f:
            json.dump(report, f, indent=2)
        return

    # Load golden test lists
    fail_to_pass, pass_to_pass = load_golden_tests()

    # Parse test results
    try:
        parsed_results = parser_func(test_output)
    except Exception as e:
        report = {
            "resolved": False,
            "error": f"parser_error: {str(e)}",
            "FAIL_TO_PASS": {"success": [], "failure": list(fail_to_pass)},
            "PASS_TO_PASS": {"success": [], "failure": []},
        }
        with open("/eval-results/report.json", "w") as f:
            json.dump(report, f, indent=2)
        return

    # Build a reverse lookup: strip pkg:: prefix for parsers that don't include it
    # This handles the mismatch between FAIL_TO_PASS format ("pkg::TestName")
    # and parsers that only return "TestName" as the key
    def lookup_result(test_name, results):
        if test_name in results:
            return results[test_name]
        if '::' in test_name:
            short = test_name.split('::')[-1]
            if short in results:
                return results[short]
        for key, val in results.items():
            if '::' in key and key.split('::')[-1] == test_name:
                return val
        return None

    # Evaluate FAIL_TO_PASS tests
    f2p_success = []
    f2p_failure = []
    for test_name in fail_to_pass:
        result = lookup_result(test_name, parsed_results)
        if result == "pass":
            f2p_success.append(test_name)
        else:
            f2p_failure.append(test_name)

    # Load baseline failures (tests that already fail without the agent patch)
    baseline_failures = load_baseline_failures(parser_func)
    if baseline_failures:
        print(f"EVAL: {len(baseline_failures)} pre-existing test failures excluded from P2P regression check")

    # Evaluate PASS_TO_PASS tests (regression check)
    p2p_success = []
    p2p_failure = []
    p2p_preexisting = []
    for test_name in pass_to_pass:
        result = lookup_result(test_name, parsed_results)
        if result == "pass" or result == "skip":
            p2p_success.append(test_name)
        elif result is not None:  # Test ran but didn't pass
            matched_key = test_name
            for key in parsed_results:
                if key == test_name or key.startswith(test_name):
                    matched_key = key
                    break
            if matched_key in baseline_failures:
                p2p_preexisting.append(test_name)
            else:
                p2p_failure.append(test_name)

    # Determine if instance is resolved
    resolved = (
        len(f2p_success) > 0 and  # At least one failing test now passes
        len(f2p_failure) == 0 and  # All failing tests now pass
        len(p2p_failure) == 0      # No new regressions (pre-existing excluded)
    )

    report = {
        "resolved": resolved,
        "FAIL_TO_PASS": {
            "success": f2p_success,
            "failure": f2p_failure,
        },
        "PASS_TO_PASS": {
            "success": p2p_success,
            "failure": p2p_failure,
            "preexisting": p2p_preexisting,
        },
    }

    with open("/eval-results/report.json", "w") as f:
        json.dump(report, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description="SWE-bench evaluation parser")
    parser.add_argument('--sanitize-patch', metavar='PATCH_FILE',
                       help='Clean binary diffs from patch file')
    args = parser.parse_args()

    if args.sanitize_patch:
        sanitize_patch(args.sanitize_patch)
    else:
        parse_and_evaluate()


if __name__ == '__main__':
    main()
