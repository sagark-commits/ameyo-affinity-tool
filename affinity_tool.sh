#!/usr/bin/env bash
# =============================================================================
# affinity_tool.sh — Global CPU affinity fixer for Ameyo / telephony hosts
# Works on: CentOS 6/7, RHEL 7/8/9, Rocky Linux 8/9 (and similar)
# Scales to any CPU count; role-aware; dry-run by default
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${AFFINITY_LOG_DIR:-/var/tmp/affinity-tool}"
DACX_ROOT="${DACX_ROOT:-/dacx}"
APPLY=0
VERIFY_ONLY=0
ROLE=""
PROFILE_FILE=""
HAS_TELEPHONY=""
REBOOT_HINT=0
TS="$(date +%Y%m%d-%H%M%S)"

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
declare -A PLAN_SVC=()           # service -> cpu list string
DEFAULT_AFFINITY_CPU=0

usage() {
  cat <<EOF
affinity_tool.sh v${VERSION}

Global CPU affinity planner/applier for Ameyo hosts (any CPU count).
Supports CentOS / RHEL / Rocky. Dry-run by default.

USAGE:
  $0 --role <role> [--apply] [options]
  $0 --verify
  $0 --detect

ROLES:
  single      Single server (APP+DB+ACP+Asterisk [+telephony])
  appdb       APP + DB + ACP (no Asterisk)
  call        Call server (Asterisk [+telephony], no APP/DB)
  custom      Load --profile FILE

OPTIONS:
  --role ROLE           Server role (required unless --verify/--detect)
  --profile FILE        Custom profile (key=value). Used with --role custom
                        or to override a built-in role
  --apply               Write changes (default is dry-run / plan only)
  --verify              Check current affinity vs expectations
  --detect              Print OS/CPU/IRQ discovery only
  --telephony yes|no    Force telephony present/absent (auto-detect default)
  --dacx PATH           Ameyo root (default: /dacx)
  --log-dir PATH        Log directory (default: /var/tmp/affinity-tool)
  -h, --help            This help

EXAMPLES:
  # Plan only (safe)
  sudo ./affinity_tool.sh --role single

  # Apply on a Rocky call server
  sudo ./affinity_tool.sh --role call --apply

  # Custom layout
  sudo ./affinity_tool.sh --role custom --profile ./profiles/custom.conf --apply

  # Inventory any box
  sudo ./affinity_tool.sh --detect
EOF
}

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)"; }

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE="${2:-}"; shift 2 ;;
      --profile) PROFILE_FILE="${2:-}"; shift 2 ;;
      --apply) APPLY=1; shift ;;
      --verify) VERIFY_ONLY=1; shift ;;
      --detect) ROLE="detect"; shift ;;
      --telephony) HAS_TELEPHONY="${2:-}"; shift 2 ;;
      --dacx) DACX_ROOT="${2:-}"; shift 2 ;;
      --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
  if [[ $VERIFY_ONLY -eq 0 && "$ROLE" != "detect" ]]; then
    [[ -n "$ROLE" ]] || die "--role is required (single|appdb|call|custom)"
    case "$ROLE" in
      single|appdb|call|custom|detect) ;;
      *) die "Invalid role: $ROLE" ;;
    esac
    if [[ "$ROLE" == "custom" && -z "$PROFILE_FILE" ]]; then
      die "--role custom requires --profile FILE"
    fi
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
    OS_MAJOR="${VERSION_ID%%.*}"
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

  [[ -r /proc/cpuinfo ]] || die "/proc/cpuinfo not readable"

  local -A core_cpus=()   # "phys:core" -> "cpu,cpu"
  local -A seen_cpu=()
  local proc="" phys="" core=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      processor*)
        proc="$(echo "$line" | awk -F: '{gsub(/ /,"",$2); print $2}')"
        ;;
      "physical id"*)
        phys="$(echo "$line" | awk -F: '{gsub(/ /,"",$2); print $2}')"
        ;;
      "core id"*)
        core="$(echo "$line" | awk -F: '{gsub(/ /,"",$2); print $2}')"
        if [[ -n "$proc" && -n "$phys" && -n "$core" ]]; then
          local key="${phys}:${core}"
          if [[ -n "${core_cpus[$key]:-}" ]]; then
            core_cpus[$key]="${core_cpus[$key]},${proc}"
          else
            core_cpus[$key]="$proc"
          fi
          seen_cpu[$proc]=1
          proc=""; phys=""; core=""
        fi
        ;;
    esac
  done < /proc/cpuinfo

  # Fallback if topology fields missing
  if [[ ${#core_cpus[@]} -eq 0 ]]; then
    local n
    n="$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
    local i
    for ((i=0; i<n; i++)); do
      core_cpus["0:$i"]="$i"
      seen_cpu[$i]=1
    done
  fi

  LOGICAL_CPUS=${#seen_cpu[@]}
  local -A phys_ids=()
  local key cpus first rest sib
  for key in "${!core_cpus[@]}"; do
    phys_ids["${key%%:*}"]=1
    cpus="${core_cpus[$key]}"
    first="${cpus%%,*}"
    PHYS_PRIMARY+=("$first")
    if [[ "$cpus" == *,* ]]; then
      rest="${cpus#*,}"
      sib="${rest%%,*}"
      HT_SIBLING[$first]="$sib"
      HT_SIBLING[$sib]="$first"
      # extra siblings map to first
      local x
      IFS=',' read -ra _arr <<< "$cpus"
      for x in "${_arr[@]}"; do
        HT_SIBLING[$x]="${_arr[0]}"
        [[ "$x" == "${_arr[0]}" ]] || HT_SIBLING[${_arr[0]}]="$x"
      done
    else
      HT_SIBLING[$first]="$first"
    fi
  done
  PHYSICAL_CPUS=${#phys_ids[@]}

  # Sort primary cores numerically
  IFS=$'\n' PHYS_PRIMARY=($(printf '%s\n' "${PHYS_PRIMARY[@]}" | sort -n)); unset IFS
  CORES_PER_CPU=$(( ${#PHYS_PRIMARY[@]} / (PHYSICAL_CPUS > 0 ? PHYSICAL_CPUS : 1) ))

  local max_sib=0
  local c
  for c in "${!HT_SIBLING[@]}"; do
    [[ "${HT_SIBLING[$c]}" != "$c" ]] && max_sib=1
  done
  IS_HT=$max_sib

  CPU_LIST=()
  for ((c=0; c<LOGICAL_CPUS; c++)); do CPU_LIST+=("$c"); done

  for c in "${CPU_LIST[@]}"; do
    CPU_HEX[$c]=$(printf '0x%x' $((1 << c)))
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

# -----------------------------------------------------------------------------
# Planning — scales with CPU count
# -----------------------------------------------------------------------------
plan_allocation() {
  PLAN_IRQ=()
  PLAN_SVC=()

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
  if [[ -n "${OV[irq_disk]:-}" ]]; then disk_cpu="${OV[irq_disk]}"
  else
    disk_cpu="$(pick_cores 1 "${reserved[@]}" | head -1)"
    [[ -n "$disk_cpu" ]] && reserved+=("$disk_cpu")
  fi

  if [[ "$HAS_TELEPHONY" == "yes" ]]; then
    if [[ -n "${OV[irq_telephony]:-}" ]]; then tel_cpu="${OV[irq_telephony]}"
    else
      tel_cpu="$(pick_cores 1 "${reserved[@]}" | head -1)"
      [[ -n "$tel_cpu" ]] && reserved+=("$tel_cpu")
    fi
    if [[ -n "${OV[irq_ethernet]:-}" ]]; then eth_cpu="${OV[irq_ethernet]}"
    else eth_cpu=0; fi
  else
    if [[ -n "${OV[irq_ethernet]:-}" ]]; then eth_cpu="${OV[irq_ethernet]}"
    else
      # Prefer a non-0 core for eth when no telephony
      eth_cpu="$(pick_cores 1 "${reserved[@]}" | head -1)"
      eth_cpu="${eth_cpu:-0}"
      [[ -n "$eth_cpu" && "$eth_cpu" != "0" ]] && reserved+=("$eth_cpu")
    fi
  fi

  local irq
  for irq in "${IRQ_DISK[@]:-}"; do [[ -n "$disk_cpu" ]] && PLAN_IRQ[$irq]="$disk_cpu"; done
  for irq in "${IRQ_ETH[@]:-}"; do [[ -n "$eth_cpu" ]] && PLAN_IRQ[$irq]="$eth_cpu"; done
  for irq in "${IRQ_TEL[@]:-}"; do [[ -n "$tel_cpu" ]] && PLAN_IRQ[$irq]="$tel_cpu"; done

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

  # Role defaults
  PLAN_SVC[tools]=0
  PLAN_SVC[dagent]=0

  case "$ROLE" in
    single)
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
      local n_ast need i
      n_ast=${#pool[@]}
      [[ $n_ast -lt 1 ]] && n_ast=1
      [[ $n_ast -gt 4 ]] && n_ast=4
      local ast_cores=()
      if [[ -n "$tel_cpu" ]]; then ast_cores+=("$tel_cpu"); fi
      need=$(( n_ast - ${#ast_cores[@]} ))
      [[ $need -lt 0 ]] && need=0
      for ((i=0; i<need && i<${#pool[@]}; i++)); do ast_cores+=("${pool[$i]}"); done
      pool_drop "$need"
      if [[ ${#pool[@]} -gt 0 ]]; then
        ast_cores+=("${pool[@]}")
        pool=()
      fi
      PLAN_SVC[asterisk]="$(printf '%s\n' "${ast_cores[@]}" | sort -nu | paste -sd, -)"
      ;;
    custom)
      local k
      for k in "${!OV[@]}"; do
        case "$k" in
          irq_*) ;;
          *) PLAN_SVC[$k]="${OV[$k]}" ;;
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
        *) PLAN_SVC[$k]="${OV[$k]}" ;;
      esac
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
  echo "CPUs:        logical=$LOGICAL_CPUS physical_cores=${#PHYS_PRIMARY[@]} HT=$IS_HT"
  echo "Role:        $ROLE  telephony=$HAS_TELEPHONY"
  echo "Mode:        $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
  echo
  echo "-- Default affinity (grub) --"
  echo "  CPU $DEFAULT_AFFINITY_CPU  mask=${CPU_HEX[$DEFAULT_AFFINITY_CPU]}"
  echo
  echo "-- IRQ smp_affinity --"
  if [[ ${#PLAN_IRQ[@]} -eq 0 ]]; then
    echo "  (none discovered)"
  else
    local irq
    for irq in $(printf '%s\n' "${!PLAN_IRQ[@]}" | sort -n); do
      echo "  IRQ $irq -> CPU ${PLAN_IRQ[$irq]}  mask=$(cpu_to_smp_mask "${PLAN_IRQ[$irq]}")"
    done
  fi
  echo
  echo "-- Ameyo services --"
  local svc
  for svc in $(printf '%s\n' "${!PLAN_SVC[@]}" | sort); do
    echo "  $svc = ${PLAN_SVC[$svc]}"
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
  local out="${DACX_ROOT}/affinitySetter.sh"
  mkdir -p "$DACX_ROOT"
  local tmp
  tmp="$(mktemp)"
  {
    echo "#!/bin/bash"
    echo "# Generated by affinity_tool.sh v${VERSION} on ${TS}"
    echo "# Role=$ROLE host=$(hostname)"
    echo "set -e"
    local irq cpu mask
    for irq in $(printf '%s\n' "${!PLAN_IRQ[@]}" | sort -n); do
      cpu="${PLAN_IRQ[$irq]}"
      mask="$(cpu_to_smp_mask "$cpu")"
      echo "if [[ -f /proc/irq/${irq}/smp_affinity ]]; then"
      echo "  echo ${mask} > /proc/irq/${irq}/smp_affinity"
      echo "  echo \"IRQ ${irq} -> CPU ${cpu}\""
      echo "fi"
    done
  } > "$tmp"
  if [[ $APPLY -eq 1 ]]; then
    cp -a "$tmp" "$out"
    chmod 755 "$out"
    bash "$out" || log "WARN: affinitySetter.sh had errors (IRQ may be missing)"
    # Persist via rc.local or systemd
    if [[ -f /etc/rc.d/rc.local || -f /etc/rc.local ]]; then
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
      # systemd oneshot
      cat > /etc/systemd/system/ameyo-affinity-irq.service <<EOF
[Unit]
Description=Ameyo IRQ CPU affinity
After=network-pre.target
[Service]
Type=oneshot
ExecStart=${out}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload 2>/dev/null || true
      systemctl enable ameyo-affinity-irq.service 2>/dev/null || true
      log "Installed systemd unit ameyo-affinity-irq.service"
    fi
  else
    log "DRY-RUN: would write $out"
    cat "$tmp" >&2
  fi
  rm -f "$tmp"
}

write_ameyo_service_affinity() {
  local csv="${DACX_ROOT}/var/ameyo/dacxdata/etc/djinn/serviceCPUAffinityConf.csv"
  local cfg="${DACX_ROOT}/var/ameyo/dacxdata/var/affinity.cfg"
  local use=""

  if [[ -d "${DACX_ROOT}/var/ameyo" ]]; then
    if [[ -f "$csv" ]] || [[ -d "$(dirname "$csv")" ]]; then
      use="csv"
    elif [[ -f "$cfg" ]] || [[ -d "$(dirname "$cfg")" ]]; then
      use="cfg"
    else
      # Prefer CSV for modern Ameyo
      use="csv"
      mkdir -p "$(dirname "$csv")"
    fi
  else
    log "No Ameyo tree under $DACX_ROOT — skipping service affinity files"
    return 0
  fi

  # Map internal names -> CSV names from doc
  declare -A CSV_NAME=(
    [tools]=TOOLS
    [acp]=ACP
    [dagent]=DAGENT
    [asterisk]=ASTERISK
    [server]=APPSERVER
    [database]=POSTGRESQL
    [ameyoreports]=AMEYOREPORTS
    [ameyoarchiver]=AMEYOARCHIVER
    [ameyo_voicelogs_conversion]=AMEYO_VOICELOGS_CONVERSION
  )

  if [[ "$use" == "csv" ]]; then
    local tmp; tmp="$(mktemp)"
    echo "SERVICE,CPU" > "$tmp"
    local svc name
    for svc in "${!PLAN_SVC[@]}"; do
      name="${CSV_NAME[$svc]:-$(echo "$svc" | tr '[:lower:]' '[:upper:]')}"
      # Skip empty
      [[ -n "${PLAN_SVC[$svc]}" ]] || continue
      echo "${name},${PLAN_SVC[$svc]}" >> "$tmp"
    done
    if [[ $APPLY -eq 1 ]]; then
      mkdir -p "$(dirname "$csv")"
      [[ -f "$csv" ]] && cp -a "$csv" "${csv}.bak.${TS}"
      cp "$tmp" "$csv"
      log "Wrote $csv"
      if [[ -x /etc/init.d/djinn ]]; then
        /etc/init.d/djinn restart || log "WARN: djinn restart failed"
      elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q djinn; then
        systemctl restart djinn || log "WARN: djinn restart failed"
      else
        log "NOTE: restart djinn manually to apply service affinity"
      fi
    else
      log "DRY-RUN CSV content:"
      cat "$tmp" >&2
    fi
    rm -f "$tmp"
  else
    local tmp; tmp="$(mktemp)"
    {
      echo "# Generated by affinity_tool.sh ${TS}"
      local svc
      for svc in tools acp dagent asterisk server database; do
        if [[ -n "${PLAN_SVC[$svc]:-}" ]]; then
          echo "-${svc} : ${PLAN_SVC[$svc]}"
        fi
      done
    } > "$tmp"
    if [[ $APPLY -eq 1 ]]; then
      mkdir -p "$(dirname "$cfg")"
      [[ -f "$cfg" ]] && cp -a "$cfg" "${cfg}.bak.${TS}"
      cp "$tmp" "$cfg"
      log "Wrote $cfg"
    else
      log "DRY-RUN affinity.cfg:"
      cat "$tmp" >&2
    fi
    rm -f "$tmp"
  fi
}

apply_all() {
  need_root
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
  echo "========== VERIFY =========="
  if grep -q 'default_affinity=' /proc/cmdline 2>/dev/null; then
    echo "OK  default_affinity in cmdline: $(tr ' ' '\n' < /proc/cmdline | grep default_affinity)"
  else
    echo "MISS default_affinity NOT in /proc/cmdline (reboot after grub change?)"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled irqbalance 2>/dev/null | grep -q enabled; then
      echo "WARN irqbalance is still enabled"
    else
      echo "OK  irqbalance not enabled"
    fi
  fi

  echo "-- Sample IRQ affinities --"
  local irq
  for irq in $(ls /proc/irq 2>/dev/null | grep -E '^[0-9]+$' | head -20); do
    local name
    name="$(grep -E "^[[:space:]]*${irq}:" /proc/interrupts 2>/dev/null | awk '{print $NF}' || true)"
    case "$name" in
      eth*|ens*|enp*|*megasas*|*hpsa*|*ahci*|*wanpipe*|*wcte*|*nvme*)
        echo "  IRQ $irq ($name): $(cat /proc/irq/$irq/smp_affinity 2>/dev/null || echo '?')"
        ;;
    esac
  done

  echo "-- Service taskset (if running) --"
  local p
  for name in asterisk java postgres; do
    p="$(pgrep -xo "$name" 2>/dev/null || true)"
    if [[ -n "$p" ]]; then
      echo "  $name pid=$p -> $(taskset -cp "$p" 2>/dev/null || echo 'taskset failed')"
    fi
  done
  # Ameyo java processes
  if command -v pstree >/dev/null 2>&1; then
    echo "  (use: taskset -cp <pid> for each Ameyo service)"
  fi
  echo "============================"
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
    verify_state
    exit 0
  fi

  plan_allocation
  print_plan

  if [[ $APPLY -eq 1 ]]; then
    apply_all
    verify_state
  else
    echo "Dry-run only. Re-run with --apply to make changes."
    echo "Log: $LOG_FILE"
  fi
}

main "$@"
