#!/usr/bin/env bash
set -euo pipefail

# STUB. Real version runs the six criteria and exits non-zero on failure.
{
  echo 'report<<GATE_EOF'
  echo '### Gate criteria'
  echo ''
  echo '| # | Criterion | Result |'
  echo '| --- | --- | --- |'
  echo '| 1 | SHA256SUMS signature vs pinned fingerprint | STUB |'
  echo '| 2 | Artifact checksum matches signed sums | STUB |'
  echo '| 3 | Stable release, not prerelease | STUB |'
  echo '| 4 | Version moves forward only | STUB |'
  echo '| 5 | Soak period >= 14 days | STUB |'
  echo '| 6 | Plugin API compatible with pinned Packer | STUB |'
  echo 'GATE_EOF'
} >> "$GITHUB_OUTPUT"
