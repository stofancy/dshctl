# dshctl

DeepSeek Harness (DSH) web 服务一站式管理工具。

## 简介

`dshctl` 是一个 Bash 脚本，用于管理 DeepSeek Harness web 服务的生命周期，包括安装、更新、启动、停止、日志查看等操作。它封装了底层的 systemctl、journalctl 和 npm 命令，提供统一的管理接口。

## 核心特性

### 双槽位架构

dshctl 实现了官方包和本地包的双槽位模型，两者互不覆盖，可以随时切换：

- **官方槽位（registry）**：全局 npm 安装的 `@deepseek-ai/dsh` 包
- **本地槽位（local）**：独立 prefix 中的本地构建版本

切换只需写入/删除一个 systemd drop-in 配置文件，秒级完成，服务随时可回退。

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

- Bash 4.0+
- systemd（用户态服务）
- Node.js 和 npm/pnpm
- curl（用于健康检查）

### 安装步骤

1. 下载脚本：

```bash
curl -o ~/.local/bin/dshctl https://raw.githubusercontent.com/stofancy/dshctl/main/dshctl
chmod +x ~/.local/bin/dshctl
```

2. 确保 `~/.local/bin` 在 PATH 中：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

3. 创建 systemd service 配置文件 `~/.config/systemd/user/dsh-web.service`：

```ini
[Unit]
Description=DeepSeek Harness Web Service
After=network.target

[Service]
Type=simple
ExecStart=/path/to/dsh web --host 127.0.0.1 --port 3080
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
```

4. 创建帮助文件 `~/.config/dsh-web-help.txt`（可选）：

```text
dshctl - DeepSeek Harness web 服务管理工具

常用命令：
  dshctl update           升级当前运行来源
  dshctl status           查看服务状态
  dshctl restart          重启服务
  dshctl log              查看最近日志
  dshctl source           查看当前运行来源与槽位信息
  dshctl use <来源>       切换运行来源（official/local）
  dshctl check            预检槽位是否可用
  dshctl help             显示帮助信息

无参数运行时进入交互菜单。
```

## 使用方法

### 交互式菜单

直接运行 `dshctl`（无参数）进入交互菜单：

```bash
dshctl
```

### 命令行模式

#### 更新管理

```bash
# 升级当前运行来源（沿用记忆的通道）
dshctl update

# 从指定通道安装官方包
dshctl update latest
dshctl update next
dshctl update alpha
dshctl update 0.1.5-rc.2

# 从本地源码仓库构建并安装
dshctl update --local /path/to/dsh-repo

# 从已打包的 tarball 目录安装
dshctl update --local /path/to/artifacts

# 从单个 tarball 安装
dshctl update --local /path/to/package.tgz

# 预演模式（只显示将要执行的操作，不实际安装）
dshctl update --dry-run

# 安装但不重启服务
dshctl update --no-restart
```

#### 槽位切换

```bash
# 查看当前运行来源和两个槽位的版本
dshctl source

# 切换到官方包
dshctl use official

# 切换到本地包
dshctl use local

# 预检槽位是否可用（不切换）
dshctl check
dshctl check official
dshctl check local
```

#### 服务管理

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

# 取消开机自启
dshctl disable
```

## 配置

### 环境变量

可通过环境变量自定义 dshctl 的行为：

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `DSHCTL_PACK_DIR` | `~/.cache/dshctl/pack` | 本地源码打包输出目录 |
| `DSHCTL_SLOT_DIR` | `~/.local/share/dshctl/slot-local` | 本地槽位安装目录 |
| `DSHCTL_LOCAL_NODE_FLAGS` | `--expose-internals` | 拉起本地槽位时 node 的额外参数 |
| `DSHCTL_GLOBAL_ROOT` | 自动检测 | 全局 npm 根目录 |
| `DSHCTL_HEALTH_TRIES` | `30` | 健康检查重试次数 |
| `DSHCTL_PREFLIGHT` | `1` | 是否启用预检（0=禁用） |
| `DSHCTL_PREFLIGHT_TRIES` | `25` | 预检超时秒数 |
| `DSHCTL_PREFLIGHT_PORT` | `3091` | 预检起始端口 |

### 状态文件

dshctl 将状态保存在 `~/.config/dsh/` 目录：

- `channel` - 官方包的更新通道记忆
- `local-path` - 本地包的构建来源路径
- `local-detail` - 本地包的制品描述信息

### 切换文件

运行槽位由 systemd drop-in 控制：

- `~/.config/systemd/user/dsh-web.service.d/50-dshctl-slot.conf`
  - 文件存在 → 运行本地槽位
  - 文件不存在 → 运行官方槽位

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
dshctl update --dry-run
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
