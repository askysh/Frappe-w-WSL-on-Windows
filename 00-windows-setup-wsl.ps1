<#
.SYNOPSIS
    Set up WSL2 + Ubuntu 22.04 on Windows for a Frappe v15 local install.

.DESCRIPTION
    Enables the Windows features WSL needs, installs the WSL runtime, sets
    WSL2 as the default version, and installs the Ubuntu-22.04 distribution.
    Idempotent: safe to re-run. After this completes, run
    01-wsl-system-deps.sh from inside the Ubuntu shell.

.NOTES
    Must be run from an elevated (Administrator) PowerShell window.
    A Windows reboot is required after the first run if WSL features were
    not previously enabled. The script will tell you when to reboot and
    will resume cleanly when re-run after the reboot.

    To bypass Windows' default script execution policy without changing
    it permanently, invoke as:
        powershell.exe -ExecutionPolicy Bypass -File .\00-windows-setup-wsl.ps1

    Tested on: Windows 11 Home 25H2 Build 26200.8246, WSL 2.6.3.
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers

function Write-Step  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-FeatureEnabled {
    param([string]$Name)
    $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
    return ($f -and $f.State -eq 'Enabled')
}

function Test-WslRuntime {
    # `wsl --version` prints a version table on success and exits 0.
    # Returns 1 if the runtime is not installed even though wsl.exe shim exists.
    & wsl.exe --version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-DistroInstalled {
    param([string]$Name)
    $list = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    # wsl --list output is UTF-16 with embedded NULs; strip them
    $clean = ($list -join "`n") -replace "`0", ''
    return ($clean -split "`r?`n" | Where-Object { $_.Trim() -eq $Name }).Count -gt 0
}

# ----------------------------------------------------------- pre-checks

Write-Step "Pre-checks"

if (-not (Test-Admin)) {
    Write-Fail "This script must run in an elevated PowerShell. Right-click PowerShell > Run as administrator, then re-run."
}
Write-Ok "Running as Administrator"

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]($os.BuildNumber)
if ($build -lt 19041) {
    Write-Fail "Windows build $build is too old. WSL2 needs Windows 10 build 19041+ or Windows 11. Update Windows and re-run."
}
Write-Ok "Windows build $build (>= 19041)"

# ------------------------------------------------------- enable features

Write-Step "Enable WSL Windows features"

$rebootNeeded = $false
$features = @(
    'Microsoft-Windows-Subsystem-Linux',
    'VirtualMachinePlatform'
)

foreach ($f in $features) {
    if (Test-FeatureEnabled $f) {
        Write-Ok "$f already enabled"
        continue
    }
    Write-Host "    enabling $f..."
    $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
    if ($r.RestartNeeded) { $rebootNeeded = $true }
    Write-Ok "$f enabled"
}

if ($rebootNeeded) {
    Write-Warn "A Windows reboot is required before the WSL runtime can install."
    Write-Warn "Reboot now, then re-run this script. It will skip the steps already done."
    Write-Host ""
    $ans = Read-Host "Reboot now? [y/N]"
    if ($ans -match '^[Yy]') {
        Write-Host "Rebooting in 5 seconds..."
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
    exit 0
}

# --------------------------------------------------- install WSL runtime

Write-Step "Install WSL runtime"

if (Test-WslRuntime) {
    $verLine = (& wsl.exe --version 2>$null | Select-Object -First 1)
    Write-Ok "WSL runtime already installed ($verLine)"
} else {
    Write-Host "    running 'wsl --install --no-distribution'..."
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "wsl --install --no-distribution failed (exit $LASTEXITCODE)."
    }
    Write-Ok "WSL runtime installed"
}

# --------------------------------------------------- set default WSL2

Write-Step "Set WSL2 as default version"

& wsl.exe --set-default-version 2 *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "wsl --set-default-version 2 failed (exit $LASTEXITCODE)."
}
Write-Ok "Default WSL version is 2"

# --------------------------------------------------- distro availability

Write-Step "Check Ubuntu-22.04 availability"

$online = & wsl.exe --list --online 2>$null
$onlineClean = ($online -join "`n") -replace "`0", ''
if ($onlineClean -notmatch 'Ubuntu-22\.04') {
    Write-Fail "Ubuntu-22.04 is not in 'wsl --list --online'. Microsoft may have changed the catalog. Inspect manually with: wsl --list --online"
}
Write-Ok "Ubuntu-22.04 is available"

# --------------------------------------------------- install distro

Write-Step "Install Ubuntu-22.04"

if (Test-DistroInstalled 'Ubuntu-22.04') {
    Write-Ok "Ubuntu-22.04 already installed"
} else {
    Write-Host "    running 'wsl --install -d Ubuntu-22.04'..."
    Write-Host "    A new Ubuntu window will open and prompt you to create a UNIX"
    Write-Host "    user and password. Complete that prompt, then return here."
    Write-Host ""
    & wsl.exe --install -d Ubuntu-22.04
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "wsl --install -d Ubuntu-22.04 failed (exit $LASTEXITCODE)."
    }
    Write-Ok "Ubuntu-22.04 install command returned"
}

# --------------------------------------------------- next steps

Write-Host ""
Write-Step "Done"
Write-Host ""
Write-Host "Next:" -ForegroundColor White
Write-Host "  1. If you just created a new UNIX user in the Ubuntu window, the OOBE is" -ForegroundColor White
Write-Host "     complete. If the window has not opened yet, run: wsl -d Ubuntu-22.04" -ForegroundColor White
Write-Host ""
Write-Host "  2. Inside the Ubuntu shell, copy this repo folder into your home directory" -ForegroundColor White
Write-Host "     (or clone it from GitHub) and run:" -ForegroundColor White
Write-Host "         cd ~ && bash 01-wsl-system-deps.sh" -ForegroundColor White
Write-Host ""
Write-Host "  3. Always work under the Linux home directory (~/), never under /mnt/c/..." -ForegroundColor White
Write-Host "     Files under /mnt/c/ traverse a 9P bridge to NTFS and are 10-50x slower." -ForegroundColor White
Write-Host ""
