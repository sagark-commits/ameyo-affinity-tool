#!/usr/bin/env bash
# =============================================================================
# affinity_tool.sh — Global CPU affinity fixer for Ameyo / telephony hosts
# Works on: CentOS 6/7, RHEL 7/8/9, Rocky Linux 8/9 (and similar)
# Scales to any CPU count; role-aware; dry-run by default
# =============================================================================
set -euo pipefail

VERSION="1.4.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${AFFINITY_LOG_DIR:-/var/tmp/affinity-tool}"
DACX_ROOT="${DACX_ROOT:-/dacx}"
APPLY=0
VERIFY_ONLY=0
ROLE=""
ROLE_REQUEST=""
ROLE_EVIDENCE=""
AUTO_ROLE_STATUS=""
AUTO_ROLE_CANDIDATES=""
PROFILE_FILE=""
HAS_TELEPHONY=""
CONCURRENT_CALLS=""
ACTIVE_AGENTS=""
REBOOT_HINT=0
TS="$(date +%Y%m%d-%H%M%S)"
AFFINITY_CONFIG_PATH=""
AFFINITY_CONFIG_TYPE=""

# Runtime state (filled by detect_*)
OS_FAMILY=""
OS_MAJOR=""
GRUB_STYLE=""          # legacy|grub2
LOGICAL_CPUS=0
PHYSICAL_CPUS=0
CORES_PER_CPU=0
IS_HT=0
declare -a CPU_LIST=()           # logical cpu ids sorted
declare -a PHYS_PRIMARY=()       # one logical id per physical core (prefer lower id)
declare -A HT_SIBLING=()         # cpu -> sibling (or self)
declare -A CPU_HEX=()            # cpu -> 0xN hex for docs
declare -a IRQ_ETH=()
declare -a IRQ_DISK=()
declare -a IRQ_TEL=()
declare -A PLAN_IRQ=()           # irq -> cpu
declare -A PLAN_IRQ_CLASS=()     # irq -> eth|disk|telephony
declare -A PLAN_SVC=()           # service -> cpu list string
declare -A PLAN_REASON=()        # service -> sizing explanation
declare -a SERVICE_POOL=()       # physical-core primaries available to services
DEFAULT_AFFINITY_CPU=0
IRQ_CORES_MAX="${IRQ_CORES_MAX:-4}"   # max cores per multi-queue device class

usage() {
  cat <<EOF
affinity_tool.sh v${VERSION}

Global CPU affinity planner/applier for Ameyo hosts (any CPU count).
Supports CentOS / RHEL / Rocky. Dry-run by default.

USAGE:
  $0 [--role <role|auto>] [--apply] [options]
  $0 --verify
  $0 --detect

ROLES:
  single      Single server (APP+DB+ACP+Asterisk [+telephony])
  appdb       APP + DB + ACP (no Asterisk)
  app         Dedicated APP server (APPSERVER)
  db          Dedicated DB server (Postgres)
  report      Dedicated reports/archiver/voicelogs
  asap        Dedicated ASAP/ACP server
  call        Call server (Asterisk [+telephony])
  custom      Load --profile FILE
  auto        Safely infer a role from active services, then hostname hints

OPTIONS:
  --role ROLE           Explicit role, or auto (default: auto)
  --profile FILE        Custom profile (key=value). Used with --role custom
                        or to override a built-in role
  --apply               Write changes (default is dry-run / plan only)
  --verify              Check current affinity vs expectations
  --detect              Print OS/CPU/IRQ discovery only
  --telephony yes|no    Force telephony present/absent (auto-detect default)
  --concurrent-calls N  Call workload used to size ASTERISK13
  --active-agents N     Agent workload used to size CRM
  --dacx PATH           Ameyo root (default: /dacx)
  --log-dir PATH        Log directory (default: /var/tmp/affinity-tool)
  -h, --help            This help

EXAMPLES:
  # Plan only (safe)
  sudo ./affinity_tool.sh --role single

  # Auto-detect role and use conservative workload defaults
  sudo ./affinity_tool.sh

  # Workload-aware dedicated roles
  sudo ./affinity_tool.sh --role call --concurrent-calls 800
  sudo ./affinity_tool.sh --role app --active-agents 300

  # Apply on a Rocky call server
  sudo ./affinity_tool.sh --role call --apply

  # Dedicated DB / APP / report / ASAP
  sudo ./affinity_tool.sh --role db --apply
  sudo ./affinity_tool.sh --role app --apply

  # Custom layout
  sudo ./affinity_tool.sh --role custom --profile ./profiles/custom.conf --apply

  # Inventory any box
  sudo ./affinity_tool.sh --detect

  # All hosts at once (from jump box):
  ./affinity_batch.sh --inventory inventory/blr-servers.csv
EOF
}

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE="${2:-}"; shift 2 ;;
      --profile) PROFILE_FILE="${2:-}"; shift 2 ;;
      --apply) APPLY=1; shift ;;
      --verify) VERIFY_ONLY=1; shift ;;
      --detect) ROLE="detect"; shift ;;
      --telephony) HAS_TELEPHONY="${2:-}"; shift 2 ;;
      --concurrent-calls) CONCURRENT_CALLS="${2:-}"; shift 2 ;;
      --active-agents) ACTIVE_AGENTS="${2:-}"; shift 2 ;;
      --dacx) DACX_ROOT="${2:-}"; shift 2 ;;
      --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
  if [[ $VERIFY_ONLY -eq 0 && "$ROLE" != "detect" ]]; then
    [[ -n "$ROLE" ]] || ROLE="auto"
    case "$ROLE" in
      single|appdb|app|db|report|asap|call|custom|auto|detect) ;;
      *) die "Invalid role: $ROLE" ;;
    esac
    if [[ "$ROLE" == "custom" && -z "$PROFILE_FILE" ]]; then
      die "--role custom requires --profile FILE"
    fi
  fi
  ROLE_REQUEST="$ROLE"
  if [[ -n "$CONCURRENT_CALLS" && ! "$CONCURRENT_CALLS" =~ ^[0-9]+$ ]]; then
    die "--concurrent-calls must be a non-negative integer"
  fi
  if [[ -n "$ACTIVE_AGENTS" && ! "$ACTIVE_AGENTS" =~ ^[0-9]+$ ]]; then
    die "--active-agents must be a non-negative integer"
  fi
}

init_log() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/affinity-${TS}.log"
  touch "$LOG_FILE"
  log "affinity_tool.sh v${VERSION} starting (role=${ROLE:-verify} apply=$APPLY)"
}

# -----------------------------------------------------------------------------
# OS detection
# -----------------------------------------------------------------------------
detect_os() {
  OS_FAMILY="unknown"
  OS_MAJOR="0"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_FAMILY="${ID:-unknown}"
    local version_id="${VERSION_ID:-0}"
    OS_MAJOR="${version_id%%.*}"
  elif [[ -f /etc/redhat-release ]]; then
    local rel
    rel="$(cat /etc/redhat-release)"
    if echo "$rel" | grep -qi centos; then OS_FAMILY="centos"
    elif echo "$rel" | grep -qi 'red hat\|redhat'; then OS_FAMILY="rhel"
    elif echo "$rel" | grep -qi rocky; then OS_FAMILY="rocky"
    else OS_FAMILY="rhel-like"; fi
    OS_MAJOR="$(echo "$rel" | grep -oE '[0-9]+' | head -1)"
  fi

  if [[ -f /etc/grub.conf || -f /boot/grub/grub.conf ]] && [[ ! -d /boot/grub2 && ! -d /boot/grub2 ]]; then
    GRUB_STYLE="legacy"
  fi
  # Prefer grub2 when present (CentOS7+, RHEL7+, Rocky)
  if [[ -f /etc/default/grub ]] || [[ -d /boot/grub2 ]] || command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_STYLE="grub2"
  elif [[ -f /etc/grub.conf || -f /boot/grub/grub.conf ]]; then
    GRUB_STYLE="legacy"
  else
    GRUB_STYLE="unknown"
  fi
  log "OS: family=$OS_FAMILY major=$OS_MAJOR grub=$GRUB_STYLE"
}

# -----------------------------------------------------------------------------
# CPU topology from /proc/cpuinfo (no cpuspecification.py required)
# -----------------------------------------------------------------------------
detect_cpu() {
  CPU_LIST=()
  PHYS_PRIMARY=()
  HT_SIBLING=()
  CPU_HEX=()

  local -A core_cpus=()   # "pkg:core" -> "cpu,cpu"
  local -A phys_ids=()
  local cpudir base cpu core pkg key online

  # Preferred source: sysfs topology (authoritative, lists only online CPUs)
  if compgen -G "/sys/devices/system/cpu/cpu[0-9]*/topology/core_id" >/dev/null 2>&1; then
    for cpudir in /sys/devices/system/cpu/cpu[0-9]*; do
      base="${cpudir##*/}"
      cpu="${base#cpu}"
      [[ "$cpu" =~ ^[0-9]+$ ]] || continue
      if [[ -r "$cpudir/online" ]]; then
        online="$(cat "$cpudir/online" 2>/dev/null || echo 1)"
        [[ "$online" == "0" ]] && continue
      fi
      [[ -r "$cpudir/topology/core_id" ]] || continue
      core="$(cat "$cpudir/topology/core_id")"
      pkg=0
      [[ -r "$cpudir/topology/physical_package_id" ]] && \
        pkg="$(cat "$cpudir/topology/physical_package_id")"
      key="${pkg}:${core}"
      if [[ -n "${core_cpus[$key]:-}" ]]; then
        core_cpus[$key]="${core_cpus[$key]},${cpu}"
      else
        core_cpus[$key]="$cpu"
      fi
      phys_ids[$pkg]=1
      CPU_LIST+=("$cpu")
    done
  fi

  # Fallback: parse /proc/cpuinfo blocks
  if [[ ${#core_cpus[@]} -eq 0 ]]; then
    [[ -r /proc/cpuinfo ]] || die "Cannot read CPU topology (/sys and /proc/cpuinfo unavailable)"
    local proc="" phys="" corei="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        processor[[:space:]]*|processor:*)
          # flush previous block
          if [[ -n "$proc" ]]; then
            key="${phys:-0}:${corei:-$proc}"
            if [[ -n "${core_cpus[$key]:-}" ]]; then
              core_cpus[$key]="${core_cpus[$key]},${proc}"
            else
              core_cpus[$key]="$proc"
            fi
            phys_ids["${phys:-0}"]=1
            CPU_LIST+=("$proc")
          fi
          proc="$(echo "$line" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')"
          phys=""; corei=""
          ;;
        "physical id"*)
          phys="$(echo "$line" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')"
          ;;
        "core id"*)
          corei="$(echo "$line" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')"
          ;;
      esac
    done < /proc/cpuinfo
    if [[ -n "$proc" ]]; then
      key="${phys:-0}:${corei:-$proc}"
      if [[ -n "${core_cpus[$key]:-}" ]]; then
        core_cpus[$key]="${core_cpus[$key]},${proc}"
      else
        core_cpus[$key]="$proc"
      fi
      phys_ids["${phys:-0}"]=1
      CPU_LIST+=("$proc")
    fi
  fi

  [[ ${#core_cpus[@]} -gt 0 ]] || die "Failed to determine CPU topology"

  # Sort logical CPU ids
  local sorted
  sorted="$(printf '%s\n' "${CPU_LIST[@]}" | sort -n -u)"
  CPU_LIST=()
  while IFS= read -r cpu; do [[ -n "$cpu" ]] && CPU_LIST+=("$cpu"); done <<< "$sorted"
  LOGICAL_CPUS=${#CPU_LIST[@]}

  # One primary (lowest id) per physical core; the rest are HT siblings
  local cpus first x
  IS_HT=0
  for key in "${!core_cpus[@]}"; do
    cpus="$(printf '%s\n' "${core_cpus[$key]//,/$'\n'}" | sort -n -u | paste -sd, -)"
    first="${cpus%%,*}"
    PHYS_PRIMARY+=("$first")
    local -a sibs=()
    IFS=',' read -ra sibs <<< "$cpus"
    if [[ ${#sibs[@]} -gt 1 ]]; then
      IS_HT=1
      for x in "${sibs[@]}"; do HT_SIBLING[$x]="$first"; done
      HT_SIBLING[$first]="${sibs[1]}"
    else
      HT_SIBLING[$first]="$first"
    fi
  done

  PHYSICAL_CPUS=${#phys_ids[@]}
  sorted="$(printf '%s\n' "${PHYS_PRIMARY[@]}" | sort -n -u)"
  PHYS_PRIMARY=()
  while IFS= read -r cpu; do [[ -n "$cpu" ]] && PHYS_PRIMARY+=("$cpu"); done <<< "$sorted"
  CORES_PER_CPU=$(( ${#PHYS_PRIMARY[@]} / (PHYSICAL_CPUS > 0 ? PHYSICAL_CPUS : 1) ))

  local c
  for c in "${CPU_LIST[@]}"; do
    if [[ $c -lt 63 ]]; then
      CPU_HEX[$c]=$(printf '0x%x' $((1 << c)))
    else
      CPU_HEX[$c]="(>63)"
    fi
  done

  DEFAULT_AFFINITY_CPU=0
  log "CPU: logical=$LOGICAL_CPUS physical_pkgs=$PHYSICAL_CPUS physical_cores=${#PHYS_PRIMARY[@]} ht=$IS_HT"
  log "Physical-core primaries: ${PHYS_PRIMARY[*]}"
}

# Bitmask for smp_affinity matching kernel format width
cpu_to_smp_mask() {
  local cpu=$1
  local ref=""
  if [[ -r /proc/irq/default_smp_affinity ]]; then
    ref="$(tr -d ' \n' < /proc/irq/default_smp_affinity)"
  else
    local sample
    sample="$(ls /proc/irq 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true)"
    if [[ -n "$sample" && -r "/proc/irq/$sample/smp_affinity" ]]; then
      ref="$(tr -d ' \n' < "/proc/irq/$sample/smp_affinity")"
    fi
  fi

  # Build full bitmask using python if available (handles large CPU counts)
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local py
    py="$(command -v python3 || command -v python)"
    "$py" - "$cpu" "$ref" <<'PY'
import sys
cpu = int(sys.argv[1])
ref = sys.argv[2].strip() if len(sys.argv) > 2 else ""
mask = 1 << cpu
if ref:
    # ref like 00000000,000000ff — count hex digits excluding commas
    hexdigits = ref.replace(",", "")
    width = len(hexdigits)
    if width < 1:
        width = max(8, (cpu // 4) + 1)
    # pad to width, then insert commas every 8 from the right
    h = format(mask, "x").zfill(width)
    parts = []
    while h:
        parts.append(h[-8:])
        h = h[:-8]
    print(",".join(reversed(parts)))
else:
    # default 256-bit Ameyo-style (8x8 hex)
    h = format(mask, "x").zfill(64)
    parts = [h[i:i+8] for i in range(0, 64, 8)]
    print(",".join(parts))
PY
    return
  fi

  # Pure bash fallback (up to 64 CPUs, Ameyo-style 8 groups)
  local -a groups=(00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000)
  local word=$((cpu / 32))
  local bit=$((cpu % 32))
  local idx=$((7 - word))
  [[ $idx -ge 0 && $idx -le 7 ]] || die "CPU $cpu out of fallback mask range; install python3"
  local val=$((1 << bit))
  groups[$idx]=$(printf '%08x' "$val")
  local out="${groups[0]}"
  local g
  for g in "${groups[@]:1}"; do out+=",$g"; done
  printf '%s\n' "$out"
}

# -----------------------------------------------------------------------------
# IRQ discovery
# -----------------------------------------------------------------------------
detect_irqs() {
  IRQ_ETH=(); IRQ_DISK=(); IRQ_TEL=()
  [[ -r /proc/interrupts ]] || die "/proc/interrupts not readable"

  local line irq name
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*([0-9]+): ]] || continue
    irq="${BASH_REMATCH[1]}"
    name="$(echo "$line" | awk '{print $NF}')"
    case "$name" in
      eth*|ens*|enp*|eno*|em[0-9]*)
        IRQ_ETH+=("$irq")
        ;;
      *megasas*|*hpsa*|*ahci*|*nvme*|*megaraid*|*mpt*)
        IRQ_DISK+=("$irq")
        ;;
      *wanpipe*|*wcte*|*dahdi*|*wctdm*|*tor2*|*sangoma*)
        IRQ_TEL+=("$irq")
        ;;
    esac
  done < /proc/interrupts

  # Dedup
  IRQ_ETH=($(printf '%s\n' "${IRQ_ETH[@]:-}" | awk 'NF' | sort -nu))
  IRQ_DISK=($(printf '%s\n' "${IRQ_DISK[@]:-}" | awk 'NF' | sort -nu))
  IRQ_TEL=($(printf '%s\n' "${IRQ_TEL[@]:-}" | awk 'NF' | sort -nu))

  if [[ -z "$HAS_TELEPHONY" ]]; then
    if [[ ${#IRQ_TEL[@]} -gt 0 ]]; then HAS_TELEPHONY="yes"; else HAS_TELEPHONY="no"; fi
  fi

  log "IRQs eth=[${IRQ_ETH[*]:-}] disk=[${IRQ_DISK[*]:-}] tel=[${IRQ_TEL[*]:-}] telephony=$HAS_TELEPHONY"
}

# Infer only from active runtime evidence. The installed CSV is deliberately
# ignored because generic Ameyo installations commonly contain every service.
detect_role() {
  local snapshot="${AFFINITY_PROCESS_SNAPSHOT:-}"
  local host="${AFFINITY_HOSTNAME:-$(hostname)}"
  local lower
  local has_call=0 has_app=0 has_db=0 has_report=0 has_asap=0
  local -a evidence=() candidates=()

  AUTO_ROLE_CANDIDATES=""
  ROLE_EVIDENCE=""
  if [[ -z "${AFFINITY_PROCESS_SNAPSHOT+x}" ]]; then
    snapshot="$(ps -eo comm=,args= 2>/dev/null || true)"
    if command -v systemctl >/dev/null 2>&1; then
      snapshot+=$'\n'"$(systemctl list-units --type=service --state=active --no-legend --no-pager 2>/dev/null || true)"
    fi
  fi
  lower="$(printf '%s' "$snapshot" | tr '[:upper:]' '[:lower:]')"

  if grep -Eq 'asterisk(13)?([[:space:]/.]|$)' <<< "$lower"; then
    has_call=1; evidence+=("active ASTERISK")
  fi
  if grep -Eq '(^|[[:space:]/.-])appserver([[:space:]/.-]|$)' <<< "$lower"; then
    has_app=1; evidence+=("active APPSERVER")
  fi
  if grep -Eq '(^|[[:space:]/.-])(postgres|postgresql)([[:space:]/.-]|$)' <<< "$lower"; then
    has_db=1; evidence+=("active POSTGRESQL")
  fi
  if grep -Eq 'ameyoreports|ameyoarchiver|ameyo[_-]?voicelogs' <<< "$lower"; then
    has_report=1; evidence+=("active report service")
  fi
  if grep -Eq '(^|[[:space:]/.-])(asap|acp)([[:space:]/.-]|$)' <<< "$lower"; then
    has_asap=1; evidence+=("active ASAP/ACP")
  fi

  # Co-located combinations have a more specific role than their components.
  if [[ $has_call -eq 1 && ( $has_app -eq 1 || $has_db -eq 1 ) ]]; then
    candidates=(single)
  elif [[ $has_app -eq 1 && $has_db -eq 1 && $has_report -eq 0 && $has_asap -eq 0 ]]; then
    candidates=(appdb)
  else
    [[ $has_call -eq 1 ]] && candidates+=(call)
    [[ $has_app -eq 1 ]] && candidates+=(app)
    [[ $has_db -eq 1 ]] && candidates+=(db)
    [[ $has_report -eq 1 ]] && candidates+=(report)
    [[ $has_asap -eq 1 ]] && candidates+=(asap)
  fi

  if [[ ${#candidates[@]} -eq 1 ]]; then
    ROLE="${candidates[0]}"
    ROLE_EVIDENCE="$(IFS=', '; echo "${evidence[*]}")"
    AUTO_ROLE_STATUS="active-service"
    return 0
  fi
  if [[ ${#candidates[@]} -gt 1 ]]; then
    AUTO_ROLE_CANDIDATES="$(IFS=,; echo "${candidates[*]}")"
    ROLE_EVIDENCE="$(IFS=', '; echo "${evidence[*]}")"
    AUTO_ROLE_STATUS="ambiguous-active-services"
    return 1
  fi

  # Hostname hints are intentionally conservative and used only when no active
  # service identifies the host. Split punctuation so "PAPP" and "SCS" remain
  # useful while arbitrary substrings do not become role evidence.
  lower="$(printf '%s' "$host" | tr '[:upper:]_' '[:lower:]-')"
  case "$lower" in
    *-papp|*-sapp|papp|sapp) candidates=(app) ;;
    *-pdb|*-sdb|pdb|sdb) candidates=(db) ;;
    *-preport|*-sreport|preport|sreport) candidates=(report) ;;
    *-pcs|*-scs|pcs|scs|*-call|call-*) candidates=(call) ;;
    *-pasap|*-sasap|pasap|sasap|*-asap|asap-*) candidates=(asap) ;;
  esac
  if [[ ${#candidates[@]} -eq 1 ]]; then
    ROLE="${candidates[0]}"
    ROLE_EVIDENCE="conservative hostname hint: $host"
    AUTO_ROLE_STATUS="hostname-hint"
    return 0
  fi

  AUTO_ROLE_STATUS="no-unambiguous-evidence"
  ROLE_EVIDENCE="no unique active service or conservative hostname hint"
  return 1
}

resolve_role() {
  if [[ "$ROLE_REQUEST" != "auto" ]]; then
    ROLE="$ROLE_REQUEST"
    ROLE_EVIDENCE="explicit --role $ROLE"
    AUTO_ROLE_STATUS="explicit"
    return 0
  fi
  detect_role
}

print_role_detection_failure() {
  echo
  echo "========== ROLE DETECTION =========="
  echo "Requested:   auto"
  echo "Status:      $AUTO_ROLE_STATUS"
  echo "Evidence:    $ROLE_EVIDENCE"
  [[ -n "$AUTO_ROLE_CANDIDATES" ]] && echo "Candidates:  $AUTO_ROLE_CANDIDATES"
  echo "Decision:    no affinity plan can be selected safely"
  echo "Action:      re-run with explicit --role single|appdb|app|db|report|asap|call"
  echo "===================================="
}

# Pick N distinct physical primaries, skipping reserved list
pick_cores() {
  local need=$1
  shift
  local -a reserved=("$@")
  local -a out=()
  local c r skip
  for c in "${PHYS_PRIMARY[@]}"; do
    skip=0
    for r in "${reserved[@]:-}"; do
      [[ "$c" == "$r" ]] && skip=1 && break
    done
    [[ $skip -eq 1 ]] && continue
    out+=("$c")
    [[ ${#out[@]} -ge $need ]] && break
  done
  printf '%s\n' "${out[@]}"
}

# Drop first N elements from pool array (set -u safe)
pool_drop() {
  local n=$1
  if [[ $n -le 0 ]]; then
    return 0
  elif [[ $n -ge ${#pool[@]} ]]; then
    pool=()
  else
    pool=("${pool[@]:$n}")
  fi
}

ceil_percent() {
  local value=$1 percent=$2
  echo $(( (value * percent + 99) / 100 ))
}

clamp_count() {
  local value=$1 minimum=$2 maximum=$3 available=$4
  [[ $value -lt $minimum ]] && value=$minimum
  [[ $value -gt $maximum ]] && value=$maximum
  [[ $value -gt $available ]] && value=$available
  [[ $value -lt 1 && $available -gt 0 ]] && value=1
  echo "$value"
}

first_pool_cores() {
  local count=$1
  local -a selected=("${SERVICE_POOL[@]:0:$count}")
  (IFS=,; echo "${selected[*]}")
}

# -----------------------------------------------------------------------------
# Planning — scales with CPU count
# -----------------------------------------------------------------------------
plan_allocation() {
  PLAN_IRQ=()
  PLAN_IRQ_CLASS=()
  PLAN_SVC=()
  PLAN_REASON=()
  SERVICE_POOL=()

  local n_phys=${#PHYS_PRIMARY[@]}
  [[ $n_phys -ge 2 ]] || die "Need at least 2 physical cores (found $n_phys)"

  # Always CPU 0 for OS / tools / dagent / default_affinity
  local reserved=(0)
  local disk_cpu="" eth_cpu="" tel_cpu=""
  local -a pool=()

  # Load optional profile overrides
  local -A OV=()
  if [[ -n "$PROFILE_FILE" ]]; then
    [[ -f "$PROFILE_FILE" ]] || die "Profile not found: $PROFILE_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      local k="${line%%=*}"; local v="${line#*=}"
      k="$(echo "$k" | tr -d ' ')"; v="$(echo "$v" | tr -d ' ')"
      OV[$k]="$v"
    done < "$PROFILE_FILE"
    log "Loaded profile overrides from $PROFILE_FILE"
  fi

  # --- IRQ CPUs ---
  # Multi-queue devices get their queues spread over several cores. Collapsing
  # 40 NIC queues onto one core makes that core the bottleneck under load.
  local -a disk_cpus=() eth_cpus=() tel_cpus=()

  # How many cores to devote to a device class, given its queue count
  # Roughly one eighth of the cores per class, so interrupts never eat more
  # than ~25% of the box; services keep the rest.
  irq_core_budget() {
    local queues=$1 cap=$2 n
    [[ $queues -le 1 ]] && { echo 1; return; }
    n=$(( n_phys / 8 ))
    [[ $n -lt 1 ]] && n=1
    [[ $n -gt $cap ]] && n=$cap
    [[ $n -gt $queues ]] && n=$queues
    echo "$n"
  }

  if [[ -n "${OV[irq_disk]:-}" ]]; then
    IFS=',' read -ra disk_cpus <<< "${OV[irq_disk]}"
  elif [[ ${#IRQ_DISK[@]} -gt 0 ]]; then
    local n_disk
    n_disk="$(irq_core_budget "${#IRQ_DISK[@]}" "$IRQ_CORES_MAX")"
    while IFS= read -r c; do [[ -n "$c" ]] && disk_cpus+=("$c"); done \
      < <(pick_cores "$n_disk" "${reserved[@]}")
    reserved+=("${disk_cpus[@]}")
  fi

  if [[ "$HAS_TELEPHONY" == "yes" ]]; then
    if [[ -n "${OV[irq_telephony]:-}" ]]; then
      IFS=',' read -ra tel_cpus <<< "${OV[irq_telephony]}"
    elif [[ ${#IRQ_TEL[@]} -gt 0 ]]; then
      local n_tel
      n_tel="$(irq_core_budget "${#IRQ_TEL[@]}" 2)"
      while IFS= read -r c; do [[ -n "$c" ]] && tel_cpus+=("$c"); done \
        < <(pick_cores "$n_tel" "${reserved[@]}")
      reserved+=("${tel_cpus[@]}")
    fi
    # Doc convention: with a telephony card, ethernet shares CPU 0
    if [[ -n "${OV[irq_ethernet]:-}" ]]; then
      IFS=',' read -ra eth_cpus <<< "${OV[irq_ethernet]}"
    else
      eth_cpus=(0)
    fi
  else
    if [[ -n "${OV[irq_ethernet]:-}" ]]; then
      IFS=',' read -ra eth_cpus <<< "${OV[irq_ethernet]}"
    elif [[ ${#IRQ_ETH[@]} -gt 0 ]]; then
      local n_eth
      n_eth="$(irq_core_budget "${#IRQ_ETH[@]}" "$IRQ_CORES_MAX")"
      while IFS= read -r c; do [[ -n "$c" ]] && eth_cpus+=("$c"); done \
        < <(pick_cores "$n_eth" "${reserved[@]}")
      [[ ${#eth_cpus[@]} -eq 0 ]] && eth_cpus=(0)
      reserved+=("${eth_cpus[@]}")
    fi
  fi

  # Round-robin each device's queues across its assigned cores
  local irq idx=0
  if [[ ${#disk_cpus[@]} -gt 0 ]]; then
    idx=0
    for irq in "${IRQ_DISK[@]:-}"; do
      [[ -n "$irq" ]] || continue
      PLAN_IRQ[$irq]="${disk_cpus[$(( idx % ${#disk_cpus[@]} ))]}"
      PLAN_IRQ_CLASS[$irq]="disk"
      idx=$((idx + 1))
    done
  fi
  if [[ ${#eth_cpus[@]} -gt 0 ]]; then
    idx=0
    for irq in "${IRQ_ETH[@]:-}"; do
      [[ -n "$irq" ]] || continue
      PLAN_IRQ[$irq]="${eth_cpus[$(( idx % ${#eth_cpus[@]} ))]}"
      PLAN_IRQ_CLASS[$irq]="eth"
      idx=$((idx + 1))
    done
  fi
  if [[ ${#tel_cpus[@]} -gt 0 ]]; then
    idx=0
    for irq in "${IRQ_TEL[@]:-}"; do
      [[ -n "$irq" ]] || continue
      PLAN_IRQ[$irq]="${tel_cpus[$(( idx % ${#tel_cpus[@]} ))]}"
      PLAN_IRQ_CLASS[$irq]="telephony"
      idx=$((idx + 1))
    done
  fi

  # Kept for the tiny-box override below
  disk_cpu="${disk_cpus[0]:-}"
  eth_cpu="${eth_cpus[0]:-}"
  tel_cpu="${tel_cpus[0]:-}"

  # Remaining physical cores for services
  pool=()
  local c skip r
  for c in "${PHYS_PRIMARY[@]}"; do
    skip=0
    for r in "${reserved[@]}"; do [[ "$c" == "$r" ]] && skip=1 && break; done
    [[ $skip -eq 0 ]] && pool+=("$c")
  done

  # If pool empty (tiny box), reuse non-0 reserved carefully
  if [[ ${#pool[@]} -eq 0 ]]; then
    for c in "${PHYS_PRIMARY[@]}"; do
      [[ "$c" == "0" ]] && continue
      pool+=("$c")
    done
  fi

  local np=${#pool[@]}

  # Keep the complete service pool: role-specific subsets intentionally overlap
  # it. These are allowed CPU sets, not exclusive CPU partitions.
  SERVICE_POOL=("${pool[@]}")
  local service_pool_str dagent_str crm_str asterisk13_str
  local n_dagent n_crm n_ast13 topology_crm requested
  service_pool_str="$(IFS=,; echo "${SERVICE_POOL[*]}")"

  # DAGENT is low demand: 15% of service cores, clamped to 2..3. This yields
  # 2-3 physical cores on normal medium/large hosts.
  requested="$(ceil_percent "$np" 15)"
  n_dagent="$(clamp_count "$requested" 2 3 "$np")"
  dagent_str="$(first_pool_cores "$n_dagent")"

  # CRM defaults to a topology heuristic (35%, 2..5). An explicit agent count
  # replaces that estimate at one physical core per 75 active agents.
  topology_crm="$(ceil_percent "$np" 35)"
  if [[ -n "$ACTIVE_AGENTS" ]]; then
    requested=$(( (ACTIVE_AGENTS + 74) / 75 ))
    n_crm="$(clamp_count "$requested" 2 5 "$np")"
    PLAN_REASON[crm]="${ACTIVE_AGENTS} active agents / 75 per core, clamped to 2..5 and pool"
  else
    n_crm="$(clamp_count "$topology_crm" 2 5 "$np")"
    PLAN_REASON[crm]="default ceil(35% of ${np}-core pool), clamped to 2..5"
  fi
  crm_str="$(first_pool_cores "$n_crm")"

  # ASTERISK13 uses one physical core per 100 concurrent calls, with a two-core
  # floor. Five hundred calls is the conservative omitted-input default.
  local effective_calls="${CONCURRENT_CALLS:-500}"
  requested=$(( (effective_calls + 99) / 100 ))
  n_ast13="$(clamp_count "$requested" 2 "$np" "$np")"
  asterisk13_str="$(first_pool_cores "$n_ast13")"
  if [[ -n "$CONCURRENT_CALLS" ]]; then
    PLAN_REASON[asterisk13]="${CONCURRENT_CALLS} concurrent calls / 100 per core, min 2, clamped to pool"
  else
    PLAN_REASON[asterisk13]="safe default 500 concurrent calls / 100 per core, min 2, clamped to pool"
  fi
  PLAN_REASON[dagent]="ceil(15% of ${np}-core pool), clamped to 2..3 and pool"

  case "$ROLE" in
    single)
      PLAN_SVC[tools]=0
      PLAN_SVC[dagent]=0
      # Postgres ~40% of remaining pool; asterisk 1–2 cores; rest to app/acp
      local n_db n_srv n_ast need_ast
      n_db=$(( (np * 40) / 100 )); [[ $n_db -lt 1 ]] && n_db=1
      [[ $n_db -ge $np && $np -gt 1 ]] && n_db=$((np - 1))
      local db_cores=()
      local i
      for ((i=0; i<n_db && i<${#pool[@]}; i++)); do db_cores+=("${pool[$i]}"); done
      pool_drop "$n_db"

      n_ast=1; [[ $np -ge 4 ]] && n_ast=2
      local ast_cores=()
      if [[ -n "$tel_cpu" ]]; then ast_cores+=("$tel_cpu"); fi
      need_ast=$(( n_ast - ${#ast_cores[@]} ))
      [[ $need_ast -lt 0 ]] && need_ast=0
      for ((i=0; i<need_ast && i<${#pool[@]}; i++)); do ast_cores+=("${pool[$i]}"); done
      pool_drop "$need_ast"

      n_srv=${#pool[@]}
      [[ $n_srv -lt 1 ]] && n_srv=0
      local srv_cores=()
      for ((i=0; i<n_srv && i<${#pool[@]}; i++)); do srv_cores+=("${pool[$i]}"); done
      pool=()
      # If server empty, reuse database core (tiny boxes)
      if [[ ${#srv_cores[@]} -eq 0 && ${#db_cores[@]} -gt 0 ]]; then
        srv_cores=("${db_cores[$((${#db_cores[@]} - 1))]}")
      fi

      PLAN_SVC[database]="$(IFS=,; echo "${db_cores[*]}")"
      PLAN_SVC[server]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[acp]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[asterisk]="$(IFS=,; echo "${ast_cores[*]}")"
      PLAN_SVC[ameyoreports]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[ameyoarchiver]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[ameyo_voicelogs_conversion]="$(IFS=,; echo "${srv_cores[*]}")"
      ;;
    appdb)
      PLAN_SVC[tools]=0
      PLAN_SVC[dagent]=0
      local n_db n_srv i
      n_db=$(( (np * 45) / 100 )); [[ $n_db -lt 1 ]] && n_db=1
      [[ $n_db -ge $np && $np -gt 1 ]] && n_db=$((np - 1))
      local db_cores=()
      for ((i=0; i<n_db && i<${#pool[@]}; i++)); do db_cores+=("${pool[$i]}"); done
      pool_drop "$n_db"
      n_srv=${#pool[@]}; [[ $n_srv -lt 1 ]] && n_srv=0
      local srv_cores=()
      for ((i=0; i<n_srv && i<${#pool[@]}; i++)); do srv_cores+=("${pool[$i]}"); done
      if [[ ${#srv_cores[@]} -eq 0 && ${#db_cores[@]} -gt 0 ]]; then
        srv_cores=("${db_cores[$((${#db_cores[@]} - 1))]}")
      fi
      PLAN_SVC[database]="$(IFS=,; echo "${db_cores[*]}")"
      PLAN_SVC[server]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[acp]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[ameyoreports]="$(IFS=,; echo "${srv_cores[*]}")"
      PLAN_SVC[ameyoarchiver]="$(IFS=,; echo "${srv_cores[*]}")"
      ;;
    call)
      # BLR CS is SIP-only. ASTERISK is deliberately left untouched.
      PLAN_SVC[asterisk13]="$asterisk13_str"
      PLAN_SVC[dagent]="$dagent_str"
      ;;
    app)
      PLAN_SVC[server]="$service_pool_str"
      PLAN_REASON[server]="main APP workload receives the full service pool"
      PLAN_SVC[crm]="$crm_str"
      PLAN_SVC[dagent]="$dagent_str"
      ;;
    db)
      PLAN_SVC[database]="$service_pool_str"
      PLAN_REASON[database]="main database workload receives the full service pool"
      PLAN_SVC[dagent]="$dagent_str"
      ;;
    report)
      PLAN_SVC[ameyoreports]="$service_pool_str"
      PLAN_SVC[ameyoarchiver]="$service_pool_str"
      PLAN_SVC[ameyo_voicelogs_conversion]="$service_pool_str"
      PLAN_REASON[ameyoreports]="main report services receive the full service pool"
      PLAN_REASON[ameyoarchiver]="main report services receive the full service pool"
      PLAN_REASON[ameyo_voicelogs_conversion]="main report services receive the full service pool"
      PLAN_SVC[crm]="$crm_str"
      PLAN_SVC[dagent]="$dagent_str"
      ;;
    asap)
      PLAN_SVC[asap]="$service_pool_str"
      PLAN_SVC[acp]="$service_pool_str"
      PLAN_REASON[asap]="main ASAP workload receives the full service pool"
      PLAN_REASON[acp]="main ACP workload receives the full service pool"
      PLAN_SVC[dagent]="$dagent_str"
      ;;
    custom)
      PLAN_SVC[tools]=0
      PLAN_SVC[dagent]=0
      local k
      for k in "${!OV[@]}"; do
        case "$k" in
          irq_*) ;;
          *)
            PLAN_SVC[$k]="${OV[$k]}"
            PLAN_REASON[$k]="explicit profile allocation"
            ;;
        esac
      done
      [[ -n "${PLAN_SVC[tools]:-}" ]] || PLAN_SVC[tools]=0
      [[ -n "${PLAN_SVC[dagent]:-}" ]] || PLAN_SVC[dagent]=0
      ;;
  esac

  # Profile service overrides always win
  if [[ "$ROLE" != "custom" && ${#OV[@]} -gt 0 ]]; then
    local k
    for k in "${!OV[@]}"; do
      case "$k" in
        irq_*) ;;
        *)
          PLAN_SVC[$k]="${OV[$k]}"
          PLAN_REASON[$k]="explicit profile override"
          ;;
      esac
    done
  fi

  # Services are planned on physical cores. On an HT box the sibling threads of
  # those cores would otherwise sit idle, so widen each service to both threads.
  # IRQs deliberately stay on the primary thread only.
  if [[ $IS_HT -eq 1 ]]; then
    local svc cpu sib expanded
    for svc in "${!PLAN_SVC[@]}"; do
      [[ -n "${PLAN_SVC[$svc]}" ]] || continue
      [[ "${PLAN_SVC[$svc]}" == "0" ]] && continue
      expanded=""
      for cpu in ${PLAN_SVC[$svc]//,/ }; do
        expanded+="${cpu}"$'\n'
        sib="${HT_SIBLING[$cpu]:-$cpu}"
        [[ "$sib" != "$cpu" ]] && expanded+="${sib}"$'\n'
      done
      PLAN_SVC[$svc]="$(printf '%s' "$expanded" | sort -n -u | paste -sd, -)"
    done
  fi

  # Tiny-box sanity from doc Case 1 when 4 physical cores & single
  if [[ "$ROLE" == "single" && $n_phys -eq 4 && -z "$PROFILE_FILE" ]]; then
    PLAN_SVC[tools]=0
    PLAN_SVC[dagent]=0
    PLAN_SVC[database]=1
    PLAN_SVC[server]=2
    PLAN_SVC[acp]=2
    PLAN_SVC[asterisk]=3
    PLAN_SVC[ameyoreports]=2
    PLAN_SVC[ameyoarchiver]=2
    PLAN_SVC[ameyo_voicelogs_conversion]=2
    # IRQ: eth0, disk1, tel3 — rebuild if auto differed
    if [[ "$HAS_TELEPHONY" == "yes" ]]; then
      for irq in "${IRQ_TEL[@]:-}"; do PLAN_IRQ[$irq]=3; done
      for irq in "${IRQ_DISK[@]:-}"; do PLAN_IRQ[$irq]=1; done
      for irq in "${IRQ_ETH[@]:-}"; do PLAN_IRQ[$irq]=0; done
    fi
  fi
}

print_plan() {
  echo
  echo "========== AFFINITY PLAN =========="
  echo "Host:        $(hostname)"
  echo "OS:          $OS_FAMILY $OS_MAJOR ($GRUB_STYLE)"
  echo "Topology:    logical=$LOGICAL_CPUS physical_cores=${#PHYS_PRIMARY[@]} packages=$PHYSICAL_CPUS HT=$IS_HT"
  echo "Primaries:   ${PHYS_PRIMARY[*]}"
  echo "Role:        $ROLE  telephony=$HAS_TELEPHONY"
  echo "Evidence:    $ROLE_EVIDENCE"
  echo "Service pool (physical): $(IFS=,; echo "${SERVICE_POOL[*]}")"
  echo "Inputs:      concurrent_calls=${CONCURRENT_CALLS:-500 (safe default)} active_agents=${ACTIVE_AGENTS:-topology default}"
  echo "Mode:        $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
  if discover_affinity_config; then
    echo "Config:      $AFFINITY_CONFIG_PATH ($AFFINITY_CONFIG_TYPE)"
  else
    echo "Config:      MISSING (apply will fail preflight)"
  fi
  echo
  echo "-- Default affinity (grub) --"
  echo "  CPU $DEFAULT_AFFINITY_CPU  mask=${CPU_HEX[$DEFAULT_AFFINITY_CPU]}"
  echo
  echo "-- IRQ smp_affinity --"
  if [[ ${#PLAN_IRQ[@]} -eq 0 ]]; then
    echo "  (none discovered)"
  else
    local cls irq cpus count
    for cls in eth disk telephony; do
      cpus=""; count=0
      for irq in "${!PLAN_IRQ[@]}"; do
        [[ "${PLAN_IRQ_CLASS[$irq]:-}" == "$cls" ]] || continue
        cpus+="${PLAN_IRQ[$irq]}"$'\n'
        count=$((count + 1))
      done
      [[ $count -eq 0 ]] && continue
      cpus="$(printf '%s' "$cpus" | sort -n -u | paste -sd, -)"
      printf '  %-10s %3d queue(s) -> CPU %s\n' "$cls" "$count" "$cpus"
    done
    if [[ "${AFFINITY_VERBOSE:-0}" == "1" ]]; then
      for irq in $(printf '%s\n' "${!PLAN_IRQ[@]}" | sort -n); do
        echo "    IRQ $irq -> CPU ${PLAN_IRQ[$irq]}  mask=$(cpu_to_smp_mask "${PLAN_IRQ[$irq]}")"
      done
    else
      echo "    (set AFFINITY_VERBOSE=1 for per-IRQ detail)"
    fi
  fi
  echo
  echo "-- Ameyo services --"
  local svc
  for svc in $(printf '%s\n' "${!PLAN_SVC[@]}" | sort); do
    echo "  $svc = ${PLAN_SVC[$svc]}"
    [[ -n "${PLAN_REASON[$svc]:-}" ]] && echo "    why: ${PLAN_REASON[$svc]}"
  done
  echo "==================================="
  echo
}

# -----------------------------------------------------------------------------
# Apply: irqbalance, grub, IRQ script, Ameyo configs
# -----------------------------------------------------------------------------
disable_irqbalance() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
  fi
  if [[ -x /etc/init.d/irqbalance ]]; then
    /etc/init.d/irqbalance stop 2>/dev/null || true
  fi
  if command -v chkconfig >/dev/null 2>&1; then
    chkconfig irqbalance off 2>/dev/null || true
  fi
  log "irqbalance stopped/disabled (if present)"
}

apply_grub() {
  local mask_param="default_affinity=$(printf '0x%08x' $((1 << DEFAULT_AFFINITY_CPU)))"
  # Also accept isolcpus-style? Stick to Ameyo default_affinity

  if [[ "$GRUB_STYLE" == "legacy" ]]; then
    local grubf=""
    for f in /etc/grub.conf /boot/grub/grub.conf; do [[ -f "$f" ]] && grubf="$f" && break; done
    [[ -n "$grubf" ]] || die "legacy grub.conf not found"
    cp -a "$grubf" "${grubf}.bak.${TS}"
    if grep -q 'default_affinity=' "$grubf"; then
      sed -i -E "s/default_affinity=0x[0-9a-fA-F]+/${mask_param}/g" "$grubf"
    else
      # Append to kernel lines
      sed -i -E "/^\s*kernel / s/$/ ${mask_param}/" "$grubf"
    fi
    log "Updated legacy grub: $grubf ($mask_param)"
    REBOOT_HINT=1
  elif [[ "$GRUB_STYLE" == "grub2" ]]; then
    if [[ -f /etc/default/grub ]]; then
      cp -a /etc/default/grub "/etc/default/grub.bak.${TS}"
      if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        if grep -q 'default_affinity=' /etc/default/grub; then
          sed -i -E "s/default_affinity=0x[0-9a-fA-F]+/${mask_param}/g" /etc/default/grub
        else
          sed -i -E "s/^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"/\1 ${mask_param}\"/" /etc/default/grub
        fi
      else
        echo "GRUB_CMDLINE_LINUX=\"${mask_param}\"" >> /etc/default/grub
      fi
      if command -v grub2-mkconfig >/dev/null 2>&1; then
        local outcfg="/boot/grub2/grub.cfg"
        [[ -d /boot/efi/EFI ]] && outcfg="$(find /boot/efi/EFI -name grub.cfg 2>/dev/null | head -1 || echo /boot/grub2/grub.cfg)"
        grub2-mkconfig -o "${outcfg:-/boot/grub2/grub.cfg}"
        log "grub2-mkconfig done -> ${outcfg:-/boot/grub2/grub.cfg}"
      elif [[ -f /boot/grub2/grub.cfg ]]; then
        # AmeyOS7 style: patch grub.cfg directly as doc says
        cp -a /boot/grub2/grub.cfg "/boot/grub2/grub.cfg.bak.${TS}"
        if grep -q 'default_affinity=' /boot/grub2/grub.cfg; then
          sed -i -E "s/default_affinity=0x[0-9a-fA-F]+/${mask_param}/g" /boot/grub2/grub.cfg
        else
          sed -i -E "/vmlinuz/ s/$/ ${mask_param}/" /boot/grub2/grub.cfg
        fi
        log "Patched /boot/grub2/grub.cfg directly ($mask_param)"
      fi
      REBOOT_HINT=1
    elif [[ -f /boot/grub2/grub.cfg ]]; then
      cp -a /boot/grub2/grub.cfg "/boot/grub2/grub.cfg.bak.${TS}"
      if grep -q 'default_affinity=' /boot/grub2/grub.cfg; then
        sed -i -E "s/default_affinity=0x[0-9a-fA-F]+/${mask_param}/g" /boot/grub2/grub.cfg
      else
        sed -i -E "/vmlinuz/ s/$/ ${mask_param}/" /boot/grub2/grub.cfg
      fi
      log "Patched /boot/grub2/grub.cfg ($mask_param)"
      REBOOT_HINT=1
    else
      die "Cannot find grub2 config to update"
    fi
  else
    die "Unknown grub style; set default_affinity manually: $mask_param"
  fi
}

write_irq_script() {
  local out="${AFFINITY_SETTER_OUT:-${DACX_ROOT}/affinitySetter.sh}"
  mkdir -p "$DACX_ROOT"
  local tmp
  tmp="$(mktemp)"
  {
    echo "#!/bin/bash"
    echo "# Generated by affinity_tool.sh v${VERSION} on ${TS}"
    echo "# Role=$ROLE host=$(hostname)"
    echo "set -uo pipefail"
    echo 'INTERRUPTS="${AFFINITY_PROC_INTERRUPTS:-/proc/interrupts}"'
    echo 'IRQ_ROOT="${AFFINITY_PROC_IRQ_ROOT:-/proc/irq}"'
    echo 'failures=()'
    echo 'discover_class() {'
    echo '  local cls=$1 line irq name'
    echo '  while IFS= read -r line; do'
    echo '    [[ "$line" =~ ^[[:space:]]*([0-9]+): ]] || continue'
    echo '    irq="${BASH_REMATCH[1]}"; name="${line##* }"'
    echo '    case "$cls:$name" in'
    echo '      eth:eth*|eth:ens*|eth:enp*|eth:eno*|eth:em[0-9]*) echo "$irq|$name" ;;'
    echo '      disk:*megasas*|disk:*hpsa*|disk:*ahci*|disk:*nvme*|disk:*megaraid*|disk:*mpt*) echo "$irq|$name" ;;'
    echo '      telephony:*wanpipe*|telephony:*wcte*|telephony:*dahdi*|telephony:*wctdm*|telephony:*tor2*|telephony:*sangoma*) echo "$irq|$name" ;;'
    echo '    esac'
    echo '  done < "$INTERRUPTS"'
    echo '}'
    echo 'apply_class() {'
    echo '  local cls=$1 pool_csv=$2 idx=0 item irq name cpu mask path reason'
    echo '  local -a pool=(); IFS=, read -ra pool <<< "$pool_csv"'
    echo '  [[ ${#pool[@]} -gt 0 && -n "${pool[0]}" ]] || return 0'
    echo '  while IFS= read -r item; do'
    echo '    [[ -n "$item" ]] || continue; irq="${item%%|*}"; name="${item#*|}"'
    echo '    cpu="${pool[$((idx % ${#pool[@]}))]}"; idx=$((idx + 1))'
    echo '    path="$IRQ_ROOT/$irq/smp_affinity"'
    echo '    if ! mask="$(mask_for_cpu "$cpu" 2>&1)"; then reason="$mask"'
    echo '    elif [[ ! -e "$path" ]]; then reason="affinity path missing"'
    echo '    elif ! reason="$(printf "%s\n" "$mask" > "$path" 2>&1)"; then reason="${reason:-write rejected}"'
    echo '    else echo "IRQ $irq ($name/$cls) -> CPU $cpu"; continue; fi'
    echo '    failures+=("IRQ $irq ($name/$cls): $reason")'
    echo '  done < <(discover_class "$cls")'
    echo '  [[ $idx -gt 0 ]] || failures+=("IRQ discovery ($cls): no matching IRQs found after boot ordering")'
    echo '}'
    echo 'mask_for_cpu() {'
    echo '  local cpu=$1 ref="" py'
    echo '  [[ -r "$IRQ_ROOT/default_smp_affinity" ]] && ref="$(tr -d " \n" < "$IRQ_ROOT/default_smp_affinity")"'
    echo '  py="$(command -v python3 || command -v python || true)"'
    echo '  if [[ -n "$py" ]]; then "$py" - "$cpu" "$ref" <<'"'"'PY'"'"''
    echo 'import sys'
    echo 'cpu=int(sys.argv[1]); ref=sys.argv[2].replace(",",""); width=max(len(ref),8)'
    echo 'h=format(1 << cpu,"x").zfill(width); p=[]'
    echo 'while h: p.insert(0,h[-8:]); h=h[:-8]'
    echo 'print(",".join(p))'
    echo 'PY'
    echo '  elif [[ $cpu -lt 63 ]]; then printf "%x\n" "$((1 << cpu))"'
    echo '  else echo "cannot build CPU $cpu mask without python" >&2; return 1; fi'
    echo '}'
    local cls irq cpus
    for cls in eth disk telephony; do
      cpus=""
      for irq in "${!PLAN_IRQ[@]}"; do
        [[ "${PLAN_IRQ_CLASS[$irq]:-}" == "$cls" ]] || continue
        cpus+="${PLAN_IRQ[$irq]}"$'\n'
      done
      cpus="$(printf '%s' "$cpus" | awk 'NF' | sort -n -u | paste -sd, -)"
      [[ -n "$cpus" ]] && echo "apply_class $cls '$cpus'"
    done
    echo 'if [[ ${#failures[@]} -gt 0 ]]; then'
    echo '  printf "ERROR: %d IRQ affinity write(s) failed:\n" "${#failures[@]}" >&2'
    echo '  printf "  - %s\n" "${failures[@]}" >&2'
    echo '  exit 1'
    echo 'fi'
  } > "$tmp"
  if [[ $APPLY -eq 1 ]]; then
    cp -a "$tmp" "$out"
    chmod 755 "$out"
    local irq_rc=0
    bash "$out" || irq_rc=$?
    # Prefer systemd: device IRQs are rediscovered after filesystems and network.
    if [[ "${AFFINITY_SKIP_PERSISTENCE:-0}" == "1" ]]; then
      log "Test mode: skipped boot persistence"
    elif command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
      cat > /etc/systemd/system/ameyo-affinity-irq.service <<EOF
[Unit]
Description=Ameyo dynamic IRQ CPU affinity
Wants=network-online.target
After=local-fs.target network-online.target

[Service]
Type=oneshot
ExecStart=${out}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable ameyo-affinity-irq.service
      log "Installed systemd unit ameyo-affinity-irq.service"
    elif [[ -f /etc/rc.d/rc.local || -f /etc/rc.local ]]; then
      local rcl=/etc/rc.local
      [[ -f /etc/rc.d/rc.local ]] && rcl=/etc/rc.d/rc.local
      touch "$rcl"
      chmod +x "$rcl"
      if ! grep -qF "$out" "$rcl" 2>/dev/null; then
        # Insert before exit 0 if present
        if grep -q '^exit 0' "$rcl"; then
          sed -i "s|^exit 0|bash ${out}\nexit 0|" "$rcl"
        else
          echo "bash ${out}" >> "$rcl"
        fi
      fi
      log "Ensured $out in $rcl"
    else
      die "No supported boot persistence mechanism (systemd or rc.local)"
    fi
    [[ $irq_rc -eq 0 ]] || die "IRQ affinity apply failed; see aggregate IRQ/name/reason report above"
  else
    log "DRY-RUN: would write $out"
    cat "$tmp" >&2
  fi
  rm -f "$tmp"
}

discover_affinity_config() {
  local csv="${DACX_ROOT}/var/ameyo/dacxdata/etc/djinn/serviceCPUAffinityConf.csv"
  local cfg="${DACX_ROOT}/var/ameyo/dacxdata/var/affinity.cfg"
  AFFINITY_CONFIG_PATH=""
  AFFINITY_CONFIG_TYPE=""

  if [[ -f "$csv" ]]; then
    AFFINITY_CONFIG_PATH="$csv"
    AFFINITY_CONFIG_TYPE="csv"
  elif [[ -f "$cfg" ]]; then
    AFFINITY_CONFIG_PATH="$cfg"
    AFFINITY_CONFIG_TYPE="cfg"
  else
    return 1
  fi
}

preflight_apply() {
  discover_affinity_config || die "Preflight failed: no existing affinity config (checked serviceCPUAffinityConf.csv and affinity.cfg)"
  [[ -w "$AFFINITY_CONFIG_PATH" ]] || die "Preflight failed: affinity config is not writable: $AFFINITY_CONFIG_PATH"
  [[ -w "$(dirname "$AFFINITY_CONFIG_PATH")" ]] || die "Preflight failed: affinity config directory is not writable: $(dirname "$AFFINITY_CONFIG_PATH")"
  log "Preflight OK: existing writable $AFFINITY_CONFIG_TYPE config at $AFFINITY_CONFIG_PATH"
}

restart_djinn() {
  log "Restarting DJINN after managed-service affinity merge (DJINN itself is not pinned)"
  if [[ -n "${DJINN_RESTART_CMD:-}" ]]; then
    bash -c "$DJINN_RESTART_CMD" || die "DJINN restart failed"
  elif [[ -x /etc/init.d/djinn ]]; then
    /etc/init.d/djinn restart || die "DJINN restart failed"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart djinn.service || die "DJINN restart failed"
  else
    die "DJINN restart failed: no init script or systemctl available"
  fi
  log "DJINN restart command completed successfully"
}

write_ameyo_service_affinity() {
  if [[ -z "$AFFINITY_CONFIG_PATH" ]]; then
    discover_affinity_config || {
      log "WARN: no existing service affinity config found; no service changes planned"
      return 0
    }
  fi
  local use="$AFFINITY_CONFIG_TYPE"
  local csv="$AFFINITY_CONFIG_PATH"
  local cfg="$AFFINITY_CONFIG_PATH"

  # Map internal names -> CSV names from doc
  declare -A CSV_NAME=(
    [acp]=ACP
    [asap]=ASAP
    [dagent]=DAGENT
    [crm]=CRM
    [asterisk]=ASTERISK
    [asterisk13]=ASTERISK13
    [server]=APPSERVER
    [database]=POSTGRESQL
    [ameyoreports]=AMEYOREPORTS
    [ameyoarchiver]=AMEYOARCHIVER
    [ameyo_voicelogs_conversion]=AMEYO_VOICELOGS_CONVERSION
  )

  if [[ "$use" == "csv" ]]; then
    local tmp updates; tmp="$(mktemp "${csv}.tmp.XXXXXX")"; updates="$(mktemp)"
    local svc name cpus
    for svc in "${!PLAN_SVC[@]}"; do
      # Modern CSV has no TOOLS row; tools is an old affinity.cfg concept.
      [[ "$svc" == "tools" ]] && continue
      name="${CSV_NAME[$svc]:-$(echo "$svc" | tr '[:lower:]' '[:upper:]')}"
      [[ -n "${PLAN_SVC[$svc]}" ]] || continue
      # Existing Ameyo format is SERVICE,CPU;CPU (semicolon-separated CPUs).
      cpus="${PLAN_SVC[$svc]//,/;}"
      echo "${name},${cpus}" >> "$updates"
    done

    # Replace only planned service rows and preserve every unrelated row,
    # comment, blank line, and ordering. Append planned rows not already present.
    awk -F, '
        NR == FNR {
          key=$1
          replacement[key]=$0
          order[++count]=key
          next
        }
        {
          if ($1 in replacement) {
            print replacement[$1]
            seen[$1]=1
          } else {
            print
          }
        }
        END {
          for (i=1; i<=count; i++) {
            key=order[i]
            if (!(key in seen)) print replacement[key]
          }
        }
      ' "$updates" "$csv" > "$tmp"

    if [[ $APPLY -eq 1 ]]; then
      cp -a "$csv" "${csv}.bak.${TS}"
      chmod --reference="$csv" "$tmp" 2>/dev/null || true
      chown --reference="$csv" "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$csv"
      log "Merged planned service rows into $csv (backup: ${csv}.bak.${TS})"
    else
      log "DRY-RUN merged CSV content:"
      cat "$tmp" >&2
    fi
    rm -f "$tmp" "$updates"
  else
    local tmp updates; tmp="$(mktemp "${cfg}.tmp.XXXXXX")"; updates="$(mktemp)"
    local svc
    for svc in tools acp asap dagent asterisk asterisk13 server database crm ameyoreports ameyoarchiver ameyo_voicelogs_conversion; do
      if [[ -n "${PLAN_SVC[$svc]:-}" ]]; then
        printf '%s\t-%s : %s\n' "$svc" "$svc" "${PLAN_SVC[$svc]}" >> "$updates"
      fi
    done

    # Merge old affinity.cfg rows too; never erase unrelated configuration.
    awk -F '\t' '
        NR == FNR {
          replacement[$1]=$2
          order[++count]=$1
          next
        }
        {
          line=$0
          key=line
          sub(/^[[:space:]]*-[[:space:]]*/, "", key)
          sub(/[[:space:]]*:.*/, "", key)
          if (key in replacement) {
            print replacement[key]
            seen[key]=1
          } else {
            print line
          }
        }
        END {
          for (i=1; i<=count; i++) {
            key=order[i]
            if (!(key in seen)) print replacement[key]
          }
        }
      ' "$updates" "$cfg" > "$tmp"

    if [[ $APPLY -eq 1 ]]; then
      cp -a "$cfg" "${cfg}.bak.${TS}"
      chmod --reference="$cfg" "$tmp" 2>/dev/null || true
      chown --reference="$cfg" "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$cfg"
      log "Merged planned service rows into $cfg (backup: ${cfg}.bak.${TS})"
    else
      log "DRY-RUN merged affinity.cfg:"
      cat "$tmp" >&2
    fi
    rm -f "$tmp" "$updates"
  fi
  if [[ $APPLY -eq 1 ]]; then
    restart_djinn
  fi
}

apply_all() {
  need_root
  # This must remain the first mutating-flow step.
  preflight_apply
  disable_irqbalance
  apply_grub
  write_irq_script
  write_ameyo_service_affinity
  log "Apply complete. Log: $LOG_FILE"
  if [[ $REBOOT_HINT -eq 1 ]]; then
    echo
    echo "*** Reboot required for grub default_affinity to take effect ***"
    echo "    After reboot: $0 --verify"
  fi
}

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
verify_state() {
  local verify_rc=0
  local allow_pending_reboot="${1:-0}"
  local proc_cmdline="${AFFINITY_PROC_CMDLINE:-/proc/cmdline}"
  local proc_interrupts="${AFFINITY_PROC_INTERRUPTS:-/proc/interrupts}"
  local proc_irq_root="${AFFINITY_PROC_IRQ_ROOT:-/proc/irq}"
  echo "========== VERIFY =========="
  if discover_affinity_config; then
    echo "OK  affinity config: $AFFINITY_CONFIG_PATH"
  else
    echo "FAIL affinity config not found"
    verify_rc=1
  fi
  if grep -q 'default_affinity=' "$proc_cmdline" 2>/dev/null; then
    echo "OK  default_affinity in cmdline: $(tr ' ' '\n' < "$proc_cmdline" | grep default_affinity)"
  else
    if [[ "$allow_pending_reboot" == "1" && $REBOOT_HINT -eq 1 ]]; then
      echo "PENDING default_affinity not active until the required reboot"
    else
      echo "FAIL default_affinity NOT in /proc/cmdline (reboot after grub change?)"
      verify_rc=1
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled irqbalance 2>/dev/null | grep -q enabled; then
      echo "FAIL irqbalance is still enabled"
      verify_rc=1
    else
      echo "OK  irqbalance not enabled"
    fi
    echo "-- DJINN unit state (DJINN itself is not CPU-pinned) --"
    systemctl show djinn.service -p Type -p ActiveState -p SubState -p MainPID 2>/dev/null || \
      echo "WARN unable to read djinn.service state"
    if systemctl is-enabled ameyo-affinity-irq.service >/dev/null 2>&1; then
      if systemctl is-failed ameyo-affinity-irq.service >/dev/null 2>&1; then
        echo "FAIL persistence unit ameyo-affinity-irq.service is failed"
        verify_rc=1
      else
        echo "OK  persistence unit is not failed"
      fi
    fi
  fi

  if [[ ${#PLAN_IRQ[@]} -eq 0 && ${#PLAN_SVC[@]} -eq 0 ]]; then
    echo "SKIP expected-plan comparison: no role could be safely resolved; state-only verification"
    echo "============================"
    return "$verify_rc"
  fi

  echo "-- Expected IRQ affinities --"
  local irq expected actual effective name
  for irq in $(printf '%s\n' "${!PLAN_IRQ[@]}" | sort -n); do
    expected="$(cpu_to_smp_mask "${PLAN_IRQ[$irq]}")"
    actual="$(tr -d ' \n,' < "$proc_irq_root/$irq/smp_affinity" 2>/dev/null || true)"
    effective="$(tr -d ' \n,' < "$proc_irq_root/$irq/effective_affinity" 2>/dev/null || true)"
    expected="${expected//,/}"; name="$(grep -E "^[[:space:]]*${irq}:" "$proc_interrupts" 2>/dev/null | awk '{print $NF}' || true)"
    if [[ -z "$actual" ]]; then
      echo "FAIL IRQ $irq ($name) affinity unreadable"; verify_rc=1
    elif [[ "${actual,,}" != "${expected,,}" ]]; then
      echo "FAIL IRQ $irq ($name) expected CPU ${PLAN_IRQ[$irq]} mask=$expected actual=$actual"; verify_rc=1
    elif [[ -n "$effective" && "${effective,,}" != "${expected,,}" ]]; then
      echo "INFO IRQ $irq ($name) requested mask accepted; driver-managed effective restriction=$effective"
    else
      echo "OK  IRQ $irq ($name) -> CPU ${PLAN_IRQ[$irq]}"
    fi
  done

  echo "-- Expected service configuration --"
  declare -A CSV_NAME=([acp]=ACP [asap]=ASAP [dagent]=DAGENT [crm]=CRM [asterisk]=ASTERISK [asterisk13]=ASTERISK13 [server]=APPSERVER [database]=POSTGRESQL [ameyoreports]=AMEYOREPORTS [ameyoarchiver]=AMEYOARCHIVER [ameyo_voicelogs_conversion]=AMEYO_VOICELOGS_CONVERSION)
  local svc row wanted
  if [[ "$AFFINITY_CONFIG_TYPE" == csv ]]; then
    for svc in "${!PLAN_SVC[@]}"; do
      [[ "$svc" == tools ]] && continue
      name="${CSV_NAME[$svc]:-$(echo "$svc" | tr '[:lower:]' '[:upper:]')}"
      wanted="${PLAN_SVC[$svc]//,/;}"
      row="$(awk -F, -v n="$name" '$1==n {print; exit}' "$AFFINITY_CONFIG_PATH")"
      if [[ "$row" == "$name,$wanted" ]]; then echo "OK  $name,$wanted"
      else echo "FAIL $name expected '$wanted' actual '${row#*,}'"; verify_rc=1; fi
    done
    if ! awk -F, 'NF && $0 !~ /^#/ && (NF != 2 || $2 !~ /^[0-9]+(;[0-9]+)*$/) {bad=1} END {exit bad ? 1 : 0}' "$AFFINITY_CONFIG_PATH"; then
      echo "FAIL invalid CSV row or CPU delimiter (expected SERVICE,CPU;CPU)"; verify_rc=1
    fi
  fi

  echo "-- Expected service process affinity --"
  normalize_cpu_list() {
    local value=$1 part start end i
    local -a expanded=()
    IFS=, read -ra parts <<< "$value"
    for part in "${parts[@]}"; do
      if [[ "$part" == *-* ]]; then
        start="${part%-*}"; end="${part#*-}"
        for ((i=start; i<=end; i++)); do expanded+=("$i"); done
      elif [[ -n "$part" ]]; then
        expanded+=("$part")
      fi
    done
    printf '%s\n' "${expanded[@]}" | sort -n -u | paste -sd, -
  }
  local snapshot pids pid live found expected_cpus
  snapshot="$(ps -eo pid=,args= 2>/dev/null || true)"
  for svc in "${!PLAN_SVC[@]}"; do
    [[ "$svc" == tools ]] && continue
    case "$svc" in
      server) name='appserver' ;; database) name='postgres' ;;
      ameyoreports) name='ameyoreports' ;; ameyoarchiver) name='ameyoarchiver' ;;
      ameyo_voicelogs_conversion) name='ameyo[_-]?voicelogs' ;;
      asterisk13) name='asterisk13|asterisk' ;; *) name="$svc" ;;
    esac
    pids="$(awk -v IGNORECASE=1 -v pat="$name" '$0 ~ pat {print $1}' <<< "$snapshot")"
    if [[ -z "$pids" ]]; then echo "INFO $svc not-running"; continue; fi
    found=0
    expected_cpus="$(normalize_cpu_list "${PLAN_SVC[$svc]}")"
    for pid in $pids; do
      live="$(taskset -cp "$pid" 2>/dev/null | awk -F: '{gsub(/ /,"",$NF); print $NF}')"
      if [[ "$(normalize_cpu_list "$live")" == "$expected_cpus" ]]; then found=1; echo "OK  $svc pid=$pid -> $live"
      else echo "FAIL $svc pid=$pid expected=${PLAN_SVC[$svc]} actual=${live:-unreadable}"; verify_rc=1; fi
    done
  done
  echo "============================"
  return "$verify_rc"
}

print_detect() {
  echo "========== DETECT =========="
  echo "Host:     $(hostname)"
  echo "OS:       $OS_FAMILY $OS_MAJOR grub=$GRUB_STYLE"
  echo "CPU:      logical=$LOGICAL_CPUS pkgs=$PHYSICAL_CPUS phys_cores=${#PHYS_PRIMARY[@]} HT=$IS_HT"
  echo "Primaries:${PHYS_PRIMARY[*]}"
  echo "Hex map:"
  local c
  for c in "${PHYS_PRIMARY[@]}"; do
    local sib="${HT_SIBLING[$c]:-$c}"
    if [[ "$sib" != "$c" ]]; then
      echo "  CPU $c ${CPU_HEX[$c]}  (HT sibling $sib ${CPU_HEX[$sib]})"
    else
      echo "  CPU $c ${CPU_HEX[$c]}"
    fi
  done
  echo "IRQs:"
  echo "  eth:  ${IRQ_ETH[*]:-(none)}"
  echo "  disk: ${IRQ_DISK[*]:-(none)}"
  echo "  tel:  ${IRQ_TEL[*]:-(none)}"
  echo "Ameyo:    $([[ -d $DACX_ROOT/var/ameyo ]] && echo "found under $DACX_ROOT" || echo "not found")"
  if discover_affinity_config; then
    echo "Affinity: $AFFINITY_CONFIG_PATH ($([[ -w "$AFFINITY_CONFIG_PATH" ]] && echo writable || echo read-only))"
  else
    echo "Affinity: not found (apply preflight would fail)"
  fi
  echo "============================"
}

# -----------------------------------------------------------------------------
main() {
  parse_args "$@"
  init_log
  detect_os
  detect_cpu
  detect_irqs

  if [[ "$ROLE" == "detect" ]]; then
    print_detect
    exit 0
  fi

  if [[ $VERIFY_ONLY -eq 1 ]]; then
    if [[ -n "$ROLE_REQUEST" ]]; then
      resolve_role || true
    else
      ROLE_REQUEST=auto
      resolve_role || true
    fi
    if [[ -n "$ROLE" && "$ROLE" != auto ]]; then
      plan_allocation
    else
      PLAN_IRQ=(); PLAN_SVC=()
    fi
    verify_state
    exit $?
  fi

  if ! resolve_role; then
    print_role_detection_failure
    if [[ $APPLY -eq 1 ]]; then
      die "Auto role detection is ambiguous; apply refused. Specify --role explicitly."
    fi
    echo "Dry-run stopped safely without selecting or applying an affinity plan."
    exit 0
  fi

  plan_allocation
  print_plan

  if [[ $APPLY -eq 1 ]]; then
    apply_all
    # Validate live writes/config now, while treating the newly written grub
    # parameter as pending. A later explicit --verify still fails until reboot.
    verify_state 1
  else
    echo "Dry-run only. Re-run with --apply to make changes."
    echo "Log: $LOG_FILE"
  fi
}

main "$@"
