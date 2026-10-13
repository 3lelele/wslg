# 本 fork 与上游 microsoft/wslg 的分叉说明

> 面向后续维护者（包括后续的 AI 会话）：读完本文应能明白**为什么**这个 fork 存在、
> **哪些文件**与上游不同、**怎么**构建和维护，以及这些差异是怎么演变到现在这个形态的。

## 1. 分叉原因

WSLg 在 Wayland 模式下无法使用 Linux 侧的输入法（fcitx5 等）：weston 的 text-backend
只支持 input-method-v1 + text-input-v1，而 GTK4 / Qt6 / JetBrains Runtime / Chromium 等
现代客户端只实现 zwp_text_input_v3，且 RDP RAIL shell 没有给候选窗一个合适的窗口。
上游 microsoft/wslg 与 microsoft/weston-mirror 对应的 PR 长期未合入，于是 fork 自行集成，
用 GitHub Actions 构建 `system_x64.vhd`，通过 `.wslconfig` 的 `systemDistro=` 替换官方
system distro（随时可删掉该行回滚官方版）。

集成过程中又发现并修了几个只在这套组合下暴露的 bug（IDEA 弹窗闪退、候选框弹出时搜索框被
主窗口盖住），以及顺手带上两个与 IME 无关但未合入的稳定性/安全修复。

## 2. 与上游的差异清单

### 2.1 wslg 仓库源码（已直接 merge 进 `main`，保留上游 PR 的原始提交）

| 上游 PR | 文件 | 内容 |
|---|---|---|
| [microsoft/wslg#1486](https://github.com/microsoft/wslg/pull/1486) | `config/weston.ini` | `[input-method] allow-external=true`，允许 distro 内的输入法绑定 input-method-v1 |
| [microsoft/wslg#1436](https://github.com/microsoft/wslg/pull/1436) | `WSLGd/ProcessMonitor.cpp` | 进程崩溃重启增加总次数上限 `c_maxTotalCrashes=50`，防止崩溃循环 |
| [microsoft/wslg#1333](https://github.com/microsoft/wslg/pull/1333) | `WSLGd/main.cpp` | `XDG_RUNTIME_DIR` 权限 0777→0700 |

### 2.2 weston 源码（`patches/weston/`，构建时套用到固定基线上）

weston 不在本仓库里（`vendor/` 被 gitignore，构建时克隆），所以改动以
**固定基线提交 + 线性补丁序列**的形式存放，`apply.sh` 在构建时原样套用并用 tree hash 校验。

| 补丁 | 来源 | 解决的问题 |
|---|---|---|
| 0001 | [weston-mirror#168](https://github.com/microsoft/weston-mirror/pull/168) | text-backend 桥接 text-input-v3 ↔ input-method-v1 |
| 0002 | [weston-mirror#169](https://github.com/microsoft/weston-mirror/pull/169) | rdprail-shell 给外部输入法候选窗独立的 RAIL 窗口 |
| 0003 | [weston-mirror#166](https://github.com/microsoft/weston-mirror/pull/166) | rdp 剪贴板 fd 崩溃修复（wslg#1407，IDEA 复制粘贴崩溃） |
| 0004 | [weston-mirror#172](https://github.com/microsoft/weston-mirror/pull/172) | rdp 弹窗定位与窗口状态同步（wslg#1439/#1265/#1299） |
| 0005 | 本 fork 原创 | #172 后续修复：popup "无 buffer"判定改用 `width_from_buffer`（IDEA 菜单/Ctrl+N 弹窗闪退的根因） |
| 0006 | 本 fork 原创 | #169+#172 组合问题：xdg_popup 的 RAIL owner 设为父窗口（候选框出现时 popup 被主窗口盖住） |
| 0007 | 本 fork 原创 | rdp-backend 剪贴板：Windows 侧数据响应改在 compositor 线程注册 fd。修复"复制后 weston 段错误、整个 WSLg 会话消失"（#166 之后仍会出现的跨线程竞态，见 §4.1） |

0002–0004 各自还带着让它们能一起编译的集成修复（`tests/meson.build` 条目并置、
`extract_objects` 补文件、#169/#172 在 `backend-rdp.h`/`rdprail.c` 的冲突解决）。
基线提交、维护方法见 `patches/weston/README.md` 与 `series.conf`。

### 2.3 本 fork 新增的基础设施文件（上游没有）

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-wayland-ime.yml` | 手动触发的构建 workflow，产出 `system_x64.vhd` |
| `patches/weston/series.conf` | weston 基线提交 + 套用后期望的 tree hash |
| `patches/weston/*.patch` | 补丁序列 |
| `patches/weston/apply.sh` | 构建用：克隆/检出基线、套用补丁、校验、幂等 |
| `patches/weston/regenerate.sh` | 维护用：从上游 PR 重新 merge 并生成补丁 |
| `patches/weston/README.md` | 补丁目录说明 |
| `.gitattributes` | 补丁文件标 `-text`，防止任何 checkout 改坏其中的 CRLF 上下文行 |
| `FORK.md` | 本文 |

上游原有文件中，除 2.1 的三个文件外没有改动任何内容（`build-and-export.sh`、`Dockerfile` 等均与上游一致）。

## 3. 演进历史

**第一阶段（提交 `d97a651` … `07dcf23`）**：workflow 在构建时动态 `git fetch` 各 PR 的
`pull/N/head` 并 merge，所有冲突解决、`tests/meson.build` 的确定性并置、各种
`extract_objects` 修补、以及 0005/0006 两个原创修复，都以 Python/bash 片段的形式写在
YAML 里（约 700 行）。fork 的 `main` 与上游完全一致，分叉只存在于构建瞬间。
缺点：依赖上游 PR ref 一直存在且不变；上游 `working` 分支前进就可能冲突；每次构建都在
重新做一遍脆弱的合并；YAML 里的 Python 文本模式读写还把两个 CRLF 文件整体转成了 LF。

**第二阶段（2026-10-13 本轮，提交 `3083471` … 之后）**：把所有 PR 固化进仓库。
wslg 侧三个 PR 真实 merge 进 `main`；weston 侧按旧 workflow 的顺序在本地重放一次合并，
拆成 6 个线性补丁入库，基线钉死在 `7fbf6931`；workflow 删掉全部 merge 逻辑，weston
步骤只剩 `./patches/weston/apply.sh`。合并知识转移到 `regenerate.sh` 里保存。

## 4. 本轮会话（2026-10-13）具体做了什么

1. 添加 `upstream` remote（`https://github.com/microsoft/wslg`），fetch wslg#1486/#1436/#1333
   的 head，以 `--no-ff` merge 进 `main`（三个 merge 提交，文件互不重叠，无冲突）。
2. 克隆 microsoft/weston-mirror `working`（HEAD = `7fbf6931`），fetch weston#168/#169/#166/#172，
   逐步重放旧 workflow 的合并序列（`#168 → meson 预构造 → #169 → #166 → #172 冲突解决 →
   0005 → 0006`），每一步打 tag。
3. 发现旧流程的 Python 文本模式读写把 `libweston/backend-rdp/rdprail.c` 和
   `rdprail-shell/shell.c`（CRLF 文件）整体转成 LF，造成 2 万行无意义 diff；改为保留原始行尾
   后重放。验证：新结果与旧 CI 结果 `git diff --ignore-cr-at-eol` 为空，即**编译内容完全一致**。
4. 把 6 个阶段转成线性提交并 `git format-patch`，作者/日期固定，重复生成逐字节一致。
   在干净基线上 `git apply` 整套补丁后 tree hash = `5f96a8aee525…`，写入 `series.conf`。
5. 写 `apply.sh`（测试了首次套用、重复运行跳过、脏工作区拒绝、补丁被篡改时回滚四种场景）
   和 `regenerate.sh`（真实跑通一次，产出与手工重放一致）。
6. 重写 workflow，删除所有 fetch/merge 步骤与 `apply_*` 开关，保留 `debug_build`。
7. 为本仓库设置了 `--local` 的 git 身份（与既有提交作者一致），删除了临时 `pr-*` 分支。

**未做的事**：没有在本地跑完整 Docker 构建（Mesa 等编译耗时数小时）。补丁内容与此前多次
CI 构建成功的内容一致（见第 3 条），但新 workflow 本身还需要在 Actions 上 **Run workflow**
实际验证一次。

### 4.1 同日第二轮：复制后 weston 段错误（补丁 0007）

现象：在 IDEA（原生 Wayland 模式）里复制之后，偶尔整个 WSLg 界面消失，`dmesg` 里是
`weston[...]: segfault at 28 ... in libwayland-server.so.0.22.0`，IDEA 日志只有
`WLToolkit - Wayland protocol I/O error`。已部署的 VHD（2026-09-22 构建）里已经含 #166，
即 wslg#1407 的修复**没有**覆盖这个崩溃。

定位方法：用 `debugfs` 直接从 `system_x64.vhd` 取出 `libwayland-server.so.0.22.0`，
`objdump` 到 dmesg 给出的文件偏移 `0xbdad`，指令字节与 dmesg 的 `Code:` 完全一致，落在
`wl_event_source_remove()` 第一条指令 `mov 0x28(%rdi),%edx`（读 `source->fd`），
`RDI=0` → weston 以 NULL 调用了 `wl_event_source_remove()`。weston 里所有未判空的调用点中，
只有 `rdpclip.c` 的 `clipboard_data_source_write()` 能被另一个线程抢先触发：
`clipboard_client_format_data_response()` 在 **FreeRDP 线程**上直接
`rdp_event_loop_add_fd()`，而 epoll 不管请求的 mask 是什么都会上报 `EPOLLERR/EPOLLHUP`，
请求方的管道读端若已经关闭（libweston 的 clipboard manager 在下一个 selection 到来时就会关掉它；
WSLg 里 Windows 会在 Linux 复制后约 1 秒把同样内容再推回来两次，所以这是常态），compositor
线程在 `epoll_ctl(ADD)` 内就被唤醒并跑进 `clipboard_data_source_write()`，此时
`transfer_event_source` 还没被 FreeRDP 线程写入 → `wl_event_source_remove(NULL)`。
是否崩溃取决于 FreeRDP 线程是否恰好在系统调用返回处被抢占，所以"有时候"。上游 weston
的同一段代码至今相同。

修复（0007）：响应回调只缓存数据，然后像失败路径一样 `rdp_dispatch_task_to_display_loop()`
交给 compositor 线程，由新增的 `clipboard_data_source_received()` 在那里注册 fd；
`clipboard_data_source_write()` 收到 `WL_EVENT_ERROR/HANGUP` 时直接放弃而不 `write()`
（weston 没忽略 SIGPIPE）；重复响应的判定覆盖"上一个响应还排在队列里"的情况。
`regenerate.sh` 增加了 state-7 步骤，`EXPECTED_TREE` 已更新。本地同样没有编译
（改动只用了同文件里已有的调用模式），需要 Actions 构建后替换 VHD 验证。

## 5. 维护指南

### 与上游 wslg 同步

```bash
git remote add upstream https://github.com/microsoft/wslg   # 本地没有时
git fetch upstream
git merge upstream/main
```

2.1 的三个 PR 是真实 merge（保留了上游提交对象），上游将来合入同一 PR 时 git 会识别为
已包含，不会产生冲突；如果上游以 squash 方式合入，会出现内容相同的平凡冲突，取任一侧即可。

### 升级 weston 基线 / 跟进 PR 更新 / 某 PR 被上游合入

见 `patches/weston/README.md`。核心是改 `series.conf` 的 `WESTON_BASE`，
跑 `regenerate.sh`，检查 diff 后提交。

### 本地构建

```bash
./patches/weston/apply.sh      # vendor/weston
# FreeRDP / pulseaudio / DirectX-Headers / mesa 按 workflow "克隆 vendor 源码" 一步的命令克隆
./build-and-export.sh          # 需要 docker 与 go
```

### 验证补丁完整性（不构建）

```bash
rm -rf /tmp/wt && ./patches/weston/apply.sh /tmp/wt   # 退出码 0 且打印 "tree … 校验通过"
```
