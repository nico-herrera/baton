$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("patchthrough-contract-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $recordings = Join-Path $work "Recordings"
    $session = dotnet run --project (Join-Path $repo "windows/tools/SessionFixture") -c Release -- $recordings
    foreach ($name in @("meta.json", "transcript.json", "transcript.raw.json", "transcript.md", "handoff.md")) {
        if (-not (Test-Path (Join-Path $session $name))) { throw "fixture did not write $name" }
    }
    $list = node (Join-Path $repo "cli/bin/patchthrough.js") transcripts --recordings-dir $recordings
    if ($list -notmatch [regex]::Escape((Split-Path $session -Leaf))) { throw "CLI did not list Windows fixture" }
    Write-Host "cross-platform session contract passed"
}
finally {
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
}
