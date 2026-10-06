param(
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$GamePath,
    [switch]$SkipVersionCheck,
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$AppId = '3010850'
$KnownHash = '7B52139D47DFEC98930C3C96696FBC5B2991EDFEE140D19FB72A016655EDC670'
$Package = Split-Path -Parent $MyInvocation.MyCommand.Path
$ShortcutName = 'Gears of War E-Day (offline).lnk'
$DataFolderName = '_offline_campaign'

function Find-Game {
    if ($GamePath) { return $GamePath }
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $steam = $steam -replace '/', '\'
    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $acf = Join-Path $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path $acf)) { continue }
        $folder = 'GoWEDay'
        $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"')
        if ($m.Success) { $folder = $m.Groups[1].Value }
        $game = Join-Path $library "steamapps\common\$folder"
        if (Test-Path $game) { return $game }
    }
    return $null
}

function Edit-ModsTxt($file, [scriptblock]$change) {
    # Keeps the file's encoding (UTF-8 with or without BOM).
    $bytes = [IO.File]::ReadAllBytes($file)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = & $change ([IO.File]::ReadAllText($file))
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $bom))
}

function Get-ShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
}

function Install($game) {
    $win64 = Join-Path $game 'FairlightConcept\Binaries\Win64'
    $exe = Join-Path $win64 'GoWEDay-Steam.exe'
    $hash = (Get-FileHash $exe -Algorithm SHA256).Hash
    if ($hash -ne $KnownHash -and -not $SkipVersionCheck) {
        Write-Warning 'Your game version differs from the one this mod was tested with (CL-4894450, Steam build 25708270).'
        Write-Warning 'After a game update the mod may not work.'
        if ((Read-Host 'Continue anyway? (y/n)') -ne 'y') { throw 'Installation cancelled.' }
    }

    $data = Join-Path $game $DataFolderName
    New-Item -ItemType Directory -Force $data | Out-Null
    $manifestFile = Join-Path $data 'install.json'
    if (Test-Path $manifestFile) {
        throw 'The mod is already installed. Run UNINSTALL.cmd first.'
    }
    $manifest = [ordered]@{ Mode = ''; ToRemove = @(); ModsTxtEntry = $false; PreviousMod = $null; Shortcut = $null }

    $saves = Join-Path $env:LOCALAPPDATA 'Microsoft\Gears of War E-Day\Saves'
    if (Test-Path $saves) {
        $backup = Join-Path $data ('saves-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item $saves $backup -Recurse
        Write-Host "Save backup: $backup"
    }

    $ue4ss = Join-Path $win64 'ue4ss'
    $hasUe4ss = (Test-Path (Join-Path $win64 'dwmapi.dll')) -or (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))
    if ($hasUe4ss) {
        # UE4SS is already installed (e.g. with other mods): only add this mod.
        $manifest.Mode = 'attached'
        $mods = Join-Path $ue4ss 'Mods'
        $mod = Join-Path $mods 'OfflineCampaign'
        if (Test-Path $mod) {
            $previous = Join-Path $data 'previous-OfflineCampaign'
            Copy-Item $mod $previous -Recurse
            $manifest.PreviousMod = $previous
            Remove-Item $mod -Recurse -Force
        }
        Copy-Item (Join-Path $Package 'ue4ss\Mods\OfflineCampaign') $mod -Recurse
        $manifest.ToRemove += $mod
        $modsTxt = Join-Path $mods 'mods.txt'
        if ((Test-Path $modsTxt) -and ([IO.File]::ReadAllText($modsTxt) -notmatch '(?m)^\s*OfflineCampaign\s*:')) {
            Edit-ModsTxt $modsTxt {
                param($text)
                if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
                $text + "OfflineCampaign : 1`r`n"
            }
            $manifest.ModsTxtEntry = $true
        }
        Write-Host 'Existing UE4SS found - only the OfflineCampaign mod was added.'
    } else {
        $manifest.Mode = 'full'
        Copy-Item (Join-Path $Package 'ue4ss') $ue4ss -Recurse
        Copy-Item (Join-Path $Package 'dwmapi.dll') (Join-Path $ue4ss 'dwmapi.dll.offline')
        $manifest.ToRemove += $ue4ss
        Write-Host 'Installed UE4SS with the OfflineCampaign mod (active only for offline launches).'
    }

    $launcher = Join-Path $game 'Play-offline.cmd'
    Copy-Item (Join-Path $Package 'Play-offline.cmd') $launcher -Force
    $manifest.ToRemove += $launcher

    if (-not $NoShortcut) {
        $shortcut = Get-ShortcutPath
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($shortcut)
        $lnk.TargetPath = $launcher
        $lnk.WorkingDirectory = $game
        $lnk.IconLocation = "$exe,0"
        $lnk.WindowStyle = 7
        $lnk.Save()
        $manifest.Shortcut = $shortcut
        Write-Host "Desktop shortcut: $shortcut"
    }

    $manifest | ConvertTo-Json | Set-Content $manifestFile -Encoding UTF8
    Write-Host ''
    Write-Host 'Done. Switch Steam to Offline Mode and start the game with the desktop shortcut'
    Write-Host '(or Play-offline.cmd in the game folder), then CAMPAIGN -> CONTINUE / NEW / LOAD.'
}

function Uninstall($game) {
    $data = Join-Path $game $DataFolderName
    $manifestFile = Join-Path $data 'install.json'
    if (-not (Test-Path $manifestFile)) { throw 'No installation of this mod was found.' }
    $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json

    $active = Join-Path $game 'FairlightConcept\Binaries\Win64\dwmapi.dll'
    $ours = Join-Path $game 'FairlightConcept\Binaries\Win64\ue4ss\dwmapi.dll.offline'
    if ($manifest.Mode -eq 'full' -and (Test-Path $active) -and (Test-Path $ours) -and
        (Get-FileHash $active).Hash -eq (Get-FileHash $ours).Hash) {
        Remove-Item $active -Force
    }
    foreach ($p in $manifest.ToRemove) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
    if ($manifest.PreviousMod -and (Test-Path $manifest.PreviousMod)) {
        $mod = Join-Path $game 'FairlightConcept\Binaries\Win64\ue4ss\Mods\OfflineCampaign'
        Copy-Item $manifest.PreviousMod $mod -Recurse
        Remove-Item $manifest.PreviousMod -Recurse -Force
    }
    if ($manifest.ModsTxtEntry) {
        $modsTxt = Join-Path $game 'FairlightConcept\Binaries\Win64\ue4ss\Mods\mods.txt'
        if (Test-Path $modsTxt) {
            Edit-ModsTxt $modsTxt {
                param($text)
                [regex]::Replace($text, '(?m)^[ \t]*OfflineCampaign[ \t]*:.*(\r?\n)?', '')
            }
        }
    }
    if ($manifest.Shortcut -and (Test-Path $manifest.Shortcut)) { Remove-Item $manifest.Shortcut -Force }
    Remove-Item $manifestFile -Force
    Write-Host 'Mod uninstalled. Your save backups are still in:'
    Write-Host "  $data"
}

try {
    $game = Find-Game
    if (-not $game -or -not (Test-Path (Join-Path $game 'FairlightConcept\Binaries\Win64\GoWEDay-Steam.exe'))) {
        throw 'Gears of War: E-Day was not found in your Steam libraries. Use -GamePath "<game folder>".'
    }
    Write-Host "Game folder: $game"
    if (Get-Process 'GoWEDay-Steam' -ErrorAction SilentlyContinue) {
        throw 'The game is running - close it and try again.'
    }
    if ($Action -eq 'Install') { Install $game } else { Uninstall $game }
    exit 0
} catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
