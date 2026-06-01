# install.ps1 — Claude Sandbox installer for Windows PowerShell
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1 [-Prefix C:\Users\you\bin]
param(
    [string]$Prefix = "$env:USERPROFILE\bin"
)

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $RepoDir "claude-sandbox.sh"
$InstallPath = Join-Path $Prefix "claude-sandbox.cmd"

Write-Host "=== Claude Sandbox Installer ===" -ForegroundColor Cyan
Write-Host "    Platform  : Windows (PowerShell)"
Write-Host "    Repo      : $RepoDir"
Write-Host "    Install -> : $InstallPath"
Write-Host ""

if (-not (Test-Path $ScriptPath)) {
    Write-Error "claude-sandbox.sh not found in $RepoDir"
    exit 1
}

# Create install directory
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

# Convert Windows path to Git Bash style: C:\foo\bar -> /c/foo/bar
$GitBashScript = $ScriptPath -replace '\\', '/'
if ($GitBashScript -match '^([A-Za-z]):(.*)') {
    $GitBashScript = '/' + $Matches[1].ToLower() + $Matches[2]
}

# Find Git Bash explicitly to avoid WSL bash taking precedence
$BashExe = $null
$GitBashCandidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe"
)
foreach ($candidate in $GitBashCandidates) {
    if (Test-Path $candidate) { $BashExe = $candidate; break }
}
if (-not $BashExe) {
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($bashCmd -and $bashCmd.Source -like "*Git*") { $BashExe = $bashCmd.Source }
}
if (-not $BashExe) { $BashExe = "bash" }

Write-Host "    Bash      : $BashExe"

# Create .cmd wrapper that invokes bash (Git Bash / WSL)
@"
@echo off
"$BashExe" "$GitBashScript" %*
"@ | Out-File -FilePath $InstallPath -Encoding ASCII

Write-Host ">>> Installed: $InstallPath"

# Create .bat wrapper — PowerShell resolves .bat before .cmd (per PATHEXT order),
# so both must point to the same script.
$InstallPathBat = Join-Path $Prefix "claude-sandbox.bat"
@"
@echo off
set MSYS_NO_PATHCONV=1
"$BashExe" "$GitBashScript" %*
"@ | Out-File -FilePath $InstallPathBat -Encoding ASCII

Write-Host ">>> Installed: $InstallPathBat"

# Add to user PATH if not already there
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$Prefix*") {
    [Environment]::SetEnvironmentVariable("PATH", "$Prefix;$UserPath", "User")
    Write-Host ">>> Added $Prefix to user PATH (restart terminal to apply)"
} else {
    Write-Host ">>> $Prefix is already in PATH"
}

# Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "!!! Docker not found. Install Docker Desktop:" -ForegroundColor Yellow
    Write-Host "    https://www.docker.com/products/docker-desktop/"
}

# Check Git Bash / bash availability
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "!!! bash not found. Install Git for Windows (includes Git Bash):" -ForegroundColor Yellow
    Write-Host "    https://git-scm.com/download/win"
}

Write-Host ""
Write-Host "=== Done! Run: claude-sandbox [project_path]" -ForegroundColor Green
