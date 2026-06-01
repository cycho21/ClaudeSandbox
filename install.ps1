# install.ps1 — Claude Sandbox installer for Windows PowerShell
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1 [-Prefix C:\Users\you\bin]
param(
    [string]$Prefix = "$env:USERPROFILE\bin"
)

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PS1ScriptPath = Join-Path $RepoDir "claude-sandbox.ps1"
$InstallPath    = Join-Path $Prefix "claude-sandbox.cmd"

Write-Host "=== Claude Sandbox Installer ===" -ForegroundColor Cyan
Write-Host "    Platform  : Windows (PowerShell)"
Write-Host "    Repo      : $RepoDir"
Write-Host "    Install -> : $InstallPath"
Write-Host ""

if (-not (Test-Path $PS1ScriptPath)) {
    Write-Error "claude-sandbox.ps1 not found in $RepoDir"
    exit 1
}

# Create install directory
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

# Create .cmd wrapper — calls PowerShell directly (no bash intermediary, so Docker PTY works)
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$PS1ScriptPath" %*
"@ | Out-File -FilePath $InstallPath -Encoding ASCII

Write-Host ">>> Installed: $InstallPath"

# Create .bat wrapper — PATHEXT resolves .bat before .cmd, both must be present
$InstallPathBat = Join-Path $Prefix "claude-sandbox.bat"
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$PS1ScriptPath" %*
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

Write-Host ""
Write-Host "=== Done! Run: claude-sandbox [project_path]" -ForegroundColor Green
