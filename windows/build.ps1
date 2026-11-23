# Builds dist/Nimbus-Windows-x64.exe (self-contained) and dist/Nimbus-Windows-x64-lite.exe
# (framework-dependent, needs the .NET 8 Desktop Runtime). Usage: pwsh ./windows/build.ps1
param(
    [string]$Configuration = "Release",
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# zapret release that provides winws.exe and WinDivert (bol-van/zapret, binaries/windows-x86_64)
$ZapretVersion = "v72.13"
$ZapretSha256 = "c493e33a0dc4eba23a8686efdaba55f59755ad6ade3564aebd9d13f4c65e2e0c"
$EngineFiles = @("winws.exe", "cygwin1.dll", "WinDivert.dll", "WinDivert64.sys")

$WindowsDir = $PSScriptRoot
$Root = Split-Path -Parent $WindowsDir
$EngineDir = Join-Path $WindowsDir "engine"
$VersionFile = Join-Path $EngineDir "VERSION"

$haveEngine = (Test-Path $VersionFile) -and ((Get-Content $VersionFile -Raw).Trim() -eq $ZapretVersion)
foreach ($f in $EngineFiles) { if (-not (Test-Path (Join-Path $EngineDir $f))) { $haveEngine = $false } }
if (-not $haveEngine) {
    Write-Host "Downloading zapret $ZapretVersion"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("zapret-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp "zapret.zip"
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/bol-van/zapret/releases/download/$ZapretVersion/zapret-$ZapretVersion.zip" -OutFile $zip
    $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    if ($actual -ne $ZapretSha256) { throw "zapret archive checksum mismatch: $actual" }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $bin = Join-Path $tmp "zapret-$ZapretVersion/binaries/windows-x86_64"
    if (Test-Path $EngineDir) { Remove-Item -Recurse -Force $EngineDir }
    New-Item -ItemType Directory -Force $EngineDir | Out-Null
    foreach ($f in $EngineFiles) { Copy-Item (Join-Path $bin $f) $EngineDir }
    Set-Content -NoNewline -Path $VersionFile -Value $ZapretVersion
    Remove-Item -Recurse -Force $tmp
}

if (-not $SkipTests) {
    dotnet test (Join-Path $WindowsDir "tests/Nimbus.Core.Tests/Nimbus.Core.Tests.csproj") -c $Configuration
    if ($LASTEXITCODE -ne 0) { throw "tests failed" }
}

$publish = Join-Path $Root "build/windows"
if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
dotnet publish (Join-Path $WindowsDir "src/Nimbus/Nimbus.csproj") -c $Configuration -o $publish
if ($LASTEXITCODE -ne 0) { throw "publish failed" }

$dist = Join-Path $Root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$exe = Join-Path $dist "Nimbus-Windows-x64.exe"
Copy-Item (Join-Path $publish "Nimbus.exe") $exe -Force
$size = [Math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "Built $exe ($size MB)"

$publishLite = Join-Path $Root "build/windows-lite"
if (Test-Path $publishLite) { Remove-Item -Recurse -Force $publishLite }
dotnet publish (Join-Path $WindowsDir "src/Nimbus/Nimbus.csproj") -c $Configuration -o $publishLite -p:SelfContained=false -p:EnableCompressionInSingleFile=false
if ($LASTEXITCODE -ne 0) { throw "lite publish failed" }
$lite = Join-Path $dist "Nimbus-Windows-x64-lite.exe"
Copy-Item (Join-Path $publishLite "Nimbus.exe") $lite -Force
$liteSize = [Math]::Round((Get-Item $lite).Length / 1MB, 1)
Write-Host "Built $lite ($liteSize MB, needs .NET 8 Desktop Runtime)"
