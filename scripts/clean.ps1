<#
.SYNOPSIS
  Remove everything DocHelper can generate or download again (Windows
  PowerShell 5.1, or pwsh anywhere; scripts/clean.sh is the bash twin).

.DESCRIPTION
  - flutter clean in the app and in every Flutter package;
  - build/, .dart_tool/, coverage, Flutter's ephemeral folders, CocoaPods
    (Pods/, .symlinks/), the Gradle wrapper, .gradle/ and .kotlin/;
  - every Rust target/ folder (doc_common and each engine);
  - the per-format engines' built binaries (jniLibs, dylibs, frameworks);
  - the packages' pubspec.lock files (git-ignored; pub get remakes them);
  - the downloaded test corpus (test_corpus/, test_pvs_output/).

  Nothing git tracks is ever removed: the PDF engine's committed binaries,
  the app's pubspec.lock and Podfile.lock stay. android/local.properties
  (your SDK path) is kept too.

.EXAMPLE
  .\scripts\clean.ps1
.EXAMPLE
  .\scripts\clean.ps1 -DryRun
.EXAMPLE
  .\scripts\clean.ps1 -KeepCorpus -NoFlutter
.NOTES
  If scripts are blocked: powershell -ExecutionPolicy Bypass -File scripts\clean.ps1
  Afterwards: flutter pub get, then .\scripts\build_libs.ps1 android (or host).
#>
param(
  [switch]$DryRun,
  [switch]$KeepCorpus,
  [switch]$NoFlutter,
  [switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

$ErrorActionPreference = 'Continue'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host 'Missing: git. It is needed to make sure no tracked file is removed.' -ForegroundColor Red
  Write-Host '  Install it from https://git-scm.com/downloads (Windows: winget install Git.Git),'
  Write-Host '  then open a new terminal and run this script again.'
  exit 1
}
& git -C $RepoRoot rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "$RepoRoot is not a git checkout, so tracked files cannot be told apart; nothing removed." -ForegroundColor Red
  Write-Host '  Clone the repository with: git clone --recurse-submodules <repository-url>'
  exit 1
}

$script:Removed = 0
$script:Failed = 0

function Get-Rel([string]$Path) {
  $rel = $Path.Substring($RepoRoot.Length).TrimStart('\', '/')
  if ($rel) { $rel -replace '\\', '/' } else { '.' }
}

# Whether git tracks the path, or anything inside it, in whichever
# repository (the app or an engine submodule) holds it.
function Test-Tracked([string]$Path) {
  $dir = Split-Path $Path -Parent
  $leaf = Split-Path $Path -Leaf
  $out = & git -C $dir ls-files -- $leaf 2>$null
  return [bool]$out
}

function Remove-Generated([string[]]$Paths) {
  foreach ($path in $Paths) {
    if (-not $path) { continue }
    $path = $path.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $rel = Get-Rel $path
    if (Test-Tracked $path) { Write-Host "  keep     $rel (tracked by git)"; continue }
    if ($DryRun) {
      Write-Host "  would remove $rel"
      $script:Removed++
      continue
    }
    try {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    } catch {
      # Very deep Rust target folders can pass Windows' 260-character limit.
      if ($OnWindows -and (Test-Path -LiteralPath $path -PathType Container)) {
        cmd /c rd /s /q "\\?\$path" 2>$null | Out-Null
      }
    }
    if (Test-Path -LiteralPath $path) {
      Write-Host "  FAILED   $rel (in use? close the app, IDE builds and terminals using it)" -ForegroundColor Red
      $script:Failed++
    } else {
      Write-Host "  removed  $rel"
      $script:Removed++
    }
  }
}

function Find-Flutter {
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @()
  if ($env:FLUTTER_ROOT) {
    $candidates += (Join-Path $env:FLUTTER_ROOT 'bin/flutter.bat'), (Join-Path $env:FLUTTER_ROOT 'bin/flutter')
  }
  $candidates += 'C:\src\flutter\bin\flutter.bat', (Join-Path $HOME 'flutter/bin/flutter.bat'),
    (Join-Path $HOME 'flutter/bin/flutter'), (Join-Path $HOME 'development/flutter/bin/flutter'), '/opt/flutter/bin/flutter'
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  return $null
}

$packages = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)

# Flutter projects: the app, every Flutter package and their examples.
$flutterDirs = @($RepoRoot)
foreach ($pkg in $packages) {
  foreach ($d in @($pkg.FullName, (Join-Path $pkg.FullName 'example'))) {
    if (Test-Path -LiteralPath (Join-Path $d 'pubspec.yaml')) { $flutterDirs += $d }
  }
}

# A running Gradle daemon keeps files in android/.gradle open.
$gradlew = if ($OnWindows) { Join-Path $RepoRoot 'android\gradlew.bat' } else { Join-Path $RepoRoot 'android/gradlew' }
if (-not $DryRun -and (Test-Path -LiteralPath $gradlew)) {
  Write-Host '==> stopping Gradle daemons'
  Push-Location (Join-Path $RepoRoot 'android')
  try { & $gradlew --stop *> $null } catch { } finally { Pop-Location }
}

if (-not $NoFlutter) {
  $flutter = Find-Flutter
  if (-not $flutter) {
    Write-Host '==> flutter not found; skipping flutter clean (the folders below are removed anyway).' -ForegroundColor Yellow
    Write-Host '    Install it from https://docs.flutter.dev/get-started/install, or set FLUTTER_ROOT or add <flutter>\bin to PATH.'
  } else {
    Write-Host '==> flutter clean'
    foreach ($dir in $flutterDirs) {
      $rel = Get-Rel $dir
      if ($DryRun) { Write-Host "  would run flutter clean in $rel"; continue }
      Push-Location $dir
      try { & $flutter clean *> $null; $code = $LASTEXITCODE } catch { $code = 1 } finally { Pop-Location }
      if ($code -eq 0) { Write-Host "  cleaned  $rel" }
      else { Write-Host "  flutter clean failed in $rel (the folders below are removed anyway)" }
    }
  }
}

function J([string[]]$Parts) {
  $p = $Parts[0]
  foreach ($part in $Parts[1..($Parts.Length - 1)]) { $p = Join-Path $p $part }
  return $p
}

$R = $RepoRoot
Write-Host '==> app'
Remove-Generated @(
  (J $R, 'build'), (J $R, '.dart_tool'), (J $R, 'coverage'), (J $R, '.flutter-plugins'), (J $R, '.flutter-plugins-dependencies'),
  (J $R, 'android', '.gradle'), (J $R, 'android', '.kotlin'), (J $R, 'android', 'build'),
  (J $R, 'android', 'app', 'build'), (J $R, 'android', 'app', '.cxx'),
  (J $R, 'android', 'gradlew'), (J $R, 'android', 'gradlew.bat'), (J $R, 'android', 'gradle', 'wrapper', 'gradle-wrapper.jar'),
  (J $R, 'ios', 'Pods'), (J $R, 'ios', '.symlinks'), (J $R, 'ios', 'build'), (J $R, 'ios', 'Flutter', 'ephemeral'),
  (J $R, 'ios', 'Flutter', 'Generated.xcconfig'), (J $R, 'ios', 'Flutter', 'flutter_export_environment.sh'),
  (J $R, 'ios', 'Flutter', 'Flutter.podspec'),
  (J $R, 'macos', 'Pods'), (J $R, 'macos', 'build'), (J $R, 'macos', 'Flutter', 'ephemeral'),
  (J $R, 'linux', 'flutter', 'ephemeral'), (J $R, 'windows', 'flutter', 'ephemeral')
)

Write-Host '==> downloaded test files'
Remove-Generated @((J $R, 'test_pvs_output'))
if ($KeepCorpus) { Write-Host '  keep     test_corpus (-KeepCorpus)' } else { Remove-Generated @((J $R, 'test_corpus')) }

Write-Host '==> packages'
foreach ($pkg in $packages) {
  $p = $pkg.FullName
  Remove-Generated @(
    (J $p, 'target'), (J $p, 'rust', 'target'), (J $p, 'tools', 'pdf_viewer', 'target'),
    (J $p, 'build'), (J $p, '.dart_tool'), (J $p, '.flutter-plugins'), (J $p, '.flutter-plugins-dependencies'), (J $p, 'pubspec.lock'),
    (J $p, 'example', 'build'), (J $p, 'example', '.dart_tool'), (J $p, 'example', 'pubspec.lock'),
    (J $p, 'ios', 'Frameworks')
  )
  $jni = J $p, 'android', 'src', 'main', 'jniLibs'
  if (Test-Path -LiteralPath $jni) {
    Remove-Generated @(Get-ChildItem -LiteralPath $jni -Directory | ForEach-Object { $_.FullName })
  }
  $frameworks = J $p, 'macos', 'Frameworks'
  if (Test-Path -LiteralPath $frameworks) {
    Remove-Generated @(Get-ChildItem -LiteralPath $frameworks -Filter '*.dylib' -File | ForEach-Object { $_.FullName })
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: $($script:Removed) item(s) would be removed."
} else {
  Write-Host "Done: $($script:Removed) item(s) removed, $($script:Failed) failed."
  Write-Host 'Next: flutter pub get, then .\scripts\build_libs.ps1 android (or host).'
}
if ($script:Failed -gt 0) { exit 1 }
exit 0
