#!/usr/bin/env bash
# Theme audit — design tokens must be the only source of raw colors.
#   BLOCK: raw hex (Color(hex:) / #RRGGBB) outside DesignSystem/
#   BLOCK: raw .white / .black color usage outside DesignSystem/
# Run from anywhere: bash ios/scripts/check_theme.sh
set -euo pipefail
cd "$(dirname "$0")/.."        # -> ios/
SRC="Mango"
fail=0

hex=$(grep -rnE 'Color\(hex:|#[0-9A-Fa-f]{6}' "$SRC" --include='*.swift' | grep -v '/DesignSystem/' || true)
if [ -n "$hex" ]; then
  echo "❌ Hardcoded hex outside DesignSystem/ (define it in Theme.swift):"
  echo "$hex"
  fail=1
fi

raw=$(grep -rnE '(foregroundStyle|tint|fill|stroke|background)\(\.(white|black)\b' \
        "$SRC" --include='*.swift' | grep -v '/DesignSystem/' || true)
if [ -n "$raw" ]; then
  echo "❌ Raw .white/.black outside DesignSystem/ (use Palette.onAccent / Palette.shadow):"
  echo "$raw"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "✓ theme audit passed — design tokens only"
exit $fail
