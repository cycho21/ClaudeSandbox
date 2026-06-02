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
$Rebuild     = $false
$ProjectArg  = $null
$ClaudeFlags = @()
$ConsumeNext = $false   # true when the previous flag takes a positional argument

foreach ($a in $args) {
    if ($a -eq '--rebuild') {
        $Rebuild = $true
    } elseif ($ConsumeNext) {
        # This token is an argument to the previous claude flag (e.g. session ID after --resume)
        $ClaudeFlags += $a
        $ConsumeNext = $false
    } elseif ($a -eq '--resume') {
        $ClaudeFlags += $a
        $ConsumeNext = $true
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

$CaBundle = Join-Path $REPO_DIR "ca-bundle.pem"
if (Test-Path $CaBundle) {
    $DockerArgs += '-v', "$(ToDockerMount $CaBundle):/etc/ssl/certs/ca-bundle.pem:ro"
    $DockerArgs += '-e', "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-bundle.pem"
}

if ($env:ANTHROPIC_API_KEY) {
    $DockerArgs += '-e', "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
}

# Pass explicit env override, or auto-extract from Windows Credential Manager
if ($env:GITLAB_TOKEN) {
    $DockerArgs += '-e', "GITLAB_TOKEN=$env:GITLAB_TOKEN"
    if ($env:GITLAB_HOST) { $DockerArgs += '-e', "GITLAB_HOST=$env:GITLAB_HOST" }
} else {
    # Read Git credentials directly from Windows Credential Manager via PInvoke
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinCred {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct CRED {
        public uint Flags, Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public long LastWritten;
        public uint BlobSize;
        public IntPtr Blob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CredRead(string target, uint type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);
    public static string[] Get(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        try {
            var c = Marshal.PtrToStructure<CRED>(ptr);
            if (c.BlobSize == 0 || c.Blob == IntPtr.Zero) return null;
            var bytes = new byte[c.BlobSize];
            Marshal.Copy(c.Blob, bytes, 0, (int)c.BlobSize);
            return new[] { c.UserName ?? "", Encoding.Unicode.GetString(bytes) };
        } finally { CredFree(ptr); }
    }
}
'@ 2>$null

    function Get-WinGitCred([string]$RemoteHost) {
        foreach ($target in @("git:https://$RemoteHost", "https://$RemoteHost")) {
            try {
                $r = [WinCred]::Get($target)
                if ($r -and $r[1]) { return @{ Token = $r[1].Trim(); User = $r[0].Trim() } }
            } catch {}
        }
        return $null
    }

    $remoteLines = & git -C $ProjectPath remote -v 2>$null
    $httpsHosts  = @()
    foreach ($line in $remoteLines) {
        if ($line -match 'https://(?:[^@]+@)?([^/:@\s]+)') { $httpsHosts += $Matches[1] }
    }
    Write-Host "    GitLab    : $(if ($httpsHosts) { $httpsHosts -join ', ' } else { '(no HTTPS remotes found)' })"
    foreach ($h in ($httpsHosts | Select-Object -Unique)) {
        $cred = Get-WinGitCred $h
        if ($cred) {
            Write-Host "    Auth      : token injected for $h"

            # Patch gitconfig: replace Windows GCM helper with store
            $gcContent = if (Test-Path $GitConfig) { Get-Content $GitConfig -Raw } else { "" }
            $gcPatched  = $gcContent -replace '(?m)([ \t]*helper[ \t]*=[ \t]*)manager\S*', '${1}store'
            if ($gcPatched -notmatch '(?m)^\s*helper\s*=\s*store') {
                $gcPatched += "`n[credential]`n`thelper = store`n"
            }
            $tmpGitconfig = "$env:TEMP\.sandbox-gitconfig"
            [System.IO.File]::WriteAllText($tmpGitconfig, $gcPatched, [System.Text.Encoding]::UTF8)

            # Write git-credentials file
            $gitCredUser = if ($cred.User) { $cred.User } else { "oauth2" }
            $tmpGitCreds = "$env:TEMP\.sandbox-git-credentials"
            [System.IO.File]::WriteAllText($tmpGitCreds,
                "https://${gitCredUser}:$($cred.Token)@${h}`n",
                [System.Text.Encoding]::ASCII)

            $DockerArgs += '-v', "$(ToDockerMount $tmpGitconfig):/tmp/.gitconfig.host:ro"
            $DockerArgs += '-v', "$(ToDockerMount $tmpGitCreds):/home/node/.git-credentials:ro"
            $GitConfigMounted = $true
            break
        } else {
            Write-Host "    Auth      : no credential found for $h (set GITLAB_TOKEN manually)"
        }
    }
}

# Mount original gitconfig if not already replaced by credential-patched version
if (-not $GitConfigMounted -and (Test-Path $GitConfig)) {
    $DockerArgs += '-v', "$(ToDockerMount $GitConfig):/tmp/.gitconfig.host:ro"
}

$SshDir = "$env:USERPROFILE\.ssh"
if (Test-Path $SshDir) {
    $DockerArgs += '-v', "$(ToDockerMount $SshDir):/tmp/.ssh.host:ro"
}

$DockerArgs += $IMAGE
if ($ClaudeFlags.Count -gt 0) { $DockerArgs += $ClaudeFlags }

# ── Launch ────────────────────────────────────────────────────────────────────
& docker @DockerArgs
exit $LASTEXITCODE
