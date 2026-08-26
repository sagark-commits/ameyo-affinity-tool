#!/usr/bin/env bash
# Install affinity-tool system-wide on a Linux host
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-/opt/ameyo-affinity-tool}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo $0 [$DEST]"
  exit 1
fi

mkdir -p "$DEST"
cp -a "$ROOT/affinity_tool.sh" "$DEST/"
cp -a "$ROOT/affinity_batch.sh" "$DEST/" 2>/dev/null || true
cp -a "$ROOT/profiles" "$DEST/"
cp -a "$ROOT/inventory" "$DEST/" 2>/dev/null || true
chmod 755 "$DEST/affinity_tool.sh"
[[ -f "$DEST/affinity_batch.sh" ]] && chmod 755 "$DEST/affinity_batch.sh"
ln -sfn "$DEST/affinity_tool.sh" /usr/local/sbin/affinity-tool
[[ -f "$DEST/affinity_batch.sh" ]] && ln -sfn "$DEST/affinity_batch.sh" /usr/local/sbin/affinity-batch
echo "Installed: affinity-tool -> $DEST/affinity_tool.sh"
echo "Try: affinity-tool --detect"
echo "Batch: affinity-batch --inventory $DEST/inventory/blr-servers.csv"
