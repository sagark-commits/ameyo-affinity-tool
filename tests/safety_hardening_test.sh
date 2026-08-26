#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed 's/^main "\$@"$//' "$ROOT/affinity_tool.sh" > "$TMP/tool.sh"
# shellcheck disable=SC1090
source "$TMP/tool.sh"

LOG_FILE="$TMP/test.log"
DACX_ROOT="$TMP/dacx"
AFFINITY_SETTER_OUT="$TMP/affinitySetter.sh"
AFFINITY_SKIP_PERSISTENCE=1
APPLY=1
ROLE=app
TS=test
PLAN_IRQ=([65]=2 [66]=3)
PLAN_IRQ_CLASS=([65]=disk [66]=disk)
cpu_to_smp_mask() { printf '%x\n' "$((1 << $1))"; }

# Generated persistence must rediscover by class, not retain current IRQ IDs.
mkdir -p "$TMP/irq/165" "$TMP/irq/166"
printf ' 165: 0 0 PCI-MSI-edge nvme0q0\n 166: 0 0 PCI-MSI-edge nvme0q1\n' > "$TMP/interrupts"
: > "$TMP/irq/165/smp_affinity"
: > "$TMP/irq/166/smp_affinity"
AFFINITY_PROC_INTERRUPTS="$TMP/interrupts"
AFFINITY_PROC_IRQ_ROOT="$TMP/irq"
export AFFINITY_PROC_INTERRUPTS AFFINITY_PROC_IRQ_ROOT
write_irq_script >/dev/null 2>&1
grep -Fq 'discover_class' "$AFFINITY_SETTER_OUT"
if grep -Eq '/(65|66)/smp_affinity' "$AFFINITY_SETTER_OUT"; then
  echo "Persistence retained stale IRQ IDs"
  exit 1
fi
canonical_mask() {
  local mask
  mask="$(tr -d '[:space:],' <<< "$1")"
  mask="${mask#"${mask%%[!0]*}"}"
  printf '%s\n' "${mask:-0}"
}
ACTUAL_MASKS="$(
  printf '%s\n' \
    "$(canonical_mask "$(cat "$TMP/irq/165/smp_affinity")")" \
    "$(canonical_mask "$(cat "$TMP/irq/166/smp_affinity")")" |
    sort -n | paste -sd, -
)"
[[ "$ACTUAL_MASKS" == 4,8 ]]

# Every write is attempted and failures are aggregated into a host failure.
rm -f "$TMP/irq/165/smp_affinity" "$TMP/irq/166/smp_affinity"
if (write_irq_script) >"$TMP/write-output" 2>&1; then
  echo "Failed IRQ writes unexpectedly succeeded"
  exit 1
fi
grep -Fq '2 IRQ affinity write(s) failed' "$TMP/write-output"
grep -Fq 'IRQ 165 (nvme0q0/disk)' "$TMP/write-output"
grep -Fq 'IRQ 166 (nvme0q1/disk)' "$TMP/write-output"

# Verify compares expected live IRQ/config state and returns actionable status.
CSV="$DACX_ROOT/var/ameyo/dacxdata/etc/djinn/serviceCPUAffinityConf.csv"
mkdir -p "$(dirname "$CSV")" "$TMP/irq/165"
printf 'APPSERVER,2;3\nDAGENT,2\nCRM,2\n' > "$CSV"
printf 'default_affinity=0x1\n' > "$TMP/cmdline"
printf '4\n' > "$TMP/irq/165/smp_affinity"
printf '4\n' > "$TMP/irq/165/effective_affinity"
AFFINITY_PROC_CMDLINE="$TMP/cmdline"
AFFINITY_CONFIG_PATH=""
AFFINITY_CONFIG_TYPE=""
PLAN_IRQ=([165]=2)
PLAN_IRQ_CLASS=([165]=disk)
PLAN_SVC=([server]='2,3' [dagent]=2 [crm]=2)
systemctl() {
  case "$1 $2" in
    "is-enabled irqbalance") return 1 ;;
    "is-enabled ameyo-affinity-irq.service") return 1 ;;
    "show djinn.service") return 0 ;;
  esac
  return 1
}
ps() { :; }
verify_state > "$TMP/verify-ok"
grep -Fq 'OK  IRQ 165' "$TMP/verify-ok"
grep -Fq 'OK  APPSERVER,2;3' "$TMP/verify-ok"
printf '8\n' > "$TMP/irq/165/smp_affinity"
if verify_state > "$TMP/verify-fail"; then
  echo "Expected/live mismatch unexpectedly passed"
  exit 1
fi
grep -Fq 'FAIL IRQ 165' "$TMP/verify-fail"

# Batch verify must pass inventory role and workload arguments.
grep -Fq -- "--verify --role '\${role}'" "$ROOT/affinity_batch.sh"
grep -Fq -- "--concurrent-calls '\${CONCURRENT_CALLS}'" "$ROOT/affinity_batch.sh"
grep -Fq -- "--active-agents '\${ACTIVE_AGENTS}'" "$ROOT/affinity_batch.sh"

echo "safety hardening test: PASS"
