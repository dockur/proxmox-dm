#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${DEBUG:="N"}"             # Enable debugging
: "${PASSWORD:="root"}"       # Default password
: "${POSTFIX:="Y"}"           # Start Postfix for mails
: "${RELAY_HOST:="ext.home.local"}"

# Helper functions
info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

is_enabled() {
  case "${1:-}" in
    Y|y|YES|yes|TRUE|true|1|ON|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Required command not found: $1"
    exit 21
  }
}

ensure_dir() {
  local dir="$1"
  local mode="${2:-}"
  local owner="${3:-}"

  mkdir -p "$dir"

  if [ -n "$mode" ]; then
    chmod "$mode" "$dir" || :
  fi

  if [ -n "$owner" ]; then
    chown "$owner" "$dir" || :
  fi
}

process_alive() {
  local pid="${1:-}"

  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

wait_process_alive() {
  local pid="${1:-}"
  local name="${2:-process}"
  local seconds="${3:-1}"

  sleep "$seconds"

  if ! process_alive "$pid"; then
    warn "$name exited shortly after startup."
    return 1
  fi

  return 0
}

wait_socket() {
  local sock="$1"
  local pid="$2"
  local name="$3"
  local seconds="$4"
  local i

  for i in $(seq 1 "$seconds"); do
    [[ -S "$sock" ]] && return 0

    if ! process_alive "$pid"; then
      warn "$name exited before creating socket."
      cleanup
    fi

    info "Waiting for $name socket ($i/$seconds)..."
    sleep 1
  done

  return 1
}

wait_port() {
  local pattern="$1"
  local seconds="$2"
  local message="$3"

  for _ in $(seq 1 "$seconds"); do
    if ss -ltn | grep -q "$pattern"; then
      return 0
    fi
    sleep 1
  done

  warn "$message"
  return 1
}

read_pidfile() {
  local file

  for file; do
    if [ -f "$file" ]; then
      read -r REPLY < "$file"
      [ -n "${REPLY:-}" ] && return 0
    fi
  done

  REPLY=""
  return 1
}

safe_tmpfs_mount() {
  local target="$1"

  mkdir -p "$target"

  if mountpoint -q "$target"; then
    return 0
  fi

  if ! mount -t tmpfs -o rw tmpfs "$target"; then
    warn "Could not mount tmpfs on $target."
    return 1
  fi

  return 0
}

# Check environment
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 11
[ ! -f "/usr/local/bin/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 12

# Check required binaries early.
dir="/usr/libexec/proxmox"

for cmd in \
  chpasswd \
  openssl \
  runuser \
  supercronic \
  rsyslogd \
  grep \
  awk \
  mountpoint \
  "$dir/proxmox-datacenter-privileged-api" \
  "$dir/proxmox-datacenter-api"; do
  require_cmd "$cmd"
done

if is_enabled "$POSTFIX"; then
  if [ ! -x /etc/init.d/postfix ]; then
    warn "POSTFIX=Y but /etc/init.d/postfix is missing or not executable."
  fi
fi

# Display version number
info "Starting Proxmox Datacenter Manager for Docker v$(</etc/version)..."
info "For support visit https://github.com/dockur/proxmox-dm"
echo ""

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

# Get the capability bounding set.
CAP_BND="$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')"
CAP_BND="$(printf "%d" "0x${CAP_BND}")"

# Get the last capability number.
LAST_CAP="$(cat /proc/sys/kernel/cap_last_cap)"

# Calculate the maximum capability value.
MAX_CAP="$(((1 << (LAST_CAP + 1)) - 1))"

# Check if container is privileged.
if [ "$CAP_BND" -ne "$MAX_CAP" ]; then
  error "Please start the container with the --privileged flag!"
  if ! is_enabled "$DEBUG"; then
    exit 14
  fi
fi

# If missing timezone and localtime set them.
set_timezone() {
  local zone="$1"

  if [ ! -f "/usr/share/zoneinfo/$zone" ]; then
    echo "Invalid timezone: $zone" >&2
    exit 18
  fi

  ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
  echo "$zone" > /etc/timezone
}

check_localtime() {
  if [ ! -e /etc/localtime ] && [ ! -L /etc/localtime ]; then
    return 1
  fi

  local target
  target="$(readlink -f /etc/localtime 2>/dev/null || true)"

  if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -s "$target" ]; then
    echo "Invalid TZ value." >&2
    exit 1
  fi

  return 0
}

if [ -n "${TZ:-}" ]; then
  set_timezone "$TZ"
elif ! check_localtime; then
  set_timezone "UTC"
fi

# Ensure directory permissions.
user="www-data"

ensure_dir "/etc/proxmox-datacenter-manager" 1770 "$user:$user"
ensure_dir "/etc/proxmox-datacenter-manager/auth" 0750 "root:$user"
ensure_dir "/var/lib/proxmox-datacenter-manager" "" "$user:$user"
ensure_dir "/var/lib/proxmox-datacenter-manager/rrdb" 0755 "$user:$user"
ensure_dir "/var/log/proxmox-datacenter-manager" "" "root:$user"
ensure_dir "/run/proxmox-datacenter-manager" 1770 "root:$user"
ensure_dir "/run/proxmox-datacenter-manager/shmem" "" "root:root"

safe_tmpfs_mount "/run/proxmox-datacenter-manager/shmem" || :

# Remove stale PID/socket files.
rm -f \
  /run/proxmox-datacenter-manager/priv.sock \
  /run/proxmox-datacenter-manager/api.sock \
  /var/spool/postfix/pid/master.pid \
  /proxmox.end

# Start rsyslog early because services may expect /dev/log.
echo "Starting rsyslog..."

cat >/etc/rsyslog.conf <<'EOF'
module(load="imuxsock")
input(type="imuxsock" Socket="/dev/log")
template(name="DockerFormat" type="string" string="%programname%:%msg%\n")

if $msg contains '#000' then stop
if $msg contains 'IORITY' then stop
if $msg contains 'F_LOG_TARGET' then stop
if $msg contains 'SYSLOG_IDENTIFIER' then stop

if $programname == 'runuser' then stop
if $programname == 'rsyslogd' and $msg contains '[origin software="rsyslogd"' then stop

*.* action(type="omfile" file="/var/log/system.log" template="DockerFormat")
EOF

rm -f /dev/log /var/log/system.log
touch /var/log/system.log
chmod 0644 /etc/rsyslog.conf /var/log/system.log

rsyslogd -n -iNONE -f /etc/rsyslog.conf &
RSYSLOG_PID="$!"

while [ ! -S /dev/log ]; do
  sleep 0.2
done

mkdir -p /run/systemd/journal
ln -sf /dev/log /run/systemd/journal/syslog
ln -sf /dev/log /run/systemd/journal/socket

tail -F /var/log/system.log &
TAIL_PID="$!"

# Generate keys.
keys="/etc/proxmox-datacenter-manager/auth"

if [[ ! -f "$keys/authkey.key" ]]; then
  info "Generating authentication keys..."
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$keys/authkey.key" 2>/dev/null
  openssl pkey -in "$keys/authkey.key" -pubout -out "$keys/authkey.pub" 2>/dev/null
  chmod 0640 "$keys/authkey.key"
  chmod 0644 "$keys/authkey.pub"
  chown "root:$user" "$keys/authkey.key"
fi

if [[ ! -f "$keys/csrf.key" ]]; then
  info "Generating CSRF key..."
  openssl rand -base64 32 > "$keys/csrf.key"
  chmod 0640 "$keys/csrf.key"
  chown "root:$user" "$keys/csrf.key"
fi

if [ ! -f "$keys/api.key" ] || [ ! -f "$keys/api.pem" ]; then
  info "Generating API certificate..."

  openssl req \
    -x509 \
    -newkey rsa:4096 \
    -keyout "$keys/api.key" \
    -out "$keys/api.pem" \
    -sha256 \
    -days 3650 \
    -nodes \
    -subj "/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=CommonNameOrHostname" \
    2>/dev/null

  chmod 0640 "$keys/api.key"
  chmod 0640 "$keys/api.pem"
  chown "root:$user" "$keys/api.key"
  chown "root:$user" "$keys/api.pem"
  echo ""
fi

dir="/usr/libexec/proxmox"

# Start Postfix.
#
# PDM can run without Postfix, but reports/notifications need local mail delivery.
POSTFIX_PID=""

if is_enabled "$POSTFIX"; then
  echo "Starting Postfix..."

  if [ -f /etc/postfix/main.cf ]; then
    if grep -q 'RELAY_HOST' /etc/postfix/main.cf; then
      sed -i "s|RELAY_HOST|$RELAY_HOST|g" /etc/postfix/main.cf
    fi
  fi

  if [ -x /etc/init.d/postfix ]; then
    /etc/init.d/postfix start || warn "Could not start Postfix."

    if read_pidfile /var/spool/postfix/pid/master.pid; then
      POSTFIX_PID="$REPLY"
    else
      warn "Postfix started but master.pid was not found."
    fi
  else
    warn "Postfix init script not found."
  fi
fi

# Start supercronic.
echo "Starting supercronic..."

cat >/docker.cron <<EOF
30 2 * * * $dir/proxmox-datacenter-manager-daily-update 2>&1 | tee -a /tmp/daily.log
EOF

supercronic -quiet -no-reap /docker.cron &
CRON_PID="$!"
wait_process_alive "$CRON_PID" "supercronic" 1 || :

# Trap helper.
_trap() {
  local func="$1"; shift
  local sig
  TRAP_PID="$BASHPID"

  for sig; do
    trap "$func $sig" "$sig"
  done
}

cleanup() {
  [ -f /proxmox.end ] && return 0
  [[ "${BASHPID:-}" != "${TRAP_PID:-}" ]] && return 0

  touch /proxmox.end
  echo "Shutting down PDM services..."

  pids=(
    "${API_PID:-}"
    "${PRIV_API_PID:-}"
    "${CRON_PID:-}"
    "${POSTFIX_PID:-}"
    "${RSYSLOG_PID:-}"
    "${TAIL_PID:-}"
  )

  # Send SIGTERM.
  for pid in "${pids[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    kill -TERM "$pid" 2>/dev/null || :
  done

  if is_enabled "$POSTFIX" && [ -x /etc/init.d/postfix ]; then
    /etc/init.d/postfix stop 2>/dev/null || :
  fi

  # Wait for processes.
  for pid in "${pids[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    wait "$pid" 2>/dev/null || :
  done

  echo ""
  echo "Shutdown completed successfully."
  exit 0
}

# Init trap.
rm -f /proxmox.end
_trap cleanup SIGTERM SIGINT

# Start PDM services.
echo "Starting proxmox-datacenter-privileged-api..."
"$dir/proxmox-datacenter-privileged-api" &
PRIV_API_PID="$!"

wait_process_alive "$PRIV_API_PID" "proxmox-datacenter-privileged-api" 1 || cleanup

sock="/run/proxmox-datacenter-manager/priv.sock"

# Wait for the privileged API socket to be ready.
if ! wait_socket "$sock" "$PRIV_API_PID" "privileged API" 30; then
  warn "Privileged API socket not found after 30s, starting API anyway."
fi

echo "Starting proxmox-datacenter-api..."

msg="failed to collect blockdev statistics for "

runuser -u "$user" -- \
  "$dir/proxmox-datacenter-api" \
  2> >(grep -v "$msg" >&2) &
API_PID="$!"

wait_process_alive "$API_PID" "proxmox-datacenter-api" 1 || cleanup

# Final readiness check.
echo "Checking Datacenter Manager readiness..."

if command -v ss >/dev/null 2>&1; then
  wait_port ":${PORT:-8443} " 60 "PDM web interface does not appear to be listening on port ${PORT:-8443}." || :
else
  warn "Cannot run readiness port check because 'ss' is not installed."
fi

echo ""
info "------------------------------------------------------------------------------"
info ""
info ". Welcome to the Proxmox Datacenter Manager v$(</etc/version). Connect your web browser to:"
info ""
info ".   https://127.0.0.1:${PORT:-8443}"
info ""
info "------------------------------------------------------------------------------"
info ""
echo ""

# Wait for required processes.
while true; do
  sleep 5

  process_alive "$PRIV_API_PID" || break
  process_alive "$API_PID" || break

  if [ -n "${CRON_PID:-}" ] && ! process_alive "$CRON_PID"; then
    warn "supercronic exited. Daily update job will no longer run."
    CRON_PID=""
  fi

  if [ -n "${POSTFIX_PID:-}" ] && ! process_alive "$POSTFIX_PID"; then
    warn "Postfix exited. Notifications/reports may not work."
    POSTFIX_PID=""
  fi
done

info "A required PDM process exited unexpectedly. Shutting down..."
cleanup
