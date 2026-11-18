#!/usr/bin/env bash
#
# install-custom.sh - Rootless Zabbix Agent2 + MongoDB plugin installation
# Extracts the RPMs into a user-owned directory (no sudo, no systemd).
# Target: RHEL / Rocky / Alma 8 (x86_64), Zabbix 7.0 LTS
#
set -euo pipefail

ZBX_VERSION="${ZBX_VERSION:-7.0.30}"
RPM_RELEASE="${RPM_RELEASE:-release1}"
INSTALL_DIR="${INSTALL_DIR:-/opt/zabbix-agent2}"
RPM_DIR="${RPM_DIR:-}"
ZBX_SERVER="${ZBX_SERVER:-}"
ZBX_HOSTNAME="${ZBX_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
MONGO_URI="${MONGO_URI:-tcp://localhost:27017}"
MONGO_USER="${MONGO_USER:-zbx_mongodb}"
SESSION_NAME="${SESSION_NAME:-mdb}"
LOG_SIZE_MB="${LOG_SIZE_MB:-256}"
DOWNLOAD=0; START=0; AUTOSTART=0

usage() {
  cat << USAGE
Usage: $0 --server <ZABBIX_SERVER_IP> [options]
  --server      <ip|dns>  Zabbix server / proxy address (required)
  --hostname    <name>    Hostname as registered in Zabbix (default: $ZBX_HOSTNAME)
  --install-dir <path>    Install base directory (default: $INSTALL_DIR)
  --rpm-dir     <path>    Directory holding the two RPMs (default: install dir)
  --download              Download RPMs from repo.zabbix.com (needs internet)
  --start                 Start the agent after install
  --autostart             Add an @reboot crontab entry
Password: export ZBX_MONGODB_PASSWORD=... or you will be prompted.
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) ZBX_SERVER="$2"; shift 2 ;;
    --hostname) ZBX_HOSTNAME="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --rpm-dir) RPM_DIR="$2"; shift 2 ;;
    --download) DOWNLOAD=1; shift ;;
    --start) START=1; shift ;;
    --autostart) AUTOSTART=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done
[[ -n "$ZBX_SERVER" ]] || { echo "ERROR: --server is required."; usage; }
RPM_DIR="${RPM_DIR:-$INSTALL_DIR}"

for c in rpm2cpio cpio; do
  command -v "$c" > /dev/null || { echo "ERROR: '$c' not found."; exit 1; }
done

BASE_URL="https://repo.zabbix.com/zabbix/${ZBX_VERSION%.*}/rhel/8/x86_64"
AGENT_RPM="zabbix-agent2-${ZBX_VERSION}-${RPM_RELEASE}.el8.x86_64.rpm"
PLUGIN_RPM="zabbix-agent2-plugin-mongodb-${ZBX_VERSION}-${RPM_RELEASE}.el8.x86_64.rpm"
BIN="$INSTALL_DIR/usr/sbin/zabbix_agent2"
PLUGIN="$INSTALL_DIR/usr/sbin/zabbix-agent2-plugin/zabbix-agent2-plugin-mongodb"
CONF="$INSTALL_DIR/etc/zabbix/zabbix_agent2.conf"
CONF_D="$INSTALL_DIR/etc/zabbix/zabbix_agent2.d"

set_conf() {  # set_conf <file> <key> <value>
  local f="$1" k="$2" v="$3" n
  n=$(grep -En "^${k}=" "$f" | head -1 | cut -d: -f1 || true)
  [[ -z "$n" ]] && n=$(grep -En "^#[[:space:]]*${k}=" "$f" | head -1 | cut -d: -f1 || true)
  if [[ -n "$n" ]]; then sed -i "${n}c\\${k}=${v}" "$f"; else echo "${k}=${v}" >> "$f"; fi
}

if [[ -z "${ZBX_MONGODB_PASSWORD:-}" ]]; then
  read -r -s -p "Password for MongoDB user '$MONGO_USER': " ZBX_MONGODB_PASSWORD; echo
fi

echo "[1/6] Preparing directories"
mkdir -p "$INSTALL_DIR"/{logs,run,bin}

echo "[2/6] Obtaining RPMs"
if [[ $DOWNLOAD -eq 1 ]]; then
  curl -fL -o "$RPM_DIR/$AGENT_RPM"  "$BASE_URL/$AGENT_RPM"
  curl -fL -o "$RPM_DIR/$PLUGIN_RPM" "$BASE_URL/$PLUGIN_RPM"
fi
for f in "$AGENT_RPM" "$PLUGIN_RPM"; do
  [[ -f "$RPM_DIR/$f" ]] || { echo "ERROR: $RPM_DIR/$f not found (use --download or --rpm-dir)."; exit 1; }
done

echo "[3/6] Extracting RPMs (no root required)"
cd "$INSTALL_DIR"
rpm2cpio "$RPM_DIR/$AGENT_RPM"  | cpio -idm --quiet
rpm2cpio "$RPM_DIR/$PLUGIN_RPM" | cpio -idm --quiet
chmod +x "$BIN" "$PLUGIN"
"$BIN" --version | head -1

echo "[4/6] Configuring agent"
cp -n "$CONF" "${CONF}.orig"
set_conf "$CONF" PidFile       "$INSTALL_DIR/run/zabbix_agent2.pid"
set_conf "$CONF" LogFile       "$INSTALL_DIR/logs/zabbix_agent2.log"
set_conf "$CONF" LogFileSize   "$LOG_SIZE_MB"
set_conf "$CONF" Server        "$ZBX_SERVER"
set_conf "$CONF" ServerActive  "$ZBX_SERVER"
set_conf "$CONF" Hostname      "$ZBX_HOSTNAME"
set_conf "$CONF" PluginSocket  "$INSTALL_DIR/run/agent.plugin.sock"
set_conf "$CONF" ControlSocket "$INSTALL_DIR/run/agent.sock"
sed -i -E "s|^Include=/etc/zabbix/|Include=${INSTALL_DIR}/etc/zabbix/|" "$CONF"
sed -i -E "s|(System.Path=)/usr/sbin/|\1${INSTALL_DIR}/usr/sbin/|" "$CONF_D/plugins.d/mongodb.conf"

echo "[5/6] Writing MongoDB session config"
( umask 077
  cat > "$CONF_D/mongodb_session.conf" << SESSION
Plugins.MongoDB.Sessions.${SESSION_NAME}.Uri=${MONGO_URI}
Plugins.MongoDB.Sessions.${SESSION_NAME}.User=${MONGO_USER}
Plugins.MongoDB.Sessions.${SESSION_NAME}.Password=${ZBX_MONGODB_PASSWORD}
SESSION
)
chmod 640 "$CONF_D/mongodb_session.conf"

echo "[6/6] Installing helper: $INSTALL_DIR/bin/zbxctl"
cat > "$INSTALL_DIR/bin/zbxctl" << 'CTL'
#!/usr/bin/env bash
BASE="@INSTALL_DIR@"; SESSION="@SESSION@"
BIN="$BASE/usr/sbin/zabbix_agent2"; CONF="$BASE/etc/zabbix/zabbix_agent2.conf"
PID="$BASE/run/zabbix_agent2.pid"; LOG="$BASE/logs/zabbix_agent2.log"
running() { [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; }
case "${1:-}" in
  start)  if running; then echo "already running"; else rm -f "$BASE"/run/*.sock
            nohup "$BIN" -c "$CONF" > /dev/null 2>&1 & sleep 1; echo "started"; fi ;;
  stop)   if running; then kill "$(cat "$PID")" && echo "stopped"; else echo "not running"; fi ;;
  status) if running; then echo "running (PID $(cat "$PID"))"; else echo "not running"; exit 1; fi ;;
  test)   "$BIN" -c "$CONF" -t "mongodb.ping[$SESSION]" ;;
  log)    tail -n "${2:-50}" "$LOG" ;;
  rotate) "$BIN" -c "$CONF" -R log_rotate ;;
  *) echo "Usage: $0 {start|stop|status|test|log [n]|rotate}"; exit 1 ;;
esac
CTL
sed -i "s|@INSTALL_DIR@|${INSTALL_DIR}|; s|@SESSION@|${SESSION_NAME}|" "$INSTALL_DIR/bin/zbxctl"
chmod 750 "$INSTALL_DIR/bin/zbxctl"

add_cron() { local l="$1"; (crontab -l 2>/dev/null | grep -vF "$l" || true; echo "$l") | crontab -; }
add_cron "0 0 * * * $INSTALL_DIR/bin/zbxctl rotate"
[[ $AUTOSTART -eq 1 ]] && add_cron "@reboot $INSTALL_DIR/bin/zbxctl start"
[[ $START -eq 1 ]] && "$INSTALL_DIR/bin/zbxctl" start

echo
echo "Done.  Start : $INSTALL_DIR/bin/zbxctl start"
echo "       Test  : $INSTALL_DIR/bin/zbxctl test   (expect 1)"
echo "       Next  : register host '${ZBX_HOSTNAME}' in Zabbix UI (docs/SOP.md, section 9)"
