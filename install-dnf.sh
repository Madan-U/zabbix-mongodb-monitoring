#!/usr/bin/env bash
#
# install-dnf.sh - Install Zabbix Agent2 + MongoDB plugin via dnf (root required)
# Target: RHEL / Rocky / Alma 8 (x86_64), Zabbix 7.0 LTS
#
set -euo pipefail

ZBX_SERVER="${ZBX_SERVER:-}"
ZBX_HOSTNAME="${ZBX_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
MONGO_URI="${MONGO_URI:-tcp://localhost:27017}"
MONGO_USER="${MONGO_USER:-zbx_mongodb}"
SESSION_NAME="${SESSION_NAME:-mdb}"
ZBX_MAJOR="${ZBX_MAJOR:-7.0}"
CONF=/etc/zabbix/zabbix_agent2.conf
SESSION_CONF=/etc/zabbix/zabbix_agent2.d/mongodb_session.conf

usage() {
  cat << USAGE
Usage: sudo $0 --server <ZABBIX_SERVER_IP> [options]
  --server    <ip|dns>   Zabbix server / proxy address (required)
  --hostname  <name>     Hostname as registered in Zabbix (default: $ZBX_HOSTNAME)
  --mongo-uri <uri>      MongoDB URI (default: $MONGO_URI)
  --mongo-user <user>    Monitoring user (default: $MONGO_USER)
Password: export ZBX_MONGODB_PASSWORD=... or you will be prompted.
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) ZBX_SERVER="$2"; shift 2 ;;
    --hostname) ZBX_HOSTNAME="$2"; shift 2 ;;
    --mongo-uri) MONGO_URI="$2"; shift 2 ;;
    --mongo-user) MONGO_USER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)."; exit 1; }
[[ -n "$ZBX_SERVER" ]] || { echo "ERROR: --server is required."; usage; }

if [[ -z "${ZBX_MONGODB_PASSWORD:-}" ]]; then
  read -r -s -p "Password for MongoDB user '$MONGO_USER': " ZBX_MONGODB_PASSWORD; echo
fi

set_conf() {  # set_conf <file> <key> <value> : replace key (or uncomment it), else append
  local f="$1" k="$2" v="$3" n
  n=$(grep -En "^${k}=" "$f" | head -1 | cut -d: -f1 || true)
  [[ -z "$n" ]] && n=$(grep -En "^#[[:space:]]*${k}=" "$f" | head -1 | cut -d: -f1 || true)
  if [[ -n "$n" ]]; then sed -i "${n}c\\${k}=${v}" "$f"; else echo "${k}=${v}" >> "$f"; fi
}

echo "[1/5] Configuring Zabbix ${ZBX_MAJOR} repository"
cat > /etc/yum.repos.d/zabbix.repo << REPO
[zabbix]
name=Zabbix ${ZBX_MAJOR} (RHEL 8)
baseurl=https://repo.zabbix.com/zabbix/${ZBX_MAJOR}/rhel/8/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://repo.zabbix.com/RPM-GPG-KEY-ZABBIX-B5333005
REPO

echo "[2/5] Installing packages"
dnf clean all -q
dnf install -y zabbix-agent2 zabbix-agent2-plugin-mongodb

echo "[3/5] Configuring agent"
cp -n "$CONF" "${CONF}.orig"
set_conf "$CONF" Server "$ZBX_SERVER"
set_conf "$CONF" ServerActive "$ZBX_SERVER"
set_conf "$CONF" Hostname "$ZBX_HOSTNAME"

echo "[4/5] Writing MongoDB session config"
umask 077
cat > "$SESSION_CONF" << SESSION
Plugins.MongoDB.Sessions.${SESSION_NAME}.Uri=${MONGO_URI}
Plugins.MongoDB.Sessions.${SESSION_NAME}.User=${MONGO_USER}
Plugins.MongoDB.Sessions.${SESSION_NAME}.Password=${ZBX_MONGODB_PASSWORD}
SESSION
chown root:zabbix "$SESSION_CONF"; chmod 640 "$SESSION_CONF"

echo "[5/5] Enabling and starting service"
systemctl enable --now zabbix-agent2
sleep 2
systemctl --no-pager --lines=0 status zabbix-agent2 || true

echo
echo "Verify : zabbix_agent2 -t 'mongodb.ping[${SESSION_NAME}]'   (expect 1)"
echo "Next   : register host '${ZBX_HOSTNAME}' in Zabbix UI (see docs/SOP.md, section 9)"
