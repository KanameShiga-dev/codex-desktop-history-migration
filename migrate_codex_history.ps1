[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Export', 'Import', 'Verify')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$PackagePath,

    [string]$CodexHome = (Join-Path $HOME '.codex'),

    # Optional old-root=new-root mappings for migrated project paths.
    [string[]]$PathMap = @(),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DbHelper = Join-Path $ScriptRoot 'codex_history_db.py'
$HistoryDirectories = @('sessions', 'archived_sessions', 'attachments', 'codex-remote-attachments')
$IndexFiles = @('session_index.jsonl')

function Get-PythonCommand {
    foreach ($candidate in @('python', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw 'Python 3 was not found. Add Python 3 to PATH and retry.'
}

function Assert-CodexHome([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Codex home was not found: $Path"
    }
}

function Assert-SafePackagePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char]92)
    $root = [IO.Path]::GetPathRoot($full).TrimEnd([char]92)
    if ($full -eq $root -or $full -eq [IO.Path]::GetFullPath($CodexHome).TrimEnd([char]92)) {
        throw "This location cannot be used as a migration package: $full"
    }
}

function Assert-CodexStopped {
    $running = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue
    if ($running) {
        throw 'Close Codex Desktop completely before importing. Importing while Codex is running is blocked to protect the task database.'
    }
}

function Copy-Tree([string]$Source, [string]$Destination, [switch]$Overwrite) {
    if (-not (Test-Path -LiteralPath $Source)) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($Source.TrimEnd([char]92).Length).TrimStart([char]92)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        if ($Overwrite -or -not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force:$Overwrite
        }
    }
}

function Merge-SessionIndex([string]$Incoming, [string]$Existing) {
    $byId = [ordered]@{}
    foreach ($path in @($Existing, $Incoming)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $record = $_ | ConvertFrom-Json
                if ($record.id) { $byId[[string]$record.id] = $_ }
            }
        }
    }
    $temporary = "$Existing.migration.tmp"
    $byId.Values | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Existing -Force
}

function Merge-SessionIndexFromDatabase([string]$DatabaseJson, [string]$Existing) {
    if (-not (Test-Path -LiteralPath $DatabaseJson)) { return }
    $data = Get-Content -LiteralPath $DatabaseJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $threads = @($data.databases.state.tables.threads)
    $byId = [ordered]@{}
    if (Test-Path -LiteralPath $Existing) {
        Get-Content -LiteralPath $Existing -Encoding UTF8 | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $item = $_ | ConvertFrom-Json
                if ($item.id) { $byId[[string]$item.id] = $_ }
            }
        }
    }
    $added = 0
    foreach ($thread in $threads) {
        $id = [string]$thread.id
        if (-not $id -or $byId.Contains($id)) { continue }
        $seconds = [long]$thread.updated_at
        $updated = [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime.ToString('o')
        $record = [ordered]@{ id = $id; thread_name = [string]$thread.title; updated_at = $updated }
        $byId[$id] = ($record | ConvertTo-Json -Compress)
        $added++
    }
    $byId.Values | Set-Content -LiteralPath $Existing -Encoding UTF8
    Write-Host "Session index repaired: $added entries added"
}

function Repair-SessionLogPaths([string]$SessionsRoot, [string[]]$Mappings) {
    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return }
    $changed = 0
    foreach ($file in Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl') {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $updated = $text
        foreach ($mapping in $Mappings) {
            $parts = $mapping -split '=', 2
            if ($parts.Count -ne 2) { throw "Invalid -PathMap (expected old-root=new-root): $mapping" }
            $updated = $updated.Replace($parts[0], $parts[1])
            $updated = $updated.Replace('\\?\' + $parts[0], '\\?\' + $parts[1])
            # JSONL stores backslashes escaped, for example C:\\Codex.
            # Replace that representation too; otherwise opening a migrated
            # thread restores the old cwd from session_meta and hides it from
            # the newly mapped project.
            $slash = [string][char]92
            $doubleSlash = $slash + $slash
            $oldEscaped = $parts[0].Replace($slash, $doubleSlash)
            $newEscaped = $parts[1].Replace($slash, $doubleSlash)
            $updated = $updated.Replace($oldEscaped, $newEscaped)
        }
        if ($updated -ne $text) {
            [IO.File]::WriteAllText($file.FullName, $updated, (New-Object Text.UTF8Encoding($false)))
            $changed++
        }
    }
    Write-Host "Session log paths repaired: $changed files"
}

function Export-UiState([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $state = Get-Content -LiteralPath $Source -Raw -Encoding UTF8 | ConvertFrom-Json
    $allowed = @('project-order', 'pinned-thread-ids', 'electron-saved-workspace-roots', 'active-workspace-roots', 'electron-workspace-root-labels')
    $safe = [ordered]@{}
    foreach ($name in $allowed) {
        $property = $state.PSObject.Properties[$name]
        if ($null -ne $property) { $safe[$name] = $property.Value }
    }
    $safe | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Merge-UiState([string]$Incoming, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Incoming)) { return }
    $current = if (Test-Path -LiteralPath $Destination) {
        Get-Content -LiteralPath $Destination -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { [pscustomobject]@{} }
    $source = Get-Content -LiteralPath $Incoming -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in $source.PSObject.Properties) {
        $current | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }
    $current | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Convert-MappedWorkspacePath([object]$Value, [string[]]$Mappings) {
    if ($null -eq $Value) { return $Value }
    if ($Value -is [string]) {
        $result = [string]$Value
        if ($result.StartsWith('\\?\')) { $result = $result.Substring(4) }
        foreach ($mapping in $Mappings) {
            $parts = $mapping -split '=', 2
            if ($parts.Count -ne 2) { throw "Invalid -PathMap (expected old-root=new-root): $mapping" }
            $old = $parts[0].TrimEnd([char]92)
            $new = $parts[1].TrimEnd([char]92)
            if ($result -eq $old -or $result.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase)) {
                return $new + $result.Substring($old.Length)
            }
        }
        return $result
    }
    return $Value
}

function Repair-UiStatePaths([string]$Destination, [string[]]$Mappings) {
    if (-not (Test-Path -LiteralPath $Destination)) { return }
    $state = Get-Content -LiteralPath $Destination -Raw -Encoding UTF8 | ConvertFrom-Json
    $arrayKeys = @('project-order', 'electron-saved-workspace-roots')
    foreach ($key in $arrayKeys) {
        $property = $state.PSObject.Properties[$key]
        if ($null -ne $property) {
            $mapped = @($property.Value | ForEach-Object { Convert-MappedWorkspacePath $_ $Mappings }) | Select-Object -Unique
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $mapped -Force
        }
    }
    foreach ($key in @('active-workspace-roots')) {
        $property = $state.PSObject.Properties[$key]
        if ($null -ne $property) {
            if ($property.Value -is [System.Array]) {
                $mapped = @($property.Value | ForEach-Object { Convert-MappedWorkspacePath $_ $Mappings }) | Select-Object -Unique
            } else {
                $mapped = Convert-MappedWorkspacePath $property.Value $Mappings
            }
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $mapped -Force
        }
    }
    $state | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Destination -Encoding UTF8
    Write-Host 'Codex Desktop project paths repaired'
}

function Write-Manifest([string]$Root) {
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object Name -ne 'manifest.json'
    $entries = foreach ($file in $files) {
        [ordered]@{
            path = $file.FullName.Substring($Root.TrimEnd([char]92).Length).TrimStart([char]92).Replace([char]92, '/')
            length = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    [ordered]@{
        format = 'codex-history-migration'
        version = 1
        exported_at = (Get-Date).ToUniversalTime().ToString('o')
        source_codex_home = (Resolve-Path -LiteralPath $CodexHome).Path
        file_count = @($entries).Count
        files = @($entries)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Root 'manifest.json') -Encoding UTF8
}

function Test-Package([string]$Root) {
    $manifestPath = Join-Path $Root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json was not found: $Root" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.format -ne 'codex-history-migration' -or $manifest.version -ne 1) {
        throw 'This is not a supported migration package.'
    }
    $errors = @()
    foreach ($entry in $manifest.files) {
        $path = Join-Path $Root ([string]$entry.path).Replace('/', [char]92)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += "Missing: $($entry.path)"; continue }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -ne [long]$entry.length) { $errors += "Size mismatch: $($entry.path)"; continue }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $entry.sha256) { $errors += "Hash mismatch: $($entry.path)" }
    }
    if ($errors.Count) { throw ($errors -join [Environment]::NewLine) }
    Write-Host "Verification passed: $($manifest.file_count) files"
}

$PackagePath = [IO.Path]::GetFullPath($PackagePath)
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
Assert-SafePackagePath $PackagePath

switch ($Mode) {
    'Export' {
        Assert-CodexHome $CodexHome
        if (Test-Path -LiteralPath $PackagePath) {
            if (-not $Force) { throw "The output path already exists. Use another path or specify -Force: $PackagePath" }
            Remove-Item -LiteralPath $PackagePath -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $PackagePath | Out-Null
        $payload = Join-Path $PackagePath 'payload'
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        foreach ($directory in $HistoryDirectories) {
            Copy-Tree (Join-Path $CodexHome $directory) (Join-Path $payload $directory)
        }
        foreach ($file in $IndexFiles) {
            $source = Join-Path $CodexHome $file
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $payload $file) }
        }
        Export-UiState (Join-Path $CodexHome '.codex-global-state.json') (Join-Path $payload 'ui-state.json')
        $python = Get-PythonCommand
        & $python $DbHelper export --codex-home $CodexHome --output (Join-Path $payload 'database.json')
        if ($LASTEXITCODE -ne 0) { throw 'Database metadata export failed.' }
        Write-Manifest $PackagePath
        Test-Package $PackagePath
        Write-Host "Export completed: $PackagePath"
    }
    'Verify' { Test-Package $PackagePath }
    'Import' {
        Assert-CodexHome $CodexHome
        Assert-CodexStopped
        Test-Package $PackagePath
        $payload = Join-Path $PackagePath 'payload'
        $backup = Join-Path $CodexHome ('migration-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if ($PSCmdlet.ShouldProcess($CodexHome, "Import Codex task history (backup: $backup)")) {
            New-Item -ItemType Directory -Force -Path $backup | Out-Null
            foreach ($file in @('session_index.jsonl', '.codex-global-state.json')) {
                $source = Join-Path $CodexHome $file
                if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $backup $file) }
            }
            Get-ChildItem -LiteralPath $CodexHome -Recurse -Depth 1 -File -Include 'state_*.sqlite*','goals_*.sqlite*' | ForEach-Object {
                $relative = $_.FullName.Substring($CodexHome.TrimEnd([char]92).Length).TrimStart([char]92)
                $target = Join-Path $backup $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $target
            }
            foreach ($directory in $HistoryDirectories) {
                Copy-Tree (Join-Path $payload $directory) (Join-Path $CodexHome $directory) -Overwrite:$Force
            }
            Merge-SessionIndex (Join-Path $payload 'session_index.jsonl') (Join-Path $CodexHome 'session_index.jsonl')
            Merge-UiState (Join-Path $payload 'ui-state.json') (Join-Path $CodexHome '.codex-global-state.json')
            Repair-UiStatePaths (Join-Path $CodexHome '.codex-global-state.json') $PathMap
            $python = Get-PythonCommand
            $dbArgs = @('import', '--codex-home', $CodexHome, '--input', (Join-Path $payload 'database.json'))
            foreach ($mapping in $PathMap) {
                if ($mapping -notmatch '=') { throw "Invalid -PathMap (expected old-root=new-root): $mapping" }
                $dbArgs += @('--path-map', $mapping)
            }
            & $python $DbHelper @dbArgs
            if ($LASTEXITCODE -ne 0) { throw "Database metadata import failed. Backup: $backup" }
            Merge-SessionIndexFromDatabase (Join-Path $payload 'database.json') (Join-Path $CodexHome 'session_index.jsonl')
            Repair-SessionLogPaths (Join-Path $CodexHome 'sessions') $PathMap
            Write-Host "Import completed: $CodexHome"
            Write-Host "Existing data backup: $backup"
            Write-Host 'Restart Codex and confirm the task list, task contents, and attachments.'
        }
    }
}
