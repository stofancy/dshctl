#!/usr/bin/env pwsh
# dshctl.ps1 - PowerShell 版本的 dsh web 服务管理工具
# 用于 Windows 平台管理 DeepSeek Harness web 服务

<#
.SYNOPSIS
    DeepSeek Harness web 服务一站式管理工具 (Windows 版本)

.DESCRIPTION
    管理 DSH web 服务的生命周期，包括安装、更新、启动、停止等操作。
    支持双槽位架构：官方包和本地包可随时切换。

.PARAMETER Command
    要执行的命令：update, status, start, stop, restart, log, source, use, check, help

.EXAMPLE
    .\dshctl.ps1 update
    更新当前运行来源

.EXAMPLE
    .\dshctl.ps1 update -Local C:\path\to\dsh-repo
    从本地源码构建并安装

.EXAMPLE
    .\dshctl.ps1 use official
    切换到官方包
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    
    [Parameter(Position = 1)]
    [string]$Target,
    
    [switch]$Local,
    [switch]$Registry,
    [switch]$DryRun,
    [switch]$NoRestart,
    [switch]$Help
)

# ── 常量配置 ────────────────────────────────────────────────────────────
$script:PACKAGE_NAME = "@deepseek-ai/dsh"
$script:SERVICE_NAME = "dsh-web"
$script:DEFAULT_PORT = 3080
$script:DEFAULT_HOST = "127.0.0.1"
$script:URL = "http://${DEFAULT_HOST}:${DEFAULT_PORT}"

# 状态目录
$script:STATE_DIR = Join-Path $env:USERPROFILE ".config\dsh"
$script:CHANNEL_FILE = Join-Path $STATE_DIR "channel"
$script:LOCAL_PATH_FILE = Join-Path $STATE_DIR "local-path"
$script:LOCAL_DETAIL_FILE = Join-Path $STATE_DIR "local-detail"
$script:CURRENT_SOURCE_FILE = Join-Path $STATE_DIR "current-source"

# 本地打包输出目录
$script:LOCAL_PACK_DIR = if ($env:DSHCTL_PACK_DIR) { 
    $env:DSHCTL_PACK_DIR 
} else { 
    Join-Path $env:USERPROFILE ".cache\dshctl\pack" 
}

# DSH 源码仓库
$script:DSH_REPO_URL = "https://github.com/deepseek-ai/dsh.git"
$script:DSH_DEFAULT_CLONE_DIR = Join-Path $env:USERPROFILE ".cache\dshctl\dsh-repo"

# 本地槽位
$script:LOCAL_SLOT = if ($env:DSHCTL_SLOT_DIR) { 
    $env:DSHCTL_SLOT_DIR 
} else { 
    Join-Path $env:USERPROFILE ".local\share\dshctl\slot-local" 
}

# 进程标识文件
$script:PID_FILE = Join-Path $STATE_DIR "dsh-web.pid"

# ── 工具函数 ────────────────────────────────────────────────────────────

function Write-ColorText {
    param(
        [string]$Text,
        [string]$Color = "White"
    )
    Write-Host $Text -ForegroundColor $Color
}

function Write-Success {
    param([string]$Text)
    Write-ColorText "✓ $Text" "Green"
}

function Write-Error {
    param([string]$Text)
    Write-ColorText "✘ $Text" "Red"
}

function Write-Warning {
    param([string]$Text)
    Write-ColorText "⚠ $Text" "Yellow"
}

function Write-Info {
    param([string]$Text)
    Write-ColorText "ℹ $Text" "Cyan"
}

# 读取状态文件
function Read-State {
    param([string]$File)
    if (Test-Path $File) {
        return (Get-Content $File -Raw).Trim()
    }
    return ""
}

# 写入状态文件
function Write-State {
    param(
        [string]$File,
        [string]$Value
    )
    $dir = Split-Path $File -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Value | Out-File -FilePath $File -Encoding utf8 -NoNewline
}

# 检查命令是否存在
function Test-Command {
    param([string]$Command)
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# 验证更新通道
function Test-ValidChannel {
    param([string]$Channel)
    return $Channel -match '^(latest|next|alpha|[0-9]+\.[0-9]+\.[0-9]+.*)$'
}

# 获取当前通道
function Get-CurrentChannel {
    $channel = Read-State $script:CHANNEL_FILE
    if ($channel -and (Test-ValidChannel $channel)) {
        return $channel
    }
    if ($channel) {
        Write-Warning "记忆的更新通道无效（$channel），本次回退 latest"
    }
    return "latest"
}

# 获取当前运行来源
function Get-CurrentSource {
    $source = Read-State $script:CURRENT_SOURCE_FILE
    if ($source -in @("registry", "local")) {
        return $source
    }
    return "registry"
}

# 设置当前运行来源
function Set-CurrentSource {
    param([string]$Source)
    Write-State $script:CURRENT_SOURCE_FILE $Source
}

# 获取已安装版本
function Get-InstalledVersion {
    param([string]$Source = (Get-CurrentSource))
    
    $bin = Get-ServiceBin $Source
    if ($bin -and (Test-Path $bin)) {
        try {
            $version = & node $bin --version 2>$null
            return $version
        } catch {
            return "未知"
        }
    }
    return "未安装"
}

# 获取服务可执行文件路径
function Get-ServiceBin {
    param([string]$Source = (Get-CurrentSource))
    
    if ($Source -eq "local") {
        return Join-Path $script:LOCAL_SLOT "bin\dsh"
    } else {
        # 官方槽位：全局 npm
        try {
            $globalRoot = npm root -g 2>$null
            return Join-Path $globalRoot "@deepseek-ai\dsh\dist\index.js"
        } catch {
            return $null
        }
    }
}

# ── 本地包支持 ──────────────────────────────────────────────────────────

# 识别本地路径类型
function Get-LocalKind {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return $null
    }
    
    if (Test-Path $Path -PathType Leaf) {
        if ($Path -match '\.tgz$') {
            return "tarball"
        }
        return $null
    }
    
    # 目录
    $tarballs = Get-ChildItem -Path $Path -Filter "*.tgz" -File -ErrorAction SilentlyContinue
    if ($tarballs) {
        return "artifacts"
    }
    
    $workspace = Join-Path $Path "pnpm-workspace.yaml"
    $package = Join-Path $Path "package.json"
    if ((Test-Path $workspace) -and (Test-Path $package)) {
        $content = Get-Content $package -Raw
        if ($content -match '"release:pack"') {
            return "checkout"
        }
    }
    
    return $null
}

# 提示克隆 DSH 仓库
function Invoke-PromptCloneDsh {
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Warning "本地槽位需要 DeepSeek Harness 源码仓库"
    Write-Host ""
    Write-Host "本地槽位用于从源码构建 DSH，需要完整的源码仓库。"
    Write-Host "如果您只是想使用稳定版本，建议使用官方包："
    Write-Host "  .\dshctl.ps1 update latest" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "是否自动克隆 DSH 源码仓库到："
    Write-Host "  $($script:DSH_DEFAULT_CLONE_DIR)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "仓库地址：$($script:DSH_REPO_URL)"
    Write-Host "克隆大小：约 100MB，首次构建需要数分钟"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host ""
    
    $answer = Read-Host "是否继续克隆？[y/N]"
    return $answer -match '^[yY]'
}

# 克隆 DSH 仓库
function Invoke-CloneDshRepo {
    $target = $script:DSH_DEFAULT_CLONE_DIR
    
    if (Test-Path $target) {
        Write-Info "目标目录已存在：$target"
        if (Test-Path (Join-Path $target ".git")) {
            Write-Info "检测到已有 git 仓库，尝试更新..."
            try {
                Push-Location $target
                git pull --ff-only 2>$null
                Pop-Location
                Write-Success "已更新到最新版本"
                return $target
            } catch {
                Write-Warning "更新失败，将使用现有版本"
                Pop-Location
                return $target
            }
        }
    }
    
    Write-Info "开始克隆 DSH 源码仓库..."
    Write-Info "仓库：$($script:DSH_REPO_URL)"
    Write-Info "目标：$target"
    
    if (-not (Test-Command "git")) {
        Write-Error "未找到 git 命令，无法克隆仓库"
        return $null
    }
    
    $parentDir = Split-Path $target -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    
    try {
        git clone --depth 1 $script:DSH_REPO_URL $target 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "克隆完成：$target"
            return $target
        } else {
            throw "git clone 失败"
        }
    } catch {
        Write-Error "克隆失败：$_"
        if (Test-Path $target) {
            Remove-Item $target -Recurse -Force
        }
        return $null
    }
}

# ── 服务管理 ────────────────────────────────────────────────────────────

# 获取服务进程
function Get-DshProcess {
    $pidFile = $script:PID_FILE
    if (Test-Path $pidFile) {
        $pid = [int](Get-Content $pidFile -Raw).Trim()
        try {
            $process = Get-Process -Id $pid -ErrorAction Stop
            # 验证是否是 dsh 进程
            if ($process.ProcessName -match 'node|dsh') {
                return $process
            }
        } catch {
            # 进程不存在，清理 PID 文件
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
    }
    
    # 尝试通过端口查找进程
    try {
        $connection = Get-NetTCPConnection -LocalPort $script:DEFAULT_PORT -ErrorAction Stop | Select-Object -First 1
        if ($connection) {
            return Get-Process -Id $connection.OwningProcess -ErrorAction Stop
        }
    } catch {
    }
    
    return $null
}

# 启动服务
function Start-DshService {
    $process = Get-DshProcess
    if ($process) {
        Write-Warning "服务已在运行（PID: $($process.Id)）"
        return $true
    }
    
    $bin = Get-ServiceBin
    if (-not $bin -or -not (Test-Path $bin)) {
        Write-Error "未找到可执行文件：$bin"
        return $false
    }
    
    Write-Info "启动服务..."
    
    try {
        $logDir = Join-Path $script:STATE_DIR "logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        
        $logFile = Join-Path $logDir "dsh-web.log"
        $errFile = Join-Path $logDir "dsh-web.err.log"
        
        # 启动进程
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "node"
        $psi.Arguments = "`"$bin`" web --host $($script:DEFAULT_HOST) --port $($script:DEFAULT_PORT)"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $env:USERPROFILE
        
        $process = [System.Diagnostics.Process]::Start($psi)
        
        # 保存 PID
        $process.Id | Out-File -FilePath $script:PID_FILE -Encoding utf8 -NoNewline
        
        # 重定向输出到日志文件（后台任务）
        Start-Job -ScriptBlock {
            param($proc, $logFile, $errFile)
            $proc.StandardOutput.BaseStream.CopyTo([System.IO.File]::OpenWrite($logFile))
            $proc.StandardError.BaseStream.CopyTo([System.IO.File]::OpenWrite($errFile))
        } -ArgumentList $process, $logFile, $errFile | Out-Null
        
        # 等待服务启动
        Start-Sleep -Seconds 2
        
        if (Test-ServiceHealth) {
            Write-Success "服务已启动：$($script:URL)"
            return $true
        } else {
            Write-Error "服务启动后无法访问"
            return $false
        }
    } catch {
        Write-Error "启动失败：$_"
        return $false
    }
}

# 停止服务
function Stop-DshService {
    $process = Get-DshProcess
    if (-not $process) {
        Write-Warning "服务未运行"
        return $true
    }
    
    Write-Info "停止服务（PID: $($process.Id)）..."
    
    try {
        $process.Kill()
        $process.WaitForExit(5000)
        
        if (Test-Path $script:PID_FILE) {
            Remove-Item $script:PID_FILE -Force
        }
        
        Write-Success "服务已停止"
        return $true
    } catch {
        Write-Error "停止失败：$_"
        return $false
    }
}

# 重启服务
function Restart-DshService {
    Write-Info "重启服务..."
    Stop-DshService | Out-Null
    Start-Sleep -Seconds 1
    return Start-DshService
}

# 测试服务健康
function Test-ServiceHealth {
    param([int]$MaxRetries = 15)
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $script:URL -Method Head -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -in @(200, 401, 303)) {
                return $true
            }
        } catch {
            # 某些状态码会抛异常，检查异常中的状态码
            if ($_.Exception.Response.StatusCode.value__ -in @(200, 401, 303)) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

# 获取服务状态
function Get-ServiceStatus {
    $process = Get-DshProcess
    $source = Get-CurrentSource
    $version = Get-InstalledVersion $source
    
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  DSH Web 服务状态" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    
    if ($process) {
        Write-ColorText "  状态：运行中" "Green"
        Write-Host "  进程ID：$($process.Id)"
        Write-Host "  内存：$([math]::Round($process.WorkingSet64 / 1MB, 2)) MB"
    } else {
        Write-ColorText "  状态：已停止" "Red"
    }
    
    Write-Host "  访问地址：$($script:URL)"
    Write-Host "  运行来源：$(if($source -eq 'local'){'本地包'}else{'官方包'})"
    Write-Host "  版本：$version"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
}

# ── 安装与更新 ──────────────────────────────────────────────────────────

# 安装官方包
function Install-RegistryPackage {
    param([string]$Channel = (Get-CurrentChannel))
    
    if (-not (Test-ValidChannel $Channel)) {
        Write-Error "无效的通道或版本：$Channel"
        Write-Host "可用：latest / next / alpha，或显式版本号（如 0.1.5-rc.2）"
        return $false
    }
    
    Write-Info "安装官方包 $($script:PACKAGE_NAME)@$Channel ..."
    
    try {
        npm install -g "$($script:PACKAGE_NAME)@$Channel" --fetch-timeout=120000 --fetch-retries=3
        if ($LASTEXITCODE -eq 0) {
            Write-Success "安装完成"
            Write-State $script:CHANNEL_FILE $Channel
            Set-CurrentSource "registry"
            return $true
        } else {
            Write-Error "npm install 失败"
            return $false
        }
    } catch {
        Write-Error "安装失败：$_"
        return $false
    }
}

# 安装本地包
function Install-LocalPackage {
    param([string]$Path)
    
    # 验证路径
    if (-not $Path) {
        # 尝试读取记忆的路径
        $Path = Read-State $script:LOCAL_PATH_FILE
    }
    
    if (-not $Path) {
        # 提示克隆
        if (Invoke-PromptCloneDsh) {
            $Path = Invoke-CloneDshRepo
            if (-not $Path) {
                Write-Host ""
                Write-Host "克隆失败。您也可以手动克隆后再试：" -ForegroundColor Yellow
                Write-Host "  git clone $($script:DSH_REPO_URL) C:\path\to\dsh" -ForegroundColor Cyan
                Write-Host "  .\dshctl.ps1 update -Local C:\path\to\dsh" -ForegroundColor Cyan
                return $false
            }
        } else {
            Write-Host ""
            Write-Host "已取消。建议使用官方包：.\dshctl.ps1 update latest" -ForegroundColor Yellow
            return $false
        }
    }
    
    if (-not (Test-Path $Path)) {
        Write-Error "路径不存在：$Path"
        return $false
    }
    
    $kind = Get-LocalKind $Path
    if (-not $kind) {
        Write-Error "无法识别的本地路径：$Path"
        Write-Host "需要源码仓库（含 pnpm-workspace.yaml 与 release:pack）、含 *.tgz 的目录，或 .tgz 文件。"
        return $false
    }
    
    Write-Info "安装本地包..."
    Write-Info "  路径：$Path"
    Write-Info "  类型：$kind"
    
    # 根据类型处理
    $tarballs = @()
    switch ($kind) {
        "checkout" {
            # 构建源码
            Write-Info "构建源码（可能需要数分钟）..."
            
            if (-not (Test-Command "pnpm")) {
                Write-Error "未找到 pnpm 命令"
                return $false
            }
            
            try {
                Push-Location $Path
                pnpm run build:official
                if ($LASTEXITCODE -ne 0) {
                    throw "构建失败"
                }
                
                $outVendor = Join-Path $script:LOCAL_PACK_DIR "vendor"
                $outDsh = Join-Path $script:LOCAL_PACK_DIR "dsh"
                
                pnpm run release:pack --family vendor --out $outVendor
                pnpm run release:pack --family dsh --out $outDsh
                
                Pop-Location
                
                # 收集 tarball
                $tarballs += Get-ChildItem -Path $outVendor -Filter "*.tgz" -File -Recurse
                $tarballs += Get-ChildItem -Path $outDsh -Filter "*.tgz" -File -Recurse
            } catch {
                Pop-Location
                Write-Error "构建失败：$_"
                return $false
            }
        }
        "artifacts" {
            $tarballs = Get-ChildItem -Path $Path -Filter "*.tgz" -File
        }
        "tarball" {
            $tarballs = @(Get-Item $Path)
        }
    }
    
    if ($tarballs.Count -eq 0) {
        Write-Error "未找到任何 tarball"
        return $false
    }
    
    Write-Info "安装 $($tarballs.Count) 个包到本地槽位..."
    
    try {
        $tarballPaths = $tarballs | ForEach-Object { $_.FullName }
        npm install -g --prefix $script:LOCAL_SLOT --no-audit --no-fund $tarballPaths
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "安装完成"
            Write-State $script:LOCAL_PATH_FILE $Path
            Set-CurrentSource "local"
            return $true
        } else {
            Write-Error "npm install 失败"
            return $false
        }
    } catch {
        Write-Error "安装失败：$_"
        return $false
    }
}

# 更新命令
function Invoke-Update {
    param(
        [string]$Target,
        [switch]$Local,
        [switch]$Registry
    )
    
    if ($script:DryRun) {
        Write-Warning "[DRY RUN] 预演模式，不会实际执行"
    }
    
    $success = $false
    
    if ($Local) {
        if (-not $script:DryRun) {
            $success = Install-LocalPackage $Target
        } else {
            Write-Info "将从本地路径安装：$(if($Target){$Target}else{'记忆的路径或自动克隆'})"
            return $true
        }
    } elseif ($Registry -or $Target -match '^(latest|next|alpha|[0-9])') {
        if (-not $script:DryRun) {
            $channel = if ($Target) { $Target } else { Get-CurrentChannel }
            $success = Install-RegistryPackage $channel
        } else {
            Write-Info "将安装官方包：$($script:PACKAGE_NAME)@$(if($Target){$Target}else{Get-CurrentChannel})"
            return $true
        }
    } else {
        # 默认：更新当前来源
        $currentSource = Get-CurrentSource
        if ($currentSource -eq "local") {
            $success = Install-LocalPackage
        } else {
            $success = Install-RegistryPackage
        }
    }
    
    if ($success -and -not $script:NoRestart) {
        Restart-DshService | Out-Null
    }
    
    return $success
}

# 切换来源
function Invoke-UseSource {
    param([string]$Source)
    
    if (-not $Source) {
        $current = Get-CurrentSource
        Write-Host "当前运行来源：$(if($current -eq 'local'){'本地包'}else{'官方包'})"
        Write-Host "可切换：official（官方包） / local（本地包）"
        return
    }
    
    $targetSource = switch ($Source.ToLower()) {
        { $_ -in @("official", "registry", "官方", "官方包") } { "registry" }
        { $_ -in @("local", "本地", "本地包") } { "local" }
        default { 
            Write-Error "未知来源：$Source（可用：official / local）"
            return
        }
    }
    
    $current = Get-CurrentSource
    if ($current -eq $targetSource) {
        Write-Warning "当前已经是 $(if($targetSource -eq 'local'){'本地包'}else{'官方包'})，无需切换"
        return
    }
    
    # 检查目标槽位是否可用
    $version = Get-InstalledVersion $targetSource
    if ($version -eq "未安装") {
        Write-Error "目标槽位未安装"
        if ($targetSource -eq "local") {
            Write-Host "先执行：.\dshctl.ps1 update -Local <路径>" -ForegroundColor Cyan
        } else {
            Write-Host "先执行：.\dshctl.ps1 update latest" -ForegroundColor Cyan
        }
        return
    }
    
    if ($script:DryRun) {
        Write-Warning "[DRY RUN] 将切换到 $(if($targetSource -eq 'local'){'本地包'}else{'官方包'})"
        return
    }
    
    Set-CurrentSource $targetSource
    Write-Success "已切换为 $(if($targetSource -eq 'local'){'本地包'}else{'官方包'})"
    
    if (-not $script:NoRestart) {
        Restart-DshService | Out-Null
    }
}

# 显示来源信息
function Show-Source {
    $source = Get-CurrentSource
    $regVersion = Get-InstalledVersion "registry"
    $localVersion = Get-InstalledVersion "local"
    
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  运行来源信息" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  当前来源：$(if($source -eq 'local'){'本地包'}else{'官方包'})" -ForegroundColor Green
    Write-Host "  服务入口：$(Get-ServiceBin $source)"
    
    if ($source -eq "registry") {
        Write-Host "  更新通道：$(Get-CurrentChannel)"
    } else {
        $localPath = Read-State $script:LOCAL_PATH_FILE
        if ($localPath) {
            Write-Host "  构建来源：$localPath"
        }
    }
    
    Write-Host ""
    Write-Host "  官方槽位版本：$regVersion"
    Write-Host "  本地槽位版本：$localVersion"
    Write-Host ""
    Write-Host "切换（不重装）：.\dshctl.ps1 use local / .\dshctl.ps1 use official" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
}

# 查看日志
function Show-Log {
    $logFile = Join-Path $script:STATE_DIR "logs\dsh-web.log"
    $errFile = Join-Path $script:STATE_DIR "logs\dsh-web.err.log"
    
    Write-Host ""
    Write-Host "━━━ 标准输出 ━━━" -ForegroundColor Cyan
    if (Test-Path $logFile) {
        Get-Content $logFile -Tail 50
    } else {
        Write-Warning "日志文件不存在：$logFile"
    }
    
    Write-Host ""
    Write-Host "━━━ 错误输出 ━━━" -ForegroundColor Cyan
    if (Test-Path $errFile) {
        Get-Content $errFile -Tail 50
    } else {
        Write-Warning "日志文件不存在：$errFile"
    }
    Write-Host ""
}

# 显示帮助
function Show-Help {
    Write-Host @"

dshctl.ps1 - DeepSeek Harness web 服务管理工具 (Windows 版本)

用法：
  .\dshctl.ps1 <命令> [参数] [选项]

常用命令：
  update [通道/版本]      更新官方包（默认沿用记忆的通道）
  update -Local [路径]    从本地源码/制品安装
  status                  查看服务状态
  start                   启动服务
  stop                    停止服务
  restart                 重启服务
  log                     查看最近日志
  source                  查看当前运行来源与槽位信息
  use <来源>              切换运行来源（official/local）
  help                    显示帮助信息

通道/版本示例：
  .\dshctl.ps1 update latest
  .\dshctl.ps1 update next
  .\dshctl.ps1 update 0.1.5-rc.2

本地安装示例：
  .\dshctl.ps1 update -Local C:\path\to\dsh-repo
  .\dshctl.ps1 update -Local C:\path\to\artifacts
  .\dshctl.ps1 update -Local C:\path\to\package.tgz

选项：
  -DryRun        预演模式（不实际执行）
  -NoRestart     安装后不重启服务
  -Help          显示帮助

示例：
  .\dshctl.ps1 status
  .\dshctl.ps1 update latest
  .\dshctl.ps1 update -Local -DryRun
  .\dshctl.ps1 use local
  .\dshctl.ps1 restart

"@
}

# ── 主入口 ──────────────────────────────────────────────────────────────

function Main {
    # 处理帮助
    if ($Help -or $Command -eq "help") {
        Show-Help
        return
    }
    
    # 根据命令分发
    switch ($Command.ToLower()) {
        "" {
            # 无参数：显示状态
            Get-ServiceStatus
        }
        { $_ -in @("update", "u") } {
            Invoke-Update -Target $Target -Local:$Local -Registry:$Registry
        }
        { $_ -in @("status", "s") } {
            Get-ServiceStatus
        }
        "start" {
            Start-DshService | Out-Null
        }
        "stop" {
            Stop-DshService | Out-Null
        }
        { $_ -in @("restart", "r") } {
            Restart-DshService | Out-Null
        }
        { $_ -in @("log", "l") } {
            Show-Log
        }
        { $_ -in @("use", "switch") } {
            Invoke-UseSource $Target
        }
        { $_ -in @("source", "src") } {
            Show-Source
        }
        default {
            Write-Error "未知命令：$Command"
            Write-Host ""
            Show-Help
            exit 1
        }
    }
}

# 执行主函数
Main
