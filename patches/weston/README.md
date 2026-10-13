# weston 补丁序列

`vendor/` 被 `.gitignore` 排除、weston 源码在构建时才克隆，所以 weston 侧的改动无法像
wslg 侧那样直接合进本仓库源码。这里用的是等价做法：**固定上游基线提交 + 一组线性补丁**，
构建时由 `apply.sh` 原样套用，不再 fetch 任何 PR、不再做 merge、也不可能出现冲突。

| 文件 | 作用 |
|---|---|
| `series.conf` | 基线提交 `WESTON_BASE`、套用后的期望 tree hash `EXPECTED_TREE` |
| `0001`–`0006-*.patch` | 补丁序列，按文件名顺序套用 |
| `apply.sh` | **构建用**。克隆/检出基线并套用补丁，幂等，结果用 tree hash 校验 |
| `regenerate.sh` | **维护用**。从上游 PR 重新生成补丁序列（需要网络） |

## 补丁来源

| 补丁 | 来源 | 解决的问题 |
|---|---|---|
| 0001 | [weston-mirror #168](https://github.com/microsoft/weston-mirror/pull/168) | text-backend 桥接 text-input-v3 ↔ input-method-v1，让 GTK4/Qt6/JBR 等客户端能用 fcitx5 |
| 0002 | [weston-mirror #169](https://github.com/microsoft/weston-mirror/pull/169) | rdprail-shell 给外部输入法候选窗一个独立的 RAIL 窗口 |
| 0003 | [weston-mirror #166](https://github.com/microsoft/weston-mirror/pull/166) | rdp-backend 剪贴板 fd 崩溃修复（wslg #1407，IDEA 复制粘贴崩溃） |
| 0004 | [weston-mirror #172](https://github.com/microsoft/weston-mirror/pull/172) | rdp 弹窗定位与窗口状态同步（wslg #1439/#1265/#1299，GTK4 弹窗/子菜单） |
| 0005 | 本仓库 | #172 的后续修复：popup 无 buffer 判定改用 `width_from_buffer`（IDEA 弹窗闪退根因） |
| 0006 | 本仓库 | #169+#172 组合问题：xdg_popup 的 RAIL owner 设为父窗口（候选框弹出时搜索框被主窗口盖住） |

0002–0004 还各自带了让它们能一起编译的集成修复（`tests/meson.build` 条目并置、
`extract_objects` 补文件、#169/#172 的冲突解决），具体见各补丁的描述。

## 构建

`build-wayland-ime.yml` 会自动调用 `apply.sh`。本地构建：

```bash
./patches/weston/apply.sh      # 克隆 weston 到 vendor/weston，检出基线，套用补丁
# 其余 vendor 组件（FreeRDP、pulseaudio、DirectX-Headers、mesa）按 workflow 里的方式克隆
./build-and-export.sh
```

`apply.sh` 不产生提交：`vendor/weston` 的 HEAD 停在上游基线上，补丁以未提交改动的形式存在。
这样 `/etc/versions.txt` 里的 `weston:` 仍是上游可查的提交，而"套用了哪些补丁"由本仓库的提交决定。
重复运行会直接跳过；如果 `vendor/weston` 有来历不明的改动会报错而不是覆盖。

## 升级基线 / 更新 PR

```bash
vim patches/weston/series.conf          # 改 WESTON_BASE（升级基线时）
./patches/weston/regenerate.sh          # 重新 merge 各 PR、生成补丁、改写 EXPECTED_TREE
git diff patches/weston/                # 检查变化
git add patches/weston && git commit
```

`regenerate.sh` 里保存着原先 workflow 中积累的全部合并经验：#168/#169 对
`tests/meson.build` 的确定性并置、#169/#172 在 `backend-rdp.h`/`rdprail.c` 的冲突解决模式、
各 PR 漏掉的 `extract_objects` 条目等。上游或 PR 变动导致某个锚点找不到时它会报错指出位置，
按提示调整对应段落即可。

某个 PR 被上游合入后：把它从 `regenerate.sh` 的合并序列中删掉，更新 `WESTON_BASE` 到包含它的
提交，重新生成。

## 行尾说明

weston 里 `libweston/backend-rdp/rdprail.c` 与 `rdprail-shell/shell.c` 是 CRLF 文件。
`regenerate.sh` 的所有文本修补都保留原始行尾，因此补丁只含真实改动（0006 共 24 行）。
旧版 workflow 用 Python 文本模式读写，会把这两个文件整体转成 LF——编译结果相同，但 diff 膨胀到一万行。
