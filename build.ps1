<#
.SYNOPSIS
    Package LaxxPing into a distributable zip.

.DESCRIPTION
    Produces dist\LaxxPing-<version>.zip containing a single top-level
    LaxxPing\ folder, which is the layout a user can extract straight into
    Interface\AddOns.

    The version is read from the .toc rather than passed in, so the zip name
    and the version the game reports can never disagree.

    Staging into a clean directory first is the point of the script: zipping
    the working tree in place would sweep in .git, the build output itself,
    and whatever an editor left lying around -- and the resulting archive
    would still install, so nobody would notice.
#>
[CmdletBinding()]
param(
    # Files that belong in the shipped addon. Anything not named here is not
    # in the build, which is the safe direction for a list to be wrong in.
    [string[]]$Include = @(
        "LaxxPing.toc",
        "LaxxPing.lua",
        "LaxxPing_Options.lua",
        "Bindings.xml",
        "README.md",
        "LICENSE"
    )
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$name = "LaxxPing"

$tocPath = Join-Path $root "$name.toc"
if (-not (Test-Path $tocPath)) { throw "No $name.toc beside this script." }

$versionLine = Select-String -Path $tocPath -Pattern '^## Version:' | Select-Object -First 1
if (-not $versionLine) { throw "No '## Version:' directive in $name.toc." }
$version = ($versionLine.Line -replace '^## Version:\s*', '').Trim()
if ([string]::IsNullOrWhiteSpace($version)) { throw "Empty version in $name.toc." }

$dist = Join-Path $root "dist"
$stage = Join-Path $root ".build"
$payload = Join-Path $stage $name
$zip = Join-Path $dist "$name-$version.zip"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $payload -Force | Out-Null
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

foreach ($f in $Include) {
    $src = Join-Path $root $f
    if (-not (Test-Path $src)) { throw "Listed in the build but missing: $f" }
    Copy-Item $src -Destination (Join-Path $payload $f)
}

if (Test-Path $zip) { Remove-Item $zip -Force }

# Entries are written BY HAND, with forward slashes, and neither
# Compress-Archive nor ZipFile::CreateFromDirectory is used.
#
# Both of those write entry paths with BACKSLASHES on Windows PowerShell 5.1
# (.NET Framework; fixed only in .NET Core). The zip spec requires forward
# slashes, so a strict extractor produces a single file literally named
# "LaxxPing\LaxxPing.lua" rather than a folder, and the addon does not load.
# Windows' own extractor tolerates it, which is exactly why this ships broken
# and is reported later by somebody on another tool.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
try {
    $archive = New-Object System.IO.Compression.ZipArchive(
        $fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($f in $Include) {
            $entry = $archive.CreateEntry("$name/$f",
                [System.IO.Compression.CompressionLevel]::Optimal)
            $out = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes((Join-Path $payload $f))
                $out.Write($bytes, 0, $bytes.Length)
            } finally { $out.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $fs.Dispose() }

Remove-Item $stage -Recurse -Force

$size = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host "$name $version  ->  dist\$name-$version.zip  ($size KB)" -ForegroundColor Green
Write-Host "Contents:" -ForegroundColor DarkGray
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $archive.Entries | ForEach-Object { Write-Host ("  " + $_.FullName) -ForegroundColor DarkGray }
} finally {
    $archive.Dispose()
}
