#!/usr/bin/env bash
# Initialize the benchmark workspace PVC with AMI binary, datasets, and scripts.
# Run this ONCE from the coordinator pod after it starts.
#
# Usage: exec into coordinator pod, then: bash /scripts/setup-workspace.sh

set -euo pipefail

WORKSPACE="/workspace"
NAMESPACE="ccamacho-test-bench"

echo "=== Setting up benchmark workspace ==="

mkdir -p "$WORKSPACE"/{ami,data,staging,results,eval-results,scripts,logs,.cache,.config}

# ── install AMI binary ──────────────────────────────────────────────
if [ ! -f "$WORKSPACE/ami/ami" ]; then
  echo "Installing AMI binary..."
  # Download latest AMI release
  curl -fsSL https://github.com/anthropics/ami/releases/latest/download/ami-linux-x64 \
    -o "$WORKSPACE/ami/ami" 2>/dev/null || {
    echo "WARNING: Could not download AMI. You can manually copy it:"
    echo "  oc cp /path/to/ami benchmark-coordinator-xxx:/workspace/ami/ami"
  }
  chmod +x "$WORKSPACE/ami/ami" 2>/dev/null || true
fi

# ── install Python + dependencies (for evaluation) ──────────────────
echo "Installing Python tools..."
dnf install -y python3 python3-pip jq git 2>/dev/null || \
yum install -y python3 python3-pip jq git 2>/dev/null || \
apt-get update -qq && apt-get install -y python3 python3-pip jq git 2>/dev/null || true

# ── clone SWE-bench-Live for evaluation ─────────────────────────────
if [ ! -d "$WORKSPACE/SWE-bench-Live" ]; then
  echo "Cloning SWE-bench-Live evaluation framework..."
  git clone --depth=1 https://github.com/SWE-bench-Live/SWE-bench-Live.git "$WORKSPACE/SWE-bench-Live" 2>/dev/null || {
    echo "WARNING: Could not clone SWE-bench-Live"
  }
fi

# ── download datasets ──────────────────────────────────────────────
echo "Downloading multilang datasets..."
for LANG in go java; do
  DEST="$WORKSPACE/data/swebench-multilang-${LANG}.jsonl"
  if [ ! -f "$DEST" ]; then
    echo "  Downloading $LANG dataset..."
    # These are typically in the repo or HuggingFace
    echo "  TODO: copy dataset to $DEST"
    echo "  oc cp /path/to/swebench-multilang-${LANG}.jsonl benchmark-coordinator-xxx:$DEST"
  else
    echo "  $LANG dataset exists ($DEST)"
  fi
done

echo ""
echo "=== Workspace setup complete ==="
echo "  AMI:       $WORKSPACE/ami/ami"
echo "  Data:      $WORKSPACE/data/"
echo "  Results:   $WORKSPACE/results/"
echo "  Scripts:   $WORKSPACE/scripts/"
echo ""
echo "Next: copy datasets and run benchmarks"
