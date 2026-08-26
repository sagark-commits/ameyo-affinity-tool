#!/usr/bin/env bash
# Offline test of plan_allocation() against known hardware shapes.
# Loads affinity_tool.sh without running main(), stubs topology, prints plans.
set -uo pipefail

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/affinity_tool.sh"

# Load function definitions only: strip the trailing main invocation.
TMP="$(mktemp)"
sed 's/^main "\$@"$//' "$TOOL" > "$TMP"
# shellcheck disable=SC1090
source "$TMP"
rm -f "$TMP"

LOG_FILE="$(mktemp)"
cpu_to_smp_mask() { printf 'mask(%s)\n' "$1"; }

setup_cpus() {
  local n_cores=$1 ht=$2
  PHYS_PRIMARY=(); CPU_LIST=(); HT_SIBLING=(); CPU_HEX=()
  local i
  for ((i=0; i<n_cores; i++)); do
    PHYS_PRIMARY+=("$i")
    CPU_LIST+=("$i")
    CPU_HEX[$i]=$(printf '0x%x' $((1 << i)))
    if [[ $ht -eq 1 ]]; then
      HT_SIBLING[$i]=$((i + n_cores))
      CPU_LIST+=("$((i + n_cores))")
      CPU_HEX[$((i + n_cores))]=$(printf '0x%x' $((1 << (i + n_cores))))
    else
      HT_SIBLING[$i]="$i"
    fi
  done
  LOGICAL_CPUS=${#CPU_LIST[@]}
  PHYSICAL_CPUS=1
  IS_HT=$ht
}

seq_irqs() { local s=$1 n=$2 i; for ((i=0; i<n; i++)); do echo $((s + i)); done; }

run_case() {
  local name=$1 role=$2 cores=$3 ht=$4 n_eth=$5 n_disk=$6 n_tel=$7
  setup_cpus "$cores" "$ht"
  mapfile -t IRQ_ETH < <(seq_irqs 173 "$n_eth")
  mapfile -t IRQ_DISK < <(seq_irqs 65 "$n_disk")
  mapfile -t IRQ_TEL < <(seq_irqs 30 "$n_tel")
  [[ $n_tel -gt 0 ]] && HAS_TELEPHONY=yes || HAS_TELEPHONY=no
  ROLE="$role"; PROFILE_FILE=""; APPLY=0

  plan_allocation 2>/dev/null

  echo "=== $name (role=$role cores=$cores ht=$ht eth=$n_eth disk=$n_disk tel=$n_tel) ==="
  local cls irq cpus count
  for cls in eth disk telephony; do
    cpus=""; count=0
    for irq in "${!PLAN_IRQ[@]}"; do
      [[ "${PLAN_IRQ_CLASS[$irq]:-}" == "$cls" ]] || continue
      cpus+="${PLAN_IRQ[$irq]}"$'\n'; count=$((count + 1))
    done
    [[ $count -eq 0 ]] && continue
    cpus="$(printf '%s' "$cpus" | sort -n -u | paste -sd, -)"
    printf '  IRQ %-10s %3d -> CPU %s\n' "$cls" "$count" "$cpus"
  done
  local svc
  for svc in $(printf '%s\n' "${!PLAN_SVC[@]}" | sort); do
    [[ -n "${PLAN_SVC[$svc]}" ]] && printf '  %-28s %s\n' "$svc" "${PLAN_SVC[$svc]}"
  done
  echo
}

# BLR fleet, verified against lscpu on each host (HT on, single socket)
# APP/DB/REPORT are 16c/32t; CS/ASAP are 8c/16t
run_case "BLR-P|SAPP"    app    16 1 40 40 0
run_case "BLR-P|SDB"     db     16 1 40 40 0
run_case "BLR-P|SREPORT" report 16 1 40 40 0
run_case "BLR-P|SCS"     call    8 1 40 40 0
run_case "BLR-P|SCS+card" call   8 1 40 40 4
run_case "BLR-P|SASAP"   asap    8 1 40 40 0

# Small/legacy shapes
run_case "4-core single" single 4 0 1 1 1
run_case "2-core minimal" appdb 2 0 1 1 0
