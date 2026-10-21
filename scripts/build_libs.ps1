<#
.SYNOPSIS
  Build DocHelper's Rust engine libraries from PowerShell (Windows, or
  pwsh on Linux). scripts/build_libs.sh is the bash twin for macOS/Linux.

.DESCRIPTION
  Targets (several may be given; android is the default):
    android  jniLibs for arm64-v8a, armeabi-v7a and x86_64, which the
             Gradle preflight (verifyEngines) checks before a build.
    host     libraries for this machine, then sets *_CORE_LIB_PATH in
             this session for flutter test.
    env      sets *_CORE_LIB_PATH in this session from what host built.
    test     cargo tests: doc_common and each engine.

  Engines: text, sheet, word, slide, archive. The PDF engine's Android and
  Apple binaries are committed, so it is built only with -WithPdf (or
  "pdf" in -Only); a rebuild shows in packages/flutter_pdf_core's git
  status. On Windows the PDF engine may not link for host (getrandom and
  windows-sys want dlltool); that is reported as a warning.

  On Windows without the Visual C++ build tools, the GNU toolchain
  (stable-x86_64-pc-windows-gnu) is used when it is installed. Missing
  Android Rust targets are added with rustup. cargo-ndk must be installed
  (cargo install cargo-ndk) and an NDK found through ANDROID_NDK_HOME,
  ANDROID_HOME, ANDROID_SDK_ROOT, android/local.properties or the default
  SDK folder.

  Before building, it checks everything the targets need (engine sources,
  Rust 1.92+, a working linker, cargo-ndk, an NDK) and lists all that is
  missing, each with the command or link to get it, then stops.

  Engines (and the PDF engine with -WithPdf) build side by side in
  background jobs, each with cargo's own parallelism, using every logical
  core unless -Jobs (or CARGO_BUILD_JOBS) says otherwise. -Jobs 1 builds
  one thing at a time with one job.

.EXAMPLE
  .\scripts\build_libs.ps1 android
.EXAMPLE
  .\scripts\build_libs.ps1 host
.EXAMPLE
  .\scripts\build_libs.ps1 android -Only text,sheet
.EXAMPLE
  .\scripts\build_libs.ps1 android host -WithPdf
.EXAMPLE
  .\scripts\build_libs.ps1 android -Jobs 4
.EXAMPLE
  .\scripts\build_libs.ps1 test -Toolchain stable-x86_64-pc-windows-gnu
.NOTES
  Run it in the session (not with powershell -File) so host and env can
  set the environment variables. If scripts are blocked, run once:
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [ValidateSet('android', 'host', 'env', 'test')]
  [string[]]$Target = @('android'),
  [string[]]$Only,
  [switch]$WithPdf,
  [switch]$DebugBuild,
  [string]$Toolchain,
  [int]$Jobs = 0,
  [switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$ErrorActionPreference = 'Continue'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Packages = Join-Path $RepoRoot 'packages'
$OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$OnMac = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
$AllEngines = @('text', 'sheet', 'word', 'slide', 'archive')
$Abis = [ordered]@{
  'arm64-v8a'   = 'aarch64-linux-android'
  'armeabi-v7a' = 'armv7-linux-androideabi'
  'x86_64'      = 'x86_64-linux-android'
}
$script:Failures = @()

# Cores to use: -Jobs, else CARGO_BUILD_JOBS, else every logical core.
if ($Jobs -le 0) {
  $fromEnv = 0
  if ([int]::TryParse("$env:CARGO_BUILD_JOBS", [ref]$fromEnv) -and $fromEnv -gt 0) { $Jobs = $fromEnv }
  else { $Jobs = [Math]::Max(1, [Environment]::ProcessorCount) }
}
$env:CARGO_BUILD_JOBS = "$Jobs"

# Engines to build.
$picked = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
foreach ($name in $picked) {
  if ($AllEngines -notcontains $name -and $name -ne 'pdf') {
    Write-Error "Unknown engine '$name' (text, sheet, word, slide, archive, pdf)."
    return
  }
}
$Requested = if ($picked.Count -gt 0) { @($AllEngines | Where-Object { $picked -contains $_ }) } else { $AllEngines }
$Engines = @($Requested | Where-Object { Test-Path (Join-Path $Packages "flutter_$($_)_core/rust/Cargo.toml") })
$BuildPdf = $WithPdf -or ($picked -contains 'pdf')
$RustMinMinor = 92   # Rust 1.92 or newer

# Cargo from rustup, even when this shell's PATH lacks it.
$cargoBin = Join-Path $HOME '.cargo/bin'
if ((Test-Path $cargoBin) -and -not (($env:PATH -split [IO.Path]::PathSeparator) -contains $cargoBin)) {
  $env:PATH = $cargoBin + [IO.Path]::PathSeparator + $env:PATH
}

# Everything missing is collected first and reported together, each with
# how to get it, so one run tells the whole story.
$script:Problems = New-Object System.Collections.Generic.List[string]
function Add-Problem([string]$What, [string[]]$Fix) {
  $text = "  - $What"
  foreach ($line in $Fix) { $text += [Environment]::NewLine + "      $line" }
  $script:Problems.Add($text)
}

function Test-Command([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Test-RustVersion([string[]]$TcArg) {
  $v = & rustc @TcArg --version 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $v) {
    if ($TcArg) {
      Add-Problem "The Rust toolchain '$($TcArg[0].TrimStart('+'))' is not installed." @("Run: rustup toolchain install $($TcArg[0].TrimStart('+'))")
    } else {
      Add-Problem 'rustc does not run (rustup has no default toolchain?).' @('Run: rustup default stable')
    }
    return $false
  }
  if ("$v" -match 'rustc (\d+)\.(\d+)') {
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    if ($major -lt 1 -or ($major -eq 1 -and $minor -lt $RustMinMinor)) {
      Add-Problem "Rust $major.$minor is too old; the engines need 1.$RustMinMinor or newer." @('Run: rustup update stable')
      return $false
    }
  }
  return $true
}

# Whether rustc can link a tiny program: the MSVC toolchain needs a working
# Visual C++ linker, which may be missing or unfindable even when Visual
# Studio says it is installed; Linux needs cc, macOS the Xcode tools.
function Test-Links([string[]]$TcArg) {
  $probe = Join-Path ([IO.Path]::GetTempPath()) "dochelper_link_probe_$PID"
  New-Item -ItemType Directory -Force $probe | Out-Null
  try {
    Set-Content (Join-Path $probe 'main.rs') 'fn main() {}' -Encoding ascii
    & rustc @TcArg (Join-Path $probe 'main.rs') -o (Join-Path $probe 'probe.exe') *> $null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally {
    Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue
  }
}

function Get-Toolchain {
  if ($Toolchain) {
    $tc = $Toolchain.TrimStart('+')
    if (Test-Links @("+$tc")) { return $tc }
  } else {
    if (Test-Links @()) { return $null }
    if ($OnWindows) {
      # Fall back to the GNU toolchain, which brings its own linker.
      $gnu = 'stable-x86_64-pc-windows-gnu'
      $list = @(& rustup toolchain list 2>$null)
      if (($list | Where-Object { $_ -like "$gnu*" }) -and (Test-Links @("+$gnu"))) { return $gnu }
    }
  }
  if ($OnWindows) {
    Add-Problem 'Rust cannot link Windows programs: the Visual C++ linker is missing or unusable.' @(
      'Either run: rustup toolchain install stable-x86_64-pc-windows-gnu   (this script then uses it)',
      "or install Visual Studio Build Tools with 'Desktop development with C++':",
      'https://visualstudio.microsoft.com/visual-cpp-build-tools/')
  } elseif ($OnMac) {
    Add-Problem 'Rust cannot link programs: the Xcode command-line tools are missing.' @('Run: xcode-select --install')
  } else {
    Add-Problem 'Rust cannot link programs: no C linker (cc) found.' @(
      'Debian/Ubuntu: sudo apt install build-essential',
      'Fedora: sudo dnf install gcc    Arch: sudo pacman -S base-devel')
  }
  return $null
}

function Invoke-Cargo([string]$Dir, [string[]]$CargoArgs) {
  $all = @($script:TcArgs) + $CargoArgs
  Write-Host "    cargo $($all -join ' ')" -ForegroundColor DarkGray
  Push-Location $Dir
  try {
    & cargo @all | Out-Host
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  return ($code -eq 0)
}

# Runs several cargo commands side by side, each in its own background job
# (at most $Jobs at once), and prints each one's output when it finishes.
# Items are objects with Name, Dir and CargoArgs; the result maps each Name
# to whether cargo succeeded. With -Jobs 1 (or one item) it runs in turn.
function Invoke-CargoBatch([object[]]$Items) {
  $results = @{}
  if ($Items.Count -eq 0) { return $results }
  if ($Items.Count -eq 1 -or $Jobs -le 1) {
    foreach ($item in $Items) {
      Write-Host "==> $($item.Name)" -ForegroundColor Cyan
      $results[$item.Name] = Invoke-Cargo $item.Dir $item.CargoArgs
    }
    return $results
  }
  $block = {
    param([string]$Dir, [string[]]$CargoArgs)
    Set-Location -LiteralPath $Dir
    & cargo @CargoArgs 2>&1 | ForEach-Object { "$_" }
    "__EXIT__$LASTEXITCODE"
  }
  $limit = [Math]::Min($Jobs, $Items.Count)
  $pending = New-Object System.Collections.Queue
  foreach ($item in $Items) { $pending.Enqueue($item) }
  $running = @{}
  Write-Host "Building $($Items.Count) side by side ($Jobs cargo jobs each): $(($Items | ForEach-Object { $_.Name }) -join ', ')"
  try {
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
      while ($pending.Count -gt 0 -and $running.Count -lt $limit) {
        $item = $pending.Dequeue()
        $all = @($script:TcArgs) + $item.CargoArgs
        Write-Host "    cargo $($all -join ' ')  [$($item.Name)]" -ForegroundColor DarkGray
        $job = Start-Job -ScriptBlock $block -ArgumentList $item.Dir, $all
        $running[$job.Id] = $item
      }
      $finished = @(Wait-Job -Id ([int[]]@($running.Keys)) -Any)
      foreach ($job in $finished) {
        $item = $running[$job.Id]
        $exit = 1
        $text = @()
        foreach ($line in @(Receive-Job $job)) {
          if ("$line" -match '^__EXIT__(\d+)$') { $exit = [int]$Matches[1] } else { $text += "$line" }
        }
        Write-Host "==> $($item.Name)" -ForegroundColor Cyan
        $text | Out-Host
        if ($job.State -eq 'Failed' -and $job.ChildJobs[0].JobStateInfo.Reason) {
          Write-Host $job.ChildJobs[0].JobStateInfo.Reason.Message -ForegroundColor Red
        }
        $results[$item.Name] = ($exit -eq 0)
        $running.Remove($job.Id)
        Remove-Job -Job $job -Force
      }
    }
  } finally {
    foreach ($id in @($running.Keys)) {
      Stop-Job -Id $id -ErrorAction SilentlyContinue
      Remove-Job -Id $id -Force -ErrorAction SilentlyContinue
    }
  }
  return $results
}

function Get-Profile { if ($DebugBuild) { 'debug' } else { 'release' } }
function Get-ProfileArgs { if ($DebugBuild) { return } '--release' }

function Get-HostLibName([string]$Kind) {
  if ($OnWindows) { "$($Kind)_ffi.dll" } elseif ($OnMac) { "lib$($Kind)_ffi.dylib" } else { "lib$($Kind)_ffi.so" }
}

function Get-RustDir([string]$Kind) { Join-Path $Packages "flutter_$($Kind)_core/rust" }

function Test-Ndk([string]$Dir) {
  $Dir -and (Test-Path (Join-Path $Dir 'toolchains/llvm/prebuilt'))
}

function Find-Ndk {
  if ($env:ANDROID_NDK_HOME) {
    if (Test-Ndk $env:ANDROID_NDK_HOME) { return $env:ANDROID_NDK_HOME }
    Write-Warning "ANDROID_NDK_HOME ($env:ANDROID_NDK_HOME) is not an NDK; looking in the Android SDK instead."
  }
  $sdks = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
  $props = Join-Path $RepoRoot 'android/local.properties'
  if (Test-Path $props) {
    $line = Get-Content $props | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
    if ($line) { $sdks += ($line -replace '^sdk\.dir=', '' -replace '\\:', ':' -replace '\\\\', '\') }
  }
  if ($env:LOCALAPPDATA) { $sdks += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
  $sdks += (Join-Path $HOME 'Library/Android/sdk'), (Join-Path $HOME 'Android/Sdk')
  foreach ($sdk in $sdks) {
    if (-not $sdk) { continue }
    $ndkRoot = Join-Path $sdk 'ndk'
    if (-not (Test-Path $ndkRoot)) { continue }
    $best = Get-ChildItem $ndkRoot -Directory | Where-Object { ($_.Name -as [version]) -and (Test-Ndk $_.FullName) } |
      Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if ($best) { return $best.FullName }
  }
  return $null
}

# Checks the tools each requested target needs, without changing anything.
function Test-Prerequisites {
  # Engine sources: submodules that were never checked out are empty folders.
  $wanted = @($Requested)
  if ($BuildPdf) { $wanted += 'pdf' }
  foreach ($kind in $wanted) {
    if ($Target -eq 'env' -and $Target.Count -eq 1) { break }
    if (-not (Test-Path (Join-Path (Get-RustDir $kind) 'Cargo.toml'))) {
      Add-Problem "packages/flutter_$($kind)_core has no Rust sources (submodule not checked out)." @(
        'Run: git submodule update --init --recursive',
        "or leave it out with -Only (engines: $($AllEngines -join ','))")
    }
  }
  if (($Target -contains 'test') -and -not (Test-Path (Join-Path $Packages 'doc_common/Cargo.toml'))) {
    Add-Problem 'packages/doc_common is missing.' @('Restore it with: git checkout -- packages/doc_common')
  }

  if ($Target -eq 'env' -and $Target.Count -eq 1) { return }

  # Rust.
  if (-not (Test-Command cargo) -or -not (Test-Command rustc)) {
    Add-Problem 'Rust (cargo, rustc) is not installed or not on PATH.' @(
      'Install it with rustup from https://rustup.rs (Windows: rustup-init.exe),',
      'then open a new terminal and run this script again.')
    return
  }
  if (-not (Test-Command rustup)) {
    Add-Problem 'rustup is not on PATH; it is needed to add Rust targets and toolchains.' @(
      'Install Rust with rustup from https://rustup.rs (a system Rust package has no rustup).')
    return
  }
  $tcArg = @()
  if ($Toolchain) { $tcArg = @("+$($Toolchain.TrimStart('+'))") }
  if (-not (Test-RustVersion $tcArg)) { return }
  $script:Tc = Get-Toolchain
  $script:TcArgs = @()
  if ($script:Tc) { $script:TcArgs = @("+$($script:Tc)") }

  # Android.
  if ($Target -contains 'android') {
    if (-not (Test-Command cargo-ndk)) {
      Add-Problem 'cargo-ndk is not installed.' @('Run: cargo install cargo-ndk')
    }
    $ndk = Find-Ndk
    if ($ndk) {
      $script:Ndk = $ndk
    } else {
      Add-Problem 'No Android NDK found (looked at ANDROID_NDK_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, android/local.properties and the default SDK folder).' @(
        'Android Studio: Settings > Languages & Frameworks > Android SDK > SDK Tools > NDK (Side by side),',
        'or: sdkmanager --install "ndk;27.2.12479018"',
        'or set ANDROID_NDK_HOME to an unpacked NDK.')
    }
  }
}

function Initialize-Android {
  $env:ANDROID_NDK_HOME = $script:Ndk
  Write-Host "Using NDK: $($script:Ndk)"
  $rustupTc = @()
  if ($script:Tc) { $rustupTc = @('--toolchain', $script:Tc) }
  $installed = & rustup target list --installed @rustupTc 2>$null
  $missing = @($Abis.Values | Where-Object { $installed -notcontains $_ })
  if ($missing.Count -gt 0) {
    Write-Host "Adding Rust targets: $($missing -join ', ')"
    & rustup target add @rustupTc @missing | Out-Host
    if ($LASTEXITCODE -ne 0) {
      Write-Host ("Could not add the Rust Android targets (offline?). Run: rustup target add $($rustupTc -join ' ') " +
        ($missing -join ' ')) -ForegroundColor Red
      return $false
    }
  }
  return $true
}

function Build-AndroidAll([string[]]$Kinds) {
  Write-Host "==> Android ($($Abis.Keys -join ', ')): $($Kinds -join ', ')" -ForegroundColor Cyan
  $items = @()
  foreach ($kind in $Kinds) {
    $out = Join-Path $Packages "flutter_$($kind)_core/android/src/main/jniLibs"
    $cargoArgs = @('ndk')
    foreach ($abi in $Abis.Keys) { $cargoArgs += '-t', $abi }
    $cargoArgs += @('-o', $out, 'build', '-p', "$($kind)_ffi") + @(Get-ProfileArgs)
    $items += [pscustomobject]@{ Name = "$kind android"; Dir = (Get-RustDir $kind); CargoArgs = $cargoArgs }
  }
  $results = Invoke-CargoBatch $items
  foreach ($kind in $Kinds) {
    if (-not $results["$kind android"]) { $script:Failures += "$kind android"; continue }
    $out = Join-Path $Packages "flutter_$($kind)_core/android/src/main/jniLibs"
    Get-ChildItem $out -Recurse -Filter "lib$($kind)_ffi.so" |
      ForEach-Object { Write-Host ("    {0}/{1}  {2:N1} MB" -f $_.Directory.Name, $_.Name, ($_.Length / 1MB)) }
  }
}

function Build-HostAll([string[]]$Kinds) {
  $items = @()
  foreach ($kind in $Kinds) {
    $items += [pscustomobject]@{
      Name = "$kind host"; Dir = (Get-RustDir $kind)
      CargoArgs = (@('build', '-p', "$($kind)_ffi") + @(Get-ProfileArgs))
    }
  }
  $results = Invoke-CargoBatch $items
  foreach ($kind in $Kinds) {
    if ($results["$kind host"]) { continue }
    if ($kind -eq 'pdf') {
      Write-Warning "The pdf engine did not build for this machine (on Windows it needs dlltool for getrandom/windows-sys); PDF tests will skip."
    } else {
      $script:Failures += "$kind host"
    }
  }
}

function Set-LibEnv {
  $kinds = @($AllEngines) + 'pdf'
  foreach ($kind in $kinds) {
    $lib = Join-Path (Get-RustDir $kind) (Join-Path "target/$(Get-Profile)" (Get-HostLibName $kind))
    $name = "$($kind.ToUpper())_CORE_LIB_PATH"
    if (Test-Path $lib) {
      Set-Item "env:$name" $lib
      Write-Host "`$env:$name = '$lib'"
    } else {
      Write-Host "# $name not set: $(Get-HostLibName $kind) not built (run: .\scripts\build_libs.ps1 host)" -ForegroundColor DarkGray
    }
  }
}

function Test-Engines {
  $items = @([pscustomobject]@{ Name = 'doc_common tests'; Dir = (Join-Path $Packages 'doc_common'); CargoArgs = @('test', '--quiet') })
  foreach ($kind in $Engines) {
    $items += [pscustomobject]@{ Name = "$kind tests"; Dir = (Get-RustDir $kind); CargoArgs = @('test', '--quiet') }
  }
  if ($BuildPdf) {
    $items += [pscustomobject]@{ Name = 'pdf tests'; Dir = (Get-RustDir 'pdf'); CargoArgs = @('test', '--workspace', '--release') }
  }
  $results = Invoke-CargoBatch $items
  foreach ($item in $items) {
    if (-not $results[$item.Name]) { $script:Failures += $item.Name }
  }
}

Test-Prerequisites
if ($script:Problems.Count -gt 0) {
  Write-Host ''
  Write-Host "Cannot build yet; missing for '$($Target -join ' ')':" -ForegroundColor Red
  $script:Problems | ForEach-Object { Write-Host $_ }
  Write-Host ''
  Write-Host 'Fix these, open a new terminal if you installed something, and run the script again.'
  $global:LASTEXITCODE = 1
  return
}
if ($script:Tc) { Write-Host "Using Rust toolchain: $($script:Tc)" }

foreach ($t in $Target) {
  Write-Host "######## $t" -ForegroundColor Yellow
  switch ($t) {
    'android' {
      if (-not (Initialize-Android)) { $script:Failures += 'android setup'; break }
      $kinds = @($Engines)
      if ($BuildPdf) { $kinds += 'pdf' }
      Build-AndroidAll $kinds
    }
    'host' {
      $kinds = @($Engines)
      if ($BuildPdf) { $kinds += 'pdf' }
      Build-HostAll $kinds
      Set-LibEnv
    }
    'env' { Set-LibEnv }
    'test' { Test-Engines }
  }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
  Write-Host "Failed: $($script:Failures -join ', '). See the cargo output above." -ForegroundColor Red
  $global:LASTEXITCODE = 1
} else {
  Write-Host 'Done.' -ForegroundColor Green
  if ($Target -contains 'android') {
    if (Test-Command flutter) {
      Write-Host 'Next: flutter pub get, then flutter run -d <device-id> (flutter devices lists them).'
    } else {
      Write-Host ('Next: flutter run. Flutter is not on PATH: install it from https://docs.flutter.dev/get-started/install ' +
        'or add <flutter>\bin to PATH.') -ForegroundColor Yellow
    }
  }
  $global:LASTEXITCODE = 0
}
