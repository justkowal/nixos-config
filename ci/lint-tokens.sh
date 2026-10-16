#!/usr/bin/env bash
# UI files must take colours, radii and fonts from the token module. files that predate
# the rule are listed in ci/token-baseline.txt; that list may only shrink.
set -euo pipefail
cd "${1:-.}"

scan() {
  find home hosts/rpi4/scripts -type f \( -name '*.nix' -o -name '*.py' -o -name '*.sh' -o -name '*.css' -o -name '*.rasi' \) \
    ! -path 'home/matugen/*' | sort |
    while IFS= read -r f; do
      grep -qE '#[0-9a-fA-F]{6}\b|border-radius:[[:space:]]*[0-9]+px|font-family' "$f" && echo "$f"
    done
}

if [ "${2:-}" = "--baseline" ]; then
  scan
  exit 0
fi

bad=$(scan | grep -vxFf ci/token-baseline.txt || true)
if [ -n "$bad" ]; then
  echo "hardcoded colour, radius or font outside the token module:"
  echo "$bad" | sed 's/^/  /'
  exit 1
fi
