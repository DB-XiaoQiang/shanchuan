param(
    [Parameter(Mandatory = $true)][string]$BaseVersion,
    [Parameter(Mandatory = $true)][string]$TargetVersion
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Remove the CI secret before starting ANY build, Setup or GUI child process.
$PrivateKey = $env:UPDATE_MANIFEST_PRIVATE_KEY
[Environment]::SetEnvironmentVariable('UPDATE_MANIFEST_PRIVATE_KEY', $null)
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw '实际 GUI 升级验收仅允许在全新的一次性 GitHub Windows runner 执行。'
}
if ([string]::IsNullOrWhiteSpace($PrivateKey)) { throw '缺少用于隔离缓存签名的发行私钥。' }
if ($BaseVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or
    $TargetVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or
    [version]$TargetVersion -le [version]$BaseVersion) { throw '必须明确提供递增的三段版本号。' }
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($TargetVersion -ne (Get-Content (Join-Path $RepositoryRoot 'VERSION') -Raw).Trim()) { throw '目标必须等于用户指定的 VERSION。' }
$ReportRoot = Join-Path $env:RUNNER_TEMP 'gui-update-smoke'
$Work = Join-Path $ReportRoot ('work-' + [guid]::NewGuid().ToString('N'))
$Feed = Join-Path $Work 'feed'
$ProductOutput = Join-Path $Work 'production'
$DriverOutput = Join-Path $Work 'driver'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable 失败，退出码 $LASTEXITCODE。" }
}

Push-Location $RepositoryRoot
try {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/DB-XiaoQiang/shanchuan/releases/tags/v$BaseVersion" -Headers @{ 'User-Agent' = 'Shanchuan-Gui-Update-Acceptance' }
    if ($Release.draft -or $Release.tag_name -ne "v$BaseVersion") { throw '基线必须是明确指定的原始公开版本。' }
    $Asset = @($Release.assets | Where-Object { $_.name -eq 'Shanchuan-win-x64-Setup.exe' })
    if ($Asset.Count -ne 1 -or -not $Asset[0].digest.StartsWith('sha256:')) { throw '基线安装包缺少唯一附件或 SHA-256 摘要。' }
    $OriginalSetup = Join-Path $Work 'original-public-Setup.exe'
    Invoke-WebRequest -Uri "https://github.com/DB-XiaoQiang/shanchuan/releases/download/v$BaseVersion/Shanchuan-win-x64-Setup.exe" -OutFile $OriginalSetup
    if (('sha256:' + (Get-FileHash $OriginalSetup -Algorithm SHA256).Hash.ToLowerInvariant()) -ne $Asset[0].digest) { throw '原始公开安装包校验失败。' }
    @{ source = "https://github.com/DB-XiaoQiang/shanchuan/releases/tag/v$BaseVersion"; sha256 = $Asset[0].digest; installerUnmodified = $true } |
        ConvertTo-Json | Set-Content (Join-Path $ReportRoot 'original-installer.json') -Encoding utf8NoBOM

    Invoke-Checked 'dotnet' @('tool', 'restore')
    $Product = Join-Path $RepositoryRoot 'windows/src/Shanchuan.Windows/Shanchuan.Windows.csproj'
    Invoke-Checked 'dotnet' @('publish', $Product, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-o', $ProductOutput,
        "-p:Version=$TargetVersion", '-p:UpdateRepository=https://github.com/DB-XiaoQiang/shanchuan', '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:DebugType=None', '-p:DebugSymbols=false')
    Invoke-Checked 'dotnet' @('vpk', 'pack', '--packId', 'Shanchuan', '--packVersion', $TargetVersion, '--packDir', $ProductOutput,
        '--mainExe', 'Shanchuan.exe', '--packTitle', '闪传', '--runtime', 'win-x64', '--channel', 'win-x64',
        '--icon', (Join-Path $RepositoryRoot 'windows/src/Shanchuan.Windows/Assets/app.ico'), '--outputDir', $Feed)
    $DriverProject = Join-Path $RepositoryRoot 'windows/tests/Shanchuan.GuiUpdateSmoke/Shanchuan.GuiUpdateSmoke.csproj'
    Invoke-Checked 'dotnet' @('publish', $DriverProject, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-o', $DriverOutput,
        '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:DebugType=None', '-p:DebugSymbols=false')

    $Start = [Diagnostics.ProcessStartInfo]::new((Join-Path $DriverOutput 'Shanchuan.GuiUpdateSmoke.exe'))
    $Start.UseShellExecute = $false
    $Start.RedirectStandardInput = $true
    $Start.RedirectStandardOutput = $true
    $Start.RedirectStandardError = $true
    $Start.Environment.Remove('UPDATE_MANIFEST_PRIVATE_KEY') | Out-Null
    foreach ($Argument in @($Work, $OriginalSetup, $Feed, $BaseVersion, $TargetVersion, $ReportRoot)) { $Start.ArgumentList.Add($Argument) }
    $Driver = [Diagnostics.Process]::Start($Start)
    $OutputTask = $Driver.StandardOutput.ReadToEndAsync()
    $ErrorTask = $Driver.StandardError.ReadToEndAsync()
    $Driver.StandardInput.Write($PrivateKey)
    $Driver.StandardInput.Close()
    $PrivateKey = $null
    if (-not $Driver.WaitForExit(600000)) {
        try { $Driver.Kill($true) } catch { }
        throw '实际 GUI 升级验收超过 10 分钟。'
    }
    $Driver.WaitForExit()
    $OutputTask.GetAwaiter().GetResult() | Set-Content (Join-Path $ReportRoot 'gui-driver.stdout.log') -Encoding utf8NoBOM
    $ErrorTask.GetAwaiter().GetResult() | Set-Content (Join-Path $ReportRoot 'gui-driver.stderr.log') -Encoding utf8NoBOM
    if ($Driver.ExitCode -ne 0) { throw "实际 GUI 升级验收失败，退出码 $($Driver.ExitCode)。" }
    $Report = Get-Content (Join-Path $ReportRoot 'gui-update-report.json') -Raw | ConvertFrom-Json
    if (-not $Report.passed -or $Report.publicPrereleaseAutoDiscoveryTested -or $Report.formalUpdateChannelEnabled) { throw 'GUI 升级报告状态无效。' }
    Write-Host "实际原始 GUI 升级验收通过：$BaseVersion -> $TargetVersion。正式更新通道未开启。"
}
finally {
    $PrivateKey = $null
    [Environment]::SetEnvironmentVariable('UPDATE_MANIFEST_PRIVATE_KEY', $null)
    Pop-Location
}
