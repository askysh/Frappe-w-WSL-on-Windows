#!/usr/bin/env bash
#
# 02-wsl-frappe-install.sh
#
# Install Frappe v15 + ERPNext on a WSL2 Ubuntu 22.04 box that has already
# had 01-wsl-system-deps.sh run on it. Idempotent: re-running on a finished
# install is a no-op + validate; re-running on a partial install picks up
# where it left off.
#
# Usage:
#   bash 02-wsl-frappe-install.sh                # install + validate
#   bash 02-wsl-frappe-install.sh --validate     # validate only
#
# Environment overrides (all optional):
#   SITE_NAME              default "wsldev"
#   FRAPPE_BRANCH          default "version-15"
#   ERPNEXT_BRANCH         default "version-15"
#   NODE_VERSION           default "20"     (major version; nvm picks the latest)
#   YARN_VERSION           default "1.22.22"  (yarn classic; do NOT use 4.x for v15)
#   MARIADB_ROOT_PASSWORD  if set, bench new-site uses it; else bench prompts
#   ADMIN_PASSWORD         if set, bench new-site uses it; else bench prompts
#
# Run as a regular user with sudo privileges (NOT as root).
# Requires: 01-wsl-system-deps.sh has succeeded (mariadb running, hardened,
# utf8mb4 charset, redis running, wkhtmltopdf with patched Qt available).
#
# Tested on: Ubuntu 22.04.5 LTS (jammy) under WSL 2.6.3, Frappe v15.106.0,
# ERPNext v15.105.0, frappe-bench 5.29.1.

set -euo pipefail

SITE_NAME="${SITE_NAME:-wsldev}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
ERPNEXT_BRANCH="${ERPNEXT_BRANCH:-version-15}"
NODE_VERSION="${NODE_VERSION:-20}"
YARN_VERSION="${YARN_VERSION:-1.22.22}"
NVM_TAG="v0.40.4"
PYTHON_BIN="python3.10"
BENCH_DIR="$HOME/frappe-bench"

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
if [[ "${ID:-}" != "ubuntu" ]]; then die "Not Ubuntu (ID=$ID)"; fi
if [[ "${VERSION_ID:-}" != "22.04" ]]; then die "Ubuntu 22.04 required, found $VERSION_ID"; fi
ok "Distro: $PRETTY_NAME"

if [[ $EUID -eq 0 ]]; then die "Don't run as root. Run as your regular user with sudo."; fi
ok "User: $(whoami)"

# We deliberately don't reject /mnt/c here — bench commands will, but our setup
# steps need to be runnable from the cloned repo path (which may sit under /mnt/c).
# We just warn and proceed. The bench dir itself is always under $HOME.
case "$PWD" in
  /mnt/c/*)
    warn "Running from /mnt/c. The bench will be created under \$HOME (~/frappe-bench), but"
    warn "future bench commands MUST run from inside ~/frappe-bench, never under /mnt/c."
    ;;
  *) ok "CWD: $PWD" ;;
esac

if ! sudo -n true 2>/dev/null; then
  echo "    sudo will prompt for your password..."
  sudo -v || die "sudo authentication failed"
fi
ok "sudo available"

# Confirm 01's outputs — fail fast if 01 didn't run or didn't finish
for cmd in mariadb redis-server wkhtmltopdf $PYTHON_BIN; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd not found. Run 01-wsl-system-deps.sh first (or its --validate to diagnose)."
  fi
done
if ! systemctl is-active --quiet mariadb; then die "mariadb not running. Run 01-wsl-system-deps.sh."; fi
if ! systemctl is-active --quiet redis-server; then die "redis-server not running. Run 01-wsl-system-deps.sh."; fi
ok "01-wsl-system-deps.sh prerequisites present"

# ------------------------------------------------------------ install phase

if [[ "$MODE" == "install" ]]; then

  # ---- nvm

  step "Install nvm + Node $NODE_VERSION"
  if [[ ! -s "$HOME/.nvm/nvm.sh" ]]; then
    echo "    fetching nvm $NVM_TAG..."
    # Do NOT gate on installer output: nvm $NVM_TAG misdetects WSL2 as WSL1
    # and prints two false-positive warnings that don't actually affect install.
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh" | bash >/dev/null 2>&1 || true
    if [[ ! -s "$HOME/.nvm/nvm.sh" ]]; then
      die "nvm install failed — ~/.nvm/nvm.sh not present after install script ran"
    fi
    ok "nvm installed"
  else
    ok "nvm already present at ~/.nvm"
  fi

  # Source nvm explicitly for the rest of this script (the install we just
  # did edits ~/.bashrc but won't take effect until shell restart)
  export NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"

  # nvm 0.40.4's install does NOT auto-activate the default — `nvm install` will
  # set it but only after we run install/use explicitly.
  if nvm ls "$NODE_VERSION" 2>/dev/null | grep -q "v$NODE_VERSION"; then
    ok "Node $NODE_VERSION already installed via nvm"
  else
    echo "    installing Node $NODE_VERSION..."
    nvm install "$NODE_VERSION" >/dev/null 2>&1
    ok "Node $NODE_VERSION installed via nvm"
  fi
  nvm alias default "$NODE_VERSION" >/dev/null
  nvm use default --silent >/dev/null 2>&1

  ok "node: $(node --version)"
  ok "npm:  $(npm --version)"

  # ---- patch ~/.profile so non-interactive shells (bench's subprocesses) get nvm

  step "Ensure ~/.profile activates nvm for non-interactive shells"
  PROFILE="$HOME/.profile"
  if grep -q '^nvm use default' "$PROFILE" 2>/dev/null; then
    ok "~/.profile already activates nvm default"
  else
    cat >> "$PROFILE" <<'EOF'

# nvm + default Node activation, so non-interactive shells (and bench's
# subprocesses spawned via subprocess.call) have node and yarn on PATH.
# nvm's installer only adds these to ~/.bashrc, but Ubuntu's default ~/.bashrc
# returns early for non-interactive shells, so they never run there.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use default --silent 2>/dev/null
EOF
    ok "Appended nvm activation block to ~/.profile"
  fi

  # ---- yarn classic via corepack

  step "Pin yarn $YARN_VERSION (classic) via corepack"
  if ! corepack --version >/dev/null 2>&1; then
    die "corepack not available — Node $NODE_VERSION install is broken"
  fi
  corepack enable >/dev/null 2>&1 || true
  CURRENT_YARN=$(yarn --version 2>/dev/null || echo "missing")
  if [[ "$CURRENT_YARN" == "$YARN_VERSION" ]]; then
    ok "yarn $YARN_VERSION already active"
  else
    # NOTE: do NOT use corepack prepare yarn@stable --activate — that resolves
    # to yarn 4.x (Berry), which Frappe v15 does NOT support.
    corepack prepare "yarn@$YARN_VERSION" --activate >/dev/null 2>&1
    ok "yarn pinned to $(yarn --version)"
  fi

  # ---- pipx

  step "Install pipx"
  if command -v pipx >/dev/null 2>&1; then
    ok "pipx already installed: $(pipx --version)"
  else
    sudo apt install -y pipx
    ok "pipx installed: $(pipx --version)"
  fi
  # Idempotent — pipx ensurepath only appends to bashrc once
  pipx ensurepath >/dev/null 2>&1
  export PATH="$PATH:$HOME/.local/bin"

  # ---- uv (silent dep of frappe-bench)

  step "Install uv (required by bench init for venv creation)"
  if command -v uv >/dev/null 2>&1; then
    ok "uv already installed: $(uv --version)"
  else
    pipx install uv >/dev/null 2>&1
    # uv was just installed; refresh PATH lookup
    hash -r 2>/dev/null || true
    ok "uv installed: $(uv --version 2>/dev/null || echo "(restart shell to use)")"
  fi

  # ---- frappe-bench

  step "Install frappe-bench via pipx"
  if command -v bench >/dev/null 2>&1; then
    ok "frappe-bench already installed: $(bench --version)"
  else
    pipx install frappe-bench >/dev/null 2>&1
    hash -r 2>/dev/null || true
    ok "frappe-bench installed: $(bench --version 2>/dev/null || echo "(restart shell to use)")"
  fi

  # ---- bench init

  step "Initialize bench at $BENCH_DIR (Frappe $FRAPPE_BRANCH)"
  if [[ -d "$BENCH_DIR" ]] && [[ -f "$BENCH_DIR/Procfile" ]] && [[ -d "$BENCH_DIR/apps/frappe" ]]; then
    ok "$BENCH_DIR already initialized"
  else
    if [[ -d "$BENCH_DIR" ]]; then
      warn "$BENCH_DIR exists but appears incomplete (no Procfile or apps/frappe)"
      die "Refusing to overwrite. Move it aside or delete it manually, then re-run."
    fi
    cd "$HOME"
    # Long-running: clone + uv pip install + yarn install + asset build.
    # We do NOT pipe through tee — would mask exit codes (set -o pipefail or
    # ${PIPESTATUS[0]} would help, but redirecting to a logfile via > is cleanest).
    LOG="$HOME/.frappe-local-bench-init.log"
    if ! bench init frappe-bench --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN" > "$LOG" 2>&1; then
      tail -40 "$LOG"
      die "bench init failed — see full log at $LOG"
    fi
    ok "bench initialized (log: $LOG)"
  fi

  # ---- bench get-app erpnext

  step "Get ERPNext app ($ERPNEXT_BRANCH)"
  if [[ -d "$BENCH_DIR/apps/erpnext" ]]; then
    ok "erpnext app already cloned"
  else
    cd "$BENCH_DIR"
    LOG="$HOME/.frappe-local-erpnext-getapp.log"
    if ! bench get-app erpnext --branch "$ERPNEXT_BRANCH" > "$LOG" 2>&1; then
      tail -40 "$LOG"
      die "bench get-app erpnext failed — see full log at $LOG"
    fi
    ok "erpnext cloned (log: $LOG)"
  fi

  # ---- bench new-site

  step "Create site $SITE_NAME"
  if [[ -d "$BENCH_DIR/sites/$SITE_NAME" ]] && [[ -f "$BENCH_DIR/sites/$SITE_NAME/site_config.json" ]]; then
    ok "site $SITE_NAME already exists"
  else
    cd "$BENCH_DIR"
    NEW_SITE_FLAGS=()
    if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]]; then
      NEW_SITE_FLAGS+=("--db-root-password" "$MARIADB_ROOT_PASSWORD")
    fi
    if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
      NEW_SITE_FLAGS+=("--admin-password" "$ADMIN_PASSWORD")
    fi
    if [[ ${#NEW_SITE_FLAGS[@]} -eq 0 ]]; then
      warn "MariaDB root password and Administrator password not set in env."
      warn "bench new-site will prompt you interactively for both."
      warn "To skip prompts, re-run with:"
      warn "  MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' bash 02-wsl-frappe-install.sh"
      echo
    fi
    bench new-site "$SITE_NAME" "${NEW_SITE_FLAGS[@]}"
    ok "site $SITE_NAME created"
  fi

  # ---- bench install-app erpnext

  step "Install ERPNext on $SITE_NAME"
  cd "$BENCH_DIR"
  if bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -q "^erpnext "; then
    ok "erpnext already installed on $SITE_NAME"
  else
    LOG="$HOME/.frappe-local-erpnext-install.log"
    if ! bench --site "$SITE_NAME" install-app erpnext > "$LOG" 2>&1; then
      tail -40 "$LOG"
      die "bench install-app erpnext failed — see full log at $LOG"
    fi
    ok "erpnext installed on $SITE_NAME (log: $LOG)"
  fi

  # ---- set default site

  step "Set $SITE_NAME as default site"
  cd "$BENCH_DIR"
  bench use "$SITE_NAME" >/dev/null 2>&1
  ok "default site: $SITE_NAME"

fi  # end install phase

# ---------------------------------------------------------------- validation

step "Validation"

# Re-source nvm since validation may run with a stale shell
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
  nvm use default --silent >/dev/null 2>&1 || true
fi
export PATH="$PATH:$HOME/.local/bin"

# nvm + node + yarn

[[ -s "$HOME/.nvm/nvm.sh" ]] && ok "nvm installed at ~/.nvm" || fail "nvm not installed"
NODE_V=$(node --version 2>&1 || echo "missing")
if [[ "$NODE_V" =~ ^v$NODE_VERSION\. ]]; then
  ok "node: $NODE_V"
else
  fail "node: expected v$NODE_VERSION.x, got '$NODE_V'"
fi

YARN_V=$(yarn --version 2>&1 || echo "missing")
if [[ "$YARN_V" == "$YARN_VERSION" ]]; then
  ok "yarn: $YARN_V"
else
  fail "yarn: expected $YARN_VERSION, got '$YARN_V'"
fi

# pipx + uv + bench

command -v pipx >/dev/null 2>&1 && ok "pipx: $(pipx --version 2>&1 | head -1)" || fail "pipx not on PATH"
command -v uv   >/dev/null 2>&1 && ok "uv: $(uv --version)"                     || fail "uv not on PATH"
command -v bench >/dev/null 2>&1 && ok "bench: $(bench --version)"              || fail "bench not on PATH"

# bench dir + apps

[[ -f "$BENCH_DIR/Procfile" ]]               && ok "$BENCH_DIR/Procfile present" || fail "Procfile missing"
[[ -d "$BENCH_DIR/apps/frappe" ]]            && ok "frappe app present"          || fail "apps/frappe missing"
[[ -d "$BENCH_DIR/apps/erpnext" ]]           && ok "erpnext app present"         || fail "apps/erpnext missing"

if [[ -d "$BENCH_DIR/apps/frappe" ]]; then
  FRAPPE_BR=$(git -C "$BENCH_DIR/apps/frappe" branch --show-current 2>/dev/null || echo "?")
  if [[ "$FRAPPE_BR" == "$FRAPPE_BRANCH" ]]; then
    ok "frappe on branch $FRAPPE_BR"
  else
    fail "frappe on wrong branch: expected $FRAPPE_BRANCH, got $FRAPPE_BR"
  fi
fi

if [[ -d "$BENCH_DIR/apps/erpnext" ]]; then
  ERPNEXT_BR=$(git -C "$BENCH_DIR/apps/erpnext" branch --show-current 2>/dev/null || echo "?")
  if [[ "$ERPNEXT_BR" == "$ERPNEXT_BRANCH" ]]; then
    ok "erpnext on branch $ERPNEXT_BR"
  else
    fail "erpnext on wrong branch: expected $ERPNEXT_BRANCH, got $ERPNEXT_BR"
  fi
fi

# default site

if [[ -f "$BENCH_DIR/sites/common_site_config.json" ]]; then
  DEFAULT_SITE=$(grep -oP '"default_site"\s*:\s*"\K[^"]+' "$BENCH_DIR/sites/common_site_config.json" 2>/dev/null || echo "")
  if [[ "$DEFAULT_SITE" == "$SITE_NAME" ]]; then
    ok "default site: $DEFAULT_SITE"
  else
    fail "default site: expected $SITE_NAME, got '$DEFAULT_SITE'"
  fi
else
  fail "common_site_config.json missing"
fi

# site dir + db

if [[ -f "$BENCH_DIR/sites/$SITE_NAME/site_config.json" ]]; then
  ok "site dir: $BENCH_DIR/sites/$SITE_NAME"
  DB_NAME=$(grep -oP '"db_name"\s*:\s*"\K[^"]+' "$BENCH_DIR/sites/$SITE_NAME/site_config.json" 2>/dev/null || echo "")
  if [[ -n "$DB_NAME" ]]; then
    TABLES=$(sudo mariadb -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'" 2>/dev/null || echo 0)
    if [[ "$TABLES" -gt 100 ]]; then
      ok "site DB '$DB_NAME': $TABLES tables"
    else
      fail "site DB '$DB_NAME': only $TABLES tables (expected >100)"
    fi
    # spot check a few erpnext-specific tables
    ERPNEXT_TABLES=$(sudo mariadb -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name IN ('tabItem','tabSales Invoice','tabCustomer','tabCompany')" 2>/dev/null || echo 0)
    if [[ "$ERPNEXT_TABLES" == "4" ]]; then
      ok "erpnext tables present: tabItem, tabSales Invoice, tabCustomer, tabCompany"
    else
      fail "erpnext tables: expected 4 of (tabItem, tabSales Invoice, tabCustomer, tabCompany), found $ERPNEXT_TABLES"
    fi
  else
    fail "could not parse db_name from site_config.json"
  fi
else
  fail "site_config.json missing for $SITE_NAME"
fi

# ---------------------------------------------------------------- summary

echo
if [[ $FAILS -eq 0 ]]; then
  step "$(green 'All checks passed.') Frappe v15 + ERPNext are installed."
  echo
  echo "  To start the dev server:"
  echo "    cd $BENCH_DIR && bench start"
  echo
  echo "  Then open http://localhost:8000 in your browser."
  echo "  Login: Administrator / <admin password you set during new-site>"
  echo
  echo "  IMPORTANT: If 'bench: command not found' in your existing shell,"
  echo "  close and reopen Ubuntu, OR run: source ~/.profile && source ~/.bashrc"
  echo
  exit 0
else
  step "$(red "$FAILS check(s) failed.") Review the [FAIL] lines above."
  exit 1
fi
