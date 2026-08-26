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
AFFINITY_MANAGED_STATE_PATH="$TMP/managed-state"
export AFFINITY_PROC_INTERRUPTS AFFINITY_PROC_IRQ_ROOT
export AFFINITY_MANAGED_STATE_PATH
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

# Mixed MSI-X behavior: a writable control vector is pinned, while an EIO
# vector with a one-hot effective mask is validated and preserved.
cat > "$TMP/write-helper" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == */166/smp_affinity || "$1" == */266/smp_affinity ]]; then
  echo "$1: Input/output error" >&2
  exit 1
fi
printf '%s\n' "$2" > "$1"
EOF
chmod +x "$TMP/write-helper"
export AFFINITY_IRQ_WRITE_HELPER="$TMP/write-helper"
printf '8\n' > "$TMP/irq/166/effective_affinity"
write_irq_script >"$TMP/mixed-output" 2>&1
grep -Fq 'APPLIED IRQ 165' "$TMP/mixed-output"
grep -Fq 'MANAGED/SKIP IRQ 166 (nvme0q1/disk) -> effective CPU 3' "$TMP/mixed-output"
grep -Fq $'disk\tnvme0q1\tmanaged\t3\t8' "$AFFINITY_MANAGED_STATE_PATH"

# The persisted script rediscovers renumbered actions and reaches the same safe
# outcome, proving that state is keyed by class/action rather than IRQ number.
mkdir -p "$TMP/irq/265" "$TMP/irq/266"
printf ' 265: 0 0 PCI-MSI-edge nvme0q0\n 266: 0 0 PCI-MSI-edge nvme0q1\n' > "$TMP/interrupts"
: > "$TMP/irq/265/smp_affinity"
: > "$TMP/irq/266/smp_affinity"
printf '10\n' > "$TMP/irq/266/effective_affinity"
bash "$AFFINITY_SETTER_OUT" >"$TMP/persist-ok" 2>&1
grep -Fq 'APPLIED IRQ 265' "$TMP/persist-ok"
grep -Fq 'MANAGED/SKIP IRQ 266' "$TMP/persist-ok"
grep -Fq $'disk\tnvme0q1\tmanaged\t4\t10' "$AFFINITY_MANAGED_STATE_PATH"

# Permission/path/format-style failures remain fatal even with one-hot live
# state; a generic one-hot mismatch is not enough to infer managed status.
cat > "$TMP/write-helper" <<'EOF'
#!/usr/bin/env bash
echo "$1: Permission denied" >&2
exit 1
EOF
chmod +x "$TMP/write-helper"
if bash "$AFFINITY_SETTER_OUT" >"$TMP/persist-fail" 2>&1; then
  echo "Permission failure unexpectedly classified as managed"
  exit 1
fi
grep -Fq '2 IRQ affinity write(s) failed' "$TMP/persist-fail"
grep -Fq 'Permission denied' "$TMP/persist-fail"
unset AFFINITY_IRQ_WRITE_HELPER

# Every write is attempted and failures are aggregated into a host failure.
printf ' 165: 0 0 PCI-MSI-edge nvme0q0\n 166: 0 0 PCI-MSI-edge nvme0q1\n' > "$TMP/interrupts"
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

# Verify accepts persisted managed evidence after IRQ renumbering, but only for
# the same action/class identity and only while the live mask remains one-hot.
printf ' 165: 0 0 PCI-MSI-edge nvme0q1\n' > "$TMP/interrupts"
printf '8\n' > "$TMP/irq/165/smp_affinity"
printf '8\n' > "$TMP/irq/165/effective_affinity"
printf '%s\n' $'disk\tnvme0q1\tmanaged\t3\t8' > "$AFFINITY_MANAGED_STATE_PATH"
verify_state > "$TMP/verify-managed"
grep -Fq 'MANAGED/SKIP IRQ 165 (nvme0q1/disk) -> effective CPU 3' "$TMP/verify-managed"
printf '3\n' > "$TMP/irq/165/effective_affinity"
if verify_state > "$TMP/verify-managed-bad"; then
  echo "Non-one-hot managed IRQ unexpectedly passed verification"
  exit 1
fi
grep -Fq 'persisted managed evidence but live affinity is not one-hot' "$TMP/verify-managed-bad"

# Batch verify must pass inventory role and workload arguments.
grep -Fq -- "--verify --role '\${role}'" "$ROOT/affinity_batch.sh"
grep -Fq -- "--concurrent-calls '\${CONCURRENT_CALLS}'" "$ROOT/affinity_batch.sh"
grep -Fq -- "--active-agents '\${ACTIVE_AGENTS}'" "$ROOT/affinity_batch.sh"
grep -Fq 'if [[ $APPLY -eq 1 && $FAIL -eq 0 ]]; then' "$ROOT/affinity_batch.sh"

echo "safety hardening test: PASS"
