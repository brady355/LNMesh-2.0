param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('preflight','deploy','bootstrap','funding','links','payments','closes','baseline','breach','reboot','metadata','status')]
    [string]$Phase,
    [string]$Python
)
$ErrorActionPreference = 'Stop'
if (-not $Python) {
    $lnmeshBundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path -LiteralPath $lnmeshBundledPython) { $Python = $lnmeshBundledPython }
    else { $Python = (Get-Command python -ErrorAction Stop).Source }
}
$lnmeshCredential = Get-Credential -UserName 'brady' -Message 'Enter the Pi sudo password. SSH still uses your local key.'
$lnmeshPreviousPassword = $env:LN_MESH_SUDO_PASSWORD
function Invoke-LNMeshScript([string]$Name, [string]$Hosts='abc', [string]$Route='lan') {
    & $Python (Join-Path $PSScriptRoot 'runner.py') (Join-Path $PSScriptRoot "scripts\$Name.sh") --hosts $Hosts --route $Route --label $Name --timeout 600
    if ($LASTEXITCODE -ne 0) { throw "LNMesh phase failed: $Name. Inspect evidence before retrying." }
}
try {
    $env:LN_MESH_SUDO_PASSWORD = $lnmeshCredential.GetNetworkCredential().Password
    switch ($Phase) {
        'preflight' { Invoke-LNMeshScript 'preflight-root' }
        'deploy' {
            Invoke-LNMeshScript 'preflight-root'
            Invoke-LNMeshScript 'install-base'
            Invoke-LNMeshScript 'configure-mesh'
            Invoke-LNMeshScript 'verify-mesh' 'abc' 'mesh'
            Invoke-LNMeshScript 'configure-time'
            Invoke-LNMeshScript 'install-binaries'
            Invoke-LNMeshScript 'configure-bitcoin' 'a'
            Invoke-LNMeshScript 'configure-lnd'
            Invoke-LNMeshScript 'gateway-no-forward' 'a'
            Invoke-LNMeshScript 'isolate-leaf' 'bc' 'mesh'
            Invoke-LNMeshScript 'verify-isolation' 'bc' 'mesh'
        }
        'status' { Invoke-LNMeshScript 'final-status' 'abc' 'mesh' }
        { $_ -in 'reboot','metadata' } {
            & $Python (Join-Path $PSScriptRoot 'verification.py') $Phase
            if ($LASTEXITCODE -ne 0) { throw "Verification failed: $Phase. Inspect evidence before retrying." }
        }
        default {
            & $Python (Join-Path $PSScriptRoot 'experiment.py') $Phase
            if ($LASTEXITCODE -ne 0) { throw "Experiment phase failed: $Phase. Inspect evidence before retrying." }
        }
    }
}
finally {
    $env:LN_MESH_SUDO_PASSWORD = $lnmeshPreviousPassword
    $lnmeshCredential = $null
}
