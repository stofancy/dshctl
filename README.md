# dshctl

DeepSeek Harness (DSH) web 服务的安装、升级与托管。

只有一条路：**官方 npm 包 `@deepseek-ai/dsh` + 系统服务（Linux/macOS）或独立进程（Windows）**。
没有第二个安装位置，也没有「运行来源」开关——装的就是跑的。

- **Linux / macOS**：`dshctl`（bash，systemd 用户服务）
- **Windows**：`dshctl.ps1`（PowerShell 5.1+，独立 node 进程 + PID 文件 + 日志）

两个实现同构，命令与行为一致。

## 安装

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/stofancy/dshctl/main/dshctl -o ~/.local/bin/dshctl
chmod +x ~/.local/bin/dshctl
dshctl install          # 装进 PATH + 写服务单元 + 装官方包
```

```powershell
# Windows
.\dshctl.ps1 install    # 装进 PATH + 初始化目录 + 装官方包
```

依赖：`node`、`npm`；Linux/macOS 还需要 `systemctl`（用户实例），自更新需要 `curl`。

## 常用命令

| 命令 | 作用 |
|------|------|
| `dshctl upgrade [通道\|版本]` | 安装/升级官方包（默认沿用记住的通道：latest/next/alpha） |
| `dshctl install` | 首次安装：放进 PATH + 写服务配置 + 装包 |
| `dshctl status` | 服务状态、已装版本、是否在跑旧代码 |
| `dshctl start\|stop\|restart` | 服务控制 |
| `dshctl log` | 最近日志 |
| `dshctl check` | 预检当前安装能否用 profile 启动（不重启） |
| `dshctl repair` | 重建服务单元（原配置先备份） |
| `dshctl self-update` | 更新 dshctl 自身 |
| `dshctl help` | 完整说明 |

通用开关：`--dry-run`（只说不做）、`--no-restart`（装完不重启）。Windows 用 `-DryRun` / `-NoRestart`。

不带参数运行会进入交互菜单（bash 版）。

## 升级为什么不会把服务升挂

全局 npm 树**就是**正在运行的那份安装。所以 `npm i -g` 先落地再预检，等于拿线上做实验：
旧进程内存里是旧代码，新会话按需加载新文件就会炸（实测：rc.2 的进程加载 rc.5 的模块，
报 `does not provide an export named 'ownedSlice'`）。

因此顺序固定为四段：

1. **暂存**：把确切版本装进隔离 prefix，全局树与运行中的服务一行都不动；
2. **预检**：用 `profile web` 在临时 `DSH_HOME` + 空闲端口试启暂存件，
   拒绝「起不来」「能应答但日志里有 entry 未激活」「profile 钉死的插件版本与核心不一致」；
3. **提交**：通过后才写进全局树，并记下当前版本；
4. **重启**：重启失败自动装回上一个版本。

预检会把 profile 里**写死**的监听端口改到空闲端口（仅临时副本）——`remote-web-ui`
的 lan-bind 块会往 `cordis.patch.yml` 写 `host-webserver.port`，而配置里的端口优先于
命令行 `--port`，不改就永远和线上服务抢同一个端口。

## 状态与漂移

`dshctl status` 除了报告服务与版本，还会回答「进程跑的是不是装的那份」：

磁盘上的包比进程启动还晚时，说明进程内存里还是旧代码。**这种状态下服务、日志、HTTP 应答
全都正常，故障只在浏览器里现形**，所以必须显式提示：

```
⚠ 磁盘上的包比运行中的进程新：进程还跑着旧代码。
  新会话可能因新旧模块混载而失败（例如某些导出不存在）。执行：dshctl restart
```

## 逃生门（环境变量）

| 变量 | 作用 |
|------|------|
| `DSHCTL_PREFLIGHT=0` | 跳过预检（有把握时才用） |
| `DSHCTL_PREFLIGHT_TRIES` | 预检等待秒数（默认 25） |
| `DSHCTL_SKIP_PROFILE_PIN_CHECK=1` | 跳过 profile 与核心的版本一致性守卫 |
| `DSHCTL_HEALTH_TRIES` | 重启后健康检查次数（默认 30） |
| `DSHCTL_FORCE_SELF_UPDATE=1` | 远端版本不比本地新时也强制覆盖 |

网络方面：代理不可达时会先说清楚，能直连 registry 就本次直连；镜像尚未同步目标版本
（dist-tag 已指向、版本还没落地）会单独说明，而不是把 npm 的报错原样糊出来。

## 0.6 的破坏性变更

删掉了三类东西，因为它们都是「同一件事的第二种做法」：

- **双槽位**（官方包 / 本地源码构建互切）与 `use`、`source` 命令；
- **本地构建安装**（`upgrade --local`、源码克隆、`release:pack` 打包）；
- **docker 部署模式**（`dshctl docker ...`）。

`update` 因语义有歧义已停用：升级 dsh 用 `upgrade`，更新 dshctl 自身用 `self-update`。
旧版留下的槽位 drop-in 与状态文件会在启动时自动清理（一次性迁移），本地源码构建的
产物目录不自动删除。

## 开发

```bash
bash tests/repair.sh     # repair 流程回归（systemctl/npm/curl 用替身，不碰本机服务）
```

发版约定：改脚本里的 `DSHCTL_VERSION` 的同时改仓库根的 `VERSION`，两处一致才放行；
`self-update` 会校验两者一致，并且不会用不比本地新的远端版本覆盖本地改动。

## License

MIT
