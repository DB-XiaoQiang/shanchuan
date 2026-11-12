param(
    [Parameter(Mandatory = $true)][string]$BaseVersion,
    [Parameter(Mandatory = $true)][string]$TargetVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script installs a console fixture with the real product packId because
# the production signed-feed verifier deliberately pins PackageId=Shanchuan.
# It must never be run against a human profile or a pre-existing installation.
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw '原生升级验证仅允许在一次性的 Windows GitHub runner 中运行。'
}
if ($BaseVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or
    $TargetVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or
    [version]$TargetVersion -le [version]$BaseVersion) { throw '必须明确提供递增的三段测试版本。' }
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SelectedVersion = (Get-Content (Join-Path $RepositoryRoot 'VERSION') -Raw).Trim()
if ($TargetVersion -ne $SelectedVersion) { throw '测试目标必须等于用户指定的 VERSION，不自动生成新版本。' }
$RegistryPaths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Shanchuan',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Shanchuan',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Shanchuan'
)
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Shanchuan')) { throw '检测到现有 Shanchuan 本机目录，拒绝运行。' }
foreach ($RegistryPath in $RegistryPaths) {
    if (Test-Path $RegistryPath) { throw '检测到现有 Shanchuan 安装登记，拒绝运行。' }
}
if (Get-Process -Name 'Shanchuan' -ErrorAction SilentlyContinue) { throw '检测到正在运行的正式闪传，拒绝运行。' }

$ReportRoot = Join-Path $env:RUNNER_TEMP 'native-update-smoke'
$Work = Join-Path $ReportRoot ('work-' + [guid]::NewGuid().ToString('N'))
$InstallRoot = Join-Path $Work 'install'
$Project = Join-Path $RepositoryRoot 'windows/tests/Shanchuan.UpdateSmoke/Shanchuan.UpdateSmoke.csproj'
$Publications = Join-Path $Work 'publish'
$BaseFeed = Join-Path $Work 'base-release'
$TargetFeed = Join-Path $Work 'feed'
$OldEnvironment = @{}
foreach ($Name in @('SHANCHUAN_UPDATE_SMOKE_ROOT', 'SHANCHUAN_UPDATE_SMOKE_BASE', 'SHANCHUAN_UPDATE_SMOKE_TARGET')) {
    $OldEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name)
}
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$env:SHANCHUAN_UPDATE_SMOKE_ROOT = $Work
$env:SHANCHUAN_UPDATE_SMOKE_BASE = $BaseVersion
$env:SHANCHUAN_UPDATE_SMOKE_TARGET = $TargetVersion
$BaseProcess = $null
$Failure = $null

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable 失败，退出码 $LASTEXITCODE。" }
}

function Wait-ProcessBounded {
    param([System.Diagnostics.Process]$Process, [int]$Seconds, [string]$Description)
    if (-not $Process.WaitForExit($Seconds * 1000)) {
        try { $Process.Kill($true) } catch { }
        throw "$Description 超过 ${Seconds} 秒。"
    }
    $Process.WaitForExit()
    if ($Process.ExitCode -ne 0) { throw "$Description 失败，退出码 $($Process.ExitCode)。" }
}

function Wait-Marker {
    param([string]$Name, [int]$Seconds = 120)
    $Marker = Join-Path $Work $Name
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while (-not (Test-Path $Marker)) {
        $FailurePath = Join-Path $Work 'failure.json'
        if (Test-Path $FailurePath) { throw (Get-Content $FailurePath -Raw) }
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw "等待 $Name 超时。" }
        Start-Sleep -Milliseconds 200
    }
    return Get-Content $Marker -Raw | ConvertFrom-Json
}

function Write-Approval {
    param([string]$Version, [string]$Hash)
    $Temporary = Join-Path $Work 'approval.json.tmp'
    @{ version = $Version; manifestHash = $Hash } | ConvertTo-Json | Set-Content -Path $Temporary -Encoding utf8NoBOM
    Move-Item -Force -Path $Temporary -Destination (Join-Path $Work 'approval.json')
}

Push-Location $RepositoryRoot
try {
    Invoke-Checked 'dotnet' @('tool', 'restore')
    foreach ($Pair in @(@{ Version = $BaseVersion; Feed = $BaseFeed; Name = 'base' }, @{ Version = $TargetVersion; Feed = $TargetFeed; Name = 'target' })) {
        $Output = Join-Path $Publications $Pair.Name
        Invoke-Checked 'dotnet' @('publish', $Project, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-o', $Output,
            "-p:Version=$($Pair.Version)", '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true',
            '-p:DebugType=None', '-p:DebugSymbols=false')
        Invoke-Checked 'dotnet' @('vpk', 'pack', '--packId', 'Shanchuan', '--packVersion', $Pair.Version, '--packDir', $Output,
            '--mainExe', 'Shanchuan.UpdateSmoke.exe', '--packTitle', 'Shanchuan isolated update smoke',
            '--runtime', 'win-x64', '--channel', 'win-x64', '--outputDir', $Pair.Feed)
    }
    Invoke-Checked (Join-Path $Publications 'target/Shanchuan.UpdateSmoke.exe') @('--prepare-fixture')
    if (-not (Test-Path (Join-Path $Work 'fixture-ready.json'))) { throw '签名测试源未生成。' }
    $Setup = Join-Path $BaseFeed 'Shanchuan-win-x64-Setup.exe'
    $SetupProcess = Start-Process -FilePath $Setup -ArgumentList @('--silent', '--installto', "`"$InstallRoot`"", '--log', "`"$(Join-Path $Work 'setup.log')`"") -PassThru
    Wait-ProcessBounded $SetupProcess 120 '原生 Setup 安装'
    $InstalledExecutable = Join-Path $InstallRoot 'current/Shanchuan.UpdateSmoke.exe'
    if (-not (Test-Path $InstalledExecutable)) { throw '原生 Setup 没有生成预期安装目录。' }
    $BaseProcess = Start-Process -FilePath $InstalledExecutable -PassThru -RedirectStandardOutput (Join-Path $Work 'base.stdout.log') -RedirectStandardError (Join-Path $Work 'base.stderr.log')
    $Pending = Wait-Marker 'awaiting-approval.json'
    if ($Pending.currentVersion -ne $BaseVersion -or $Pending.targetVersion -ne $TargetVersion) { throw '已安装程序与候选版本不一致。' }
    # A fake authorization is rejected without staging a native package.
    Write-Approval $TargetVersion ('0' * 64)
    $Rejected = Wait-Marker 'rejected-approval.json'
    if (-not $Rejected.rejected -or -not $Rejected.noManagedTarget) { throw '错误授权没有被拒绝。' }
    if ($BaseProcess.HasExited) { throw '确认前基线程序已经退出。' }
    # Explicit test-driver approval corresponds to the user confirming the footer dialog.
    Write-Approval $TargetVersion $Pending.manifestHash
    $Result = Wait-Marker 'success.json' 180
    foreach ($Property in @('signedManifestVerified', 'noInstallBeforeApproval', 'wrongApprovalRejected', 'nativeSetupInstalled', 'nativeUpdateRestarted', 'userDataPreserved')) {
        if (-not $Result.$Property) { throw "原生升级断言未满足：$Property" }
    }
    if ($Result.oldVersion -ne $BaseVersion -or $Result.newVersion -ne $TargetVersion -or $Result.oldPid -eq $Result.newPid) {
        throw '原生升级未完成版本和进程切换。'
    }
    $Result | Add-Member -NotePropertyName testKind -NotePropertyValue 'isolated-console-payload-using-production-core-and-native-velopack'
    $Result | Add-Member -NotePropertyName limitation -NotePropertyValue 'Does not claim to upgrade the previously published GUI 0.1.1 through its disabled public prerelease channel.'
    $Result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ReportRoot 'report.json') -Encoding utf8NoBOM
    Write-Host "原生升级验证通过：$BaseVersion -> $TargetVersion，已验证签名缓存、确认门槛、真实替换重启和数据保留。"
}
catch {
    $Failure = $_
    @{ success = $false; baseVersion = $BaseVersion; targetVersion = $TargetVersion; error = $_.Exception.Message } |
        ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ReportRoot 'report.json') -Encoding utf8NoBOM
}
finally {
    # Let the native apply worker finish its post-relaunch bookkeeping before cleanup.
    if (Test-Path (Join-Path $Work 'success.json')) {
        $NativeDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
        do {
            $NativeWorkers = @(Get-CimInstance Win32_Process | Where-Object {
                $_.ExecutablePath -and $_.ExecutablePath.Equals((Join-Path $InstallRoot 'Update.exe'), [StringComparison]::OrdinalIgnoreCase)
            })
            if ($NativeWorkers.Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $NativeDeadline)
    }
    # Kill only executables located under this unique fixture install, never by a
    # shared process name and never anything in a normal Shanchuan installation.
    try {
        Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $Updater = Join-Path $InstallRoot 'Update.exe'
        if (Test-Path $Updater) {
            $Uninstall = Start-Process -FilePath $Updater -ArgumentList @('uninstall', '--silent', '--log', "`"$(Join-Path $Work 'uninstall.log')`"") -PassThru
            Wait-ProcessBounded $Uninstall 60 '测试安装清理'
        }
    }
    catch {
        $_.Exception.Message | Set-Content (Join-Path $ReportRoot 'cleanup.log') -Encoding utf8NoBOM
        if ($null -eq $Failure) { $Failure = $_ }
    }
    foreach ($Log in Get-ChildItem -Path $Work -Recurse -Filter '*.log' -ErrorAction SilentlyContinue) {
        Copy-Item -Path $Log.FullName -Destination (Join-Path $ReportRoot ($Log.Name)) -Force
    }
    foreach ($Name in $OldEnvironment.Keys) { [Environment]::SetEnvironmentVariable($Name, $OldEnvironment[$Name]) }
    Pop-Location
}
if ($null -ne $Failure) { throw $Failure }
