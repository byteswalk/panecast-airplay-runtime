param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Msys2Root = 'C:\msys64',
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$stageUcrt = Join-Path $RepoRoot 'out/runtime/ucrt64'
$bin = Join-Path $stageUcrt 'bin'
$plugins = Join-Path $stageUcrt 'lib/gstreamer-1.0'
$scanner = Join-Path $stageUcrt 'libexec/gstreamer-1.0'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'uxplay.exe') -PathType Leaf)) {
    throw "Runtime is not staged. Run scripts/build-runtime.ps1 first (missing $bin\uxplay.exe)."
}

$pacman = Join-Path $Msys2Root 'usr/bin/pacman.exe'
if (-not (Test-Path -LiteralPath $pacman -PathType Leaf)) {
    throw "MSYS2 not found: $Msys2Root"
}

$env:MSYSTEM = 'UCRT64'
function Convert-ToMsysPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full -match '^([A-Za-z]):/(.*)$') {
        return "/$($Matches[1].ToLower())/$($Matches[2])"
    }
    throw "Cannot convert path for MSYS2: $Path"
}

# 1) Map every binary in the staged tree to its owning MSYS2 package.
$filePackages = @{}
foreach ($file in Get-ChildItem -LiteralPath $stageUcrt -Recurse -File) {
    if ($file.Extension -notin '.dll', '.exe') { continue }
    $msys = Convert-ToMsysPath $file.FullName
    $owned = & $pacman -Qo $msys 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $owned -match '^(.+) is owned by (.+?) (\S+) ([\d\.:\-]+)$') {
        $filePackages[$file.FullName] = $Matches[2].Trim()
    }
}

$packageNames = $filePackages.Values | Sort-Object -Unique
$components = @()
$licenseDir = Join-Path $RepoRoot 'out/licenses'
New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null

foreach ($package in $packageNames) {
    $pkgLicenseDir = Join-Path $Msys2Root "ucrt64/share/licenses/$package"
    $usrLicenseDir = Join-Path $Msys2Root "usr/share/licenses/$package"
    $licenseSource = $null
    foreach ($candidate in @($pkgLicenseDir, $usrLicenseDir)) {
        if (Test-Path -LiteralPath $candidate) { $licenseSource = $candidate; break }
    }
    if ($licenseSource) {
        Copy-Item -LiteralPath (Join-Path $licenseSource '*') -Destination $licenseDir -Recurse -Force
    }
    $components += [ordered]@{
        package = $package
        license = if ($licenseSource) { 'see licenses/' } else { 'not captured (see MSYS2 package)' }
    }
}

# 2) Record the per-file manifest (sha256) and the SBOM.
$files = Get-ChildItem -LiteralPath $stageUcrt -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($stageUcrt.Length).TrimStart('\').Replace('\', '/')
    [ordered]@{
        path = "ucrt64/$relative"
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        package = if ($filePackages.ContainsKey($_.FullName)) { $filePackages[$_.FullName] } else { 'panecast' }
    }
} | Sort-Object path
$files | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RepoRoot 'out/runtime-files.json') -Encoding UTF8
[ordered]@{
    schemaVersion = 1
    version = $Version
    uxPlayVersion = '1.73.6'
    gstreamerVersion = '1.28.5-1 UCRT64'
    packages = @($components)
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RepoRoot 'out/components.json') -Encoding UTF8

# 3) Package the archive with the license texts alongside the runtime.
$packageDir = Join-Path $RepoRoot 'out/package'
if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'out/runtime') -Destination $packageDir -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $packageDir 'GPL-3.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'dnssd-compat/LICENSE') -Destination (Join-Path $packageDir 'MIT-dnssd-compat.txt') -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'out/licenses') -Destination (Join-Path $packageDir 'licenses') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'out/components.json') -Destination (Join-Path $packageDir 'components.json') -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'out/runtime-files.json') -Destination (Join-Path $packageDir 'runtime-files.json') -Force

$zip = Join-Path $RepoRoot "out/panecast-airplay-runtime-$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  panecast-airplay-runtime-$Version.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII

[pscustomobject]@{
    Zip = $zip
    Sha256 = $hash
    Packages = @($packageNames)
}
