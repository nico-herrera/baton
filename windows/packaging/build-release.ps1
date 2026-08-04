[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [string] $OutputDirectory,

    [string] $InnoCompiler,

    [string] $CertificateThumbprint,

    [string] $TimestampUrl = 'http://timestamp.digicert.com',

    [switch] $SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDirectory = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDirectory '..\..'))
$project = Join-Path $repoRoot 'windows\src\Patchthrough.Windows\Patchthrough.Windows.csproj'
$installerScript = Join-Path $scriptDirectory 'Patchthrough.iss'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'dist'
} else {
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
}

$artifactStem = 'Patchthrough-windows-x64'
$zipPath = Join-Path $OutputDirectory "$artifactStem.zip"
$setupPath = Join-Path $OutputDirectory "$artifactStem-setup.exe"
$stagingDirectory = Join-Path $OutputDirectory '.windows-x64-staging'
$publishDirectory = Join-Path $stagingDirectory 'publish'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command exited with code $LASTEXITCODE"
    }
}

function Find-SignTool {
    $command = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $kitsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    $candidates = @(Get-ChildItem (Join-Path $kitsRoot 'Windows Kits\10\bin\*\x64\signtool.exe') -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending)
    if ($candidates.Count -eq 0) {
        throw 'signtool.exe was not found. Install the Windows SDK or omit -CertificateThumbprint.'
    }
    return $candidates[0].FullName
}

function Invoke-AuthenticodeSign {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        return
    }
    $signTool = Find-SignTool
    Invoke-Checked $signTool 'sign' '/sha1' $CertificateThumbprint '/fd' 'sha256' '/tr' $TimestampUrl '/td' 'sha256' '/v' $Path
    Invoke-Checked $signTool 'verify' '/pa' '/v' $Path
}

function Find-InnoCompiler {
    if (-not [string]::IsNullOrWhiteSpace($InnoCompiler)) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InnoCompiler)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Inno Setup compiler not found at $resolved"
        }
        return $resolved
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ISCC_PATH) -and (Test-Path -LiteralPath $env:ISCC_PATH -PathType Leaf)) {
        return $env:ISCC_PATH
    }

    $roots = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    ) | Select-Object -Unique
    foreach ($root in $roots) {
        foreach ($directory in @('Inno Setup 7', 'Inno Setup 6')) {
            $candidate = Join-Path $root "$directory\ISCC.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    throw 'ISCC.exe was not found. Install Inno Setup 6 or 7, pass -InnoCompiler, or use -SkipInstaller.'
}

function Write-Checksum {
    param([Parameter(Mandatory = $true)][string] $Path)

    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $line = "$hash  $([System.IO.Path]::GetFileName($Path))`n"
    [System.IO.File]::WriteAllText(
        "$Path.sha256",
        $line,
        [System.Text.UTF8Encoding]::new($false))
}

function Get-VersionInfoVersion {
    $core = ($Version -split '[-+]', 2)[0]
    return "$core.0"
}

function Copy-DotnetNotices {
    param([Parameter(Mandatory = $true)][string] $Destination)

    $projectDirectory = Split-Path -Parent $project
    $depsPath = Join-Path $projectDirectory 'obj\Release\net8.0-windows\win-x64\Patchthrough.deps.json'
    $assetsPath = Join-Path $projectDirectory 'obj\project.assets.json'
    if (-not (Test-Path -LiteralPath $depsPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) {
        throw 'dotnet publish did not leave the dependency manifests needed for release notices'
    }

    $deps = Get-Content -LiteralPath $depsPath -Raw | ConvertFrom-Json
    $runtime = @($deps.libraries.PSObject.Properties | Where-Object {
        $_.Name -like 'runtimepack.Microsoft.NETCore.App.Runtime.win-x64/*'
    })
    if ($runtime.Count -ne 1) {
        throw "expected one .NET runtime pack in $depsPath, found $($runtime.Count)"
    }
    $runtimeVersion = ($runtime[0].Name -split '/', 2)[1]

    $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json
    $packageRoots = @($assets.packageFolders.PSObject.Properties.Name)
    $runtimeDirectory = $null
    foreach ($packageRoot in $packageRoots) {
        $candidate = Join-Path $packageRoot "microsoft.netcore.app.runtime.win-x64\$runtimeVersion"
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $runtimeDirectory = $candidate
            break
        }
    }
    if ($null -eq $runtimeDirectory) {
        throw "could not find Microsoft.NETCore.App.Runtime.win-x64 $runtimeVersion in the NuGet package roots"
    }

    Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'LICENSE.TXT') -Destination (Join-Path $Destination 'DOTNET-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $Destination 'DOTNET-THIRD-PARTY-NOTICES.txt')
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
foreach ($artifact in @($zipPath, "$zipPath.sha256", $setupPath, "$setupPath.sha256")) {
    if (Test-Path -LiteralPath $artifact) {
        Remove-Item -LiteralPath $artifact -Force
    }
}
if (Test-Path -LiteralPath $stagingDirectory) {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $publishDirectory | Out-Null

try {
    Write-Host "Publishing Patchthrough $Version for win-x64"
    Invoke-Checked 'dotnet' 'restore' $project '--nologo'
    Invoke-Checked 'dotnet' 'publish' $project '--configuration' 'Release' '--self-contained' 'true' '--output' $publishDirectory '--no-restore' '--nologo' `
        "-p:Version=$Version" '-p:PublishSingleFile=true' '-p:IncludeNativeLibrariesForSelfExtract=true' `
        '-p:EnableCompressionInSingleFile=true' '-p:PublishTrimmed=false' '-p:DebugSymbols=false' '-p:DebugType=None' `
        '-p:IncludeSourceRevisionInInformationalVersion=false'

    $publishedExe = Join-Path $publishDirectory 'Patchthrough.exe'
    if (-not (Test-Path -LiteralPath $publishedExe -PathType Leaf)) {
        throw "dotnet publish did not produce $publishedExe"
    }

    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $publishDirectory 'LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\README.md') -Destination (Join-Path $publishDirectory 'README.md')
    Copy-Item -LiteralPath (Join-Path $scriptDirectory 'THIRD-PARTY-NOTICES.txt') -Destination $publishDirectory
    Copy-Item -LiteralPath (Join-Path $scriptDirectory 'APACHE-2.0.txt') -Destination $publishDirectory
    Copy-DotnetNotices $publishDirectory
    Invoke-AuthenticodeSign $publishedExe

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $publishDirectory,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false)
    Write-Checksum $zipPath

    if (-not $SkipInstaller) {
        $compiler = Find-InnoCompiler
        Write-Host "Compiling the per-user installer with $compiler"
        Invoke-Checked $compiler `
            "/DAppVersion=$Version" `
            "/DVersionInfoVersion=$(Get-VersionInfoVersion)" `
            "/DPublishDir=$publishDirectory" `
            "/DOutputDir=$OutputDirectory" `
            "/DRepoRoot=$repoRoot" `
            $installerScript
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
            throw "Inno Setup did not produce $setupPath"
        }
        Invoke-AuthenticodeSign $setupPath
        Write-Checksum $setupPath
    }

    Write-Host "Built $zipPath"
    if (-not $SkipInstaller) {
        Write-Host "Built $setupPath"
    }
} finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}
