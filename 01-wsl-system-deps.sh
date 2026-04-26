#!/usr/bin/env bash
#
# 01-wsl-system-deps.sh
#
# Install Frappe v15 system dependencies inside a fresh WSL2 + Ubuntu 22.04
# distro, then validate that everything is in place. Idempotent — safe to
# re-run. Run after 00-windows-setup-wsl.ps1 has finished and you have
# created your UNIX user.
#
# Usage:
#   bash 01-wsl-system-deps.sh              # install + validate
#   bash 01-wsl-system-deps.sh --validate   # validate only (no installs)
#
# Run as a regular user with sudo privileges (NOT as root).
# Requires: Ubuntu 22.04, sudo, internet access for apt + GitHub releases.
#
# Tested on: Ubuntu 22.04.5 LTS (jammy) under WSL 2.6.3.

set -euo pipefail

# ----------------------------------------------------------------- output

red()    { printf '\033[31m%s\033[0m' "$*"; }
green()  { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
cyan()   { printf '\033[36m%s\033[0m' "$*"; }

step()   { echo; echo "$(cyan '==>') $*"; }
ok()     { echo "  $(green '[OK]  ') $*"; }
warn()   { echo "  $(yellow '[WARN]') $*"; }
fail()   { echo "  $(red '[FAIL]') $*"; FAILS=$((FAILS+1)); }
die()    { echo "$(red '[FATAL]') $*" >&2; exit 1; }

FAILS=0
MODE="install"
case "${1:-}" in
  ""|"install") MODE="install" ;;
  "--validate") MODE="validate-only" ;;
  *) die "Unknown argument: $1. Use --validate or no argument." ;;
esac

# --------------------------------------------------------------- pre-checks

step "Pre-checks"

if [[ ! -f /etc/os-release ]]; then die "/etc/os-release missing — not a standard Linux"; fi
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then die "Not Ubuntu (ID=$ID) — this script targets Ubuntu only"; fi
if [[ "${VERSION_ID:-}" != "22.04" ]]; then die "Ubuntu 22.04 required, found $VERSION_ID"; fi
ok "Distro: $PRETTY_NAME"

if [[ $EUID -eq 0 ]]; then die "Don't run as root. Run as your regular user with sudo."; fi
ok "User: $(whoami)"

if [[ $(uname -r) != *microsoft* ]]; then
  warn "Kernel '$(uname -r)' does not look like WSL — proceeding anyway"
else
  ok "Kernel: $(uname -r)"
fi

if ! sudo -n true 2>/dev/null; then
  echo "    sudo will prompt for your password..."
  sudo -v || die "sudo authentication failed"
fi
ok "sudo available"

# ------------------------------------------------------------ install phase

if [[ "$MODE" == "install" ]]; then

  # ---- apt update + upgrade

  step "Apt update + upgrade"
  sudo apt update
  sudo apt upgrade -y
  ok "Apt index refreshed, base packages upgraded"

  # ---- base packages

  step "Install Frappe v15 base system dependencies"
  sudo apt install -y \
    build-essential pkg-config \
    git curl ca-certificates gnupg lsb-release software-properties-common \
    python3-dev python3-pip python3-setuptools python3-venv python3-distutils \
    libffi-dev libssl-dev \
    mariadb-server mariadb-client libmariadb-dev \
    redis-server \
    xvfb libfontconfig1
  ok "Base packages installed"

  # ---- mariadb charset config

  step "Configure MariaDB for utf8mb4 (Frappe requirement)"
  CONF=/etc/mysql/mariadb.conf.d/99-frappe.cnf
  TMPCONF=$(mktemp)
  cat > "$TMPCONF" <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

  if sudo test -f "$CONF" && sudo cmp -s "$TMPCONF" "$CONF"; then
    ok "$CONF already current"
    rm -f "$TMPCONF"
  else
    sudo install -m 0644 -o root -g root "$TMPCONF" "$CONF"
    rm -f "$TMPCONF"
    sudo systemctl restart mariadb
    ok "$CONF written, mariadb restarted"
  fi

  # ---- secure mariadb (interactive only if not already hardened)

  step "Secure MariaDB"

  hardened=true
  ANON=$(sudo mariadb -Nse "SELECT COUNT(*) FROM mysql.global_priv WHERE User=''" 2>/dev/null || echo "ERR")
  TESTDB=$(sudo mariadb -Nse "SHOW DATABASES LIKE 'test'" 2>/dev/null || echo "ERR")
  REMOTE=$(sudo mariadb -Nse "SELECT COUNT(*) FROM mysql.global_priv WHERE User='root' AND Host != 'localhost'" 2>/dev/null || echo "ERR")
  PWSET=$(sudo mariadb -Nse "SELECT IF(JSON_VALUE(Priv,'\$.authentication_string')='','no','yes') FROM mysql.global_priv WHERE User='root' AND Host='localhost'" 2>/dev/null || echo "ERR")

  for v in "$ANON" "$TESTDB" "$REMOTE" "$PWSET"; do
    [[ "$v" == "ERR" ]] && hardened=false
  done
  [[ "$ANON" == "0" ]]   || hardened=false
  [[ -z "$TESTDB" ]]     || hardened=false
  [[ "$REMOTE" == "0" ]] || hardened=false
  [[ "$PWSET" == "yes" ]] || hardened=false

  if $hardened; then
    ok "MariaDB already hardened (no anon users, no test db, no remote root, password set)"
  else
    warn "MariaDB needs hardening. Launching mysql_secure_installation interactively."
    warn "Recommended answers:"
    warn "  - Current root password: empty (Enter) on first run"
    warn "  - Switch to unix_socket auth: n"
    warn "  - Change root password: y, then pick a strong one (you'll need it for bench new-site)"
    warn "  - Remove anonymous users: y"
    warn "  - Disallow root login remotely: y"
    warn "  - Remove test database: y"
    warn "  - Reload privilege tables: y"
    echo
    sudo mysql_secure_installation
    ok "mysql_secure_installation completed"
  fi

  # ---- wkhtmltopdf with patched Qt

  step "Install wkhtmltopdf with patched Qt"
  if command -v wkhtmltopdf >/dev/null 2>&1 && wkhtmltopdf --version 2>/dev/null | grep -q "patched qt"; then
    ok "wkhtmltopdf with patched Qt already installed: $(wkhtmltopdf --version)"
  else
    CODENAME=$(lsb_release -cs)
    VERSION="0.12.6.1-3"
    DEB="wkhtmltox_${VERSION}.${CODENAME}_amd64.deb"
    URL="https://github.com/wkhtmltopdf/packaging/releases/download/${VERSION}/${DEB}"
    TMPDEB="/tmp/${DEB}"
    echo "    downloading $URL"
    curl -fSL -o "$TMPDEB" "$URL"
    sudo apt install -y "$TMPDEB"
    rm -f "$TMPDEB"
    ok "wkhtmltopdf installed: $(wkhtmltopdf --version)"
  fi

fi  # end install phase

# ---------------------------------------------------------------- validation

step "Validation"

check_pkg() {
  local pkg=$1
  if dpkg -s "$pkg" 2>/dev/null | grep -q '^Status: install ok installed$'; then
    ok "package: $pkg"
  else
    fail "package: $pkg NOT installed"
  fi
}

check_service() {
  local svc=$1
  if systemctl is-active --quiet "$svc"; then
    ok "service: $svc active"
  else
    fail "service: $svc NOT active"
  fi
}

check_port() {
  local port=$1 name=$2
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${port}\$"; then
    ok "port: $name on :$port listening"
  else
    fail "port: $name on :$port NOT listening"
  fi
}

# packages
for p in build-essential pkg-config git curl python3-dev python3-pip python3-venv \
         libffi-dev libssl-dev mariadb-server mariadb-client libmariadb-dev \
         redis-server xvfb libfontconfig1; do
  check_pkg "$p"
done

# wkhtmltopdf binary + patched qt
if command -v wkhtmltopdf >/dev/null 2>&1 && wkhtmltopdf --version 2>/dev/null | grep -q "patched qt"; then
  ok "wkhtmltopdf: $(wkhtmltopdf --version)"
else
  fail "wkhtmltopdf missing or not the patched-Qt build"
fi

# services
check_service mariadb
check_service redis-server

# ports
check_port 3306 mariadb
check_port 6379 redis

# python toolchain version
PV=$(python3 --version 2>&1 || echo "absent")
if [[ "$PV" =~ "Python 3.10" ]]; then
  ok "python: $PV"
else
  fail "python: expected 3.10.x, got '$PV'"
fi

# mariadb charset
CHARSET=$(sudo mariadb -Nse "SELECT @@character_set_server" 2>/dev/null || echo "")
COLLATION=$(sudo mariadb -Nse "SELECT @@collation_server" 2>/dev/null || echo "")
if [[ "$CHARSET" == "utf8mb4" && "$COLLATION" == "utf8mb4_unicode_ci" ]]; then
  ok "mariadb charset: $CHARSET / $COLLATION"
else
  fail "mariadb charset: got '$CHARSET / $COLLATION', expected 'utf8mb4 / utf8mb4_unicode_ci'"
fi

# mariadb hardened
ANON=$(sudo mariadb -Nse "SELECT COUNT(*) FROM mysql.global_priv WHERE User=''" 2>/dev/null || echo "ERR")
TESTDB=$(sudo mariadb -Nse "SHOW DATABASES LIKE 'test'" 2>/dev/null || echo "ERR")
REMOTE=$(sudo mariadb -Nse "SELECT COUNT(*) FROM mysql.global_priv WHERE User='root' AND Host != 'localhost'" 2>/dev/null || echo "ERR")
[[ "$ANON" == "0" ]]   && ok "mariadb: no anonymous users"        || fail "mariadb: anonymous users still present (count=$ANON)"
[[ -z "$TESTDB" ]]     && ok "mariadb: no test database"          || fail "mariadb: test database still present"
[[ "$REMOTE" == "0" ]] && ok "mariadb: no remote root login"      || fail "mariadb: remote root still present (count=$REMOTE)"

# ---------------------------------------------------------------- summary

echo
if [[ $FAILS -eq 0 ]]; then
  step "$(green 'All checks passed.') System is ready for 02-wsl-frappe-install.sh."
  exit 0
else
  step "$(red "$FAILS check(s) failed.") Review the [FAIL] lines above."
  exit 1
fi
