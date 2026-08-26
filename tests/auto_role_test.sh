#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Load the real argument parsing, role detection, planning, and main flow without
# executing it immediately. Host discovery is stubbed because Git Bash on
# Windows intentionally has no Linux /proc/interrupts.
sed 's/^main "\$@"$//' "$ROOT/affinity_tool.sh" > "$TMP/tool.sh"
# shellcheck disable=SC1090
source "$TMP/tool.sh"

detect_os() {
  OS_FAMILY=test
  OS_MAJOR=0
  GRUB_STYLE=unknown
}
detect_cpu() {
  PHYS_PRIMARY=(0 1 2 3)
  CPU_LIST=(0 1 2 3)
  HT_SIBLING=([0]=0 [1]=1 [2]=2 [3]=3)
  CPU_HEX=([0]=0x1 [1]=0x2 [2]=0x4 [3]=0x8)
  LOGICAL_CPUS=4
  PHYSICAL_CPUS=1
  CORES_PER_CPU=4
  IS_HT=0
  DEFAULT_AFFINITY_CPU=0
}
detect_irqs() {
  IRQ_ETH=()
  IRQ_DISK=()
  IRQ_TEL=()
  HAS_TELEPHONY=no
}

SNAPSHOT=$'/usr/lib/postgresql/postgres\n/opt/ameyo/ameyoarchiver'

# Ambiguous dry-run explains the evidence, requests an explicit role, and exits
# successfully without producing an affinity plan.
OUTPUT="$(
  AFFINITY_PROCESS_SNAPSHOT="$SNAPSHOT" AFFINITY_HOSTNAME=unknown-host \
    main --role auto --dacx "$TMP/dacx" \
      --log-dir "$TMP/logs" 2>&1
)"
grep -Fq "Status:      ambiguous-active-services" <<< "$OUTPUT"
grep -Fq "Candidates:  db,report" <<< "$OUTPUT"
grep -Fq "re-run with explicit --role" <<< "$OUTPUT"
grep -Fq "Dry-run stopped safely" <<< "$OUTPUT"
if grep -Fq "AFFINITY PLAN" <<< "$OUTPUT"; then
  echo "Ambiguous dry-run unexpectedly produced a plan"
  exit 1
fi

# The same ambiguity must reject apply before config discovery or any mutation.
if (
  AFFINITY_PROCESS_SNAPSHOT="$SNAPSHOT" AFFINITY_HOSTNAME=unknown-host \
    main --role auto --apply --dacx "$TMP/dacx" \
      --log-dir "$TMP/apply-logs" >"$TMP/apply-output" 2>&1
); then
  echo "Ambiguous auto apply unexpectedly succeeded"
  exit 1
fi
grep -Fq "apply refused" "$TMP/apply-output"
[[ ! -e "$TMP/dacx/affinitySetter.sh" ]]

# A generic installed CSV listing every role is not detection evidence.
CSV="$TMP/generic/var/ameyo/dacxdata/etc/djinn/serviceCPUAffinityConf.csv"
mkdir -p "$(dirname "$CSV")"
printf '%s\n' 'APPSERVER,1' 'POSTGRESQL,2' 'ASTERISK13,3' 'ASAP,4' > "$CSV"
NO_EVIDENCE_OUTPUT="$(
  AFFINITY_PROCESS_SNAPSHOT="" AFFINITY_HOSTNAME=unknown-host \
    main --role auto --dacx "$TMP/generic" \
      --log-dir "$TMP/generic-logs" 2>&1
)"
grep -Fq "Status:      no-unambiguous-evidence" <<< "$NO_EVIDENCE_OUTPUT"
grep -Fq "Dry-run stopped safely" <<< "$NO_EVIDENCE_OUTPUT"

echo "auto role test: PASS"
