#!/usr/bin/env bash

set -euo pipefail

printf "\nScanning Solidity files in src/ (including src/interfaces/) for functions missing NatSpec docs...\n\n"

missing=0

for file in $(find src -type f -name "*.sol" | sort); do
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      missing=1
      echo "$line"
    fi
  done < <(awk -v file="$file" '
    {
      lines[NR] = $0
    }

    function has_natspec(lineNum,    i, text) {
      for (i = lineNum - 1; i >= 1 && i >= lineNum - 12; i--) {
        text = lines[i]
        if (text ~ /^[[:space:]]*\/\//) {
          return 1
        }
        if (text ~ /^[[:space:]]*contract[[:space:]]/ || text ~ /^[[:space:]]*interface[[:space:]]/ || text ~ /^[[:space:]]*library[[:space:]]/ ) {
          return 0
        }
      }
      return 0
    }

    /^[[:space:]]*(function|constructor)[[:space:]]/ {
      if ($0 ~ /external/ || $0 ~ /public/ || $0 ~ /constructor/) {
      if (!has_natspec(NR)) {
        printf "%s:%d:%s\n", file, NR, $0
      }
    }
    }

    END {
      # Shell receives output lines via process substitution; no exit-side metadata needed.
    }
  ' "$file")
done

if [[ "$missing" -eq 0 ]]; then
  echo "No missing NatSpec comments found for scanned public/external functions."
else
  echo "NatSpec coverage check failed. Add NatSpec blocks to listed functions."
  exit 1
fi
