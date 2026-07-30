#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 00 与 04 直接复用 common-nodes 的文件（不复制一份，避免副本漂移，见 L5）
MODULES=(
  extensions/common-nodes/00-env-utils.sh
  extensions/quic-h3/01-read-existing.sh
  extensions/quic-h3/02-server-config.sh
  extensions/quic-h3/03-client-config.sh
  extensions/common-nodes/04-subscription-output.sh
)

OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
OUTPUT="$OUT_DIR/add-quic-h3.sh"
mkdir -p "$OUT_DIR"

cat > "$OUTPUT" <<'SCRIPTHEADER'
#!/bin/bash
set -e
SCRIPTHEADER

for module in "${MODULES[@]}"; do
  cat "$ROOT_DIR/$module" >> "$OUTPUT"
  printf '\n' >> "$OUTPUT"
done
chmod +x "$OUTPUT"

echo "Generated $OUTPUT"
