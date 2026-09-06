# codegraph-termux

[colbymchenry/codegraph](https://github.com/colbymchenry/codegraph) —— 面向 AI
代理的本地优先代码智能工具（MCP），原生运行在 **Termux（Android）** 上。

本仓库是 Termux 的构建/安装适配层，与本工作区中其他 `*-termux` 仓库
（codebuff-termux、opencode-termux 等）同一种思路。上游发布包捆绑了自己的
Node.js 运行时（glibc，121 MB）和 Rust 内核；Termux 提供的是 **bionic** libc，
因此必须解决两个问题：

1. 捆绑的 glibc `node` 二进制无法在 bionic 上加载 → 用 `patchelf` 修补
2. Android 禁止读取 `/proc/stat` → Node 的 `os.cpus()` 返回 0 核
   → 用 `proot` + 伪造文件解决

## 状态

| 功能                    | 状态 |
|-------------------------|------|
| `codegraph --version`   | ✅ 1.5.0 |
| `codegraph init`        | ✅ |
| `codegraph index`       | ✅（包含 spawn 原生 `git`） |
| `codegraph status`      | ✅ |
| `codegraph query`       | ✅ |
| `os.cpus()`             | ✅ proot 伪造后 8 核 |
| MCP server (daemon)     | ✅ 经 wrapper 正常运行 |
| 升级                    | 手动 — `make runtime VER=<新版本>`（或重跑 `scripts/install.sh <新版本>`） |

## 快速开始

```bash
cd ~/develop/codegraph-termux
# 本机为 pacman 系 Termux：直接装预构建包
pacman -U packing/pacman/codegraph-1.5.0-1-aarch64.pkg.tar.xz
# 或一键构建并安装：
make all VER=1.5.0 PKG=pacman && pacman -U packing/pacman/codegraph-1.5.0-1-aarch64.pkg.tar.xz
# 或经典脚本方式：
bash scripts/install.sh 1.5.0
make test
codegraph init                 # 在你的项目里执行
codegraph index
```

依赖（Termux，本机为 pacman 系）：`pacman -S gcc patchelf proot glibc curl`（或 `pkg install …`）

## 从 hope2333 软件源安装（Termux）

配置软件源（一行）：

```sh
curl -fsSL https://hope2333.github.io/repo/install.sh | sh
```

配置并安装（一行）：

```sh
curl -fsSL https://hope2333.github.io/repo/install.sh | sh -s -- --install codegraph
```

后续升级：

```sh
pacman -Syu                    # pacman 客户端
apt update && apt upgrade     # apt 客户端（mirrorlist 包更新走 [hope2333-meta] 源）
```

详见：https://hope2333.github.io/wiki/guides/install.html

## 工作原理

```
终端
  │  codegraph  （C wrapper，本机编译 → bionic ELF）
  │    • 清除 LD_PRELOAD / LD_LIBRARY_PATH / LD_DEBUG
  │      （LD_LIBRARY_PATH 会泄漏给 bionic 子进程如 `git` 并使其崩溃：
  │       "CANNOT LINK EXECUTABLE … bad ELF magic"）
  │    • 写入伪造的 /proc/stat、/proc/loadavg、/proc/cpuinfo、
  │      /sys/devices/system/cpu/{present,online} 到 $TMPDIR/.codegraph-fake
  │    • 设置 CODEGRAPH_HOST_PPID（对齐上游 launcher 行为，#1185）
  │
  ▼  proot  （5 个绑定挂载，最小化，不需要 qemu）
  │
  ▼  node  （捆绑的 glibc v24.16.0，patchelf 替换 interpreter）
  │       + codegraph.js（--liftoff-only，与上游一致）
  │
  ▼  Rust 内核（codegraph-kernel.node）+ tree-sitter wasm 解析器
```

### 两个关键修复

**1. glibc 二进制跑在 bionic 上 —— 只做一次 `patchelf`，只改 interpreter**

```
patchelf --set-interpreter $PREFIX/glibc/lib/ld-linux-aarch64.so.1 node
```

- Termux 的 glibc `ld.so` 编译时已内置默认搜索路径
  `/data/data/com.termux/files/usr/glibc/lib/` → **不需要** `LD_LIBRARY_PATH`。
- 切勿加 `--set-rpath`，也切勿对 node 二次 patchelf：两者都会弄坏 121 MB
  的二进制（立即 SIGSEGV，exit 139）。

**2. Android 屏蔽了 `/proc/stat` 和 `/proc/loadavg`（Permission denied）**

`os.cpus()` 返回空 → 下游工具以为 0 核而卡死。wrapper 通过 `proot` 绑定 5 个
伪造文件解决（proot 开销足够小，不需要像 codebuff-termux 那样上
`LD_PRELOAD` hook.c）。

干净环境至关重要：没有 `LD_LIBRARY_PATH`，codegraph spawn 的 bionic 子进程
（`git`、`timeout` 等）才能正常工作。

## 安装布局

```
$PREFIX/bin/codegraph              → C wrapper（bionic）
$PREFIX/lib/codegraph-termux/
  current → 1.5.0/
  1.5.0/                           → 解压后的发布包
    node                           → glibc node，interpreter 已修补
    bin/codegraph                  → 上游 shell launcher（未使用）
    lib/dist/bin/codegraph.js      → JS 入口
    lib/kernel/codegraph-kernel.node → Rust 内核
```

## 脚本

| 脚本                   | 作用 |
|------------------------|------|
| `scripts/install.sh`   | 解析版本 → 下载（或 `CODEGRAPH_TARBALL=…` 指定本地包）→ 解压 → 修补 node → 编译 wrapper → 建 `current` 软链 → 冒烟测试 |
| `scripts/build.sh`     | 编译 `codegraph-wrapper.c`，把四个 `-D` 路径编译进去 |
| `scripts/test.sh`      | PASS/FAIL/SKIP 测试框架：ELF 检查、interpreter 检查、`--version`、proot 下 `os.cpus()`、伪造文件生成、临时 git 仓库中 `index`+`status` |

## 常见问题

- **`os.cpus()` 还是 0** → 先 `pkg install proot`；伪造文件位于
  `${TMPDIR:-$PREFIX/tmp}/.codegraph-fake`（每次运行 wrapper 都会重建）。
- **`CANNOT LINK EXECUTABLE`（git/sh）** → 有脚本导出了 `LD_LIBRARY_PATH`；
  wrapper 会清除它——请通过 wrapper 运行 codegraph，不要直接跑捆绑的 node。
- **SIGSEGV / exit 139** → 捆绑 node 被二次 patchelf 或加了 rpath；从压缩包
  重新解压并只 patchelf 一次。
- **升级** → `bash scripts/install.sh <新版本号>`；旧版本会留在
  `$PREFIX/lib/codegraph-termux/` 下，手动删除即可。
- **遥测** → codegraph 会上报使用数据（见上游文档）；可用
  `codegraph telemetry --help`（或设 `CODEGRAPH_DISABLE_TELEMETRY=1`）关闭。

## License

MIT —— 见 [LICENSE](LICENSE)。捆绑的上游二进制保留其自身许可。
