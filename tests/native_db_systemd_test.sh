#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed 's/^main "\$@"$//' "$ROOT/affinity_tool.sh" > "$TMP/tool.sh"
# shellcheck disable=SC1090
source "$TMP/tool.sh"

LOG_FILE="$TMP/test.log"
SYSTEMD_CONFIG_ROOT="$TMP/systemd"
CGROUP_ROOT="$TMP/cgroup"
TS=test
ROLE=db
PLAN_SVC=([database]='5,6,21,22' [dagent]='5,6')
mkdir -p "$SYSTEMD_CONFIG_ROOT" "$CGROUP_ROOT/postgres" "$CGROUP_ROOT/djinn"
printf '101\n102\n' > "$CGROUP_ROOT/postgres/cgroup.procs"
printf '201\n202\n' > "$CGROUP_ROOT/djinn/cgroup.procs"

PG_UNITS="postgresql-14.service"
declare -A LIVE=([101]='0-31' [102]='0-31' [201]='0-31' [202]='0-31')
systemctl() {
  if [[ "$1" == list-units ]]; then
    local u; for u in $PG_UNITS; do echo "$u loaded active running PostgreSQL"; done
    return 0
  fi
  if [[ "$1" == show ]]; then
    local unit=$2 prop=$4
    case "$unit:$prop" in
      postgresql*.service:LoadState|djinn.service:LoadState) echo loaded ;;
      postgresql*.service:ActiveState|djinn.service:ActiveState) echo active ;;
      postgresql*.service:ControlGroup) echo /postgres ;;
      djinn.service:ControlGroup) echo /djinn ;;
      postgresql*.service:MainPID) echo 101 ;;
      djinn.service:MainPID) echo 201 ;;
      postgresql*.service:CPUAffinity) echo '5 6 21 22' ;;
      djinn.service:CPUAffinity) echo '5 6' ;;
    esac
    return 0
  fi
  [[ "$1" == daemon-reload ]] && { touch "$TMP/reloaded"; return 0; }
  [[ "$1 $2" == "restart djinn.service" ]] && { touch "$TMP/djinn-restarted"; return 0; }
  return 1
}
taskset() {
  if [[ "$1" == -apc ]]; then LIVE[$3]="$2"; return 0; fi
  [[ "$1" == -cp ]] && { echo "pid $2's current affinity list: ${LIVE[$2]}"; return 0; }
  return 1
}
ps() {
  cat <<'EOF'
 201 djinn /opt/ameyo/djinn
 202 dagent /opt/ameyo/dagent --worker
 999 httpdagent /opt/ameyo/httpdagent
EOF
}

resolve_postgres_unit
[[ "$POSTGRES_UNIT" == postgresql-14.service ]]
PG_UNITS="postgresql-14.service postgresql-15.service"
if resolve_postgres_unit >/dev/null 2>&1; then
  echo "Ambiguous PostgreSQL units unexpectedly resolved"; exit 1
fi
PG_UNITS=""
if resolve_postgres_unit >/dev/null 2>&1; then
  echo "Missing PostgreSQL unit unexpectedly resolved"; exit 1
fi
PG_UNITS="postgresql-14.service"
detect_db_native_backend

mkdir -p "$SYSTEMD_CONFIG_ROOT/postgresql-14.service.d"
printf '# old managed file\n[Service]\nCPUAffinity=1\n' \
  > "$SYSTEMD_CONFIG_ROOT/postgresql-14.service.d/$SYSTEMD_DROPIN_NAME"
apply_native_db_affinity >/dev/null

grep -Fqx 'CPUAffinity=5 6 21 22' \
  "$SYSTEMD_CONFIG_ROOT/postgresql-14.service.d/$SYSTEMD_DROPIN_NAME"
grep -Fqx 'CPUAffinity=5 6' \
  "$SYSTEMD_CONFIG_ROOT/djinn.service.d/$SYSTEMD_DROPIN_NAME"
compgen -G "$SYSTEMD_CONFIG_ROOT/postgresql-14.service.d/$SYSTEMD_DROPIN_NAME.bak.*" >/dev/null
[[ -e "$TMP/reloaded" && -e "$TMP/djinn-restarted" ]]
[[ "${LIVE[101]}" == '5,6,21,22' && "${LIVE[102]}" == '5,6,21,22' ]]
[[ "${LIVE[201]}" == '5,6' && "${LIVE[202]}" == '5,6' ]]

mapfile -t DAGENT_PIDS < <(exact_dagent_pids)
[[ "${DAGENT_PIDS[*]}" == 202 ]]

verify_systemd_dropin postgresql-14.service '5,6,21,22' >/dev/null
verify_systemd_dropin djinn.service '5,6' >/dev/null
verify_unit_tasks postgresql-14.service '5,6,21,22' >/dev/null
verify_unit_tasks djinn.service '5,6' >/dev/null

# Guard the most important operational safety rule: PostgreSQL is never restarted.
if rg -q 'systemctl restart (postgresql|"\$POSTGRES_UNIT")' "$ROOT/affinity_tool.sh" 2>/dev/null; then
  echo "PostgreSQL restart found"; exit 1
fi

echo "native DB systemd test: PASS"
