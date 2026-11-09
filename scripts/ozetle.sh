#!/usr/bin/env bash
# Bir komutu çalıştırır; başarısız olursa çıktının hata satırlarını GitHub "annotation" olarak yazar,
# böylece hata kaydı indirilmeden de görülebilir.
# Kullanım: bash scripts/ozetle.sh <etiket> <komut...>
set -uo pipefail
label="$1"; shift
log="ozet-$label.log"
"$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
if [[ $code -ne 0 || "$label" == "analiz" || "$label" == "surumler" ]]; then
  # Hata içeren satırlar ve hemen çevreleri; en fazla 120 satır
  lines=$( { grep -n -A12 "What went wrong" "$log"; \
             grep -n -E -B2 -A2 "error [A-Z]+[0-9]+|: error|Error:|error:|\.dart:[0-9]+:[0-9]+|Exception|CMake Error|FAILED" "$log"; \
             echo "---- son satirlar ----"; tail -n 40 "$log" | sed 's/^/T: /'; } \
          | grep -viE "nuget\.org|  GET https|  OK https|Node\.js 20" | awk '!seen[$0]++' | head -200 | cut -c1-260)
  [[ "$label" == "surumler" ]] && lines=$(head -60 "$log" | cut -c1-200)
  [[ -z "$lines" ]] && lines=$(tail -60 "$log" | cut -c1-300)
  msg=$(printf '%s' "$lines" | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"}{print}')
  level=error; [[ "$label" == "analiz" || "$label" == "surumler" ]] && level=warning
  echo "::$level title=$label::$msg"
fi
exit $code
