param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$UxPlaySource = '',
    [string]$Msys2Root = 'C:\msys64',
    [switch]$SkipRustBuild
)

$ErrorActionPreference = 'Stop'

function Assert-PathUnderRoot {
    param([string]$Path, [string]$Root)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the repository: $resolvedPath"
    }
}

function Convert-ToMsysPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full -match '^([A-Za-z]):/(.*)$') {
        return "/$($Matches[1].ToLower())/$($Matches[2])"
    }
    throw "Cannot convert path for MSYS2: $Path"
}

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
if ([string]::IsNullOrWhiteSpace($UxPlaySource)) {
    $UxPlaySource = Join-Path $RepoRoot 'work/source/FDH2-UxPlay-21eef8d'
}
$UxPlaySource = [IO.Path]::GetFullPath($UxPlaySource)
$bash = Join-Path $Msys2Root 'usr/bin/bash.exe'
$ucrtBin = Join-Path $Msys2Root 'ucrt64/bin'
$requiredTools = @(
    $bash,
    (Join-Path $ucrtBin 'cmake.exe'),
    (Join-Path $ucrtBin 'ninja.exe'),
    (Join-Path $ucrtBin 'gcc.exe'),
    (Join-Path $ucrtBin 'gst-inspect-1.0.exe')
)
foreach ($tool in $requiredTools) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "AirPlay UCRT64 build dependency is missing: $tool"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $UxPlaySource 'README.md') -PathType Leaf)) {
    throw "UxPlay source is missing: $UxPlaySource"
}
$readme = Get-Content -LiteralPath (Join-Path $UxPlaySource 'README.md') -Raw -Encoding UTF8
if ($readme -notmatch '# UxPlay 1\.73') {
    throw 'The supplied source is not the reviewed UxPlay 1.73.x tree.'
}

$workRoot = Join-Path $RepoRoot 'work/build'
$patchedSource = Join-Path $workRoot 'UxPlay-1.73.6'
$buildDirectory = Join-Path $workRoot 'UxPlay-1.73.6-build'
$stageRoot = Join-Path $RepoRoot 'out/runtime'
$stageUcrt = Join-Path $stageRoot 'ucrt64'
$stageBin = Join-Path $stageUcrt 'bin'
$stagePlugins = Join-Path $stageUcrt 'lib/gstreamer-1.0'
$stageScanner = Join-Path $stageUcrt 'libexec/gstreamer-1.0'
foreach ($path in @($workRoot, $patchedSource, $buildDirectory, $stageRoot, $stageUcrt, $stageBin)) {
    Assert-PathUnderRoot -Path $path -Root $RepoRoot
}

if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $patchedSource -Force | Out-Null
Copy-Item -Path (Join-Path $UxPlaySource '*') -Destination $patchedSource -Recurse -Force

$patch = Join-Path $RepoRoot 'patches/uxplay-1.73.6-windows-dnssd-runtime.patch'
$repoUri = [Uri]::new($RepoRoot.TrimEnd('\') + '\')
$patchedSourceUri = [Uri]::new($patchedSource)
$patchedSourceRelative = [Uri]::UnescapeDataString(
    $repoUri.MakeRelativeUri($patchedSourceUri).ToString()
).TrimEnd('/')
& git -C $RepoRoot apply --check "--directory=$patchedSourceRelative" $patch
if ($LASTEXITCODE -ne 0) {
    throw 'The reviewed UxPlay patch no longer applies cleanly.'
}
& git -C $RepoRoot apply "--directory=$patchedSourceRelative" $patch
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to apply the reviewed UxPlay patch.'
}

if (-not $SkipRustBuild) {
    & cargo build --manifest-path (Join-Path $RepoRoot 'Cargo.toml') --release -p panecast-dnssd-compat
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to build dnssd.dll.'
    }
}
$dnssd = Join-Path $RepoRoot 'target/release/dnssd.dll'
if (-not (Test-Path -LiteralPath $dnssd -PathType Leaf)) {
    throw "dnssd.dll was not produced: $dnssd"
}

$sourceMsys = Convert-ToMsysPath $patchedSource
$buildMsys = Convert-ToMsysPath $buildDirectory
$command = @"
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin
export SOURCE_DATE_EPOCH=1774137600
cmake -S '$sourceMsys' -B '$buildMsys' -G Ninja -DNO_MARCH_NATIVE=ON -DCMAKE_BUILD_TYPE=Release '-DCMAKE_EXE_LINKER_FLAGS=-Wl,--no-insert-timestamp'
cmake --build '$buildMsys' --parallel
"@
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
& $bash -lc $command
if ($LASTEXITCODE -ne 0) {
    throw 'UxPlay UCRT64 build failed.'
}

$uxplay = Join-Path $buildDirectory 'uxplay.exe'
if (-not (Test-Path -LiteralPath $uxplay -PathType Leaf)) {
    throw "UxPlay executable was not produced: $uxplay"
}
if (Test-Path -LiteralPath $stageUcrt) {
    Remove-Item -LiteralPath $stageUcrt -Recurse -Force
}
New-Item -ItemType Directory -Path $stageBin, $stagePlugins, $stageScanner -Force | Out-Null
Copy-Item -LiteralPath $uxplay -Destination (Join-Path $stageBin 'uxplay.exe') -Force
Copy-Item -LiteralPath $dnssd -Destination (Join-Path $stageBin 'dnssd.dll') -Force

$previousPath = $env:PATH
$previousPluginPath = $env:GST_PLUGIN_PATH_1_0
$previousSystemPluginPath = $env:GST_PLUGIN_SYSTEM_PATH_1_0
$previousScanner = $env:GST_PLUGIN_SCANNER_1_0
$previousRegistry = $env:GST_REGISTRY_1_0
try {
    $env:PATH = "$stageBin;$ucrtBin;$previousPath"
    $help = & (Join-Path $stageBin 'uxplay.exe') -h 2>&1 | Out-String
    if ($help -notmatch '\-vrtp' -or $help -notmatch '\-artp') {
        throw 'Built UxPlay does not expose the required RTP output options.'
    }
    foreach ($element in @('rtph264pay', 'rtpL16pay', 'udpsink', 'level')) {
        & (Join-Path $ucrtBin 'gst-inspect-1.0.exe') $element *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "GStreamer UCRT64 is missing required element: $element"
        }
    }

    $pluginNames = @(
        'libgstapp.dll',
        'libgstautodetect.dll',
        'libgstcoreelements.dll',
        'libgstplayback.dll',
        'libgstvideoparsersbad.dll',
        'libgstrtp.dll',
        'libgstudp.dll',
        'libgstaudioconvert.dll',
        'libgstaudioresample.dll',
        'libgstvolume.dll',
        'libgstlevel.dll',
        'libgstlibav.dll'
    )
    $pluginSources = @()
    foreach ($pluginName in $pluginNames) {
        $plugin = Join-Path $Msys2Root "ucrt64/lib/gstreamer-1.0/$pluginName"
        if (-not (Test-Path -LiteralPath $plugin -PathType Leaf)) {
            throw "Required GStreamer plugin is missing: $pluginName"
        }
        $pluginSources += $plugin
        Copy-Item -LiteralPath $plugin -Destination (Join-Path $stagePlugins $pluginName) -Force
    }
    foreach ($toolName in @('gst-launch-1.0.exe', 'gst-inspect-1.0.exe')) {
        Copy-Item -LiteralPath (Join-Path $ucrtBin $toolName) -Destination (Join-Path $stageBin $toolName) -Force
    }
    $scanner = Join-Path $Msys2Root 'ucrt64/libexec/gstreamer-1.0/gst-plugin-scanner.exe'
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
        throw "GStreamer plugin scanner is missing: $scanner"
    }
    Copy-Item -LiteralPath $scanner -Destination (Join-Path $stageScanner 'gst-plugin-scanner.exe') -Force

    $dependencyRoots = @(
        $uxplay,
        (Join-Path $ucrtBin 'gst-launch-1.0.exe'),
        (Join-Path $ucrtBin 'gst-inspect-1.0.exe'),
        $scanner
    ) + $pluginSources
    $runtimeDlls = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($root in $dependencyRoots) {
        $rootMsys = Convert-ToMsysPath $root
        $dependencyOutput = & $bash -lc "export PATH=/ucrt64/bin:/usr/bin; ldd '$rootMsys'" 2>&1 | Out-String
        foreach ($match in [regex]::Matches($dependencyOutput, '/ucrt64/bin/[^\s]+\.dll')) {
            [void]$runtimeDlls.Add([IO.Path]::GetFileName($match.Value))
        }
    }
    foreach ($dllName in $runtimeDlls) {
        $dll = Join-Path $ucrtBin $dllName
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
            throw "Resolved UCRT64 runtime DLL is missing: $dllName"
        }
        Copy-Item -LiteralPath $dll -Destination (Join-Path $stageBin $dllName) -Force
    }

    $env:PATH = "$stageBin;$env:SystemRoot\System32"
    $env:GST_PLUGIN_PATH_1_0 = $stagePlugins
    $env:GST_PLUGIN_SYSTEM_PATH_1_0 = $stagePlugins
    $env:GST_PLUGIN_SCANNER_1_0 = Join-Path $stageScanner 'gst-plugin-scanner.exe'
    $env:GST_REGISTRY_1_0 = Join-Path $workRoot 'gstreamer-registry.bin'
    foreach ($element in @(
        'appsrc',
        'autodetect',
        'queue',
        'playback',
        'h264parse',
        'rtph264pay',
        'rtpL16pay',
        'udpsink',
        'audioconvert',
        'audioresample',
        'volume',
        'level',
        'avdec_aac',
        'avdec_alac'
    )) {
        & (Join-Path $stageBin 'gst-inspect-1.0.exe') $element *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "The isolated AirPlay runtime cannot load GStreamer element: $element"
        }
    }
} finally {
    $env:PATH = $previousPath
    $env:GST_PLUGIN_PATH_1_0 = $previousPluginPath
    $env:GST_PLUGIN_SYSTEM_PATH_1_0 = $previousSystemPluginPath
    $env:GST_PLUGIN_SCANNER_1_0 = $previousScanner
    $env:GST_REGISTRY_1_0 = $previousRegistry
}

$artifact = Get-FileHash -LiteralPath (Join-Path $stageBin 'uxplay.exe') -Algorithm SHA256
$compat = Get-FileHash -LiteralPath (Join-Path $stageBin 'dnssd.dll') -Algorithm SHA256
$runtimeFiles = Get-ChildItem -LiteralPath $stageUcrt -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($stageUcrt.Length).TrimStart('\').Replace('\', '/')
    [ordered]@{
        path = "ucrt64/$relativePath"
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        component = if ($_.Name -eq 'uxplay.exe') {
            'UxPlay'
        } elseif ($_.Name -eq 'dnssd.dll') {
            'Panecast DNS-SD compatibility layer'
        } else {
            'GStreamer UCRT64 runtime'
        }
    }
} | Sort-Object path
$gstreamerTreeLines = $runtimeFiles |
    Where-Object { $_.component -eq 'GStreamer UCRT64 runtime' } |
    ForEach-Object { "$($_.path)`t$($_.sha256)" }
$treeBytes = [Text.UTF8Encoding]::new($false).GetBytes(($gstreamerTreeLines -join "`n"))
$treeHasher = [Security.Cryptography.SHA256]::Create()
try {
    $gstreamerTreeHash = [BitConverter]::ToString($treeHasher.ComputeHash($treeBytes)).Replace('-', '').ToLowerInvariant()
} finally {
    $treeHasher.Dispose()
}
$runtimeManifest = [ordered]@{
    schemaVersion = 1
    uxPlayVersion = '1.73.6'
    gstreamerVersion = '1.28.5-1 UCRT64'
    gstreamerTreeSha256 = $gstreamerTreeHash
    files = @($runtimeFiles)
}
$runtimeManifestPath = Join-Path $RepoRoot 'out/runtime-files.json'
$runtimeManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $runtimeManifestPath -Encoding UTF8

[pscustomobject]@{
    UxPlay = $artifact.Hash.ToLowerInvariant()
    DnssdCompat = $compat.Hash.ToLowerInvariant()
    GStreamerTree = $gstreamerTreeHash
    RuntimeFiles = @($runtimeFiles).Count
    Stage = $stageRoot
    DevRuntime = "$stageRoot;$Msys2Root"
}
