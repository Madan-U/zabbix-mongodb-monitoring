# SOP: Zabbix Agent2 Installation for MongoDB Monitoring

**Version:** 3.0 | **OS:** RHEL 8.x (x86_64) | **Zabbix:** 7.0.30

> **Naming note:** "Zabbix Agent" here means **Agent2**. File, binary and config names keep the `agent2` suffix; do not rename or alias them.

**Placeholders used in this document**

| Placeholder | Meaning |
|---|---|
| `<INSTALL_DIR>` | Base directory for the rootless install, e.g. `/path/to/zabbix-agent2` |
| `<ZABBIX_SERVER_IP>` | Zabbix server / proxy address |
| `<HOSTNAME>` | Host name registered in Zabbix |
| `<ZBX_MONGODB_PASSWORD>` | Password of the monitoring user |

## Table of contents
1. [Concepts](#1-concepts) 2. [MongoDB plugin](#2-mongodb-plugin) 3. [Monitoring user](#3-mongodb-monitoring-user) 4. [Prerequisites](#4-prerequisites) 5. [Method A: dnf](#5-method-a-dnf-install-root) 6. [Method B: rootless](#6-method-b-rootless-install) 7. [Directory layout](#7-directory-layout-method-b) 8. [Log rotation](#8-log-rotation) 9. [Register host](#9-register-host-in-zabbix) 10. [Checklist](#10-checklist) 11. [Troubleshooting](#11-troubleshooting)

---

## 1. Concepts

**Zabbix Agent2** is a lightweight daemon on the monitored server. It collects OS metrics natively and MongoDB metrics through a plugin, and reports to the Zabbix server.

**Why Agent2, not Agent (v1)?** v1 only monitors OS-level metrics. Agent2 supports external plugins (MongoDB, MySQL, Redis, Oracle, ...). MongoDB monitoring requires Agent2.

| Responsibility | Description |
|---|---|
| Passive checks | Listens on **10050**; the server pulls values |
| Active checks | Connects to server on **10051** and pushes values |
| OS metrics | CPU, memory, disk, network, processes (built in) |
| Plugin management | Starts plugin processes, communicates via Unix socket |
| Logging | Startup, errors, connections, collection activity |

```
Zabbix Server ─ 10050 (passive) / 10051 (active) ─► Agent2 ─ Unix socket ─► MongoDB plugin ─ TCP 27017 ─► MongoDB
```

## 2. MongoDB plugin

`zabbix-agent2-plugin-mongodb` is a **separate binary** launched by the agent. A plugin crash does not crash the agent, plugins can be updated independently, and only needed plugins are installed.

| Category | Metrics |
|---|---|
| Availability | Ping, response time |
| Connections | Current, available, total created |
| Operations | Reads/writes/updates/deletes/commands per second |
| Memory | RSS, virtual, mapped |
| Storage | Data, storage and index size per database |
| Replication | Member state, lag, oplog window |
| WiredTiger | Cache hit ratio, dirty bytes, checkpoint time |
| Cursors / Network | Open and timed-out cursors; bytes in/out, requests |

## 3. MongoDB monitoring user

`zbx_mongodb` is a dedicated **read-only** account with the `clusterMonitor` role. A dedicated account limits exposure if the session config file leaks.

| Permission | Allowed |
|---|---|
| `serverStatus`, `replSetGetStatus`, `dbStats`, `collStats` | ✅ |
| Read application data | ❌ |
| Insert / update / delete | ❌ |
| Create/drop databases, manage users, shut down | ❌ |

Check if it exists:
```bash
mongosh --port 27017 -u <ADMIN_USER> -p --authenticationDatabase admin \
  --eval "db.getSiblingDB('admin').getUsers()" --quiet
```

Create it (only if missing):
```javascript
use admin
db.createUser({
  user: "zbx_mongodb",
  pwd: "<STRONG_PASSWORD>",
  roles: [{ role: "clusterMonitor", db: "admin" }]
})
db.getUser("zbx_mongodb")   // verify
```

## 4. Prerequisites

| Item | Requirement |
|---|---|
| OS | RHEL 8.x x86_64 (Rocky / Alma compatible) |
| MongoDB | Port 27017, authentication enabled |
| Firewall | TCP 10050 and 10051 between DB host and Zabbix server |
| Method A | root / sudo, access to `repo.zabbix.com` |
| Method B | No root, no internet on the DB host (RPMs copied in or `--download`) |

---

## 5. Method A: dnf install (root)

Script: [`scripts/install-dnf.sh`](../scripts/install-dnf.sh)

```bash
export ZBX_MONGODB_PASSWORD='<ZBX_MONGODB_PASSWORD>'
sudo -E ./scripts/install-dnf.sh --server <ZABBIX_SERVER_IP> --hostname <HOSTNAME>
```

What it does:
1. Adds the Zabbix 7.0 repository (GPG check on).
2. Installs `zabbix-agent2` and `zabbix-agent2-plugin-mongodb`.
3. Sets `Server`, `ServerActive`, `Hostname` in `/etc/zabbix/zabbix_agent2.conf` (original saved as `.orig`).
4. Writes `/etc/zabbix/zabbix_agent2.d/mongodb_session.conf` (`root:zabbix`, mode `640`).
5. Enables and starts `zabbix-agent2` via systemd.

Verify:
```bash
systemctl status zabbix-agent2
zabbix_agent2 -t 'mongodb.ping[mdb]'    # expect [s|1.000000]
tail -50 /var/log/zabbix/zabbix_agent2.log
```

## 6. Method B: rootless install

Script: [`scripts/install-custom.sh`](../scripts/install-custom.sh)

```bash
export ZBX_MONGODB_PASSWORD='<ZBX_MONGODB_PASSWORD>'
./scripts/install-custom.sh --server <ZABBIX_SERVER_IP> \
  --install-dir <INSTALL_DIR> --rpm-dir /path/to/rpms --start --autostart
```

### 6.1 Manual steps (what the script automates)

**Download** (on a workstation with internet):
```bash
curl -LO "https://repo.zabbix.com/zabbix/7.0/rhel/8/x86_64/zabbix-agent2-7.0.30-release1.el8.x86_64.rpm"
curl -LO "https://repo.zabbix.com/zabbix/7.0/rhel/8/x86_64/zabbix-agent2-plugin-mongodb-7.0.30-release1.el8.x86_64.rpm"
scp zabbix-agent2-*.rpm <USER>@<DB_HOST>:<INSTALL_DIR>/
```

**Extract** (equivalent to unzipping; no root):
```bash
cd <INSTALL_DIR>
rpm2cpio zabbix-agent2-7.0.30-release1.el8.x86_64.rpm | cpio -idmv
rpm2cpio zabbix-agent2-plugin-mongodb-7.0.30-release1.el8.x86_64.rpm | cpio -idmv
chmod +x usr/sbin/zabbix_agent2 usr/sbin/zabbix-agent2-plugin/zabbix-agent2-plugin-mongodb
mkdir -p logs run
usr/sbin/zabbix_agent2 --version      # zabbix_agent2 (Zabbix) 7.0.30
```

**Main config** `<INSTALL_DIR>/etc/zabbix/zabbix_agent2.conf`:
```ini
PidFile=<INSTALL_DIR>/run/zabbix_agent2.pid
LogFile=<INSTALL_DIR>/logs/zabbix_agent2.log
LogFileSize=256
Server=<ZABBIX_SERVER_IP>
ServerActive=<ZABBIX_SERVER_IP>
Hostname=<HOSTNAME>
PluginSocket=<INSTALL_DIR>/run/agent.plugin.sock
ControlSocket=<INSTALL_DIR>/run/agent.sock
Include=<INSTALL_DIR>/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
Include=<INSTALL_DIR>/etc/zabbix/zabbix_agent2.d/*.conf
```

**Plugin path** `zabbix_agent2.d/plugins.d/mongodb.conf`:
```ini
Plugins.MongoDB.System.Path=<INSTALL_DIR>/usr/sbin/zabbix-agent2-plugin/zabbix-agent2-plugin-mongodb
```

**Session** `zabbix_agent2.d/mongodb_session.conf` (mode `640`):
```ini
Plugins.MongoDB.Sessions.mdb.Uri=tcp://localhost:27017
Plugins.MongoDB.Sessions.mdb.User=zbx_mongodb
Plugins.MongoDB.Sessions.mdb.Password=<ZBX_MONGODB_PASSWORD>
```
The session name `mdb` must match the host macro `{$MONGODB.CONNSTRING}=mdb`.

### 6.2 Operating the agent: `zbxctl`

| Command | Action |
|---|---|
| `zbxctl start` | Start in background (clears stale sockets) |
| `zbxctl stop` | Stop using the PID file |
| `zbxctl status` | Show running state |
| `zbxctl test` | `mongodb.ping[mdb]`, returns `1` if OK |
| `zbxctl log [n]` | Last *n* log lines (default 50) |
| `zbxctl rotate` | Rotate log now |

Auto-start without systemd (`--autostart` adds this):
```bash
(crontab -l 2>/dev/null; echo "@reboot <INSTALL_DIR>/bin/zbxctl start") | crontab -
```

## 7. Directory layout (Method B)

```
<INSTALL_DIR>/
├── bin/zbxctl                          # helper (generated)
├── usr/sbin/
│   ├── zabbix_agent2                   # agent daemon
│   └── zabbix-agent2-plugin/zabbix-agent2-plugin-mongodb
├── etc/zabbix/
│   ├── zabbix_agent2.conf              # main config
│   └── zabbix_agent2.d/
│       ├── plugins.d/mongodb.conf      # plugin binary path (critical)
│       └── mongodb_session.conf        # credentials, keep at 640
├── logs/zabbix_agent2.log
└── run/  zabbix_agent2.pid, agent.plugin.sock, agent.sock
```

| Path | Purpose |
|---|---|
| `zabbix_agent2` | Listens on 10050, pushes to 10051, collects OS metrics, launches plugins |
| `zabbix-agent2-plugin-mongodb` | Runs `serverStatus`, `dbStats`, etc. against MongoDB and returns values to the agent |
| `zabbix_agent2.conf` | Server address, hostname, log/pid/socket paths, Include directives |
| `plugins.d/mongodb.conf` | Tells the agent where the plugin binary is; wrong path ⇒ all MongoDB items fail |
| `plugins.d/*` (ceph, docker, redis, ...) | Defaults from the package; unused and harmless |
| `mongodb_session.conf` | Session `mdb`: URI, user, password. Contains credentials |
| `zabbix_agent2.pid` | PID used by `zbxctl stop` |
| `agent.plugin.sock` | Agent ⇄ plugin IPC. A leftover file after a crash is stale |
| `agent.sock` | Control socket for runtime commands (`-R log_rotate`, log level) |

## 8. Log rotation

- **Size-based:** `LogFileSize=256` (MB). At the limit the log becomes `zabbix_agent2.log.old` and a new one starts (max ≈ 512 MB).
- **Daily:** cron at midnight (added by the script):
  ```bash
  0 0 * * * <INSTALL_DIR>/bin/zbxctl rotate
  ```
- **Manual:** `zbxctl rotate`, or `zabbix_agent2 -c <conf> -R log_rotate`

(Method A uses the package's logrotate configuration.)

## 9. Register host in Zabbix

**Configuration → Hosts → Create host**

| Tab | Field | Value |
|---|---|---|
| Host | Host name | Exactly the agent's `Hostname=` |
| Host | Interface | Agent, `<DB_HOST_IP>`, port `10050` |
| Templates | Template | `MongoDB node by Zabbix agent 2` |
| Macros | `{$MONGODB.CONNSTRING}` | `mdb` |

Data appears under **Monitoring → Latest data** within 1-2 minutes.
Until the host is registered, the log shows `host [<hostname>] not found`, which is expected.

## 10. Checklist

| # | Task | Verify |
|---|---|---|
| 1 | Monitoring user exists | `db.getUser("zbx_mongodb")` |
| 2 | Agent installed | `zabbix_agent2 --version` |
| 3 | Server / Hostname set | `grep -E '^(Server\|ServerActive\|Hostname)=' <conf>` |
| 4 | Plugin path correct | `grep System.Path plugins.d/mongodb.conf` |
| 5 | Session file mode 640 | `ls -l mongodb_session.conf` |
| 6 | Agent running | `systemctl status zabbix-agent2` / `zbxctl status` |
| 7 | MongoDB ping = 1 | `zabbix_agent2 -t 'mongodb.ping[mdb]'` / `zbxctl test` |
| 8 | Host added in Zabbix UI | Latest data populated |
| 9 | Auto-start configured | systemd enabled / `crontab -l` |
| 10 | Log rotation configured | `LogFileSize`, cron entry |

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot include "...": no such file or directory` | Config still has `/etc/zabbix/` Include paths | Re-run installer or fix `Include=` lines |
| `mongodb.ping[mdb]` returns `0` / error | Wrong credentials or user missing | Check user in MongoDB and the session file |
| `host [<hostname>] not found` | Host not registered | See section 9 |
| `ZBX_NOTSUPPORTED` on MongoDB items | Plugin path wrong | Fix `Plugins.MongoDB.System.Path` |
| Agent not in `ps` | Crashed / not started | Start it, then read the log |
| Agent stops after logout | Started from a plain shell | Use `zbxctl start` (nohup) plus `@reboot` cron |
| Stale socket error | Unclean shutdown | `rm <INSTALL_DIR>/run/agent.plugin.sock`, then start (`zbxctl start` does this) |
| dnf installs a different `zabbix-agent2` | EPEL package shadows Zabbix repo | Add `excludepkgs=zabbix*` to the EPEL repo definition |

---
*End of SOP*
