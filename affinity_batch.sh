#!/usr/bin/env bash
# =============================================================================
# affinity_batch.sh — Run affinity_tool.sh on many hosts in one go (via SSH)
# Dry-run by default. Use --apply to write changes on all targets.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${SCRIPT_DIR}/inventory/blr-servers.csv"
SSH_USER="${SSH_USER:-root}"
SSH_RETRIES="${SSH_RETRIES:-3}"
SSH_RETRY_WAIT="${SSH_RETRY_WAIT:-8}"
SSH_MUX_DIR="${TMPDIR:-/tmp}/affinity-mux-$$"

# Multiplex every session for a host over one TCP connection. Without this the
# deploy opens five connections per host in a burst, which trips SSH rate
# limiting (fail2ban / firewalld / iptables recent) and the next SYN is dropped.
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -o BatchMode=yes
  -o LogLevel=ERROR
  -o ControlMaster=auto
  -o "ControlPath=${SSH_MUX_DIR}/%r@%h:%p"
  -o ControlPersist=120
)
# -n keeps ssh from consuming the inventory on stdin (it would eat the CSV loop).
# No -q here: it would also swallow the reason a connection failed.
SSH_RUN=(ssh -n "${SSH_OPTS[@]}")

mkdir -p "$SSH_MUX_DIR"
chmod 700 "$SSH_MUX_DIR"
cleanup_mux() { rm -rf "$SSH_MUX_DIR" 2>/dev/null || true; }
trap cleanup_mux EXIT

# Retry the first contact: a dropped SYN from rate limiting clears on its own.
ssh_connect_retry() {
  local target="$1" cmd="$2" attempt=1 rc=0
  while :; do
    rc=0
    "${SSH_RUN[@]}" "$target" "$cmd" || rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $attempt -ge $SSH_RETRIES ]] && return "$rc"
    echo "  attempt ${attempt}/${SSH_RETRIES} failed (exit ${rc}); retrying in ${SSH_RETRY_WAIT}s"
    sleep "$SSH_RETRY_WAIT"
    attempt=$((attempt + 1))
  done
}
REMOTE_DIR="/opt/ameyo-affinity-tool"
APPLY=0
VERIFY=0
DETECT=0
PARALLEL=0
LIMIT_HOST=""
LIMIT_PAIR=""
CONCURRENT_CALLS=""
ACTIVE_AGENTS=""
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${SCRIPT_DIR}/batch-logs/${TS}"

usage() {
  cat <<EOF
affinity_batch.sh — apply affinity across an inventory (primary+secondary)

USAGE:
  $0 [--inventory FILE] [options]

OPTIONS:
  --inventory FILE   CSV: hostname,ip,role,pair,notes  (default: inventory/blr-servers.csv)
  --user USER        SSH user (default: root, or \$SSH_USER)
  --apply            Apply on each host (default: dry-run / plan only)
  --verify           Only verify affinity on each host
  --detect           Only run --detect on each host
  --parallel         Run hosts in parallel (faster; logs per host)
  --host NAME|IP     Limit to one hostname or IP from inventory
  --pair NAME        Limit to one failover pair; apply secondary then primary
  --concurrent-calls N  Pass call workload to selected inventory hosts
  --active-agents N     Pass CRM workload to selected inventory hosts
  -h, --help         Help

EXAMPLES:
  # Plan all 10 BLR servers (safe)
  ./affinity_batch.sh

  # Apply one failover pair, secondary then primary
  ./affinity_batch.sh --pair APP --apply

  # One host only
  ./affinity_batch.sh --host BLR-PCS --apply

  # Verify after reboot
  ./affinity_batch.sh --verify

Requires: ssh/scp key access as \$SSH_USER to every IP in the inventory.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) INVENTORY="${2:-}"; shift 2 ;;
    --user) SSH_USER="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --detect) DETECT=1; shift ;;
    --parallel) PARALLEL=1; shift ;;
    --host) LIMIT_HOST="${2:-}"; shift 2 ;;
    --pair) LIMIT_PAIR="${2:-}"; shift 2 ;;
    --concurrent-calls) CONCURRENT_CALLS="${2:-}"; shift 2 ;;
    --active-agents) ACTIVE_AGENTS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -f "$INVENTORY" ]] || { echo "Inventory not found: $INVENTORY"; exit 1; }
if [[ -n "$CONCURRENT_CALLS" && ! "$CONCURRENT_CALLS" =~ ^[0-9]+$ ]]; then
  echo "--concurrent-calls must be a non-negative integer"
  exit 1
fi
if [[ -n "$ACTIVE_AGENTS" && ! "$ACTIVE_AGENTS" =~ ^[0-9]+$ ]]; then
  echo "--active-agents must be a non-negative integer"
  exit 1
fi
if [[ -n "$LIMIT_HOST" && -n "$LIMIT_PAIR" ]]; then
  echo "Use only one of --host or --pair"
  exit 1
fi
if [[ $APPLY -eq 1 && -z "$LIMIT_HOST" && -z "$LIMIT_PAIR" ]]; then
  echo "Production apply is limited to one host or pair. Use --host NAME or --pair NAME."
  exit 1
fi
if [[ $APPLY -eq 1 && $PARALLEL -eq 1 ]]; then
  echo "Parallel apply is disabled; pair rollout must be secondary-first with verification."
  exit 1
fi
mkdir -p "$LOG_DIR"

# Pair application is deliberately serialized secondary-first. The second pass
# contains the primary (and any nonstandard member names) only after secondary
# has returned success.
if [[ $APPLY -eq 1 && -n "$LIMIT_PAIR" ]]; then
  ORDERED_INVENTORY="${LOG_DIR}/.pair-order.csv"
  awk -F, -v wanted="$LIMIT_PAIR" '
    BEGIN { IGNORECASE=1 }
    $4 == wanted && $1 ~ /(^|[-_])S/ { print }
  ' "$INVENTORY" > "$ORDERED_INVENTORY"
  awk -F, -v wanted="$LIMIT_PAIR" '
    BEGIN { IGNORECASE=1 }
    $4 == wanted && $1 !~ /(^|[-_])S/ { print }
  ' "$INVENTORY" >> "$ORDERED_INVENTORY"
  INVENTORY="$ORDERED_INVENTORY"
fi

MODE="DRY-RUN"
[[ $APPLY -eq 1 ]] && MODE="APPLY"
[[ $DETECT -eq 1 ]] && MODE="DETECT"
[[ $VERIFY -eq 1 ]] && MODE="VERIFY"

echo "=== affinity_batch ==="
echo "Inventory: $INVENTORY"
echo "SSH user:  $SSH_USER"
echo "Mode:      $MODE"
echo "Logs:      $LOG_DIR"
echo

run_one() {
  local host="$1" ip="$2" role="$3" pair="$4"
  local logfile="${LOG_DIR}/${host}.log"
  local remote_cmd
  local rc=0

  {
    echo "---- $host ($ip) role=$role pair=$pair ----"
    echo "[$(date '+%F %T')] deploy tool -> ${SSH_USER}@${ip}:${REMOTE_DIR}"

    local ssh_rc=0
    ssh_connect_retry "${SSH_USER}@${ip}" "mkdir -p '${REMOTE_DIR}/profiles'" || ssh_rc=$?
    if [[ $ssh_rc -ne 0 ]]; then
      echo "SSH FAILED (exit ${ssh_rc}): $host ($ip)"
      echo "Reproduce with: ssh -v ${SSH_USER}@${ip} \"mkdir -p '${REMOTE_DIR}/profiles'\""
      case "$ssh_rc" in
        255) echo "Hint: exit 255 is an ssh transport error. 'Connection timed out' with a" \
                  "host that answers manually usually means SSH rate limiting (fail2ban," \
                  "firewalld, or iptables recent) dropped the SYN." ;;
        1)   echo "Hint: connected, but the remote command failed (permissions or read-only /opt?)." ;;
      esac
      return 1
    fi

    if ! scp -q "${SSH_OPTS[@]}" \
      "${SCRIPT_DIR}/affinity_tool.sh" \
      "${SSH_USER}@${ip}:${REMOTE_DIR}/affinity_tool.sh" >/dev/null; then
      echo "DEPLOY FAILED: could not copy affinity_tool.sh to $host"
      return 1
    fi

    # profiles optional; newer scp (SFTP mode) rejects a bare "." source
    if compgen -G "${SCRIPT_DIR}/profiles/*" >/dev/null 2>&1; then
      scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}"/profiles/* \
        "${SSH_USER}@${ip}:${REMOTE_DIR}/profiles/" >/dev/null || true
    fi

    if ! "${SSH_RUN[@]}" "${SSH_USER}@${ip}" "chmod +x '${REMOTE_DIR}/affinity_tool.sh'"; then
      echo "DEPLOY FAILED: could not make remote tool executable on $host"
      return 1
    fi

    if [[ $VERIFY -eq 1 ]]; then
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --verify"
    elif [[ $DETECT -eq 1 ]]; then
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --detect"
    elif [[ $APPLY -eq 1 ]]; then
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --role '${role}' --apply"
    else
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --role '${role}'"
    fi
    [[ -n "$CONCURRENT_CALLS" ]] && remote_cmd+=" --concurrent-calls '${CONCURRENT_CALLS}'"
    [[ -n "$ACTIVE_AGENTS" ]] && remote_cmd+=" --active-agents '${ACTIVE_AGENTS}'"

    # If already root, drop sudo
    if [[ "$SSH_USER" == "root" ]]; then
      remote_cmd="${remote_cmd#sudo }"
    fi

    echo "[$(date '+%F %T')] RUN: $remote_cmd"
    # shellcheck disable=SC2029
    "${SSH_RUN[@]}" "${SSH_USER}@${ip}" "$remote_cmd" || rc=$?
    echo "[$(date '+%F %T')] exit=$rc"
    return "$rc"
  } >"$logfile" 2>&1
}

declare -a PIDS=()
declare -a HOSTS=()
FAIL=0
OK=0
SKIP=0
SELECTED=0

while IFS= read -r line <&3 || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^hostname, ]] && continue

  # CSV split (simple — no embedded commas in fields except notes)
  IFS=',' read -r hostname ip role pair notes <<<"$line"
  hostname="$(echo "$hostname" | tr -d '[:space:]')"
  ip="$(echo "$ip" | tr -d '[:space:]')"
  role="$(echo "$role" | tr -d '[:space:]')"
  pair="$(echo "$pair" | tr -d '[:space:]')"

  [[ -n "$hostname" && -n "$ip" && -n "$role" ]] || continue

  if [[ -n "$LIMIT_HOST" ]]; then
    if [[ "$hostname" != "$LIMIT_HOST" && "$ip" != "$LIMIT_HOST" ]]; then
      continue
    fi
  fi
  if [[ -n "$LIMIT_PAIR" && "${pair^^}" != "${LIMIT_PAIR^^}" ]]; then
    continue
  fi

  case "$role" in
    single|appdb|app|db|report|asap|call|custom) ;;
    *)
      echo "SKIP $hostname: invalid role '$role'"
      SKIP=$((SKIP + 1))
      continue
      ;;
  esac

  HOSTS+=("$hostname")
  SELECTED=$((SELECTED + 1))
  echo "Queue: $hostname  $ip  role=$role  pair=$pair"

  if [[ $PARALLEL -eq 1 ]]; then
    run_one "$hostname" "$ip" "$role" "$pair" &
    PIDS+=("$!")
  else
    if run_one "$hostname" "$ip" "$role" "$pair"; then
      echo "OK   $hostname  (log: ${LOG_DIR}/${hostname}.log)"
      OK=$((OK + 1))
    else
      echo "FAIL $hostname  (log: ${LOG_DIR}/${hostname}.log)"
      FAIL=$((FAIL + 1))
      if [[ $APPLY -eq 1 && -n "$LIMIT_PAIR" ]]; then
        echo "STOP pair $LIMIT_PAIR: not continuing after $hostname failure"
        break
      fi
    fi
  fi
done 3< "$INVENTORY"

if [[ $PARALLEL -eq 1 ]]; then
  for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    host="${HOSTS[$i]}"
    if wait "$pid"; then
      echo "OK   $host  (log: ${LOG_DIR}/${host}.log)"
      OK=$((OK + 1))
    else
      echo "FAIL $host  (log: ${LOG_DIR}/${host}.log)"
      FAIL=$((FAIL + 1))
    fi
  done
fi

echo
echo "=== SUMMARY ==="
echo "OK=$OK  FAIL=$FAIL  SKIP=$SKIP"
echo "Logs: $LOG_DIR"
if [[ $SELECTED -eq 0 ]]; then
  echo "ERROR: no inventory host matched the requested host or pair"
  exit 1
fi
if [[ $APPLY -eq 1 ]]; then
  echo
  echo "NOTE: grub default_affinity needs a reboot on each host."
  echo "After reboot:  $0 --verify"
fi
[[ $FAIL -eq 0 ]] || exit 1
