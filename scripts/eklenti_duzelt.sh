#!/usr/bin/env bash
# Bazı eklentiler (ör. file_picker 8) eski bir Android SDK ile derleniyor; yeni Flutter bağımlılıkları
# en az 36 istiyor. pub önbelleğindeki eklentilerin derleme SDK'sını 36'ya çıkarır (davranışı değiştirmez).
set -euo pipefail
CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
for f in "$CACHE"/hosted/pub.dev/*/android/build.gradle "$CACHE"/hosted/pub.dev/*/android/build.gradle.kts; do
  [[ -f "$f" ]] || continue
  if grep -qE 'compileSdk(Version)?\s*(=\s*)?(2[0-9]|3[0-5])\b' "$f"; then
    sed -i -E 's/(compileSdk(Version)?\s*(=\s*)?)(2[0-9]|3[0-5])\b/\136/' "$f"
    echo "compileSdk 36: $f"
  fi
done
