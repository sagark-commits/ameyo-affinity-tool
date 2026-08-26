#!/usr/bin/env bash
# =============================================================================
# affinity_batch.sh — Run affinity_tool.sh on many hosts in one go (via SSH)
# Dry-run by default. Use --apply to write changes on all targets.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${SCRIPT_DIR}/inventory/blr-servers.csv"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)
# -n keeps ssh from consuming the inventory on stdin (it would eat the CSV loop).
# No -q here: it would also swallow the reason a connection failed.
SSH_RUN=(ssh -n "${SSH_OPTS[@]}")
REMOTE_DIR="/opt/ameyo-affinity-tool"
APPLY=0
VERIFY=0
DETECT=0
PARALLEL=0
LIMIT_HOST=""
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
  -h, --help         Help

EXAMPLES:
  # Plan all 10 BLR servers (safe)
  ./affinity_batch.sh

  # Apply everywhere
  ./affinity_batch.sh --apply

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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -f "$INVENTORY" ]] || { echo "Inventory not found: $INVENTORY"; exit 1; }
mkdir -p "$LOG_DIR"

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
    "${SSH_RUN[@]}" "${SSH_USER}@${ip}" "mkdir -p '${REMOTE_DIR}/profiles'" || ssh_rc=$?
    if [[ $ssh_rc -ne 0 ]]; then
      echo "SSH FAILED (exit ${ssh_rc}): $host ($ip)"
      echo "Reproduce with: ssh -v ${SSH_USER}@${ip} \"mkdir -p '${REMOTE_DIR}/profiles'\""
      case "$ssh_rc" in
        255) echo "Hint: exit 255 is an ssh transport/auth error (key, host key, or unreachable)." ;;
        1)   echo "Hint: connected, but the remote command failed (permissions or read-only /opt?)." ;;
      esac
      return 1
    fi

    scp -q "${SSH_OPTS[@]}" \
      "${SCRIPT_DIR}/affinity_tool.sh" \
      "${SSH_USER}@${ip}:${REMOTE_DIR}/affinity_tool.sh" >/dev/null

    # profiles optional; newer scp (SFTP mode) rejects a bare "." source
    if compgen -G "${SCRIPT_DIR}/profiles/*" >/dev/null 2>&1; then
      scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}"/profiles/* \
        "${SSH_USER}@${ip}:${REMOTE_DIR}/profiles/" >/dev/null || true
    fi

    "${SSH_RUN[@]}" "${SSH_USER}@${ip}" "chmod +x '${REMOTE_DIR}/affinity_tool.sh'"

    if [[ $VERIFY -eq 1 ]]; then
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --verify"
    elif [[ $DETECT -eq 1 ]]; then
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --detect"
    elif [[ $APPLY -eq 1 ]]; then
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --role '${role}' --apply"
    else
      remote_cmd="sudo '${REMOTE_DIR}/affinity_tool.sh' --role '${role}'"
    fi

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

  case "$role" in
    single|appdb|app|db|report|asap|call|custom) ;;
    *)
      echo "SKIP $hostname: invalid role '$role'"
      SKIP=$((SKIP + 1))
      continue
      ;;
  esac

  HOSTS+=("$hostname")
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
if [[ $APPLY -eq 1 ]]; then
  echo
  echo "NOTE: grub default_affinity needs a reboot on each host."
  echo "After reboot:  $0 --verify"
fi
[[ $FAIL -eq 0 ]] || exit 1
