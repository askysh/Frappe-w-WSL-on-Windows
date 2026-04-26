# Frappe with WSL on Windows

Scripts for setting up a local Frappe / ERPNext development bench on Windows
via WSL2 + Ubuntu 22.04.

This is the Windows / WSL counterpart to
[askysh/frappe_mac_local_install](https://github.com/askysh/frappe_mac_local_install).
The two repos do the same thing on different platforms; conventions are kept
similar where they reasonably can be, but the platform-specific bootstrap
layers differ enough that they live separately.

## What You Get

- A fully provisioned WSL2 Ubuntu 22.04 distribution
- Frappe v15 system dependencies installed inside Ubuntu (build chain, Python
  toolchain, MariaDB 10.6, Redis 6, wkhtmltopdf with patched Qt, X11 stub libs)
- MariaDB hardened (no anonymous users, no test database, no remote root, root
  password set) and configured for `utf8mb4` / `utf8mb4_unicode_ci`
- nvm + Node 20 + yarn 1.22 (Classic) + pipx + uv + frappe-bench
- A `~/frappe-bench/` with Frappe v15 and ERPNext v15 cloned, built, and
  installed against a default site (`wsldev` by default)
- Each script has a `--validate` mode that runs health checks (~25 in script
  01, ~15 in script 02) against the installed system
- Idempotent re-runs: every step checks state before acting

## Requirements

- Windows 10 build 19041+ or Windows 11 (any edition; Home is fine)
- Administrator access on the Windows account
- Virtualization enabled in BIOS (the script checks the OS build but not BIOS;
  if `wsl --install` later complains about virtualization, that is the cause)
- Internet access for the first install
- About 5 GB of free disk for WSL + Ubuntu + Frappe deps

Not required: Windows Pro, Hyper-V toggle, Docker, or a separate Linux box.

## Quick Start

Clone this repo onto the Windows side:

```powershell
git clone https://github.com/askysh/Frappe-w-WSL-on-Windows.git
cd "Frappe-w-WSL-on-Windows"
```

Open **Windows PowerShell as Administrator**, navigate to the cloned folder,
and run the WSL setup script:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\00-windows-setup-wsl.ps1
```

What it does:

1. Enables the Windows features `Microsoft-Windows-Subsystem-Linux` and
   `VirtualMachinePlatform`.
2. **Reboots** if those features were just enabled (you re-run the script
   after the reboot to continue).
3. Installs the WSL runtime and sets WSL2 as the default version.
4. Installs the `Ubuntu-22.04` distribution.
5. Launches a new Ubuntu window for first-time setup. Create your UNIX
   username and password when prompted.

When the script finishes, switch to the Ubuntu shell and run the system
dependency install:

```bash
cd ~
bash /mnt/c/path/to/Frappe-w-WSL-on-Windows/01-wsl-system-deps.sh
```

`mysql_secure_installation` will prompt interactively the first time. The
script prints the recommended answers above the prompt. The root password
you set is the one you will need later for `bench new-site`.

When script `01` ends with `All checks passed`, run script `02` to install
Frappe + ERPNext:

```bash
bash /mnt/c/path/to/Frappe-w-WSL-on-Windows/02-wsl-frappe-install.sh
```

Script `02` will prompt twice during `bench new-site`: once for the MariaDB
root password (the one you set during `mysql_secure_installation` in script
`01`), and once for a new Administrator password for the site. To skip both
prompts in non-interactive runs, supply them via env vars:

```bash
MARIADB_ROOT_PASSWORD='your-db-root-password' \
ADMIN_PASSWORD='your-site-admin-password' \
bash 02-wsl-frappe-install.sh
```

When `02` ends with `All checks passed`, start the dev server:

```bash
cd ~/frappe-bench
bench start
```

Open `http://localhost:8000` in any Windows browser. WSL2 forwards Windows
localhost into the WSL VM automatically — no `/etc/hosts` edits needed.
Login as `Administrator` with the password you set during `new-site`.

## Customizing Script 02

```bash
# default site name (default: wsldev)
SITE_NAME=mysite bash 02-wsl-frappe-install.sh

# Frappe / ERPNext branches (default: version-15 for both)
FRAPPE_BRANCH=develop ERPNEXT_BRANCH=develop bash 02-wsl-frappe-install.sh

# Node major version (default: 20). Frappe v15 supports 18+; do NOT downgrade
# below 18.
NODE_VERSION=22 bash 02-wsl-frappe-install.sh
```

`YARN_VERSION` defaults to `1.22.22` (yarn Classic). Do NOT set it to a 4.x
version — Frappe v15's package.json and bench's frontend toolchain both
expect Classic semantics. Yarn 4 (Berry) will break `bench build`.

## Validation

To re-run only the health checks without installing anything:

```bash
bash 01-wsl-system-deps.sh --validate
bash 02-wsl-frappe-install.sh --validate
```

Script 01's validate runs 25 checks (packages, services, listening ports,
`wkhtmltopdf` patched-Qt build, MariaDB charset, MariaDB hardening).
Script 02's validate runs ~15 checks (nvm, node, yarn, pipx, uv, bench,
bench dir, frappe app, erpnext app, branches, default site, site DB,
ERPNext tables). Both exit 0 on success, 1 on any failure.

## Re-running Safely

All three scripts are designed to be re-run.

- `00-windows-setup-wsl.ps1` — every step probes Windows / WSL state and
  reports `[OK] already installed/enabled` for steps that are done.
- `01-wsl-system-deps.sh` — `apt install` is naturally idempotent; the
  MariaDB charset config is compared by checksum and only rewritten if it
  differs; `mysql_secure_installation` is launched only if the database
  has not already been hardened; `wkhtmltopdf` install is skipped if a
  patched-Qt build is already on `PATH`.
- `02-wsl-frappe-install.sh` — nvm install is skipped if `~/.nvm/` exists;
  Node + yarn version checks compare against the requested version before
  installing; `bench init` is skipped if `~/frappe-bench/Procfile` exists;
  `bench get-app` and `install-app` are skipped if the app is already
  cloned / installed; `bench new-site` is skipped if the site directory
  exists. Re-running on a finished install is just a `--validate` pass.

## WSL-Specific Notes

- **Always work under the Linux home directory** (`~/`, i.e.
  `/home/<username>/`). Files under `/mnt/c/...` traverse a 9P bridge
  into NTFS and are 10–50x slower for filesystem-heavy workloads like
  `git clone`, `bench init`, `npm install`.
- **systemd is on by default** in modern WSL + Ubuntu 22.04 — the distro
  provisioning step writes `/etc/wsl.conf` with `[boot] systemd=true`
  automatically. `mariadb` and `redis-server` start on first boot of
  the distro. No manual `service ... start` needed.
- **Services bind to loopback only** out of the box (MariaDB on
  `127.0.0.1:3306`, Redis on `127.0.0.1:6379`). The Windows host cannot
  reach them by default. If you ever need to expose them to Windows,
  edit the `bind-address` in `/etc/mysql/mariadb.conf.d/50-server.cnf`
  and the `bind` line in `/etc/redis/redis.conf` — and understand the
  security implications first.
- **WSL VM is reaped when idle.** Long shell idleness or all WSL windows
  closed will shut down the VM; the next `wsl` command brings it back
  up and re-runs `systemd` boot. Service start times in `systemctl status`
  resetting unexpectedly is normal.

## Files

```text
00-windows-setup-wsl.ps1     # run on Windows in admin PowerShell
01-wsl-system-deps.sh        # run inside Ubuntu (regular user with sudo)
02-wsl-frappe-install.sh     # run inside Ubuntu after 01 succeeds
.gitattributes               # locks bash scripts to LF, ps1 to CRLF
README.md
LICENSE
```

## Roadmap

- App bundles (`minimal` / `common` / `extended`) — install HRMS, Payments,
  CRM, Helpdesk, Insights alongside ERPNext, matching the Mac repo's
  `APP_BUNDLE` env var pattern.
- Profile flags (`v15-lts` / `v16-lts`) for switching between Frappe major
  versions, again matching the Mac repo.
- Test harness under `tests/` with mocked `git` and `bench` for CI-runnable
  validation of script logic without doing a real install.
- Optional: a `99-wsl-uninstall.sh` to roll back everything 01 + 02 did,
  for experimenters who want a clean slate without nuking the whole distro.

## Important Notes

- Do not run the bench under `/mnt/c/...`. The 9P bridge will make every
  bench operation painfully slow and some will fail with permission or
  inotify errors.
- Do not install `wkhtmltopdf` from `apt` (`apt install wkhtmltopdf`) —
  that build is missing the patched Qt fork and will crash on real Frappe
  templates. Use the upstream `.deb` that script `01` installs.
- Do not switch MariaDB root to unix_socket-only auth during
  `mysql_secure_installation`. Frappe's `bench` connects with
  username/password and needs password auth available.
- Do not skip the reboot prompted by `00-windows-setup-wsl.ps1` after
  enabling WSL features. The runtime install will fail without it.

## License

MIT — see `LICENSE`.
