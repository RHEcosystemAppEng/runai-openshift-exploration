#!/usr/bin/env python3
"""
Official SWE-bench grading for Go test output.
Replaces custom bash eval logic to match upstream behavior exactly.

Usage: python3 eval_grade.py <test_output_log> <fail_to_pass.json> <pass_to_pass.json> <report_output.json>
"""
import json
import re
import sys


def parse_log_gotest(log: str) -> dict:
    """Parse Go test output — matches upstream swebench.harness.log_parsers.go"""
    test_status_map = {}
    pattern = re.compile(r'^--- (PASS|FAIL|SKIP): (.+) \((.+)\)$', re.MULTILINE)
    for match in pattern.finditer(log):
        status = match.group(1)
        test_name = match.group(2)
        test_status_map[test_name] = status
    return test_status_map


def normalize_test_name(name: str) -> str:
    """Normalize Go test names for comparison.
    SWE-bench uses 'pkg::TestName' format, Go outputs just 'TestName'.
    """
    if '::' in name:
        return name.split('::')[-1]
    if '/' in name:
        parts = name.rsplit('/', 1)
        return parts[-1]
    return name


def get_package_from_test(name: str) -> str:
    """Extract package from 'pkg::TestName' format."""
    if '::' in name:
        return name.split('::')[0]
    return ''


def match_test_result(test_spec_name: str, status_map: dict) -> str | None:
    """Find a test result matching the spec name.
    Handles both 'pkg::TestFunc' and 'pkg::TestFunc/subtest' formats.
    """
    norm = normalize_test_name(test_spec_name)
    if norm in status_map:
        return status_map[norm]

    for key, status in status_map.items():
        if key == norm or key.startswith(norm + '/'):
            return status
        key_norm = normalize_test_name(key)
        if key_norm == norm:
            return status
    return None


def grade(test_log: str, fail_to_pass: list, pass_to_pass: list) -> dict:
    """Grade test results against expected outcomes."""
    status_map = parse_log_gotest(test_log)

    f2p_success = []
    f2p_failure = []
    for test in fail_to_pass:
        result = match_test_result(test, status_map)
        if result == 'PASS':
            f2p_success.append(test)
        else:
            f2p_failure.append(test)

    p2p_success = []
    p2p_failure = []
    for test in pass_to_pass:
        result = match_test_result(test, status_map)
        if result in ('PASS', 'SKIP', None):
            p2p_success.append(test)
        else:
            p2p_failure.append(test)

    resolved = len(f2p_success) > 0 and len(f2p_failure) == 0 and len(p2p_failure) == 0

    return {
        'resolved': resolved,
        'FAIL_TO_PASS': {
            'success': f2p_success,
            'failure': f2p_failure,
        },
        'PASS_TO_PASS': {
            'success': p2p_success,
            'failure': p2p_failure,
        },
    }


def main():
    if len(sys.argv) != 5:
        print(f'Usage: {sys.argv[0]} <test_log> <fail_to_pass.json> <pass_to_pass.json> <report.json>')
        sys.exit(1)

    test_log_path = sys.argv[1]
    f2p_path = sys.argv[2]
    p2p_path = sys.argv[3]
    report_path = sys.argv[4]

    with open(test_log_path) as f:
        test_log = f.read()

    with open(f2p_path) as f:
        fail_to_pass = json.load(f)

    with open(p2p_path) as f:
        pass_to_pass = json.load(f)

    report = grade(test_log, fail_to_pass, pass_to_pass)

    with open(report_path, 'w') as f:
        json.dump(report, f, indent=2)

    status = 'RESOLVED' if report['resolved'] else 'FAILED'
    f2p_ok = len(report['FAIL_TO_PASS']['success'])
    f2p_fail = len(report['FAIL_TO_PASS']['failure'])
    p2p_ok = len(report['PASS_TO_PASS']['success'])
    p2p_fail = len(report['PASS_TO_PASS']['failure'])
    print(f'{status}: F2P={f2p_ok}/{f2p_ok+f2p_fail} P2P_ok={p2p_ok} P2P_fail={p2p_fail}')


if __name__ == '__main__':
    main()
