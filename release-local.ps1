<#
.SYNOPSIS
    本地构建并以 GitHub API 发布 FastGithubOps.UI 的 win-x64 Release。

.DESCRIPTION
    这是 CI（release.yml）之外的一条独立发布路径。当 fork 仓库的 GITHUB_TOKEN
    无写权限、无法在 CI 内推送 tag 时，用本机 dotnet 构建，再用已登录的 gh CLI
    创建 Release 并上传产物。所有产物写到系统临时目录，不污染工作区。

    流程：前置检查 -> 构建主程序(net10 单文件) + UI(net45) -> 关键文件校验
          -> 删除 cacert/logs -> 生成 sha256 -> 扁平 zip -> gh release create
          -> 上传后回读核对 size 与 sha256。

.PARAMETER Version
    版本号，格式 vX.Y.Z（例如 v2.6.15）。必须与 Directory.Build.props 的
    <Version> 一致，且 release-notes/<Version>.md 已存在。

.PARAMETER Repo
    目标仓库，默认当前 fork：FluxForceDynamics/FastGithubOps.UI。

.PARAMETER Target
    打 tag 所基于的提交。默认取当前 HEAD 的完整 40 位 SHA。
    注意：gh release create 的 --target 必须用完整 SHA，短 SHA 会报
    "target_commitish is invalid"。

.PARAMETER OutDir
    构建/打包输出目录。默认系统临时目录下的 fastgithub-release-<Version>。

.PARAMETER NoPublish
    只做构建、校验与打包，不创建 Release。用于验证脚本或离线检查产物。

.PARAMETER SkipChecks
    跳过「版本号与 props 一致 / release notes 存在 / tag 未占用」前置检查。
    一般不要使用，仅在特殊恢复场景。

.EXAMPLE
    .\release-local.ps1 -Version v2.6.15

.EXAMPLE
    .\release-local.ps1 -Version v2.6.15 -NoPublish
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$Repo = 'FluxForceDynamics/FastGithubOps.UI',

    [string]$Target,

    [string]$OutDir,

    [switch]$NoPublish,

    [switch]$SkipChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2 { param($msg) Write-Host "    [警告] $msg" -ForegroundColor Yellow }
function Fail        { param($msg) throw "错误: $msg" }

# 定位仓库根（脚本所在目录），所有相对路径都相对它。
$RepoRoot = $PSScriptRoot
$publishDir = Join-Path $RepoRoot 'publish'
Push-Location $RepoRoot

try {
    # ------------------------------------------------------------------ 前置检查
    Write-Step '前置检查'

    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCmd) { Fail '未找到 dotnet，请先安装 .NET 10 SDK' }
    Write-Ok ("dotnet: " + (& dotnet --version))

    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCmd -and -not $NoPublish) { Fail '未找到 gh CLI，请先安装并登录' }
    if ($ghCmd) {
        & gh auth status 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -and -not $NoPublish) { Fail 'gh 未登录，请先执行 gh auth login' }
        $gh = $ghCmd.Source
        if ($NoPublish) { Write-Ok 'gh: 已找到（-NoPublish 模式不校验登录态）' }
    }

    if (-not (Test-Path (Join-Path $RepoRoot 'Directory.Build.props'))) {
        Fail '脚本必须放在仓库根目录执行（找不到 Directory.Build.props）'
    }

    if (-not $SkipChecks) {
        # 版本号必须与程序集版本一致，否则会出现「Release 叫 v2.6.15、exe 内部还是 2.6.14」。
        $propsRaw = Get-Content (Join-Path $RepoRoot 'Directory.Build.props') -Raw -Encoding UTF8
        $assemblyVersion = $null
        if ($propsRaw -match '<Version>\s*([0-9]+\.[0-9]+\.[0-9]+)\s*</Version>') {
            $assemblyVersion = $Matches[1]
        }
        $bare = $Version.TrimStart('v')
        if ($assemblyVersion -ne $bare) {
            Fail "Version ($bare) 与 Directory.Build.props 的 <Version> ($assemblyVersion) 不一致；请先同步版本号"
        }
        Write-Ok "版本号一致: $bare"

        # Release 正文必须是因为单一事实来源，缺失时宁可中断，也不发一个没有说明的包。
        $notesPath = Join-Path $RepoRoot "release-notes/$Version.md"
        if (-not (Test-Path $notesPath)) {
            Fail "缺少 release-notes/$Version.md，请先编写发布说明"
        }
        Write-Ok "发布说明存在: release-notes/$Version.md"

        if (-not $NoPublish) {
            # 已存在的 tag / Release 不再重复发布，避免覆盖。
            & $gh api "repos/$Repo/git/ref/tags/$Version" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Fail "远程已存在 tag $Version" }
            Write-Ok '远程无同名 tag'
        }
    } else {
        $notesPath = Join-Path $RepoRoot "release-notes/$Version.md"
        if (-not (Test-Path $notesPath)) {
            Write-Warn2 "release-notes/$Version.md 不存在（-SkipChecks），将不传 --notes-file"
        }
    }

    # ------------------------------------------------------------------ 输出目录
    if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ("fastgithub-release-" + $Version) }
    $OutDir = [System.IO.Path]::GetFullPath($OutDir)
    if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    Write-Ok "输出目录: $OutDir"

    # 用临时 NuGet 配置指向 nuget.org：仓库自带的华为云镜像在部分网络下会返回损坏的 nupkg。
    # 通过 -p:RestoreConfigFile 注入，不修改仓库的 NuGet.config。
    $nugetCfg = Join-Path $OutDir 'NuGet.org.config'
    @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
</configuration>
'@ | Set-Content -Path $nugetCfg -Encoding UTF8

    $binDir = Join-Path $OutDir 'bin'

    # ------------------------------------------------------------------ 构建
    Write-Step '构建主程序（net10 / win-x64 自包含单文件）'
    & dotnet publish FastGithub/FastGithub.csproj -c Release -r win-x64 `
        --self-contained true -p:PublishSingleFile=true `
        "-p:RestoreConfigFile=$nugetCfg" -o $binDir
    if ($LASTEXITCODE -ne 0) { Fail '主程序构建失败' }

    Write-Step '构建 UI（net45 / WPF，输出到同一目录）'
    & dotnet publish FastGithub.UI/FastGithub.UI.csproj -c Release `
        "-p:RestoreConfigFile=$nugetCfg" -o $binDir
    if ($LASTEXITCODE -ne 0) { Fail 'UI 构建失败' }

    # ------------------------------------------------------------------ 校验文件
    Write-Step '校验发布文件'
    foreach ($f in @('fastgithub.exe', 'FastGithub.UI.exe', 'FastGithub.UI.exe.config', 'appsettings.json')) {
        if (-not (Test-Path (Join-Path $binDir $f))) { Fail "缺少发布文件: $f" }
        Write-Ok "OK  $f"
    }

    # CA 私钥绝不能随包分发：程序启动会自动重建 cacert 目录。
    foreach ($d in @('cacert', 'logs')) {
        $p = Join-Path $binDir $d
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Ok "已删除敏感目录: $d" }
    }

    # ------------------------------------------------------------------ 打包
    Write-Step '生成 sha256 与 zip'
    $shaFile = Join-Path $OutDir 'fastgithub-win-x64.sha256'
    $shaLines = @()
    foreach ($f in @('fastgithub.exe', 'FastGithub.UI.exe')) {
        $h = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $binDir $f)).Hash.ToLower()
        # 与 CI 的 sha256sum 输出格式一致：两个空格 + 文件名。
        $shaLines += "$h  $f"
    }
    $shaLines | Set-Content -Path $shaFile -Encoding ASCII
    Write-Ok ($shaLines -join "`n    ")

    $zipFile = Join-Path $OutDir 'fastgithub-win-x64.zip'
    if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
    Compress-Archive -Path (Join-Path $binDir '*') -DestinationPath $zipFile -CompressionLevel Optimal
    Write-Ok ("zip: {0} ({1} 字节)" -f $zipFile, (Get-Item $zipFile).Length)

    if ($NoPublish) {
        Write-Host "`n-NoPublish：已生成产物，未创建 Release。" -ForegroundColor Green
        Write-Host "  $zipFile`n  $shaFile"
        return
    }

    # ------------------------------------------------------------------ 发布
    Write-Step '创建 GitHub Release 并上传'
    if (-not $Target) { $Target = (& git rev-parse HEAD).Trim() }
    if ($Target -notmatch '^[0-9a-f]{40}$') {
        Fail "Target 必须是完整 40 位 SHA（当前: $Target），短 SHA 会报 target_commitish is invalid"
    }
    Write-Ok "target: $Target"

    $assetArgs = @($zipFile, $shaFile)
    $releaseArgs = @('release', 'create', $Version,
        '--repo', $Repo,
        '--title', "FastGithubOps.UI $Version",
        '--target', $Target)
    if (Test-Path $notesPath) { $releaseArgs += @('--notes-file', $notesPath) }
    $releaseArgs += $assetArgs

    & $gh @releaseArgs
    if ($LASTEXITCODE -ne 0) { Fail 'gh release create 失败' }

    # ------------------------------------------------------------------ 回读核对
    # 上传后回读 size 与 digest（sha256）核对，防止链路损坏导致发出坏包。
    # 这一条继承自仓库内 create_release.py 的既有约定。
    Write-Step '回读核对上传产物'
    $json = & $gh api "repos/$Repo/releases/tags/$Version" `
        --jq '[.assets[] | {name, size, digest}]' | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { Fail '回读 Release assets 失败' }

    $allOk = $true
    foreach ($asset in $json) {
        $local = if ($asset.name -eq 'fastgithub-win-x64.zip') { $zipFile } else { $shaFile }
        if (-not (Test-Path $local)) { continue }
        $localSize = (Get-Item $local).Length
        $localHash = (Get-FileHash -Algorithm SHA256 -Path $local).Hash.ToLower()
        $remoteHash = ($asset.digest -replace '^sha256:', '').ToLower()
        $sizeOk = ($asset.size -eq $localSize)
        $hashOk = ($remoteHash -eq $localHash)
        if ($sizeOk -and $hashOk) {
            Write-Ok ("核对一致: {0}  sha256={1}..." -f $asset.name, $localHash.Substring(0, 16))
        } else {
            $allOk = $false
            Write-Warn2 ("不一致: {0}  size {1}/{2}  sha256 {3}/{4}" -f `
                $asset.name, $asset.size, $localSize, $remoteHash, $localHash)
        }
    }
    if (-not $allOk) { Fail '上传产物回读核对失败，请检查 Release' }

    Write-Host "`n发布完成: https://github.com/$Repo/releases/tag/$Version" -ForegroundColor Green
}
finally {
    Pop-Location
}
