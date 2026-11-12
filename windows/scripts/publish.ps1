param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",
    [string]$UpdateRepository = "",
    [switch]$Installer
)

$ErrorActionPreference = "Stop"
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $WindowsRoot
$Project = Join-Path $WindowsRoot "src/Shanchuan.Windows/Shanchuan.Windows.csproj"
$TestProject = Join-Path $WindowsRoot "tests/Shanchuan.Core.Tests/Shanchuan.Core.Tests.csproj"
$Output = Join-Path $WindowsRoot "dist/publish/$Runtime"
$Archive = Join-Path $WindowsRoot "dist/Shanchuan-$Runtime.zip"

Push-Location $RepositoryRoot
try {
    dotnet test $TestProject --configuration Release
    if ($LASTEXITCODE -ne 0) { throw "核心测试失败。" }

    if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
    dotnet publish $Project --configuration Release --runtime $Runtime --self-contained true --output $Output `
        -p:UpdateRepository="$UpdateRepository" -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) { throw "Windows 发布失败。" }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Archive) | Out-Null
    if (Test-Path $Archive) { Remove-Item $Archive -Force }
    Compress-Archive -Path (Join-Path $Output "*") -DestinationPath $Archive -CompressionLevel Optimal
    if ($Installer) {
        $Version = (Get-Content (Join-Path $RepositoryRoot "VERSION") -Raw).Trim()
        dotnet tool restore
        if ($LASTEXITCODE -ne 0) { throw "更新工具还原失败。" }
        dotnet vpk pack --packId Shanchuan --packVersion $Version --packDir $Output --mainExe Shanchuan.exe --packTitle "闪传" --runtime $Runtime --channel $Runtime --icon (Join-Path $WindowsRoot "src/Shanchuan.Windows/Assets/app.ico") --outputDir (Join-Path $WindowsRoot "dist/releases")
        if ($LASTEXITCODE -ne 0) { throw "安装包生成失败。" }
    }
    Write-Host "发布完成：$Archive"
}
finally {
    Pop-Location
}
