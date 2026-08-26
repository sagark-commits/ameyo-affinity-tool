#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Load definitions without executing main.
sed 's/^main "\$@"$//' "$ROOT/affinity_tool.sh" > "$TMP/tool.sh"
# shellcheck disable=SC1090
source "$TMP/tool.sh"

DACX_ROOT="$TMP/dacx"
CSV="$DACX_ROOT/var/ameyo/dacxdata/etc/djinn/serviceCPUAffinityConf.csv"
mkdir -p "$(dirname "$CSV")"
cat > "$CSV" <<'EOF'
AMD,0
REPORTIKA_QUEUE,0
APPSERVER,1;2
ASTERISK,1;2
ASTERISK13,1;2
CRM,1
ASAP,1;2
KAFKA,3;4
ZOOKEEPER,3;4
CMS,5
data_logger,6
EOF

LOG_FILE="$TMP/test.log"
APPLY=0
PLAN_SVC=()
PLAN_SVC[server]="5,6,21,22"
PLAN_SVC[asterisk13]="3,4,11,12"

OUTPUT="$(write_ameyo_service_affinity 2>&1)"

assert_has() {
  local expected="$1"
  grep -Fqx "$expected" <<< "$OUTPUT" || {
    echo "Missing expected row: $expected"
    echo "$OUTPUT"
    exit 1
  }
}

assert_has "APPSERVER,5;6;21;22"
assert_has "ASTERISK,1;2"
assert_has "ASTERISK13,3;4;11;12"
assert_has "CRM,1"
assert_has "REPORTIKA_QUEUE,0"
assert_has "ASAP,1;2"
assert_has "AMD,0"
assert_has "KAFKA,3;4"
assert_has "ZOOKEEPER,3;4"
assert_has "CMS,5"
assert_has "data_logger,6"

if grep -Fqx "SERVICE,CPU" <<< "$OUTPUT"; then
  echo "Unexpected CSV header"
  exit 1
fi

# Dry run must not modify the original file.
grep -Fqx "APPSERVER,1;2" "$CSV"
grep -Fqx "CRM,1" "$CSV"

# Apply creates a timestamped backup, atomically replaces the known file, and
# restarts DJINN only after the managed rows have been merged.
APPLY=1
DJINN_RESTART_CMD="printf restarted > '$TMP/djinn-restarted'"
write_ameyo_service_affinity >/dev/null 2>&1
grep -Fqx "APPSERVER,5;6;21;22" "$CSV"
grep -Fqx "ASTERISK,1;2" "$CSV"
grep -Fqx "ASTERISK13,3;4;11;12" "$CSV"
EXPECTED_ORDER="AMD,REPORTIKA_QUEUE,APPSERVER,ASTERISK,ASTERISK13,CRM,ASAP,KAFKA,ZOOKEEPER,CMS,data_logger"
ACTUAL_ORDER="$(cut -d, -f1 "$CSV" | paste -sd, -)"
[[ "$ACTUAL_ORDER" == "$EXPECTED_ORDER" ]] || {
  echo "CSV row order changed: $ACTUAL_ORDER"
  exit 1
}
[[ -f "$TMP/djinn-restarted" ]]
compgen -G "${CSV}.bak.*" >/dev/null

# Restart failure must make the host apply fail, never report success.
DJINN_RESTART_CMD="false"
if (write_ameyo_service_affinity >/dev/null 2>&1); then
  echo "DJINN restart failure unexpectedly succeeded"
  exit 1
fi

# Legacy cfg receives the same row-preserving merge behavior.
CFG_ROOT="$TMP/cfg-dacx"
CFG="$CFG_ROOT/var/ameyo/dacxdata/var/affinity.cfg"
mkdir -p "$(dirname "$CFG")"
cat > "$CFG" <<'EOF'
# hand-maintained
-server : 1,2
-kafka : 7,8
-dagent : 0
EOF
DACX_ROOT="$CFG_ROOT"
AFFINITY_CONFIG_PATH=""
AFFINITY_CONFIG_TYPE=""
APPLY=0
PLAN_SVC=()
PLAN_SVC[server]="5,6"
PLAN_SVC[dagent]="5"
CFG_OUTPUT="$(write_ameyo_service_affinity 2>&1)"
grep -Fqx -- "-server : 5,6" <<< "$CFG_OUTPUT"
grep -Fqx -- "-kafka : 7,8" <<< "$CFG_OUTPUT"
grep -Fqx -- "-dagent : 5" <<< "$CFG_OUTPUT"

# A missing known config must abort before irqbalance, grub, or IRQ mutation.
DACX_ROOT="$TMP/missing-dacx"
AFFINITY_CONFIG_PATH=""
AFFINITY_CONFIG_TYPE=""
APPLY=1
MARKER="$TMP/mutated"
need_root() { :; }
disable_irqbalance() { touch "$MARKER"; }
apply_grub() { touch "$MARKER"; }
write_irq_script() { touch "$MARKER"; }
if (apply_all >/dev/null 2>&1); then
  echo "Missing-config apply unexpectedly succeeded"
  exit 1
fi
if [[ -e "$MARKER" ]]; then
  echo "Missing-config apply mutated the host before preflight"
  exit 1
fi

echo "service merge test: PASS"
