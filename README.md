# Ameyo Global Affinity Tool

One script for **any** host: different CPU counts, roles, and OS (CentOS / RHEL / Rocky).

Dry-run by default. Safe to run with `--detect` on any box.

## What it does

1. Detects OS + grub style (legacy CentOS6 `grub.conf` vs grub2 / Rocky / RHEL)
2. Builds CPU map from sysfs (with `/proc/cpuinfo` fallback), grouping arbitrary
   package/core IDs and HT sibling layouts
3. Finds IRQs for ethernet / disk / telephony
4. Detects a safe role when requested and plans a workload-aware layout
5. Optionally applies:
   - grub `default_affinity`
   - `/dacx/affinitySetter.sh` + boot persistence
   - Merges role-specific rows into Ameyo `serviceCPUAffinityConf.csv` or
     `affinity.cfg` while preserving unrelated service rows
   - disables `irqbalance`
   - on dedicated DB hosts, keeps an existing Ameyo CSV/cfg authoritative for
     PostgreSQL and DAGENT while always pinning DJINN through systemd; direct
     PostgreSQL systemd management is used only when CSV/cfg is absent

## Quick start (on the Linux server)

```bash
# Copy this folder to the server, then:
cd ameyo-affinity-tool
chmod +x affinity_tool.sh

# 1) See what the box looks like
sudo ./affinity_tool.sh --detect

# 2) Plan only (no changes)
sudo ./affinity_tool.sh --role single          # or: appdb | call

# Or safely infer the role from active services (hostname is only a fallback)
sudo ./affinity_tool.sh

# 3) Apply
sudo ./affinity_tool.sh --role single --apply

# 4) After reboot (grub), verify against the same explicit plan
sudo ./affinity_tool.sh --verify --role single
```

## Roles

| Role | Use when |
|------|----------|
| `single` | APP + DB + ACP + Asterisk on one server |
| `appdb` | APP + DB + ACP (no Asterisk) |
| `app` | Dedicated APP server |
| `db` | Dedicated DB (Postgres) |
| `report` | Dedicated reports / archiver / voicelogs |
| `asap` | Dedicated ASAP / ACP |
| `call` | Call server (Asterisk ± telephony) |
| `custom` | Your own `profiles/*.conf` |
| `auto` | Infer from unambiguous active-service evidence, then hostname hints |

On **exactly 4 physical cores** + `single`, the plan matches the Ameyo doc Case 1 (tools/dagent=0, db=1, server/acp=2, asterisk=3).

Dedicated APP, DB, REPORT, ASAP, and ACP workloads use their full post-system/
IRQ service pool. CRM and DAGENT use computed subsets of that same pool. These
sets intentionally overlap: they are allowed CPU sets, not exclusive
partitions. ASTERISK13 is managed only by the `call` role; the older `ASTERISK`
row is left untouched.

## Intelligent sizing

All counts below are **physical service cores**. On HT systems the selected
core's logical siblings are added to service CPU lists; IRQs stay on primary
threads. Every result is clamped to the available service pool.

- DAGENT: `ceil(service_cores × 15%)`, minimum 2, maximum 3. A one-core
  service pool necessarily clamps to one.
- CRM without `--active-agents`: `ceil(service_cores × 35%)`, minimum 2,
  maximum 5. This normally gives 4–5 cores on a 16-physical-core host after
  system/IRQ reservations.
- CRM with `--active-agents N`: `ceil(N / 75)`, minimum 2, maximum 5.
- ASTERISK13: `ceil(concurrent_calls / 100)`, minimum 2. If
  `--concurrent-calls` is omitted, the safe default is 500 calls (five cores
  when available); there is no fixed maximum beyond the service pool.
- APP/APPSERVER, DB/POSTGRESQL, report services, ASAP, and ACP: full service
  pool.

Examples:

```bash
# 800 calls -> 8 physical ASTERISK13 cores, or all available if fewer
sudo ./affinity_tool.sh --role call --concurrent-calls 800

# 300 active agents -> 4 CRM cores; APPSERVER still gets the full pool
sudo ./affinity_tool.sh --role app --active-agents 300

# Omitted inputs print the defaults and exact calculation in the plan
sudo ./affinity_tool.sh --role report
```

## Safe automatic role detection

Omitting `--role`, or using `--role auto`, applies this priority:

1. An explicit non-auto `--role` always wins.
2. Unambiguous active process/systemd evidence selects `single`, `appdb`,
   `app`, `db`, `report`, `asap`, or `call`.
3. If there is no active-service match, conservative hostname forms such as
   `PAPP/SAPP`, `PDB/SDB`, `PREPORT/SREPORT`, `PCS/SCS`, and `PASAP/SASAP`
   may select a role.

The installed service affinity CSV is never role evidence because generic
installs commonly list every service. If evidence is absent or conflicting, a
dry-run explains the candidates and stops without a plan. `--apply` fails
closed and asks for an explicit role.

## Batch all servers (primary + secondary)

Use `affinity_batch.sh` from a jump host that has SSH key access to every node.

BLR inventory is already mapped:

| Pair | Hosts | Role |
|------|-------|------|
| APP | BLR-PAPP / BLR-SAPP | `app` |
| DB | BLR-PDB / BLR-SDB | `db` |
| REPORT | BLR-PREPORT / BLR-SREPORT | `report` |
| CS | BLR-PCS / BLR-SCS | `call` |
| ASAP | BLR-PASAP / BLR-SASAP | `asap` |

```bash
# On jump host (copy this repo first)
chmod +x affinity_tool.sh affinity_batch.sh install.sh

# 1) Plan all 10 (no changes)
./affinity_batch.sh --inventory inventory/blr-servers.csv

# 2) Apply one pair at a time (secondary first, then primary)
./affinity_batch.sh --pair APP --apply

# 3) One host only
./affinity_batch.sh --host BLR-PCS --concurrent-calls 800 --apply

# 4) After reboot — verify all
./affinity_batch.sh --verify

# Continue only after checking the completed pair
./affinity_batch.sh --pair DB --apply
```

SSH user defaults to `root`. Override with `--user ameyo` or `SSH_USER=ameyo`.

Primary and secondary in each pair get the **same role** so failover affinity matches.
Inventory roles remain explicit and are never replaced by auto detection.
`--concurrent-calls` and `--active-agents` can be passed through batch runs;
only services managed by each inventory role use the relevant input.
Batch verification passes each inventory role and both workload inputs to the
remote tool, so it regenerates the exact expected plan instead of sampling
arbitrary live state.
Production apply requires either `--host` or `--pair`; parallel apply is
rejected. Pair apply stops immediately if the secondary fails, so the primary
is not changed after a partial rollout.

## OS support

| OS | Grub handling |
|----|----------------|
| CentOS 6 / old AmeyOS | `/etc/grub.conf` |
| CentOS 7+, RHEL 7+, Rocky 8/9 | `/etc/default/grub` + `grub2-mkconfig`, or direct `/boot/grub2/grub.cfg` |

Detection and dry-run work without an Ameyo tree. Apply is fail-closed: an
existing writable `serviceCPUAffinityConf.csv` or `affinity.cfg` must be found
before irqbalance, grub, or IRQ state is changed, except for explicit `db`
role when exactly one active, loaded `postgresql*.service` and an active,
loaded `djinn.service` are available. Dedicated DB apply requires those units
even when CSV/cfg exists. Other roles do not acquire this requirement. The tool
never creates a guessed affinity file.

## Dedicated DB hybrid/native runbook

On a dedicated DB server, use:

```bash
sudo ./affinity_tool.sh --role db
sudo ./affinity_tool.sh --role db --apply
sudo ./affinity_tool.sh --verify --role db
```

An existing `serviceCPUAffinityConf.csv` (preferred) or `affinity.cfg` remains
the authority for PostgreSQL and DAGENT. Only those two DB rows are merged;
unrelated generic rows are preserved and ignored during DB verification.
DJINN independently receives the DAGENT CPU subset through the tool-owned
systemd drop-in. After both files are ready, systemd is reloaded and DJINN is
restarted exactly once. PostgreSQL is not restarted; its live unit tasks must
show the full service-pool affinity applied by DJINN/Ameyo.

When neither CSV nor cfg exists, the native fallback manages both PostgreSQL
and DJINN with systemd drop-ins. The backend rejects zero or multiple active
`postgresql*.service` units rather
than guessing (for example, production may resolve to
`postgresql-14.service`). It writes tool-managed drop-ins named
`90-ameyo-affinity.conf` below `/etc/systemd/system/<unit>.d/`, backing up an
existing managed file before atomic replacement. PostgreSQL receives the full
computed DB service pool; DJINN and DAGENT receive the dynamic DAGENT subset.
In native fallback, every current PostgreSQL cgroup task is updated and
verified immediately. PostgreSQL is never restarted. DJINN is updated,
restarted once, and required to
return active with a persistent MainPID; exact DAGENT processes are then
checked for DJINN cgroup membership and inherited affinity. A missing DAGENT is
informational on a passive DB.

This backend assumes only DJINN/DAGENT are launched in `djinn.service`, as in
the verified dedicated-DB architecture. Because systemd CPU affinity is
inherited, any other child launched there would receive the same restricted
set. PostgreSQL is widened independently through its own unit.

## Custom profile

```bash
sudo ./affinity_tool.sh --role custom --profile profiles/custom.example.conf --apply
```

Or override a built-in role:

```bash
sudo ./affinity_tool.sh --role single --profile profiles/single-4core.conf --apply
```

Profile keys: `tools`, `dagent`, `database`, `server`, `acp`, `asterisk`, `ameyoreports`, `ameyoarchiver`, `ameyo_voicelogs_conversion`, `irq_disk`, `irq_ethernet`, `irq_telephony`.

## Failover

Run the **same role + profile** on every node in a pair so affinity matches.

## Install everywhere (optional)

```bash
sudo mkdir -p /opt/ameyo-affinity-tool
sudo cp -a affinity_tool.sh profiles /opt/ameyo-affinity-tool/
sudo ln -sf /opt/ameyo-affinity-tool/affinity_tool.sh /usr/local/sbin/affinity-tool

# then from any server:
sudo affinity-tool --role call --apply
```

## Troubleshooting

**`/usr/bin/env: 'bash\r': No such file or directory`**

The files were copied with Windows line endings. Fix on the server:

```bash
sed -i 's/\r$//' affinity_tool.sh affinity_batch.sh install.sh profiles/*.conf inventory/*.csv
chmod +x affinity_tool.sh affinity_batch.sh install.sh
```

(Repo now ships `.gitattributes` forcing LF, so fresh clones are fine. Avoid copy-pasting through Windows editors.)

## Safety

- Default is **dry-run** (prints plan only)
- Backs up grub / CSV / cfg with timestamp before write
- Existing affinity configuration is merged, not replaced
- Modern CSV output keeps Ameyo's semicolon CPU delimiter and has no header
- CS/call updates `ASTERISK13` only and preserves the existing `ASTERISK` row
- ASAP roles update both `ACP` and `ASAP`
- CSV/cfg roles restart DJINN after an atomic successful merge. For `db`, the
  CSV/cfg and DJINN drop-in are prepared before one centralized restart; the
  native fallback also performs only that restart. DJINN and exact DAGENT
  processes must inherit the subset, while PostgreSQL must have the full pool.
- All discovered IRQ writes are attempted. A rejected write is accepted only
  when its error is consistent with a kernel-managed IRQ (for example EIO,
  EINVAL, EBUSY, or EOPNOTSUPP) and its effective/current affinity is a valid,
  nonempty one-hot CPU mask. Debugfs managed-affinity flags strengthen the
  evidence when mounted but are not required. These vectors are preserved and
  reported as `MANAGED/SKIP`; writable control vectors remain pinned normally.
  Permission denied, read-only/missing paths, malformed masks, unrestricted
  masks, and all other unexplained errors remain fatal and are aggregated.
- Boot persistence stores CPU pools, not IRQ numbers. At each boot it
  rediscovers NIC, disk, and telephony IRQs and round-robins current queues over
  those pools. It records successful/managed outcomes by IRQ class and action
  name (not IRQ number), so verification remains valid after IRQ renumbering.
  The persistence unit is installed or enabled only after the immediate IRQ
  pass contains exclusively applied or validated-managed outcomes. Systemd runs it after `local-fs.target` and
  `network-online.target`; failures are visible on
  `ameyo-affinity-irq.service` in the journal. `rc.local` is only a fallback on
  systems without systemd.
- Logs under `/var/tmp/affinity-tool/`
- Reboot needed once for grub `default_affinity`

### Recovering a partial apply

If an older tool stopped after writable vectors were pinned but rejected
kernel-managed MSI-X vectors, deploy this version and rerun the same explicit
role with `--apply`; no reboot is required before rerunning. The operation is
idempotent: it rediscovers current IRQs, reapplies writable vectors, validates
managed vectors, installs persistence only after that pass succeeds, then
merges the service CSV/config and restarts DJINN. Reboot afterward only to
activate a changed grub `default_affinity`.

If the rerun reports a genuine IRQ failure, persistence is not newly enabled,
the service merge and DJINN restart do not run, and the batch command does not
advertise reboot. Correct the reported path/permission/format or unexpected
kernel error and rerun.

## Pair rollout and verification

Apply the secondary first and review it before allowing the batch command to
continue to the primary. For PDB, PASAP, and PREPORT especially, run detection
or a dry-run first to confirm which existing affinity path is selected.

After each host, verify:

```bash
# Preferred: regenerate and compare the full expected plan. Reuse workload
# inputs from apply when they were supplied.
sudo ./affinity_tool.sh --verify --role app --active-agents 300

# Merged file: unrelated rows retained; managed rows use semicolon CPU lists
sudo grep -E '^(APPSERVER|POSTGRESQL|AMEYOREPORTS|AMEYOARCHIVER|AMEYO_VOICELOGS_CONVERSION|CRM|DAGENT|ASTERISK13|ASAP|ACP),' \
  /dacx/var/ameyo/dacxdata/etc/djinn/serviceCPUAffinityConf.csv

# Managed processes and IRQs
sudo taskset -cp <managed-service-pid>
cat /proc/irq/<irq>/smp_affinity
systemctl is-enabled irqbalance

# Native DB verification requires active djinn.service with a persistent
# MainPID. CSV/cfg-backed legacy roles retain their existing service behavior.
systemctl status djinn.service
systemctl status ameyo-affinity-irq.service
journalctl -u ameyo-affinity-irq.service

# After the planned reboot
grep -o 'default_affinity=[^ ]*' /proc/cmdline
cat /proc/irq/default_smp_affinity
```

Verification checks every currently discovered planned IRQ, requested and
effective masks, and reports validated kernel-managed vectors distinctly.
Managed acceptance requires matching persisted class/action evidence from a
successful apply (surviving IRQ renumbering) or a readable kernel managed flag,
plus a one-hot live assignment; an arbitrary one-hot mismatch is still a
failure. Verification also checks all managed CSV rows and delimiters, relevant service process
affinity when a reliable process match exists, `default_affinity`, irqbalance,
and persistence-unit failure. Missing expected processes are reported as
`not-running`; they are informational because standby services may legitimately
be stopped. Actionable mismatches return nonzero. Bare `--verify` remains
available: it attempts safe role detection and clearly reports when expected
plan comparison was skipped.

## Manual checklist (if you only want the plan)

```bash
sudo ./affinity_tool.sh --role <role>     # copy the printed PLAN into the change ticket
```
