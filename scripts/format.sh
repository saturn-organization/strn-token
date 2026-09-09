#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-check}"
case "$mode" in
  check)
    prettier_mode=--check
    shell_mode=-d
    python_args=(--check)
    forge_args=(--check)
    ;;
  write)
    prettier_mode=--write
    shell_mode=-w
    python_args=()
    forge_args=()
    ;;
  *)
    echo 'Usage: scripts/format.sh [check|write]' >&2
    exit 2
    ;;
esac
[[ "$(shfmt --version)" == v3.12.0 ]] || {
  echo 'Install shfmt v3.12.0 (see docs/VERIFICATION.md).' >&2
  exit 1
}
ruff format ${python_args[@]+"${python_args[@]}"} scripts/*.py
shfmt -i 2 -ci "$shell_mode" scripts/*.sh
./node_modules/.bin/prettier "$prettier_mode" '*.json' '*.md' 'scripts/*.{js,cjs}' 'config/**/*.json' 'config/**/*.md' 'docs/**/*.md' 'audits/**/*.md' '.github/**/*.yml' --no-error-on-unmatched-pattern
forge fmt ${forge_args[@]+"${forge_args[@]}"}
