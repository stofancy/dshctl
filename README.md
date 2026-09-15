# dshctl

DeepSeek Harness (DSH) web 服务一站式管理工具。

## 简介

`dshctl` 是一个跨平台的服务管理工具，用于管理 DeepSeek Harness web 服务的生命周期，包括安装、更新、启动、停止、日志查看等操作。

- **Linux/macOS**：`dshctl` Bash 脚本，封装 systemctl、journalctl 和 npm 命令
- **Windows**：`dshctl.ps1` PowerShell 脚本，提供相同功能的 Windows 实现

## 核心特性

### 三种部署形态

| 形态 | 适用场景 | 管理命令 |
|------|---------|---------|
| 官方槽位（npm 全局包） | 日常使用，跟随官方通道升级 | `dshctl upgrade [latest/next/alpha]` |
| 本地槽位（源码构建） | 开发调试 DSH 本身 | `dshctl upgrade --local <路径>` |
| Docker 容器 | 不想装 node/systemd，或隔离部署 | `dshctl docker up` |

前两种合称「双槽位架构」，可秒级互切；Docker 是独立的第三种部署形态（见下文 [Docker 部署](#docker-部署)）。

### 双槽位架构

dshctl 实现了官方包和本地包的双槽位模型，两者互不覆盖，可以随时切换：

- **官方槽位（registry）**：全局 npm 安装的 `@deepseek-ai/dsh` 包
- **本地槽位（local）**：独立 prefix 中的本地构建版本

切换只需修改配置文件（Linux 用 systemd drop-in，Windows 用状态文件），秒级完成，服务随时可回退。

### 本地槽位说明

**重要**：本地槽位需要 DeepSeek Harness 的完整源码仓库才能工作。

本地槽位用于从源码构建 DSH，适合以下场景：
- 开发和调试 DSH
- 测试未发布的功能
- 使用自定义修改版本

如果您只是想使用稳定版本，**建议使用官方包**：
```bash
# Linux/macOS
dshctl upgrade latest

# Windows
.\dshctl.ps1 update latest
```

首次使用本地槽位时，如果未指定路径，dshctl 会询问是否自动克隆 DSH 源码仓库：
- 同意：自动克隆到 `~/.cache/dshctl/dsh-repo`（Linux/macOS）或 `%USERPROFILE%\.cache\dshctl\dsh-repo`（Windows）
- 拒绝：退出安装，建议使用官方包

您也可以手动克隆并指定路径：
```bash
# 手动克隆
git clone https://github.com/deepseek-ai/dsh.git /path/to/dsh

# Linux/macOS
dshctl upgrade --local /path/to/dsh

# Windows
.\dshctl.ps1 update -Local C:\path\to\dsh
```

### 预检机制

在切换槽位前，dshctl 会在临时环境中试启目标版本：

- 使用当前 profile 配置
- 在空闲端口上启动
- 验证应用级应答
- 失败则拒绝切换，保护线上服务

### 安全保障

- 切换失败自动回退到上一个可用槽位
- 服务重启失败时自动恢复
- 原子化状态写入，避免中断导致状态损坏
- 不认识的参数拒绝执行，防止误操作

## 安装

### 前置要求

#### Linux/macOS
- Bash 4.0+
- systemd（用户态服务，Linux；仅 systemd 部署模式需要）
- Node.js 和 npm（仅 systemd 部署模式需要）
- curl（用于健康检查）
- git（用于克隆源码，本地槽位需要）
- pnpm（构建本地槽位需要）
- Docker（仅 docker 部署模式需要）

#### Windows
- PowerShell 5.1+ 或 PowerShell Core 7+
- Node.js 和 npm（仅本机部署模式需要）
- Docker Desktop（仅 docker 部署模式需要）
- git（用于克隆源码，本地槽位需要）
- pnpm（构建本地槽位需要）

### 安装步骤

#### Linux/macOS

下载后跑一次 `install`，它会装 dshctl 到 `~/.local/bin`、生成 systemd 服务骨架（unit 的 ExecStart 自动指向 npm 全局 bin）、生成帮助文件：

```bash
curl -fsSL -o /tmp/dshctl https://raw.githubusercontent.com/stofancy/dshctl/main/dshctl
chmod +x /tmp/dshctl
/tmp/dshctl install            # 本机进程部署（systemd）
/tmp/dshctl install --docker   # 或：docker 容器部署
```

`install` 只搭骨架，不替你选版本；装完后执行 `dshctl upgrade`（装官方包并启动）或 `dshctl docker up`。

`install` 做的事：

1. 复制自身到 `~/.local/bin/dshctl`（已在该位置则跳过），PATH 缺失时给出提示
2. 生成帮助文件 `~/.config/dsh-web-help.txt`（已存在则跳过）
3. 生成 systemd 用户 unit `~/.config/systemd/user/dsh-web.service`（已存在则跳过；`--docker` 时跳过），模板：

```ini
[Unit]
Description=DeepSeek Harness Web (dsh)
After=network-online.target

[Service]
Type=simple
ExecStart=<npm 全局前缀>/bin/dsh web --host 127.0.0.1 --port 3080
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
```

#### Windows

1. 下载脚本并初始化：

```powershell
$url = "https://raw.githubusercontent.com/stofancy/dshctl/main/dshctl.ps1"
$tmp = "$env:TEMP\dshctl.ps1"
Invoke-WebRequest -Uri $url -OutFile $tmp
& $tmp install            # 装到 ~\.local\bin\dshctl.ps1 并初始化状态目录
& $tmp install --docker   # 或：docker 容器部署
```

2. （可选）添加到 PATH 或创建别名：

```powershell
# 在 PowerShell profile 中添加别名
Set-Alias -Name dshctl -Value "$env:USERPROFILE\.local\bin\dshctl.ps1"

# 或者把目录加入 PATH（系统设置 → 环境变量）
```

3. 执行策略（首次运行可能需要）：

```powershell
# 允许执行本地脚本
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**注意**：Windows 版本不依赖 systemd，服务管理通过进程和 PID 文件实现。

## 使用方法

### 交互式菜单（仅 Linux/macOS）

直接运行 `dshctl`（无参数）进入交互菜单：

```bash
dshctl
```

Windows 版本无交互菜单，直接运行会显示服务状态：

```powershell
.\dshctl.ps1  # 显示状态
```

### 命令行模式

> **v0.4 起命令语义**：`update` 只负责更新 dshctl 自身，升级 dsh 用 `upgrade`（旧写法 `update latest` 仍可用，会提示迁移并转发）。首次使用先跑 `install`。

**Linux/macOS:**
```bash
# 首次安装：装 dshctl 到 ~/.local/bin + systemd 服务骨架 + 帮助文件
dshctl install
dshctl install --docker    # docker 部署形态，跳过 systemd

# 升级当前槽位的 dsh（沿用记忆的通道）
dshctl upgrade

# 从指定通道安装官方包
dshctl upgrade latest
dshctl upgrade next
dshctl upgrade alpha
dshctl upgrade 0.1.5-rc.2

# 从本地源码仓库构建并安装（未指定路径会提示克隆）
dshctl upgrade --local
dshctl upgrade --local /path/to/dsh-repo

# 从已打包的 tarball 目录安装
dshctl upgrade --local /path/to/artifacts

# 从单个 tarball 安装
dshctl upgrade --local /path/to/package.tgz

# 预演模式（只显示将要执行的操作，不实际安装）
dshctl upgrade --dry-run

# 安装但不重启服务
dshctl upgrade --no-restart

# 更新 dshctl 自身（对比 GitHub 上的 VERSION，校验后原子替换）
dshctl update
dshctl update --dry-run    # 只看有没有新版本
```

**Windows:**
```powershell
# 首次安装：装 dshctl.ps1 到 ~\.local\bin + 初始化状态目录
.\dshctl.ps1 install
.\dshctl.ps1 install --docker    # docker 部署形态

# 升级当前槽位的 dsh
.\dshctl.ps1 upgrade

# 从指定通道安装官方包
.\dshctl.ps1 upgrade latest
.\dshctl.ps1 upgrade next
.\dshctl.ps1 upgrade 0.1.5-rc.2

# 从本地源码构建并安装（未指定路径会提示克隆）
.\dshctl.ps1 upgrade -Local
.\dshctl.ps1 upgrade -Local C:\path\to\dsh-repo

# 预演模式
.\dshctl.ps1 upgrade -DryRun

# 安装但不重启服务
.\dshctl.ps1 upgrade -NoRestart

# 更新 dshctl 自身
.\dshctl.ps1 update
```

#### 槽位切换

**Linux/macOS:**
```bash
# 查看当前运行来源和两个槽位的版本
dshctl source

# 切换到官方包
dshctl use official

# 切换到本地包
dshctl use local

# 预检槽位是否可用（不切换，仅 Linux/macOS）
dshctl check
dshctl check official
dshctl check local
```

**Windows:**
```powershell
# 查看当前运行来源
.\dshctl.ps1 source

# 切换到官方包
.\dshctl.ps1 use official

# 切换到本地包
.\dshctl.ps1 use local
```

#### 服务管理

**Linux/macOS:**
```bash
# 查看服务状态
dshctl status

# 查看最近日志
dshctl log

# 重启服务
dshctl restart

# 启动/停止服务
dshctl start
dshctl stop

# 取消开机自启（仅 Linux）
dshctl disable
```

**Windows:**
```powershell
# 查看服务状态
.\dshctl.ps1 status

# 查看最近日志
.\dshctl.ps1 log

# 重启服务
.\dshctl.ps1 restart

# 启动/停止服务
.\dshctl.ps1 start
.\dshctl.ps1 stop
```

## Docker 部署

**官方没有提供 Docker 镜像**，dshctl 默认封装社区镜像 [`smanx/deepseek-harness`](https://hub.docker.com/r/smanx/deepseek-harness)（维护活跃、开箱即用），可通过环境变量切换到其他镜像。

### 可选镜像对比

| | smanx/deepseek-harness（默认） | runzhliu/deepseek-harness-docker |
|---|---|---|
| 定位 | 开箱即用，支持局域网访问 | 生产级安全加固 |
| 维护 | 活跃（Docker Hub 50K+ 拉取） | 活跃（GitHub，每日上游版本监控） |
| 局域网访问 | ✅ 内置反向代理（解决 DSH 禁止 `--host 0.0.0.0` 的限制） | ❌ 仅回环发布（安全边界不同） |
| 认证 | 可选 Basic Auth | launch token + 签名 cookie |
| 安全加固 | 一般（root 运行） | 强（非 root、cap_drop ALL、只读根文件系统） |
| 附加能力 | admin 变体带网页管理台（切版本/换源/重启） | 内置 Chromium + noVNC 桌面、Helm chart、Headless 模式 |
| 体积 | 精简版约 128MB | 更大（含浏览器） |

想换镜像：

```bash
# Linux/macOS
export DSHCTL_DOCKER_IMAGE=ghcr.io/runzhliu/deepseek-harness:latest
dshctl docker up

# Windows
$env:DSHCTL_DOCKER_IMAGE = "ghcr.io/runzhliu/deepseek-harness:latest"
.\dshctl.ps1 docker up
```

### 快速开始

```bash
# Linux/macOS（Windows 把 dshctl 换成 .\dshctl.ps1）
dshctl docker up       # 拉镜像并启动容器（首次会拉取约 128MB）
dshctl docker status   # 容器状态 + 应用应答
dshctl docker log      # 最近 100 行容器日志
dshctl docker update   # 拉最新镜像重建容器；起不来自动回退旧镜像
dshctl docker restart  # 重启容器
dshctl docker down     # 停止并移除容器（数据卷保留）
```

行为说明：

- **数据持久化**：会话与配置存在命名卷 `dshctl-dsh-data`（挂载容器 `/root/.dsh`），`down` 或容器删除后数据不丢；彻底清除需 `docker volume rm dshctl-dsh-data`。
- **开机自启**：容器带 `--restart unless-stopped`，Docker 启动时自动拉起。
- **端口**：默认宿主 `3080` → 容器 `3080`（`DSHCTL_DOCKER_PORT` 可改）。与 systemd 模式共用端口，两者不能同时运行——`up` 时若检测到 systemd 服务在跑会拒绝并提示。
- **Basic Auth**（可选，局域网暴露时建议开启）：同时设置 `DSHCTL_DOCKER_AUTH_USER` 和 `DSHCTL_DOCKER_AUTH_PASS` 即启用；只设一个会被 dshctl 拒绝（镜像侧只设一个等于完全放行）。
- **admin 变体**：镜像名含 `admin` 时自动追加挂载 `dshctl-dsh-install:/opt/dsh`，容器重建后版本切换与 npm 源配置仍保留。

## 配置

### 环境变量

可通过环境变量自定义 dshctl 的行为：

| 变量名 | 默认值（Linux/macOS） | 默认值（Windows） | 说明 |
|--------|---------------------|------------------|------|
| `DSHCTL_PACK_DIR` | `~/.cache/dshctl/pack` | `%USERPROFILE%\.cache\dshctl\pack` | 本地源码打包输出目录 |
| `DSHCTL_SLOT_DIR` | `~/.local/share/dshctl/slot-local` | `%USERPROFILE%\.local\share\dshctl\slot-local` | 本地槽位安装目录 |
| `DSHCTL_LOCAL_NODE_FLAGS` | `--expose-internals` | （不适用） | 拉起本地槽位时 node 的额外参数（仅 Linux/macOS） |
| `DSHCTL_GLOBAL_ROOT` | 自动检测 | 自动检测 | 全局 npm 根目录 |
| `DSHCTL_HEALTH_TRIES` | `30` | （不适用） | 健康检查重试次数（仅 Linux） |
| `DSHCTL_PREFLIGHT` | `1` | （不适用） | 是否启用预检（0=禁用，仅 Linux/macOS） |
| `DSHCTL_PREFLIGHT_TRIES` | `25` | （不适用） | 预检超时秒数（仅 Linux/macOS） |
| `DSHCTL_PREFLIGHT_PORT` | `3091` | （不适用） | 预检起始端口（仅 Linux/macOS） |
| `DSHCTL_DOCKER_IMAGE` | `smanx/deepseek-harness:latest` | 同左 | docker 模式使用的镜像 |
| `DSHCTL_DOCKER_PORT` | `3080` | 同左 | docker 模式宿主端口 |
| `DSHCTL_DOCKER_AUTH_USER` | 未设置 | 同左 | docker 模式 Basic Auth 用户名（须与密码同时设置） |
| `DSHCTL_DOCKER_AUTH_PASS` | 未设置 | 同左 | docker 模式 Basic Auth 密码（须与用户名同时设置） |

### 状态文件

**Linux/macOS:** `~/.config/dsh/`
**Windows:** `%USERPROFILE%\.config\dsh\`

- `channel` - 官方包的更新通道记忆
- `local-path` - 本地包的构建来源路径
- `local-detail` - 本地包的制品描述信息
- `current-source` - 当前运行来源（Windows）
- `dsh-web.pid` - 服务进程 ID（Windows）

### 切换机制

**Linux/macOS:**
运行槽位由 systemd drop-in 控制：
- `~/.config/systemd/user/dsh-web.service.d/50-dshctl-slot.conf`
  - 文件存在 → 运行本地槽位
  - 文件不存在 → 运行官方槽位

**Windows:**
运行槽位由状态文件 `current-source` 记录，服务管理通过进程和 PID 文件实现。

## 工作原理

### 双槽位模型

```
┌─────────────────────────────────────────────────┐
│                 dshctl 管理器                    │
│                                                  │
│  ┌────────────────┐        ┌─────────────────┐  │
│  │  官方槽位       │        │   本地槽位      │  │
│  │  (registry)    │        │   (local)       │  │
│  │                │        │                 │  │
│  │  全局 npm 树    │        │  独立 prefix    │  │
│  │  自动更新      │        │  手动构建       │  │
│  └────────────────┘        └─────────────────┘  │
│           ▲                         ▲            │
│           └─────────┬───────────────┘            │
│                     │                            │
│            systemd drop-in 切换                  │
│                     │                            │
│                     ▼                            │
│         ┌─────────────────────┐                  │
│         │  dsh-web.service    │                  │
│         └─────────────────────┘                  │
└─────────────────────────────────────────────────┘
```

### 安装流程

1. **验证目标** - 检查通道/路径是否合法
2. **安装包** - 执行 npm install 到对应槽位
3. **预检** - 在临时环境试启目标槽位
4. **切换槽位** - 更新 systemd drop-in
5. **重启服务** - 加载新版本，失败则自动回退

### 预检机制

```bash
# 预检步骤
1. 创建临时 DSH_HOME
2. 复制当前 profile 配置
3. 在空闲端口启动目标槽位
4. 等待应用级应答（401/303/200）
5. 确认进程稳定运行
6. 清理临时环境

# 预检通过 → 允许切换
# 预检失败 → 拒绝切换，保持当前槽位
```

## 开发

### 版本与发布约定

- dshctl 自身的版本号写在两处：仓库根 `VERSION` 文件、`dshctl` 里的 `DSHCTL_VERSION` 常量（PowerShell 版为 `dshctl.ps1` 里的 `$DSHCTL_VERSION`）。**发版时两处必须同步改**。
- `dshctl update` 自更新依赖这两处的一致性做校验：远端 `VERSION` 宣称的版本号必须与下载脚本内的常量一致，否则拒绝替换——半截文件或错误页都换不坏正在用的 dshctl。
- 命令语义自 v0.4 起：`update` = 更新 dshctl 自身，`upgrade` = 升级槽位 dsh（旧写法 `update <通道>` 兼容转发）。

### 代码架构

dshctl 采用契约式设计，每个安装来源实现七个函数：

- `<来源>_label` - 来源的中文名
- `<来源>_validate` - 校验目标参数
- `<来源>_describe` - 描述本次安装内容
- `<来源>_install` - 执行安装
- `<来源>_remember` - 写入状态并切换槽位
- `<来源>_bind` - 仅切换槽位
- `<来源>_ready` - 检查槽位是否可用
- `<来源>_cmd` - 生成启动命令（用于预检）

新增安装来源只需实现这八个函数并在 `SOURCES` 变量中登记。

### 测试

```bash
# 预演模式测试（不实际执行）
dshctl upgrade --dry-run
dshctl use local --dry-run

# 禁用预检（应急使用，有风险）
DSHCTL_PREFLIGHT=0 dshctl use local

# 只预检，不切换
dshctl check
```

## 故障排查

### 服务启动失败

```bash
# 查看详细日志
dshctl log

# 检查两个槽位是否可用
dshctl check

# 查看当前运行来源
dshctl source

# 切换到已知可用的槽位
dshctl use official
```

### 切换被拒绝

预检失败通常是因为：

1. 目标槽位的版本与当前 profile 配置不兼容
2. 缺少必要的插件依赖
3. Node.js 版本不匹配

检查预检日志中的错误信息，更新 profile 或重新安装目标槽位。

### Docker 模式排查

```bash
dshctl docker status   # 容器状态 + 应用应答码
dshctl docker log      # 最近容器日志（DSH 本体的输出在最后）

# 容器起不来时看完整日志
docker logs dshctl-dsh-web

# 端口冲突：docker 模式与 systemd 服务共用 3080，两者只能跑一个
dshctl stop            # 停 systemd 服务后再 docker up

# 数据卷问题（会话/配置丢失感）确认卷还在
docker volume inspect dshctl-dsh-data
```

### 状态记忆损坏

状态文件损坏不会中断 dshctl 运行，系统会自动回退到安全默认值：

- 官方通道 → `latest`
- 本地路径 → 需要重新指定

手动修复：

```bash
# 查看当前状态
cat ~/.config/dsh/channel
cat ~/.config/dsh/local-path

# 手动写入正确值
echo "next" > ~/.config/dsh/channel
```

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！

## 相关链接

- [DeepSeek Harness](https://github.com/deepseek-ai/dsh)
