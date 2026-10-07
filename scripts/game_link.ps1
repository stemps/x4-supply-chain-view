# Link or unlink this repo's src/ mod folder into the game's extensions folder via a directory junction.
# Extensions dir resolution: $env:X4_EXTENSIONS > toolkit .claude/x4-paths.env > $X4_GAME\extensions.
# -Source (repo-relative mod folder, default src) and -Name (extension folder name, default the
# repo folder name) link another mod folder from this repo, such as a development sample.
param(
    [Parameter(Mandatory = $true)][ValidateSet('link', 'unlink', 'status')][string]$Action,
    [string]$Source = 'src',
    [string]$Name = ''
)
$ErrorActionPreference = 'Stop'

$modDir = Split-Path -Parent $PSScriptRoot
$modName = if ($Name) { $Name } else { Split-Path -Leaf $modDir }
$srcDir = Join-Path $modDir $Source
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { throw "Mod folder not found: $srcDir" }

function Read-PathsEnv {
    $values = @{}
    $toolkit = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { Join-Path $modDir '..\..' }
    $envFile = Join-Path $toolkit '.claude\x4-paths.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*"?([^"]*)"?\s*$') { $values[$Matches[1]] = $Matches[2] }
        }
    }
    return $values
}

function Resolve-ExtensionsDir {
    if ($env:X4_EXTENSIONS) { return $env:X4_EXTENSIONS }
    $paths = Read-PathsEnv
    if ($paths['X4_EXTENSIONS']) { return $paths['X4_EXTENSIONS'] }
    $game = if ($env:X4_GAME) { $env:X4_GAME } else { $paths['X4_GAME'] }
    if ($game) { return (Join-Path $game 'extensions') }
    throw 'Cannot locate the game extensions folder. Set X4_EXTENSIONS or X4_GAME (env var or toolkit .claude/x4-paths.env).'
}

$extensions = Resolve-ExtensionsDir
if (-not (Test-Path -LiteralPath $extensions -PathType Container)) {
    throw "Extensions folder not found: $extensions"
}
$linkPath = Join-Path $extensions $modName
$item = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
$isLink = $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
$target = if ($isLink) { @($item.Target)[0] } else { $null }

switch ($Action) {
    'status' {
        if (-not $item) { Write-Output "Not linked: $linkPath does not exist." }
        elseif ($isLink -and (Resolve-Path -LiteralPath $target).Path -ne (Resolve-Path -LiteralPath $srcDir).Path) {
            Write-Output "Outdated link: $linkPath -> $target (expected $srcDir). Unlink it, then link again."
        }
        elseif ($isLink) { Write-Output "Linked: $linkPath -> $target" }
        else { Write-Output "Not a link: $linkPath is a regular folder (copied deploy?)." }
    }
    'link' {
        if ($isLink) {
            if ((Resolve-Path -LiteralPath $target).Path -eq (Resolve-Path -LiteralPath $srcDir).Path) {
                Write-Output "Already linked: $linkPath -> $target"
                exit 0
            }
            throw "$linkPath already links to $target. Unlink it first."
        }
        if ($item) { throw "$linkPath exists as a regular folder. Remove or rename it first; refusing to overwrite." }
        New-Item -ItemType Junction -Path $linkPath -Target $srcDir | Out-Null
        Write-Output "Linked: $linkPath -> $srcDir"
    }
    'unlink' {
        if (-not $item) { Write-Output "Nothing to unlink: $linkPath does not exist."; exit 0 }
        if (-not $isLink) { throw "$linkPath is a regular folder, not a link. Refusing to delete it." }
        # Non-recursive delete removes only the reparse point, never the target's contents.
        [IO.Directory]::Delete($linkPath, $false)
        Write-Output "Unlinked: $linkPath (was -> $target)"
    }
}
