#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit baseline update; review the resulting snapshots diff before committing.
forge test --match-contract STRNGas --gas-snapshot-check false --gas-snapshot-emit true
