# Follow the game's debug log. Log resolution: $env:X4_DEBUGLOG > toolkit .claude/x4-paths.env
# (X4_DEBUGLOG, then X4_PROFILE\debug.txt) > the newest debug.txt under Documents\Egosoft\X4.
$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent $PSScriptRoot

function Read-PathsEnv {
    $values = @{}
    $toolkit = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { Join-Path $repoDir '..\..' }
    $envFile = Join-Path $toolkit '.claude\x4-paths.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$') { $values[$Matches[1]] = $Matches[2] }
        }
    }
    return $values
}

function Resolve-DebugLog {
    if ($env:X4_DEBUGLOG) { return $env:X4_DEBUGLOG }
    $paths = Read-PathsEnv
    if ($paths['X4_DEBUGLOG']) { return $paths['X4_DEBUGLOG'] }
    if ($paths['X4_PROFILE']) { return (Join-Path $paths['X4_PROFILE'] 'debug.txt') }
    $newest = Get-ChildItem -Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Egosoft\X4\*\debug.txt') `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    throw 'Cannot locate debug.txt. Set X4_DEBUGLOG (env var or toolkit .claude/x4-paths.env).'
}

$log = Resolve-DebugLog
Write-Output "Following $log (Ctrl+C to stop)"
Get-Content -LiteralPath $log -Tail 30 -Wait
