#!/usr/bin/env pwsh
#requires -Version 5.1
# dshctl.ps1 - dsh web 服务的安装、升级与托管（Windows 版）
#
# 只管一件事：把官方 npm 包 @deepseek-ai/dsh 装进全局树，并以独立进程托管它。
# 没有第二个安装位置，也没有「运行来源」开关：装的就是跑的。与 bash 版 0.6 同构。
#
# 用法：
#   .\dshctl.ps1                    查看状态
#   .\dshctl.ps1 upgrade [通道|版本] 安装/升级官方包（默认沿用记住的通道）
#   .\dshctl.ps1 install            首次安装：把 dshctl 放进 PATH、初始化目录并装包
#   .\dshctl.ps1 status             状态 + 已装版本 + 「进程是否还跑着旧代码」
#   .\dshctl.ps1 log                最近日志
#   .\dshctl.ps1 start|stop|restart 服务控制
#   .\dshctl.ps1 check              预检：已装版本能否用当前 profile 启动（不重启）
#   .\dshctl.ps1 repair             清理陈旧进程记录并重启
#   .\dshctl.ps1 self-update        更新 dshctl 自身
#   .\dshctl.ps1 help               完整说明
#   通用开关：-DryRun 只说不做；-NoRestart 装完不重启
#
# 三条硬规则，与 bash 版同源：
#   1. 未知的 - 开头参数一律拒绝执行，不猜。
#   2. 预检必须在正式安装之前跑在暂存件上。全局 npm 树就是正在运行的那份安装，
#      npm i -g 先落地再预检等于拿线上做实验：旧进程内存里是旧代码，新会话按需加载
#      新文件就会炸（bash 侧实测：rc.2 进程加载 rc.5 的模块，报导出不存在）。
#      所以顺序固定为：隔离暂存 → 预检 → 提交 → 重启，重启失败自动装回上一个版本。
#   3. 预检必须在「不占用线上端口」的前提下跑。profile 可能把监听端口写死
#      （remote-web-ui 的 lan-bind 块会写 host-webserver.port，配置优先于 --port），
#      所以临时 DSH_HOME 里也要把那个端口改到空闲端口，否则预检永远端口冲突。
#
# 还有一条体现在输出里：磁盘上的包装得比进程启动还晚时，必须直说——那种状态下
# 进程、日志、HTTP 应答全都「正常」，故障只在浏览器里现形。

<#
.SYNOPSIS
    dsh web 服务的安装、升级与托管（Windows 版）

.DESCRIPTION
    把官方 npm 包 @deepseek-ai/dsh 装进全局树，并以独立进程托管。
    升级是事务式的：隔离暂存 → 用当前 profile 预检 → 提交 → 重启，失败自动回滚。

.PARAMETER Command
    upgrade / install / status / start / stop / restart / log / check / repair / self-update / help

.PARAMETER Target
    upgrade 的通道或版本：latest / next / alpha / 0.2.1-rc.5

.EXAMPLE
    .\dshctl.ps1 upgrade next

.EXAMPLE
    .\dshctl.ps1 status
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "",

    [Parameter(Position = 1)]
    [string]$Target = "",

    [switch]$DryRun,
    [switch]$NoRestart,
    [switch]$Help
)

# ── 常量配置 ────────────────────────────────────────────────────────────
$PACKAGE_NAME = "@deepseek-ai/dsh"
$DshHost = "127.0.0.1"
$PORT = 3080
$URL = "http://${DshHost}:${PORT}"
# 服务固定以 `dsh web` 启动，所以 profile 与端口是常量。
$DshProfile = "web"

# dshctl 自身版本与远端基址：self-update 时对比仓库根的 VERSION 文件。
# 发版约定：改这里的同时改仓库根 VERSION，两处一致才放行。
$DSHCTL_VERSION = "0.6.0"
$DSHCTL_RAW_BASE = "https://raw.githubusercontent.com/stofancy/dshctl/main"

# 状态：更新通道与「上一个版本」（回滚用）。
$STATE_DIR = Join-Path $env:USERPROFILE ".config\dsh"
$CHANNEL_FILE = Join-Path $STATE_DIR "channel"
$PREV_VERSION_FILE = Join-Path $STATE_DIR "previous-version"

# 已废弃的双槽位模型留下的状态文件：留着只会误导，启动时清掉。
$LEGACY_STATE_FILES = @(
    (Join-Path $STATE_DIR "current-source"),
    (Join-Path $STATE_DIR "local-path"),
    (Join-Path $STATE_DIR "local-detail")
)

# 进程与日志
$PID_FILE = Join-Path $STATE_DIR "dsh-web.pid"
$LOG_DIR = Join-Path $STATE_DIR "logs"
$LOG_FILE = Join-Path $LOG_DIR "dsh-web.log"
$ERR_FILE = Join-Path $LOG_DIR "dsh-web.err.log"

$PREFLIGHT_TRIES = if ($env:DSHCTL_PREFLIGHT_TRIES) { [int]$env:DSHCTL_PREFLIGHT_TRIES } else { 25 }
$HEALTH_TRIES = if ($env:DSHCTL_HEALTH_TRIES) { [int]$env:DSHCTL_HEALTH_TRIES } else { 30 }

$NpmPrefixCache = $null

# ── 输出 ────────────────────────────────────────────────────────────────
function Write-ColorText {
    param([string]$Text, [string]$Color = "White")
    Write-Host $Text -ForegroundColor $Color
}

function Write-Success { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Fail { param([string]$Text) Write-Host $Text -ForegroundColor Red }
function Write-Warn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }

# ── 状态读写 ────────────────────────────────────────────────────────────
# 读取一行状态；文件缺失或读不到时返回空串，绝不因为状态损坏而中断。
function Read-State {
    param([string]$File)
    if (-not (Test-Path $File)) { return "" }
    try {
        return ([System.IO.File]::ReadAllText($File)).Trim()
    } catch {
        return ""
    }
}

# 原子写入：先写临时文件再替换，避免中断留下截断内容把记忆弄坏。
function Write-State {
    param([string]$File, [string]$Value)
    $dir = Split-Path $File -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$File.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $Value)
    Move-Item -Path $tmp -Destination $File -Force
}

# ── 通用工具 ────────────────────────────────────────────────────────────
function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# dist-tag 只认这三个；也允许显式版本号（形如 0.2.1-rc.5）。
function Test-ValidChannel {
    param([string]$Channel)
    return $Channel -match '^(latest|next|alpha|[0-9]+\.[0-9]+\.[0-9]+.*)$'
}

# 当前更新通道。记忆缺失、为空或含非法值时回落 latest——否则一个手改坏的值会让
# 此后每次裸 upgrade 都永久失败（写回发生在安装成功之后，无法自愈）。
function Get-CurrentChannel {
    $channel = Read-State $CHANNEL_FILE
    if ($channel -and (Test-ValidChannel $channel)) { return $channel }
    if ($channel) { Write-Warn "⚠ 记忆的更新通道无效（$channel），本次回退 latest" }
    return "latest"
}

function Resolve-Tag {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    return (Get-CurrentChannel)
}

# npm 全局前缀（唯一安装位置）。惰性求值并缓存。
function Get-NpmPrefix {
    if ($null -ne $script:NpmPrefixCache -and $script:NpmPrefixCache -ne "") {
        return $script:NpmPrefixCache
    }
    if (-not (Test-Command "npm")) { return $null }
    $prefix = (& npm prefix -g 2>$null | Select-Object -First 1)
    if (-not $prefix) { return $null }
    $script:NpmPrefixCache = $prefix.Trim()
    return $script:NpmPrefixCache
}

# 全局树里的包目录。装了就是它，没有第二个候选。
function Get-GlobalPackageDir {
    $prefix = Get-NpmPrefix
    if (-not $prefix) { return $null }
    return (Join-Path (Join-Path $prefix "node_modules") "@deepseek-ai\dsh")
}

# 包的入口不猜：从 package.json 的 bin.dsh 读（真实入口随上游结构变化）。
function Get-PackageEntry {
    param([string]$PackageDir)
    if (-not $PackageDir) { return $null }
    $pkgJson = Join-Path $PackageDir "package.json"
    if (-not (Test-Path $pkgJson)) { return $null }
    try {
        $bin = (Get-Content $pkgJson -Raw | ConvertFrom-Json).bin.dsh
        if ($bin -is [string] -and $bin) { return (Join-Path $PackageDir $bin) }
    } catch {
        return $null
    }
    return $null
}

function Get-DshEntry {
    param([string]$PackageDir)
    $dir = if ($PackageDir) { $PackageDir } else { Get-GlobalPackageDir }
    return (Get-PackageEntry $dir)
}

# 已装版本；读不到时报「未知」，不中断流程。
function Get-InstalledVersion {
    param([string]$PackageDir)
    $entry = Get-DshEntry $PackageDir
    if (-not $entry -or -not (Test-Path $entry)) { return "未安装" }
    try {
        $v = (& node $entry --version 2>$null)
        if ($v) { return ([string]$v).Trim() }
        return "未知"
    } catch {
        return "未知"
    }
}

# ── 网络前置检查 ────────────────────────────────────────────────────────
function Test-ProxyReachable {
    param([string]$Proxy)
    $uri = $null
    if (-not [Uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if (-not $uri.Host) { return $false }
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 80 }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($uri.Host, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(2000)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# npm 失败最容易被误读成「安装失败」的两种根因：代理挂了、镜像还没同步目标版本。
# 代理不可达时不让它伪装成安装问题：能直连就本次直连（只影响本进程），否则明确报错。
function Invoke-NetworkPrecheck {
    $proxy = $env:HTTPS_PROXY
    if (-not $proxy) { $proxy = $env:HTTP_PROXY }
    if (-not $proxy) { return $true }
    if (Test-ProxyReachable $proxy) { return $true }

    Write-Warn "⚠ 代理不可达：$proxy"
    $registry = (& npm config get registry 2>$null | Select-Object -First 1)
    if (-not $registry) { $registry = "https://registry.npmjs.org" }
    $registry = ([string]$registry).Trim()

    $saved = @{
        HTTP_PROXY = $env:HTTP_PROXY
        HTTPS_PROXY = $env:HTTPS_PROXY
    }
    $env:HTTP_PROXY = ""
    $env:HTTPS_PROXY = ""
    try {
        $null = Invoke-WebRequest -Uri $registry -Method Head -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
        Write-Info "  本次直连 $registry（仅影响这次运行）"
        return $true
    } catch {
        $env:HTTP_PROXY = $saved.HTTP_PROXY
        $env:HTTPS_PROXY = $saved.HTTPS_PROXY
        Write-Fail "  直连 $registry 也不通：先恢复代理，或换一个可用的 registry，再重试。"
        return $false
    }
}

# dist-tag / 版本号 → 确切版本。镜像同步滞后时 dist-tag 已经指过去、版本却还没落地，
# 这时说清原因，比把 npm 的报错原样糊出来有用。
function Get-NpmViewVersion {
    param([string]$Tag)
    if (-not (Test-Command "npm")) { Write-Fail "未找到 npm，无法解析 $Tag"; return $null }
    $out = (& npm view "$PACKAGE_NAME@$Tag" version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "取不到 $PACKAGE_NAME@$Tag 的版本："
        ($out | Select-Object -First 5) | ForEach-Object { Write-Host "    $_" }
        $text = ($out -join " ")
        if ($text -match "ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ECONNRESET") {
            Write-Host "    → 网络或代理问题：先确认 npm 能访问 registry"
        } elseif ($text -match "E404|404|No matching version") {
            Write-Host "    → registry 里没有 $Tag；镜像未同步时可稍后重试，或用显式版本号"
        }
        return $null
    }
    return ([string]($out | Select-Object -Last 1)).Trim()
}

# ── 漂移检测 ────────────────────────────────────────────────────────────
# 磁盘上的包装得比进程启动还晚 = 进程内存里还是旧代码。这类故障只在浏览器里现形，
# 进程状态、日志、HTTP 应答全是「正常」。
function Test-RunningStale {
    $pkgDir = Get-GlobalPackageDir
    if (-not $pkgDir) { return $false }
    $pkgJson = Join-Path $pkgDir "package.json"
    if (-not (Test-Path $pkgJson)) { return $false }
    $proc = Get-DshProcess
    if (-not $proc) { return $false }
    try {
        $installed = (Get-Item $pkgJson).LastWriteTimeUtc
        $started = $proc.StartTime.ToUniversalTime()
        return ($installed -gt $started)
    } catch {
        return $false
    }
}

function Write-StaleWarning {
    if (-not (Test-RunningStale)) { return }
    Write-Warn "⚠ 磁盘上的包比运行中的进程新：进程还跑着旧代码。"
    Write-Warn "  新会话可能因新旧模块混载而失败（例如某些导出不存在）。执行：.\dshctl.ps1 restart"
}

# ── 进程 ────────────────────────────────────────────────────────────────
# 服务进程：先认 PID 文件，再退到端口占用者。
function Get-DshProcess {
    if (Test-Path $PID_FILE) {
        $raw = Read-State $PID_FILE
        $procId = 0
        if ([int]::TryParse($raw, [ref]$procId)) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match 'node') { return $proc }
        }
        Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
    }
    try {
        $conn = Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction Stop |
            Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            return (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue)
        }
    } catch {
    }
    return $null
}

# 等待服务真正可用：进程在，且根路径给出应用级应答（认证重定向 3xx 或 401）。
# 连不上、404、5xx 都算没起来——只看进程存在会漏判「起来一秒就崩」。
function Test-ServiceHealth {
    param([int]$MaxRetries = $HEALTH_TRIES)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        if (-not (Get-DshProcess)) { Start-Sleep -Seconds 1; continue }
        try {
            $resp = Invoke-WebRequest -Uri "$URL/" -Method Head -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -in @(200, 401, 303, 302)) { return $true }
        } catch {
            $code = $null
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
            if ($code -in @(200, 401, 303, 302)) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Start-DshService {
    $existing = Get-DshProcess
    if ($existing) {
        Write-Warn "服务已在运行（PID: $($existing.Id)）"
        return $true
    }
    $entry = Get-DshEntry
    if (-not $entry -or -not (Test-Path $entry)) {
        Write-Fail "未找到可执行入口：$entry（先跑 .\dshctl.ps1 upgrade）"
        return $false
    }
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }

    Write-Info "启动服务..."
    try {
        $proc = Start-Process -FilePath "node" `
            -ArgumentList @("`"$entry`"", "web", "--host", $DshHost, "--port", "$PORT") `
            -RedirectStandardOutput $LOG_FILE `
            -RedirectStandardError $ERR_FILE `
            -WindowStyle Hidden -PassThru
        [System.IO.File]::WriteAllText($PID_FILE, [string]$proc.Id)

        if (Test-ServiceHealth) {
            Write-Success "✓ 服务已启动：$URL"
            return $true
        }
        Write-Fail "⚠ 服务启动后未给出应用级应答，查看日志：.\dshctl.ps1 log"
        return $false
    } catch {
        Write-Fail "启动失败：$($_.Exception.Message)"
        return $false
    }
}

function Stop-DshService {
    $proc = Get-DshProcess
    if (-not $proc) {
        Write-Warn "服务未运行"
        Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
        return $true
    }
    Write-Info "停止服务（PID: $($proc.Id)）..."
    try {
        # 按进程树杀：插件可能派生了子进程，只杀父进程会留孤儿占着端口。
        & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
        Write-Success "✓ 服务已停止"
        return $true
    } catch {
        Write-Fail "停止失败：$($_.Exception.Message)"
        return $false
    }
}

function Restart-DshService {
    Stop-DshService | Out-Null
    Start-Sleep -Seconds 1
    return (Start-DshService)
}

# 重启失败就装回上一个版本再重启：一个坏制品不能让线上服务躺着。
function Restart-Checked {
    if (Restart-DshService) { return $true }
    Write-Warn "  服务未起来，尝试装回上一个版本…"
    if (-not (Install-Rollback)) {
        Write-Fail "  ✘ 没有可回滚的版本，查看日志：.\dshctl.ps1 log"
        return $false
    }
    if (Restart-DshService) {
        Write-Warn "  已回滚到 $(Get-InstalledVersion)，服务恢复运行"
    } else {
        Write-Fail "  ✘ 回滚后服务仍未起来，查看日志：.\dshctl.ps1 log"
    }
    return $false
}

# ── 安装事务：暂存 / 提交 / 回滚 ────────────────────────────────────────
# 暂存：把确切版本装进隔离 prefix，全局树在这一步一行都不动。这样「预检失败」
# 才真的等于「线上什么都没变」，也不会留下装了一半的中间态。
function Install-Stage {
    param([string]$Want)
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dshctl-stage-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $script:StageRoot = $stage
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Write-Info "  暂存安装（隔离 prefix，不动全局树）..."
    & npm install -g --prefix $stage --no-audit --no-fund --prefer-offline `
        --fetch-timeout=120000 --fetch-retries=3 "$PACKAGE_NAME@$Want" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Tree $stage
        return $null
    }
    $pkgDir = Join-Path (Join-Path $stage "node_modules") "@deepseek-ai\dsh"
    $got = Get-InstalledVersion $pkgDir
    if ($got -ne $Want) {
        Write-Fail "  暂存件版本异常：装到 $got，目标是 $Want"
        Remove-Tree $stage
        return $null
    }
    return $pkgDir
}

# 提交：把已验证的确切版本装进全局树。装之前记下当前版本，服务起不来时才能退回去。
function Install-Commit {
    param([string]$Want, [string]$Prev)
    if ($Prev -match '[0-9]') {
        Write-State $PREV_VERSION_FILE $Prev
    } else {
        Write-Warn "  ⚠ 读不到当前版本，本次提交无法回滚"
    }
    Write-Info "  提交到全局 npm 树..."
    & npm install -g --no-audit --no-fund --prefer-offline `
        --fetch-timeout=120000 --fetch-retries=3 "$PACKAGE_NAME@$Want" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $got = Get-InstalledVersion
    if ($got -ne $Want) {
        Write-Fail "  提交后版本为 $got，预期 $Want"
        return $false
    }
    Write-Success "  全局树：$PACKAGE_NAME@$Want"
    return $true
}

function Install-Rollback {
    $prev = Read-State $PREV_VERSION_FILE
    if ($prev -notmatch '[0-9]') {
        Write-Fail "  没有记录上一个版本，无法回滚"
        return $false
    }
    Write-Warn "  回滚全局树到 $prev…"
    & npm install -g --no-audit --no-fund --prefer-offline `
        --fetch-timeout=120000 --fetch-retries=3 "$PACKAGE_NAME@$prev" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ((Get-InstalledVersion) -eq $prev)
}

# ── 预检支持 ────────────────────────────────────────────────────────────
# 让系统分一个空闲端口：绑 0 号端口再释放，由内核保证它是空的。
# 不能靠「连不上就当作空闲」：丢包而不是拒绝时，探测会一直挂着。
function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } catch {
        return 0
    } finally {
        try { $listener.Stop() } catch { }
    }
}

# 删除目录树，但先把 junction/符号链接当链接删掉。
# 直接 Remove-Item -Recurse 会顺着 junction 走进真实目标——那可能删掉用户真实的
# profile node_modules。这个函数存在的唯一理由就是别在那里犯错。
function Remove-Tree {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return }
    try {
        Get-ChildItem -Path $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { }
            }
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
    }
}

# 试启用 DSH_HOME：只带启动判定需要的部分（插件树与 profile 才是判据）。
# profile 的 node_modules 用 junction 指回真实目录：既不复制 600 个包，
# 也保证预检看到的就是线上那份插件树。
function New-PreflightHome {
    param([int]$WantPort, [string]$RealHome)
    $preflightHome = Join-Path ([System.IO.Path]::GetTempPath()) ("dshctl-preflight-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $preflightHome -Force | Out-Null

    foreach ($item in @("settings.yaml", "AGENTS.md")) {
        $src = Join-Path $RealHome $item
        if (Test-Path $src) { Copy-Item $src (Join-Path $preflightHome $item) -Force -ErrorAction SilentlyContinue }
    }

    $profilesSrc = Join-Path $RealHome "profiles"
    if (-not (Test-Path $profilesSrc)) { return $preflightHome }

    $profilesDst = Join-Path $preflightHome "profiles"
    New-Item -ItemType Directory -Path $profilesDst -Force | Out-Null

    foreach ($profileDir in (Get-ChildItem -Path $profilesSrc -Directory -ErrorAction SilentlyContinue)) {
        $dst = Join-Path $profilesDst $profileDir.Name
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        # 只复制配置；node_modules 走 junction。
        Get-ChildItem -Path $profileDir.FullName -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $dst $_.Name) -Force -ErrorAction SilentlyContinue }
        $modules = Join-Path $profileDir.FullName "node_modules"
        if (Test-Path $modules) {
            try {
                New-Item -ItemType Junction -Path (Join-Path $dst "node_modules") -Target $modules -ErrorAction Stop | Out-Null
            } catch {
                # 建不了 junction 就不带插件树：预检会在启动阶段暴露问题，好过静默放过。
                Write-Warn "  ⚠ 无法为 $($profileDir.Name) 建立 node_modules 链接，预检可能不完整"
            }
        }
        # profile 可能把监听端口写死，而配置里的端口优先于命令行 --port。
        # 不把这处也改到空闲端口，试启就会和线上服务抢同一个端口。
        foreach ($cfg in (Get-ChildItem -Path $dst -Filter "cordis*.yml" -File -ErrorAction SilentlyContinue)) {
            $lines = [System.IO.File]::ReadAllLines($cfg.FullName)
            $changed = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^([ \t]*port:[ \t]*)$PORT([ \t]*)$") {
                    $lines[$i] = $Matches[1] + $WantPort + $Matches[2]
                    $changed = $true
                }
            }
            if ($changed) {
                [System.IO.File]::WriteAllLines($cfg.FullName, $lines)
                Write-Info "  试启用临时 home：$($cfg.Name) 里写死的端口 $PORT 已改到 $WantPort（仅副本）"
            }
        }
    }
    return $preflightHome
}

# profile 里精确钉死的 @deepseek-ai/* 必须与目标核心同版本：这类错配只在浏览器里
# 现形（插件客户端 entry 激活失败），服务端 HTTP 应答完全正常，所以要在起服务之前拦下。
# 判据两条：声明的精确版本等于目标；实装版本等于声明（改了声明没 install 也算错配）。
# 只看服务真正加载的那个 profile；也不能拿 profile 里所有 @deepseek-ai/* 跟核心比——
# cosmokit、schemastery 也在同一个 scope 下但版本独立，全比会稳定误报。
function Test-ProfilePin {
    param([string]$Target)
    if ($Target -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') { return $true }
    if ($env:DSHCTL_SKIP_PROFILE_PIN_CHECK -eq "1") {
        Write-Info "  profile 版本守卫已跳过（DSHCTL_SKIP_PROFILE_PIN_CHECK=1）"
        return $true
    }
    $profileDir = Join-Path (Join-Path $env:USERPROFILE ".dsh\profiles") $DshProfile
    $pkgJson = Join-Path $profileDir "package.json"
    if (-not (Test-Path $pkgJson)) { return $true }

    $bad = $false
    try {
        $deps = (Get-Content $pkgJson -Raw | ConvertFrom-Json).dependencies
    } catch {
        return $true
    }
    if (-not $deps) { return $true }

    foreach ($prop in $deps.PSObject.Properties) {
        $name = $prop.Name
        $declared = [string]$prop.Value
        if (-not $name.StartsWith("@deepseek-ai/")) { continue }
        if ($declared -match '^[\^~]') { continue }
        if ($declared -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') { continue }

        if ($declared -ne $Target) {
            Write-Fail "  profile 版本错配：$DshProfile 声明 $name=$declared，目标核心 $Target"
            $bad = $true
        }
        $installedPkg = Join-Path (Join-Path (Join-Path $profileDir "node_modules") $name) "package.json"
        if (Test-Path $installedPkg) {
            try {
                $installed = [string](Get-Content $installedPkg -Raw | ConvertFrom-Json).version
                if ($installed -and $installed -ne $declared) {
                    Write-Fail "  profile 安装未对齐：$DshProfile 的 $name 声明 $declared、实装 $installed（先在该 profile 目录 pnpm install）"
                    $bad = $true
                }
            } catch {
            }
        }
    }
    if ($bad) {
        Write-Fail "  预检失败：profile $DshProfile 里精确钉死的 @deepseek-ai/* 与目标核心 $Target 不一致。"
        Write-Fail "  在 $profileDir 里把它们对齐到 $Target 并 pnpm install，再重试。"
        Write-Host "  （不推荐跳过：`$env:DSHCTL_SKIP_PROFILE_PIN_CHECK=1）"
        return $false
    }
    return $true
}

function Write-PreflightFail {
    param([string]$Reason, [string]$LogPath, [int]$ProcId)
    Write-Fail "  预检失败：$Reason"
    if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern "EADDRINUSE" -Quiet -ErrorAction SilentlyContinue)) {
        Write-Warn "    注意：这是端口被占用，属于试启环境冲突，不代表装的东西坏了。"
        Write-Warn "    排查：Get-ChildItem -Recurse $env:USERPROFILE\.dsh\profiles -Filter cordis*.yml | Select-String 'port:'"
    }
    if (Test-Path $LogPath) {
        $lines = Get-Content $LogPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "(?i)error|invalid|unknown|failed" } |
            Select-Object -Last 3
        if (-not $lines) { $lines = Get-Content $LogPath -Tail 3 -ErrorAction SilentlyContinue }
        $lines | ForEach-Object { Write-Host "    $_" }
    }
    if ($ProcId -gt 0) { & taskkill /PID $ProcId /T /F 2>$null | Out-Null }
}

# 用一个安装（暂存件或全局树）试启 web。返回 $true = 给出应用级应答。
function Invoke-Preflight {
    param([string]$PackageDir)
    if ($env:DSHCTL_PREFLIGHT -eq "0") {
        Write-Info "  预检已跳过（DSHCTL_PREFLIGHT=0）"
        return $true
    }
    $entry = Get-DshEntry $PackageDir
    if (-not $entry -or -not (Test-Path $entry)) {
        Write-Fail "  预检：找不到入口（$PackageDir）"
        return $false
    }
    $version = Get-InstalledVersion $PackageDir
    if (-not (Test-Pin $version)) { return $false }

    $probePort = Get-FreePort
    if ($probePort -le 0) { Write-Fail "  预检：找不到空闲端口"; return $false }

    $realHome = Join-Path $env:USERPROFILE ".dsh"
    $preflightHome = New-PreflightHome -WantPort $probePort -RealHome $realHome
    $log = Join-Path $preflightHome "preflight.log"
    $errLog = Join-Path $preflightHome "preflight.err.log"

    $savedHome = $env:DSH_HOME
    $env:DSH_HOME = $preflightHome
    $proc = $null
    try {
        $proc = Start-Process -FilePath "node" `
            -ArgumentList @("`"$entry`"", "web", "--host", $DshHost, "--port", "$probePort", "--no-open") `
            -RedirectStandardOutput $log -RedirectStandardError $errLog `
            -WindowStyle Hidden -PassThru
    } catch {
        $env:DSH_HOME = $savedHome
        Remove-Tree $preflightHome
        Write-Fail "  预检：无法启动进程（$($_.Exception.Message)）"
        return $false
    } finally {
        $env:DSH_HOME = $savedHome
    }

    for ($i = 1; $i -le $PREFLIGHT_TRIES; $i++) {
        if ($proc.HasExited) {
            Write-PreflightFail "启动即退出" $log $proc.Id
            Remove-Tree $preflightHome
            return $false
        }
        $code = $null
        try {
            $resp = Invoke-WebRequest -Uri "http://${DshHost}:${probePort}/" -Method Head -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            $code = $resp.StatusCode
        } catch {
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
        }
        if ($code -in @(200, 401, 303, 302)) {
            # 应答之后再确认进程还活着：起一秒就崩的制品会在这里现形。
            Start-Sleep -Seconds 1
            if ($proc.HasExited) {
                Write-PreflightFail "应答之后又退出了" $log $proc.Id
                Remove-Tree $preflightHome
                return $false
            }
            # 能应答不等于启动干净：可选 entry 激活失败只是 warning，服务照样应答 401。
            $combined = @()
            if (Test-Path $log) { $combined += Get-Content $log -ErrorAction SilentlyContinue }
            if (Test-Path $errLog) { $combined += Get-Content $errLog -ErrorAction SilentlyContinue }
            if (($combined -join "`n") -match "did not activate|startup failed") {
                Write-PreflightFail "能应答，但启动日志里有 entry 未激活" $log $proc.Id
                if (Test-Path $errLog) {
                    Get-Content $errLog -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
                }
                Remove-Tree $preflightHome
                return $false
            }
            Write-Success "  预检通过：能用 profile $DshProfile 启动"
            & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
            Remove-Tree $preflightHome
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-PreflightFail "在 ${PREFLIGHT_TRIES}s 内没有给出应用级应答" $log $proc.Id
    Remove-Tree $preflightHome
    return $false
}

# 名字很短的转发，避免上面的调用链里出现函数名笔误。
function Test-Pin { param([string]$Version) return (Test-ProfilePin $Version) }

# ── 安装 / 升级主流程 ───────────────────────────────────────────────────
function Invoke-Upgrade {
    param([string]$ExplicitTarget)

    $tag = Resolve-Tag $ExplicitTarget
    if (-not (Test-ValidChannel $tag)) {
        Write-Fail "无效的通道或版本：$tag"
        Write-Host "可用：latest / next / alpha，或显式版本号（如 0.2.1-rc.5）"
        return $false
    }

    Write-Host "── [1/4] 目标 ──"
    Write-Host "  包：$PACKAGE_NAME@$tag（npm 全局树）"
    Write-Host "  当前版本：$(Get-InstalledVersion)"

    if ($DryRun) {
        Write-Host "  [dry-run] 将：暂存到隔离目录 → 用 profile $DshProfile 预检 → 提交全局树 → 重启"
        Write-Host "── [dry-run] 跳过安装与重启（去掉 -DryRun 才会真正执行）──"
        return $true
    }

    Write-Host "── [2/4] 暂存（不动正在运行的安装）──"
    if (-not (Invoke-NetworkPrecheck)) { return $false }
    $want = Get-NpmViewVersion $tag
    if (-not $want) { return $false }
    Write-Host "  目标版本：$want"

    $stagedDir = Install-Stage $want
    if (-not $stagedDir) {
        Write-Fail "暂存失败：运行中的 $(Get-InstalledVersion) 没有被改动。"
        return $false
    }

    Write-Host "── [3/4] 预检 ──"
    if (-not (Invoke-Preflight $stagedDir)) {
        Remove-Tree $script:StageRoot
        Write-Fail "预检未通过：正式安装与运行中的服务都没有改动。"
        return $false
    }

    Write-Host "── [4/4] 提交并重启 ──"
    $prev = Get-InstalledVersion
    if (-not (Install-Commit $want $prev)) {
        Remove-Tree $script:StageRoot
        Write-Fail "提交失败：全局树可能不完整，用 .\dshctl.ps1 status / log 确认。"
        return $false
    }
    Remove-Tree $script:StageRoot
    Write-State $CHANNEL_FILE $tag

    if ($NoRestart) {
        Write-Host "── 已按 -NoRestart 跳过重启；下次启动生效 ──"
        Write-StaleWarning
        return $true
    }
    return (Restart-Checked)
}

# 首次安装：把 dshctl 放进 PATH、初始化目录，然后直接完成安装。
function Invoke-Install {
    $selfPath = $PSCommandPath
    $binDir = Join-Path $env:USERPROFILE ".local\bin"

    Write-Host "── [1/3] dshctl ──"
    $found = Get-Command dshctl.ps1 -ErrorAction SilentlyContinue
    $onPath = if ($found) { $found.Source } else { $null }
    if ($onPath -and $selfPath -and ($onPath -eq $selfPath)) {
        Write-Success "  ✓ 已在 PATH：$selfPath"
    } else {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Copy-Item -Path $selfPath -Destination (Join-Path $binDir "dshctl.ps1") -Force
        Write-Success "  ✓ 已安装：$(Join-Path $binDir 'dshctl.ps1')"
        if ($env:PATH -notlike "*$binDir*") {
            Write-Warn "  ⚠ $binDir 不在 PATH；请在系统设置里加入"
        }
    }

    Write-Host "── [2/3] 目录 ──"
    New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    Write-Success "  ✓ $STATE_DIR"

    Write-Host "── [3/3] 安装官方包 ──"
    return (Invoke-Upgrade "")
}

# ── 状态 ────────────────────────────────────────────────────────────────
function Show-Status {
    $proc = Get-DshProcess
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  DSH Web 服务状态" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    if ($proc) {
        $mem = [math]::Round($proc.WorkingSet64 / 1MB, 1)
        Write-ColorText "  状态：运行中" "Green"
        Write-Host "  进程ID：$($proc.Id)  内存：$mem MB"
        Write-Host "  启动于：$($proc.StartTime)"
    } else {
        Write-ColorText "  状态：已停止" "Red"
    }
    Write-Host "  访问地址：$URL"
    Write-Host "  入口：$(Get-DshEntry)"
    Write-Host "  已装版本：$(Get-InstalledVersion)"
    Write-Host "  更新通道：$(Get-CurrentChannel)"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-StaleWarning
    Write-Host ""
}

function Show-Log {
    Write-Host ""
    Write-Host "━━━ 标准输出 ━━━" -ForegroundColor Cyan
    if (Test-Path $LOG_FILE) { Get-Content $LOG_FILE -Tail 50 } else { Write-Warn "日志文件不存在：$LOG_FILE" }
    Write-Host ""
    Write-Host "━━━ 错误输出 ━━━" -ForegroundColor Cyan
    if (Test-Path $ERR_FILE) { Get-Content $ERR_FILE -Tail 50 } else { Write-Warn "日志文件不存在：$ERR_FILE" }
    Write-Host ""
}

# 只预检：不安装、不重启。
function Invoke-Check {
    $pkgDir = Get-GlobalPackageDir
    if (-not (Get-PkgEntry $pkgDir)) {
        Write-Fail "还没装（先跑 .\dshctl.ps1 upgrade）"
        return $false
    }
    Write-Host "预检：已装版本 $(Get-InstalledVersion) 能否用 profile $DshProfile 启动（不重启）"
    return (Invoke-Preflight $pkgDir)
}

function Get-PkgEntry { param([string]$Dir) return (Get-DshEntry $Dir) }

# Windows 没有 systemd 单元可重建：把陈旧的进程记录清掉再重启，就是这里的「修复」。
function Invoke-Repair {
    if ($DryRun) {
        Write-Host "[dry-run] 将清理陈旧 PID 记录并重启服务"
        return $true
    }
    if (Test-Path $PID_FILE) {
        $proc = Get-DshProcess
        if (-not $proc) {
            Write-Info "清理陈旧 PID 记录：$PID_FILE"
            Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
        }
    }
    if ($NoRestart) {
        Write-Host "已按 -NoRestart 跳过重启"
        return $true
    }
    return (Restart-DshService)
}

# ── dshctl 自身：自更新 ─────────────────────────────────────────────────
# 从仓库拉最新脚本，校验后替换。校验三道：语法必须解析通过、版本号必须是远端
# VERSION 宣称的那个、下载失败不动原文件。
function Invoke-SelfUpdate {
    $selfPath = $PSCommandPath
    if (-not $selfPath) { Write-Fail "取不到自身路径，无法自更新"; return $false }

    $remote = ""
    try {
        $remote = (Invoke-RestMethod -Uri "$DSHCTL_RAW_BASE/VERSION" -TimeoutSec 20).ToString().Trim()
    } catch {
        Write-Fail "取不到远端版本号（网络问题？），未做任何改动"
        return $false
    }
    if ($remote -notmatch '^\d+\.\d+\.\d+$') {
        Write-Fail "远端版本号异常：$remote，未做任何改动"
        return $false
    }
    if ($remote -eq $DSHCTL_VERSION) {
        Write-Success "✓ dshctl 已是最新（$DSHCTL_VERSION）"
        return $true
    }
    # 远端不高于本地时不要覆盖：本地可能装着还没推上去的修复。
    if (([version]$remote).CompareTo([version]$DSHCTL_VERSION) -le 0) {
        Write-Fail "远端是 $remote，不比本地 $DSHCTL_VERSION 新；自动覆盖会丢掉本地改动，已跳过。"
        Write-Fail "确实要以远端为准：`$env:DSHCTL_FORCE_SELF_UPDATE=1; .\dshctl.ps1 self-update"
        if ($env:DSHCTL_FORCE_SELF_UPDATE -ne "1") { return $false }
        Write-Warn "  已按 DSHCTL_FORCE_SELF_UPDATE=1 继续覆盖"
    }

    Write-Info "  发现新版本：$DSHCTL_VERSION → $remote"
    if ($DryRun) {
        Write-Host "── [dry-run] 只报版本不更新（去掉 -DryRun 才会真正执行）──"
        return $true
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri "$DSHCTL_RAW_BASE/dshctl.ps1" -OutFile $tmp -TimeoutSec 60 -UseBasicParsing
        $tokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count -gt 0) { throw "下载的脚本语法校验未通过" }
        $content = [System.IO.File]::ReadAllText($tmp)
        if ($content -notmatch ('\$DSHCTL_VERSION\s*=\s*"' + [regex]::Escape($remote) + '"')) {
            throw "下载内容版本号与远端 VERSION 不一致"
        }
        Copy-Item -Path $tmp -Destination $selfPath -Force
        Write-Success "✓ dshctl 已更新到 $remote（当前进程仍是旧版，重新运行即生效）"
        return $true
    } catch {
        Write-Fail "更新失败：$($_.Exception.Message)（未做任何改动）"
        return $false
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ── 迁移：清掉双槽位时代的遗留 ──────────────────────────────────────────
function Clear-LegacyState {
    $removed = @()
    foreach ($file in $LEGACY_STATE_FILES) {
        if (Test-Path $file) {
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            $removed += (Split-Path $file -Leaf)
        }
    }
    if ($removed.Count -gt 0) {
        Write-Warn "已删除废弃的槽位状态文件：$($removed -join ', ')"
    }
}

# ── 帮助 ────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Host @"

dshctl.ps1 - dsh web 服务的安装、升级与托管（只针对官方 npm 包）

用法：
  .\dshctl.ps1 <命令> [参数] [选项]

常用命令：
  upgrade [通道|版本]  安装/升级官方包（默认沿用记住的通道）
  install              首次安装：dshctl 进 PATH + 初始化目录 + 装包
  status               服务状态、已装版本、是否在跑旧代码
  start|stop|restart   服务控制
  log                  最近日志
  check                预检当前安装能否用 profile 启动（不重启）
  repair               清理陈旧进程记录并重启
  self-update          更新 dshctl 自身
  help                 显示帮助信息

升级为什么不会把服务升挂：
  1) 先把目标版本装进隔离的暂存目录，全局 npm 树与运行中的服务一行都不动；
  2) 用 profile web 在临时 DSH_HOME + 空闲端口试启暂存件，起不来就到此为止；
  3) 通过后才提交到全局树并重启，重启失败自动装回上一个版本。
  注意：预检用的临时 home 会把 profile 里写死的监听端口改到空闲端口（仅副本），
  否则试启会和线上服务抢同一个端口。

选项：
  -DryRun      只说不做
  -NoRestart   装完不重启
  -Help        显示帮助

示例：
  .\dshctl.ps1 upgrade next
  .\dshctl.ps1 status
  .\dshctl.ps1 upgrade latest -DryRun

"@
}

# ── 入口 ────────────────────────────────────────────────────────────────
function Main {
    if ($Help -or $Command -eq "help" -or $Command -eq "-h" -or $Command -eq "--help") {
        Show-Help
        return
    }

    Clear-LegacyState

    switch ($Command.ToLower()) {
        "" { Show-Status }
        { $_ -in @("upgrade", "up") } { if (-not (Invoke-Upgrade $Target)) { exit 1 } }
        "install" { if (-not (Invoke-Install)) { exit 1 } }
        { $_ -in @("status", "s") } { Show-Status }
        "start" { if (-not (Start-DshService)) { exit 1 } }
        "stop" { if (-not (Stop-DshService)) { exit 1 } }
        { $_ -in @("restart", "r") } { if (-not (Restart-DshService)) { exit 1 } }
        { $_ -in @("log", "l") } { Show-Log }
        { $_ -in @("check", "verify") } { if (-not (Invoke-Check)) { exit 1 } }
        { $_ -eq "repair" } { if (-not (Invoke-Repair)) { exit 1 } }
        { $_ -in @("self-update", "selfupdate") } { if (-not (Invoke-SelfUpdate)) { exit 1 } }
        # 这几个是已删除的功能：明确说清楚去哪，别让肌肉记忆撞空。
        { $_ -in @("source", "src") } {
            Write-Fail "「运行来源」已删除：只有官方包一种安装，装的就是跑的。"
            Write-Host "看版本和服务状态：.\dshctl.ps1 status"
            exit 2
        }
        { $_ -in @("use", "switch") } {
            Write-Fail "槽位切换已删除：没有第二个安装位置，也就没有来源可切。"
            Write-Host "安装/升级：.\dshctl.ps1 upgrade [通道|版本]"
            exit 2
        }
        "docker" {
            Write-Fail "docker 部署模式已删除：只保留官方包 + 独立进程一条路。"
            exit 2
        }
        { $_ -in @("update", "u") } {
            Write-Fail "「update」有歧义，已停用：升级 dsh 用 upgrade，更新 dshctl 自身用 self-update。"
            exit 2
        }
        default {
            Write-Fail "未知命令：$Command"
            Write-Host ""
            Show-Help
            exit 1
        }
    }
}

# 直接运行时跑 Main；被 dot-source（自测脚本）时只加载函数，不产生副作用。
if ($MyInvocation.InvocationName -ne '.') { Main }
