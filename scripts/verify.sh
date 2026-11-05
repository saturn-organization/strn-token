#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${STRN_SOLC:=solc}"
python3 scripts/check-deployment-config.py --check-draft
python3 scripts/test-deployment-config.py
forge fmt --check
forge build --sizes
python3 scripts/check-gas.py
FOUNDRY_PROFILE=audit forge test -v --gas-snapshot-emit false
forge test --match-contract 'STRNInvariant|CombinedSTRNVotesInvariant' --fuzz-seed 0x20260909 -v --gas-snapshot-emit false
node scripts/check-upgrade.cjs "$STRN_SOLC"
node scripts/check-staking-upgrade.cjs "$STRN_SOLC"
# Slither returns nonzero when reporting informational assembly; triage its JSON, do not ignore errors.
