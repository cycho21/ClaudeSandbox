# claude-sandbox.ps1 — Windows PowerShell launcher for Claude Code sandbox
# Usage:
#   claude-sandbox [project_path] [claude_flags...]
#   claude-sandbox --resume <session_id>
#   claude-sandbox --rebuild

# Do NOT set $ErrorActionPreference = 'Stop' — PowerShell treats any docker
# stderr (including harmless progress/info messages) as terminating errors.
# Instead we check $LASTEXITCODE explicitly where it matters.

$IMAGE    = "claude-sandbox"
$REPO_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# Manual arg parsing — first non-flag is project path, rest go to claude
$Rebuild    = $false
$ProjectArg = $null
$ClaudeFlags = @()

foreach ($a in $args) {
    if ($a -eq '--rebuild') {
        $Rebuild = $true
    } elseif ($null -eq $ProjectArg -and -not ($a -like '-*')) {
        $ProjectArg = $a
    } else {
        $ClaudeFlags += $a
    }
}

if ($ProjectArg) {
    $ProjectPath = (Resolve-Path $ProjectArg).Path
} else {
    $ProjectPath = (Get-Location).Path
}

# ── Path conversions ────────────────────────────────────────────────────────
function ToDockerMount([string]$p) {
    # D:\foo\bar → D:/foo/bar  (Docker Desktop volume mount format)
    $p -replace '\\', '/'
}

function ToContainerPath([string]$p) {
    # D:\foo\bar → //d/foo/bar
    # Double-slash: Linux treats //path == /path; avoids any MSYS conversion in the chain.
    if ($p -match '^([A-Za-z]):\\(.*)') {
        return '//' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
    }
    return $p
}

# ── Config directories ───────────────────────────────────────────────────────
$ClaudeDir = "$env:USERPROFILE\.claude"
$GcloudDir = "$env:USERPROFILE\AppData\Roaming\gcloud"

$ProjectMount     = ToDockerMount $ProjectPath
$ProjectContainer = ToContainerPath $ProjectPath
$ClaudeMount      = ToDockerMount $ClaudeDir

# Container name — MD5 of mount path (matches bash script naming)
$md5   = [System.Security.Cryptography.MD5]::Create()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($ProjectMount)
$hash  = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$ContainerName = "claude-sandbox-$($hash.Substring(0,8))"

# ── Docker check ─────────────────────────────────────────────────────────────
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Docker is not installed or not on PATH." -ForegroundColor Red
    exit 1
}

# ── Build image ───────────────────────────────────────────────────────────────
docker image inspect $IMAGE *>&1 | Out-Null
$imageExists = $LASTEXITCODE -eq 0

if ($Rebuild -or -not $imageExists) {
    Write-Host ">>> Building ${IMAGE} image (first time ~5 min)..."
    docker build -t $IMAGE $REPO_DIR
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host ""
}

Write-Host ">>> Claude Code Sandbox  [windows]"
Write-Host "    Project   : $ProjectPath"
Write-Host "    Mount at  : $ProjectContainer"
Write-Host "    Container : $ContainerName"
Write-Host ""

# Remove stale container (silently ignore "no such container")
docker rm -f $ContainerName *>&1 | Out-Null

# ── Assemble docker args ─────────────────────────────────────────────────────
$ProtectHarness = if ($env:CLAUDE_SANDBOX_PROTECT_HARNESS) { $env:CLAUDE_SANDBOX_PROTECT_HARNESS } else { "1" }

$DockerArgs = @(
    'run', '-it', '--rm', "--name=$ContainerName",
    '-v', "${ClaudeMount}:/home/node/.claude",
    '-v', "${ProjectMount}:${ProjectContainer}",
    '-e', "HOST_PLATFORM=windows",
    '-e', "NODE_TLS_REJECT_UNAUTHORIZED=0",
    '-e', "CLAUDE_CODE_USE_VERTEX=1",
    '-e', "ANTHROPIC_VERTEX_PROJECT_ID=r-uv-admin",
    '-e', "CLOUD_ML_REGION=global",
    '-e', "CLAUDE_SANDBOX_PROTECT_HARNESS=$ProtectHarness",
    '-w', $ProjectContainer
)

if (Test-Path $GcloudDir) {
    $GcloudMount = ToDockerMount $GcloudDir
    $DockerArgs += '-v', "${GcloudMount}:/home/node/.config/gcloud"
    $DockerArgs += '-e', "GOOGLE_APPLICATION_CREDENTIALS=/home/node/.config/gcloud/application_default_credentials.json"
}

$GitConfig = "$env:USERPROFILE\.gitconfig"
if (Test-Path $GitConfig) {
    $DockerArgs += '-v', "$(ToDockerMount $GitConfig):/tmp/.gitconfig.host:ro"
}

$CaBundle = Join-Path $REPO_DIR "ca-bundle.pem"
if (Test-Path $CaBundle) {
    $DockerArgs += '-v', "$(ToDockerMount $CaBundle):/etc/ssl/certs/ca-bundle.pem:ro"
    $DockerArgs += '-e', "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-bundle.pem"
}

if ($env:ANTHROPIC_API_KEY) {
    $DockerArgs += '-e', "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
}

$DockerArgs += $IMAGE
if ($ClaudeFlags.Count -gt 0) { $DockerArgs += $ClaudeFlags }

# ── Launch ────────────────────────────────────────────────────────────────────
& docker @DockerArgs
exit $LASTEXITCODE
