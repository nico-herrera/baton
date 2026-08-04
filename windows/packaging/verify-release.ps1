[CmdletBinding()]
param(
    [string] $ArtifactDirectory,

    [string] $ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
    $ArtifactDirectory = Join-Path $repoRoot 'dist'
} else {
    $ArtifactDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactDirectory)
}

$zipPath = Join-Path $ArtifactDirectory 'Patchthrough-windows-x64.zip'
$setupPath = Join-Path $ArtifactDirectory 'Patchthrough-windows-x64-setup.exe'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("patchthrough-release-" + [Guid]::NewGuid().ToString('N'))
$expanded = Join-Path $scratch 'expanded'
$installed = Join-Path $scratch 'installed'
$installLog = Join-Path $scratch 'install.log'
$uninstallLog = Join-Path $scratch 'uninstall.log'
$uninstaller = Join-Path $installed 'unins000.exe'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Checksum {
    param([Parameter(Mandatory = $true)][string] $Path)

    $checksumPath = "$Path.sha256"
    Assert-True (Test-Path -LiteralPath $checksumPath -PathType Leaf) "missing $checksumPath"
    $expected = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($actual -eq $expected) "checksum mismatch for $Path"
}

function Invoke-Process {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string[]] $Arguments = @()
    )

    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    Assert-True ($process.ExitCode -eq 0) "$Path exited with code $($process.ExitCode)"
}

Assert-True (Test-Path -LiteralPath $zipPath -PathType Leaf) "missing $zipPath"
Assert-True (Test-Path -LiteralPath $setupPath -PathType Leaf) "missing $setupPath"
Assert-Checksum $zipPath
Assert-Checksum $setupPath

New-Item -ItemType Directory -Force -Path $expanded | Out-Null
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expanded
    $portableExe = Join-Path $expanded 'Patchthrough.exe'
    Assert-True (Test-Path -LiteralPath $portableExe -PathType Leaf) 'portable ZIP has no Patchthrough.exe'
    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'LICENSE.txt') -PathType Leaf) 'portable ZIP has no license'
    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'README.md') -PathType Leaf) 'portable ZIP has no README'
    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'THIRD-PARTY-NOTICES.txt') -PathType Leaf) 'portable ZIP has no third-party notices'
    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'APACHE-2.0.txt') -PathType Leaf) 'portable ZIP has no Apache license'
    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'DOTNET-LICENSE.txt') -PathType Leaf) 'portable ZIP has no .NET license'
    Assert-True (Test-Path -LiteralPath (Join-Path $expanded 'DOTNET-THIRD-PARTY-NOTICES.txt') -PathType Leaf) 'portable ZIP has no .NET notices'
    # Whisper.net.Runtime.Vulkan once added its Linux natives to a win-x64
    # publish, which put 61 MB of unloadable ELF objects in the download. The
    # Windows natives ride inside the single-file executable, so a loose .so or
    # .dylib here means that regressed.
    # Assert-True evaluates its message eagerly, and strict mode rejects a
    # property read on an empty array, so name the files in a separate step.
    $foreign = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Include '*.so', '*.dylib')
    $foreignNames = @($foreign | ForEach-Object { $_.Name })
    Assert-True ($foreign.Count -eq 0) "portable ZIP carries non-Windows native libraries: $($foreignNames -join ', ')"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        $actualVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($portableExe).ProductVersion
        Assert-True ($actualVersion -eq $ExpectedVersion) "portable version is '$actualVersion', expected '$ExpectedVersion'"
    }
    Invoke-Process $portableExe

    Invoke-Process $setupPath @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/SP-',
        "/DIR=`"$installed`"",
        "/LOG=`"$installLog`""
    )

    $installedExe = Join-Path $installed 'Patchthrough.exe'
    Assert-True (Test-Path -LiteralPath $installedExe -PathType Leaf) 'installer did not install Patchthrough.exe'
    # The installer copies the same publish directory, so it repeats any stray
    # native library the ZIP carries. Its [Files] section selects those files on
    # its own, so assert the installed tree separately.
    $installedForeign = @(Get-ChildItem -LiteralPath $installed -Recurse -File -Include '*.so', '*.dylib')
    $installedForeignNames = @($installedForeign | ForEach-Object { $_.Name })
    Assert-True ($installedForeign.Count -eq 0) "installer carries non-Windows native libraries: $($installedForeignNames -join ', ')"
    Invoke-Process $installedExe

    $appPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\App Paths\Patchthrough.exe'
    $registeredExe = (Get-Item -LiteralPath $appPath).GetValue('')
    Assert-True ($registeredExe -eq $installedExe) 'installer did not register the executable App Path'

    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $pathEntries = @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') })
    Assert-True ($pathEntries -contains $installed.TrimEnd('\')) 'installer did not add Patchthrough to the user PATH'

    Assert-True (Test-Path -LiteralPath $uninstaller -PathType Leaf) 'installer did not install an uninstaller'
    Invoke-Process $uninstaller @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        "/LOG=`"$uninstallLog`""
    )

    Assert-True (-not (Test-Path -LiteralPath $installedExe)) 'uninstaller left Patchthrough.exe behind'
    Assert-True (-not (Test-Path -LiteralPath $appPath)) 'uninstaller left the App Path registration behind'
    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $pathEntries = @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') })
    Assert-True ($pathEntries -notcontains $installed.TrimEnd('\')) 'uninstaller left Patchthrough on the user PATH'

    Write-Host 'Windows portable ZIP and installer passed release verification.'
} finally {
    if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
        try {
            Start-Process -FilePath $uninstaller -ArgumentList @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
            ) -Wait -NoNewWindow
        } catch {
            Write-Warning "Cleanup could not run the uninstaller: $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
