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
  ROLE="$role"; ROLE_REQUEST="$role"; ROLE_EVIDENCE="test"
  PROFILE_FILE=""; APPLY=0; CONCURRENT_CALLS=""; ACTIVE_AGENTS=""

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

assert_service() {
  local service=$1 expected=$2
  if [[ "${PLAN_SVC[$service]:-}" != "$expected" ]]; then
    echo "FAIL $ROLE $service: expected '$expected', got '${PLAN_SVC[$service]:-<missing>}'"
    exit 1
  fi
}

assert_absent() {
  local service=$1
  if [[ -n "${PLAN_SVC[$service]:-}" ]]; then
    echo "FAIL $ROLE: $service must remain unmanaged, got '${PLAN_SVC[$service]}'"
    exit 1
  fi
}

plan_fleet_role() {
  local role=$1 cores=$2
  setup_cpus "$cores" 1
  mapfile -t IRQ_ETH < <(seq_irqs 173 40)
  mapfile -t IRQ_DISK < <(seq_irqs 65 40)
  IRQ_TEL=()
  HAS_TELEPHONY=no
  ROLE="$role"; ROLE_REQUEST="$role"; ROLE_EVIDENCE="test"
  PROFILE_FILE=""; APPLY=0; CONCURRENT_CALLS=""; ACTIVE_AGENTS=""
  plan_allocation 2>/dev/null
}

# BLR fleet, verified against lscpu on each host (HT on, single socket)
# APP/DB/REPORT are 16c/32t; CS/ASAP are 8c/16t
run_case "BLR-P|SAPP"    app    16 1 40 40 0
run_case "BLR-P|SDB"     db     16 1 40 40 0
run_case "BLR-P|SREPORT" report 16 1 40 40 0
run_case "BLR-P|SCS"     call    8 1 40 40 0
run_case "BLR-P|SCS+card" call   8 1 40 40 4
run_case "BLR-P|SASAP"   asap    8 1 40 40 0

# Exact accepted BLR allocations. Services include both HT siblings while IRQs
# remain on physical-core primary threads.
FULL16="5,6,7,8,9,10,11,12,13,14,15,21,22,23,24,25,26,27,28,29,30,31"
CRM16="5,6,7,8,21,22,23,24"
DAGENT16="5,6,21,22"
FULL8="3,4,5,6,7,11,12,13,14,15"
DAGENT8="3,4,11,12"

plan_fleet_role app 16
assert_service server "$FULL16"
assert_service crm "$CRM16"
assert_service dagent "$DAGENT16"

plan_fleet_role db 16
assert_service database "$FULL16"
assert_service dagent "$DAGENT16"

plan_fleet_role report 16
assert_service ameyoreports "$FULL16"
assert_service ameyoarchiver "$FULL16"
assert_service ameyo_voicelogs_conversion "$FULL16"
assert_service crm "$CRM16"
assert_service dagent "$DAGENT16"

plan_fleet_role call 8
assert_service asterisk13 "$FULL8"
assert_service dagent "$DAGENT8"
assert_absent asterisk

plan_fleet_role asap 8
assert_service asap "$FULL8"
assert_service acp "$FULL8"
assert_service dagent "$DAGENT8"

# Topology matrix: 4c/no-HT, 8c/16t, 16c/32t, and 32c/64t.
# Main services retain the full pool; subsets scale and clamp deterministically.
setup_cpus 4 0
IRQ_ETH=(); IRQ_DISK=(); IRQ_TEL=(); HAS_TELEPHONY=no
ROLE=app; PROFILE_FILE=""; CONCURRENT_CALLS=""; ACTIVE_AGENTS=""
plan_allocation 2>/dev/null
assert_service server "1,2,3"
assert_service crm "1,2"
assert_service dagent "1,2"

setup_cpus 8 1
IRQ_ETH=(); IRQ_DISK=(); IRQ_TEL=(); HAS_TELEPHONY=no
ROLE=call; PROFILE_FILE=""; CONCURRENT_CALLS=""; ACTIVE_AGENTS=""
plan_allocation 2>/dev/null
assert_service asterisk13 "1,2,3,4,5,9,10,11,12,13"
assert_service dagent "1,2,9,10"

plan_fleet_role app 16
assert_service server "$FULL16"

setup_cpus 32 1
IRQ_ETH=(); IRQ_DISK=(); IRQ_TEL=(); HAS_TELEPHONY=no
ROLE=app; PROFILE_FILE=""; CONCURRENT_CALLS=""; ACTIVE_AGENTS=""
plan_allocation 2>/dev/null
assert_service server "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63"
assert_service crm "1,2,3,4,5,33,34,35,36,37"
assert_service dagent "1,2,3,33,34,35"

# Workload sizing: ASTERISK13 is 100 calls/core (min 2), CRM is 75
# agents/core (min 2, max 5); both clamp to available physical service cores.
setup_cpus 8 1
IRQ_ETH=(); IRQ_DISK=(); IRQ_TEL=(); HAS_TELEPHONY=no
ROLE=call; PROFILE_FILE=""; ACTIVE_AGENTS=""; CONCURRENT_CALLS=50
plan_allocation 2>/dev/null
assert_service asterisk13 "1,2,9,10"
CONCURRENT_CALLS=9999
plan_allocation 2>/dev/null
assert_service asterisk13 "1,2,3,4,5,6,7,9,10,11,12,13,14,15"

ROLE=app; CONCURRENT_CALLS=""; ACTIVE_AGENTS=75
plan_allocation 2>/dev/null
assert_service crm "1,2,9,10"
ACTIVE_AGENTS=1000
plan_allocation 2>/dev/null
assert_service crm "1,2,3,4,5,9,10,11,12,13"

# Non-contiguous primaries and irregular logical sibling IDs are accepted.
PHYS_PRIMARY=(0 2 8 10)
CPU_LIST=(0 1 2 3 8 9 10 11)
HT_SIBLING=([0]=1 [1]=0 [2]=3 [3]=2 [8]=9 [9]=8 [10]=11 [11]=10)
LOGICAL_CPUS=8; PHYSICAL_CPUS=1; IS_HT=1
IRQ_ETH=(); IRQ_DISK=(); IRQ_TEL=(); HAS_TELEPHONY=no
ROLE=app; PROFILE_FILE=""; ACTIVE_AGENTS=""; CONCURRENT_CALLS=""
plan_allocation 2>/dev/null
assert_service server "2,3,8,9,10,11"
assert_service dagent "2,3,8,9"

# Auto role uses active evidence first, hostname only as a fallback, and refuses
# multiple unrelated active-role candidates. Generic CSV contents are not read.
ROLE_REQUEST=auto
AFFINITY_PROCESS_SNAPSHOT="/usr/sbin/asterisk13 -f"
AFFINITY_HOSTNAME="BLR-PDB"
resolve_role
[[ "$ROLE" == "call" && "$AUTO_ROLE_STATUS" == "active-service" ]]

AFFINITY_PROCESS_SNAPSHOT=""
AFFINITY_HOSTNAME="BLR-SREPORT"
resolve_role
[[ "$ROLE" == "report" && "$AUTO_ROLE_STATUS" == "hostname-hint" ]]

AFFINITY_PROCESS_SNAPSHOT=$'/usr/lib/postgresql/postgres\n/opt/ameyo/ameyoarchiver'
AFFINITY_HOSTNAME="unknown-host"
if resolve_role; then
  echo "FAIL ambiguous auto role unexpectedly resolved to $ROLE"
  exit 1
fi
[[ "$AUTO_ROLE_STATUS" == "ambiguous-active-services" ]]
[[ "$AUTO_ROLE_CANDIDATES" == "db,report" ]]
unset AFFINITY_PROCESS_SNAPSHOT AFFINITY_HOSTNAME

# Small/legacy shapes
run_case "4-core single" single 4 0 1 1 1
run_case "2-core minimal" appdb 2 0 1 1 0

echo "plan allocation tests: PASS"
