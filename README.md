# Zabbix Agent2 for MongoDB Monitoring

Production-ready installation guide and scripts to monitor MongoDB with **Zabbix Agent2** and the **MongoDB plugin** on RHEL 8 family systems.

| | |
|---|---|
| **OS** | RHEL / Rocky / AlmaLinux 8 (x86_64) |
| **Zabbix** | 7.0 LTS (tested with 7.0.30) |
| **Template** | `MongoDB node by Zabbix agent 2` |

## Architecture

```
Zabbix Server ──(10050 passive / 10051 active)──► Zabbix Agent2
                                                       │ Unix socket
                                                       ▼
                                                MongoDB plugin ──TCP 27017──► MongoDB
                                                                         (zbx_mongodb, clusterMonitor)
```

## Repository layout

```
.
├── README.md
├── docs/SOP.md                        # Full procedure, concepts, troubleshooting
├── scripts/
│   ├── install-dnf.sh                 # Method 1: package install via dnf (root)
│   └── install-custom.sh              # Method 2: rootless install from RPMs
└── config/mongodb_session.conf.example
```

## Choose an installation method

| | `install-dnf.sh` | `install-custom.sh` |
|---|---|---|
| Needs root / sudo | Yes | **No** |
| Needs internet on DB host | Yes (Zabbix repo) | No (copy RPMs) or `--download` |
| Service management | systemd | `zbxctl` helper + cron |
| Install path | `/usr`, `/etc/zabbix` | Any user-owned dir (default `/opt/zabbix-agent2`) |
| Best for | Standard servers | Restricted / no-sudo environments |

## Prerequisites

1. MongoDB auth enabled, with a monitoring user (see [SOP §3](docs/SOP.md#3-mongodb-monitoring-user)):
   ```javascript
   use admin
   db.createUser({ user: "zbx_mongodb", pwd: "<STRONG_PASSWORD>",
                   roles: [{ role: "clusterMonitor", db: "admin" }] })
   ```
2. Network: TCP 10050 / 10051 open between the DB host and the Zabbix server.

## Quick start

### Method 1: dnf (root)

```bash
export ZBX_MONGODB_PASSWORD='<ZBX_MONGODB_PASSWORD>'
sudo -E ./scripts/install-dnf.sh --server <ZABBIX_SERVER_IP> --hostname <HOST_NAME_IN_ZABBIX>
```

### Method 2: custom / rootless

```bash
export ZBX_MONGODB_PASSWORD='<ZBX_MONGODB_PASSWORD>'

# RPMs already copied to /path/to/rpms
./scripts/install-custom.sh --server <ZABBIX_SERVER_IP> \
    --install-dir /path/to/zabbix-agent2 --rpm-dir /path/to/rpms --start --autostart

# or let the script download them
./scripts/install-custom.sh --server <ZABBIX_SERVER_IP> --install-dir /path/to/zabbix-agent2 --download --start --autostart
```

Helper commands (custom method): `zbxctl {start|stop|status|test|log|rotate}`

## Verify

```bash
zabbix_agent2 -t 'mongodb.ping[mdb]'        # dnf method
/path/to/zabbix-agent2/bin/zbxctl test      # custom method
# expected: mongodb.ping[mdb]   [s|1.000000]
```

## Register the host in Zabbix

Create host → Interface *Agent* `<DB_HOST_IP>:10050` → Template `MongoDB node by Zabbix agent 2` → Macro `{$MONGODB.CONNSTRING} = mdb`.
The host name must match `Hostname=` in the agent config.

## Security notes

- Use a dedicated read-only `clusterMonitor` user, never an admin account.
- The session file holds credentials: mode `640`, never commit it (`.gitignore` already excludes it).
- Pass the password via `ZBX_MONGODB_PASSWORD` or the prompt, not command-line arguments.

## Documentation

Full procedure, file-by-file explanation, log rotation and troubleshooting: **[docs/SOP.md](docs/SOP.md)**.
