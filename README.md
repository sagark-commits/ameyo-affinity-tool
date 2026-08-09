# Ameyo Global Affinity Tool

One script for **any** host: different CPU counts, roles, and OS (CentOS / RHEL / Rocky).

Dry-run by default. Safe to run with `--detect` on any box.

## What it does

1. Detects OS + grub style (legacy CentOS6 `grub.conf` vs grub2 / Rocky / RHEL)
2. Builds CPU map from `/proc/cpuinfo` (no `cpuspecification.py` required; HT-aware)
3. Finds IRQs for ethernet / disk / telephony
4. Plans core layout from **role** (scales with CPU count)
5. Optionally applies:
   - grub `default_affinity`
   - `/dacx/affinitySetter.sh` + boot persistence
   - Ameyo `serviceCPUAffinityConf.csv` or `affinity.cfg`
   - disables `irqbalance`

## Quick start (on the Linux server)

```bash
# Copy this folder to the server, then:
cd ameyo-affinity-tool
chmod +x affinity_tool.sh

# 1) See what the box looks like
sudo ./affinity_tool.sh --detect

# 2) Plan only (no changes)
sudo ./affinity_tool.sh --role single          # or: appdb | call

# 3) Apply
sudo ./affinity_tool.sh --role single --apply

# 4) After reboot (grub), verify
sudo ./affinity_tool.sh --verify
```

## Roles

| Role | Use when |
|------|----------|
| `single` | APP + DB + ACP + Asterisk on one server |
| `appdb` | APP + DB + ACP (no Asterisk) |
| `call` | Call server (Asterisk ± telephony) |
| `custom` | Your own `profiles/*.conf` |

On **exactly 4 physical cores** + `single`, the plan matches the Ameyo doc Case 1 (tools/dagent=0, db=1, server/acp=2, asterisk=3).

On larger boxes it auto-scales: more cores → Postgres gets ~40% of free pool, app next, Asterisk 1–2 cores (tied to telephony IRQ when present).

## OS support

| OS | Grub handling |
|----|----------------|
| CentOS 6 / old AmeyOS | `/etc/grub.conf` |
| CentOS 7+, RHEL 7+, Rocky 8/9 | `/etc/default/grub` + `grub2-mkconfig`, or direct `/boot/grub2/grub.cfg` |

Works with or without an Ameyo `/dacx` tree (IRQ + grub still apply).

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

## Safety

- Default is **dry-run** (prints plan only)
- Backs up grub / CSV / cfg with timestamp before write
- Logs under `/var/tmp/affinity-tool/`
- Reboot needed once for grub `default_affinity`

## Manual checklist (if you only want the plan)

```bash
sudo ./affinity_tool.sh --role <role>     # copy the printed PLAN into the change ticket
```
