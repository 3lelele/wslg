#!/bin/bash
# 从上游 PR 重新生成本目录的 weston 补丁序列（维护用，构建时不需要）。
#
# 用法: ./patches/weston/regenerate.sh [工作目录，默认 /tmp/weston-regen]
# 需要能访问 github.com。
#
# 什么时候用：
#   - 想把基线升到更新的 working 提交：先改 series.conf 里的 WESTON_BASE，再跑本脚本
#   - 上游 PR 有新提交：直接跑本脚本（默认取各 PR 当前 head）
#   - 某个 PR 被上游合入了：把它从下面的合并序列里删掉，再跑本脚本
#
# 做的事：
#   1. 克隆/更新 weston-mirror，fetch 各 PR 的 head
#   2. 在 WESTON_BASE 上按固定顺序 merge 各 PR，并执行跨 PR 的冲突解决与
#      tests/meson.build 修补（逻辑源自旧版 build-wayland-ime.yml，已实证可构建）
#   3. 把合并结果拆成线性的 8 个补丁，写回本目录（覆盖旧 *.patch）
#   4. 把套用后的 tree hash 写回 series.conf 的 EXPECTED_TREE
#
# 文本修补一律通过 load()/save() 保留文件原有行尾：weston 里 rdprail.c、
# rdprail-shell/shell.c 是 CRLF，用普通文本模式读写会把整个文件改成 LF，
# 让一个 20 行的改动变成一万行的 diff。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=series.conf
. "$here/series.conf"

work=${1:-/tmp/weston-regen}
repo=$work/weston

log() { echo "[regenerate] $*"; }
die() { echo "[regenerate] ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------------ 准备仓库
mkdir -p "$work"
if [ ! -d "$repo/.git" ]; then
  log "克隆 $WESTON_REPO ($WESTON_BRANCH) → $repo"
  git clone --single-branch -b "$WESTON_BRANCH" "$WESTON_REPO" "$repo"
fi
cd "$repo"
git config user.name "wslg-patches"
git config user.email "patches@localhost"
# tests/meson.build 的合并由下面的"预构造"步骤接管：#168/#169 都在同一个列表
# 相邻追加条目，3-way 合不了，内置 union driver 又会交错两侧、破坏 meson 语法。
git config merge.ours.driver true
mkdir -p .git/info
grep -qxF "tests/meson.build merge=ours" .git/info/attributes 2>/dev/null \
  || echo "tests/meson.build merge=ours" >> .git/info/attributes

log "fetch $WESTON_BRANCH 与各 PR head"
git fetch origin "$WESTON_BRANCH" \
  '+refs/pull/168/head:refs/heads/pr-168' \
  '+refs/pull/169/head:refs/heads/pr-169' \
  '+refs/pull/166/head:refs/heads/pr-166' \
  '+refs/pull/172/head:refs/heads/pr-172'
git cat-file -e "$WESTON_BASE^{commit}" || die "WESTON_BASE=$WESTON_BASE 不在 $WESTON_BRANCH 上"

PR168=$(git rev-parse pr-168); PR169=$(git rev-parse pr-169)
PR166=$(git rev-parse pr-166); PR172=$(git rev-parse pr-172)
log "base  $WESTON_BASE"
log "#168  $PR168"; log "#169  $PR169"; log "#166  $PR166"; log "#172  $PR172"

git checkout -q --detach "$WESTON_BASE"
git reset -q --hard && git clean -qfdx
git tag -f state-0 >/dev/null

# 所有文本修补共用的行尾保护函数（注入到每个 python 块）
PYHELPERS='
def load(p):
    raw = open(p, "rb").read()
    return raw.decode("utf-8").replace("\r\n", "\n"), b"\r\n" in raw

def save(p, s, crlf):
    open(p, "wb").write((s.replace("\n", "\r\n") if crlf else s).encode("utf-8"))
'

# ------------------------------------------------------------------ #168
log "merge #168"
git merge --no-edit pr-168 >/dev/null || die "merge #168 冲突，需人工处理"
git tag -f state-1 >/dev/null

# ---------------------------------- 预构造 tests/meson.build（#168 + #169）
# 以两个 PR 的共同 fork 点为基准，把"基线分支改动 / #168 改动 / #169 改动"三路
# 行级操作按行号并置，得到确定性的、语法完整的结果；merge #169 之后整体覆盖。
log "预构造 tests/meson.build"
WESTON_BASE="$WESTON_BASE" python3 - <<PY
import subprocess, sys, difflib, os
$PYHELPERS
FILE = 'tests/meson.build'
BASE, P168, P169 = os.environ['WESTON_BASE'], 'pr-168', 'pr-169'

def show(ref):
    raw = subprocess.check_output(['git', 'show', f'{ref}:{FILE}'])
    return raw.decode('utf-8').replace('\r\n', '\n').splitlines(keepends=True)

def merge_base(a, b):
    return subprocess.check_output(['git', 'merge-base', a, b], text=True).strip()

W = show(BASE)
F168, F169 = merge_base(BASE, P168), merge_base(BASE, P169)
if F168 != F169:
    sys.exit('ERROR: #168/#169 的 fork 点不一致，需人工处理')
F = show(F168)

def ops(a, b):
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    return [(i1, i2, b[j1:j2]) for tag, i1, i2, j1, j2 in sm.get_opcodes() if tag != 'equal']

tagged = ([(0, *o) for o in ops(F, W)] +
          [(1, *o) for o in ops(F, show(P168))] +
          [(2, *o) for o in ops(F, show(P169))])
tagged.sort(key=lambda o: (o[1], o[2], o[0]))
out, pos = [], 0
for src, i1, i2, lines in tagged:
    if i1 < pos:
        sys.exit('ERROR: 基线/#168/#169 对 tests/meson.build 的改动区间交叉，需人工处理')
    out.extend(F[pos:i1]); out.extend(lines); pos = i2
out.extend(F[pos:])
result = ''.join(out)

need = ['TESTSUITE_TEXT_CONFIG_PATH', 'exe_text_input_method_test',
        'TESTSUITE_INPUT_METHOD_ALLOW_CONFIG_PATH', "'name': 'input-method-bind'",
        'TESTSUITE_RDPRAIL_INPUT_PANEL_CONFIG_PATH']
missing = [n for n in need if n not in result]
if missing:
    sys.exit(f'ERROR: 预构造结果缺少关键条目: {missing}')

# 跨 PR 依赖：test-rdp-teardown 的 extract_objects 需要 #169 新增的 rdprail-window-state.c
if "'rdprail.c'," in result and "'rdprail-window-state.c'," not in result:
    result = result.replace("'rdprail.c',", "'rdprail.c',\n\t\t\t'rdprail-window-state.c',", 1)

open('$work/tests-meson-final.build', 'w').write(result)
PY

# ------------------------------------------------------------------ #169
log "merge #169"
git merge --no-edit pr-169 >/dev/null || die "merge #169 冲突: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
cp "$work/tests-meson-final.build" tests/meson.build
git add tests/meson.build
git commit -q --no-edit -m "Merge fix: deterministic union of tests/meson.build (weston #168 + #169)" || true
git tag -f state-2 >/dev/null

# ------------------------------------------------------------------ #166
log "merge #166"
git merge --no-edit pr-166 >/dev/null || die "merge #166 冲突: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
# ort 会静默丢掉 #166 对 tests/meson.build 的 rdpclip-fd 测试条目；
# 另外 #166 自身漏了把 rdpclip-fd.c 加进 test-rdp-teardown 的 extract_objects。
python3 - <<PY
$PYHELPERS
s, crlf = load('tests/meson.build')
if "'rdpclip-fd'," not in s:
    anchor = "['matrix', [], [ dep_libm, dep_matrix_c ]],"
    block = anchor + "\n\t[\n\t\t'rdpclip-fd',\n\t\t['../libweston/backend-rdp/rdpclip-fd.c'],\n\t\t[ dep_zucmain ],\n\t],"
    if anchor not in s:
        raise SystemExit('ERROR: tests/meson.build 中找不到 matrix 锚点')
    s = s.replace(anchor, block, 1)
if "'rdpclip-fd.c'," not in s:
    a2 = "\t\t\t'rdpclip.c',\n\t\t\t'rdprail.c',"
    if a2 not in s:
        raise SystemExit('ERROR: tests/meson.build 中找不到 rdpclip.c/rdprail.c 锚点')
    s = s.replace(a2, "\t\t\t'rdpclip.c',\n\t\t\t'rdpclip-fd.c',\n\t\t\t'rdprail.c',", 1)
save('tests/meson.build', s, crlf)
PY
git add tests/meson.build
git commit -q --no-edit -m "Fix: restore rdpclip-fd test entry + extract_objects for test-rdp-teardown" || true
git tag -f state-3 >/dev/null

# ------------------------------------------------------------------ #172
log "merge #172"
git merge --no-edit pr-172 >/dev/null || log "  #172 有冲突: $(git diff --name-only --diff-filter=U | tr '\n' ' ')（按已知模式解决）"
# #172 与 #169 在 backend-rdp.h / rdprail.c 的冲突区域逻辑互补：
#   backend-rdp.h: 保留 #169 的 set_window_owner/set_window_visible 和 #172 的 notify_popup_state
#   rdprail.c:     保留 #169 更精确的 state_fields 位掩码判断，把 #172 的 z-order 通知放进去
python3 - <<PY
import sys
$PYHELPERS
M7, E7, G7 = chr(60) * 7, chr(61) * 7, chr(62) * 7

def resolve(path, old, new, desc):
    s, crlf = load(path)
    if old in s:
        save(path, s.replace(old, new, 1), crlf)
    elif M7 in s:
        sys.exit(f'ERROR: {desc} 冲突块与已知模式不匹配，需人工处理')

resolve('include/libweston/backend-rdp.h',
    M7 + ' HEAD\n'
    '\n'
    '\t/** Set the RAIL owner of a surface.\n'
    '\t */\n'
    '\tvoid (*set_window_owner)(struct weston_surface *surface,\n'
    '\t\t\t\t struct weston_surface *owner);\n'
    '\n'
    '\t/** Update the RAIL visibility of a surface.\n'
    '\t */\n'
    '\tvoid (*set_window_visible)(struct weston_surface *surface,\n'
    '\t\t\t\t   bool visible);\n'
    + E7 + '\n'
    '\tvoid (*notify_popup_state)(struct weston_surface *surface, bool mapped);\n'
    + G7 + ' pr-172',
    '\t/** Set the RAIL owner of a surface.\n'
    '\t */\n'
    '\tvoid (*set_window_owner)(struct weston_surface *surface,\n'
    '\t\t\t\t struct weston_surface *owner);\n'
    '\n'
    '\t/** Update the RAIL visibility of a surface.\n'
    '\t */\n'
    '\tvoid (*set_window_visible)(struct weston_surface *surface,\n'
    '\t\t\t\t   bool visible);\n'
    '\n'
    '\t/** Notify popup state change.\n'
    '\t */\n'
    '\tvoid (*notify_popup_state)(struct weston_surface *surface, bool mapped);',
    'backend-rdp.h')

resolve('libweston/backend-rdp/rdprail.c',
    M7 + ' HEAD\n'
    '\t\tif (state_fields & WINDOW_ORDER_FIELD_SHOW) {\n'
    + E7 + '\n'
    '\t\tif (rail_state->showState != rail_state->showState_requested) {\n'
    '\t\t\trdp_rail_notify_window_zorder_change(compositor);\n'
    '\t\t\tif (!rdp_rail_flush_window_zorder(b))\n'
    '\t\t\t\treturn 0;\n'
    + G7 + ' pr-172',
    '\t\tif (state_fields & WINDOW_ORDER_FIELD_SHOW) {\n'
    '\t\t\trdp_rail_notify_window_zorder_change(compositor);\n'
    '\t\t\tif (!rdp_rail_flush_window_zorder(b))\n'
    '\t\t\t\treturn 0;',
    'rdprail.c')
PY
if grep -rEn '^(<{7} |>{7} )' include/libweston/backend-rdp.h libweston/backend-rdp/rdprail.c; then
  die "冲突解决后仍有冲突标记"
fi
if git diff --name-only --diff-filter=U | grep -q .; then
  git add include/libweston/backend-rdp.h libweston/backend-rdp/rdprail.c
  git commit -q --no-edit -m "Merge pr-172 with conflict resolution (backend-rdp.h + rdprail.c)"
fi
# #172 对 tests/meson.build 的改动（文件头插入两个测试）被 ours 策略丢弃，补回
python3 - <<PY
$PYHELPERS
s, crlf = load('tests/meson.build')
if "foreach name : ['popup-constraint', 'window-state-sync']" not in s:
    s = ("foreach name : ['popup-constraint', 'window-state-sync']\n"
         "\texe = executable('test-' + name, name + '-test.c',\n"
         "\t\tinclude_directories: common_inc, install: false)\n"
         "\ttest(name, exe)\n"
         "endforeach\n\n") + s
    save('tests/meson.build', s, crlf)
PY
git add tests/meson.build
git commit -q --no-edit -m "Fix: restore popup-constraint/window-state-sync test entries" || true
git tag -f state-4 >/dev/null

# ------------------------------- 修复 #172：popup 无 buffer 判定（见 0005 补丁说明）
log "patch: surface.c width_from_buffer"
python3 - <<PY
import sys
$PYHELPERS
p = 'libweston-desktop/surface.c'
s, crlf = load(p)
for old, new in [
    ("\t\tif (surface->popup_mapped && !surface->surface->buffer_ref.buffer) {",
     "\t\tif (surface->popup_mapped &&\n\t\t    surface->surface->width_from_buffer == 0) {"),
    ("\tif (surface->popup && !surface->popup_mapped &&\n\t    surface->surface->buffer_ref.buffer) {",
     "\tif (surface->popup && !surface->popup_mapped &&\n\t    surface->surface->width_from_buffer != 0) {"),
    ("\t\tif (surface && surface->popup &&\n\t\t    !child->view->surface->buffer_ref.buffer)\n\t\t\tcontinue;",
     "\t\tif (surface && surface->popup &&\n\t\t    child->view->surface->width_from_buffer == 0)\n\t\t\tcontinue;"),
]:
    if old not in s:
        sys.exit('ERROR: surface.c 中找不到 #172 的目标代码（PR 可能已更新）:\n' + old)
    s = s.replace(old, new, 1)
save(p, s, crlf)
PY
grep -q "buffer_ref" libweston-desktop/surface.c && die "surface.c 仍残留 buffer_ref 判定"
git add libweston-desktop/surface.c
git commit -q --no-edit -m "Fix #172: detect bufferless popup commits via width_from_buffer"
git tag -f state-5 >/dev/null

# ------------------------------- xdg_popup 的 RAIL owner 设为父窗口（见 0006 补丁说明）
log "patch: xdg_popup RAIL owner"
python3 - <<PY
import sys
$PYHELPERS
def patch(path, old, new):
    s, crlf = load(path)
    if old not in s:
        sys.exit('ERROR: %s 中找不到目标代码（上游/PR 可能已更新）:\n%s' % (path, old))
    save(path, s.replace(old, new, 1), crlf)

patch('libweston-desktop/surface.c',
      "struct weston_desktop_surface *\n"
      "weston_desktop_surface_get_parent(struct weston_desktop_surface *surface)\n",
      "WL_EXPORT struct weston_desktop_surface *\n"
      "weston_desktop_surface_get_parent(struct weston_desktop_surface *surface)\n")

patch('include/libweston-desktop/libweston-desktop.h',
      "struct weston_surface *\n"
      "weston_desktop_surface_get_surface(struct weston_desktop_surface *surface);\n",
      "struct weston_surface *\n"
      "weston_desktop_surface_get_surface(struct weston_desktop_surface *surface);\n"
      "struct weston_desktop_surface *\n"
      "weston_desktop_surface_get_parent(struct weston_desktop_surface *surface);\n")

patch('rdprail-shell/shell.c',
      "static void\n"
      "desktop_popup_state_changed(struct weston_desktop_surface *desktop_surface,\n"
      "\t\t\t    bool mapped, void *data)\n"
      "{\n"
      "\tstruct desktop_shell *shell = data;\n"
      "\n"
      "\tif (shell->rdprail_api->notify_popup_state)\n"
      "\t\tshell->rdprail_api->notify_popup_state(\n"
      "\t\t\tweston_desktop_surface_get_surface(desktop_surface), mapped);\n"
      "}\n",
      "static void\n"
      "desktop_popup_state_changed(struct weston_desktop_surface *desktop_surface,\n"
      "\t\t\t    bool mapped, void *data)\n"
      "{\n"
      "\tstruct desktop_shell *shell = data;\n"
      "\tstruct weston_surface *surface =\n"
      "\t\tweston_desktop_surface_get_surface(desktop_surface);\n"
      "\n"
      "\t/* Keep popups in their parent's RAIL owner tree: Windows raises the\n"
      "\t * whole owner tree when it activates an owned window (e.g. the input\n"
      "\t * panel owned by the toplevel), so an unowned popup would be covered\n"
      "\t * by its own toplevel. */\n"
      "\tif (mapped && shell->rdprail_api->set_window_owner) {\n"
      "\t\tstruct weston_desktop_surface *parent =\n"
      "\t\t\tweston_desktop_surface_get_parent(desktop_surface);\n"
      "\n"
      "\t\tif (parent) {\n"
      "\t\t\tstruct weston_surface *owner =\n"
      "\t\t\t\tweston_surface_get_main_surface(\n"
      "\t\t\t\t\tweston_desktop_surface_get_surface(parent));\n"
      "\n"
      "\t\t\tif (owner && owner != surface)\n"
      "\t\t\t\tshell->rdprail_api->set_window_owner(surface, owner);\n"
      "\t\t}\n"
      "\t}\n"
      "\n"
      "\tif (shell->rdprail_api->notify_popup_state)\n"
      "\t\tshell->rdprail_api->notify_popup_state(surface, mapped);\n"
      "}\n")
PY
git add include/libweston-desktop/libweston-desktop.h libweston-desktop/surface.c rdprail-shell/shell.c
git commit -q --no-edit -m "rdprail-shell: give xdg_popup RAIL windows their parent as owner"
git tag -f state-6 >/dev/null

# ------------------- rdpclip: 剪贴板数据响应改在 compositor 线程注册 fd（见 0007 补丁说明）
log "patch: rdpclip data response on compositor thread"
python3 - <<PY
import sys
$PYHELPERS
def patch(path, old, new):
    s, crlf = load(path)
    if old not in s:
        sys.exit('ERROR: %s 中找不到目标代码（上游/PR 可能已更新）:\n%s' % (path, old))
    save(path, s.replace(old, new, 1), crlf)

# clipboard_data_source_write(): 显式断言 event source 已设置；对端已关闭管道时直接放弃
patch('libweston/backend-rdp/rdpclip.c',
      "\tassert(source->data_source_fd == fd);\n"
      "\t/* this data source must be tracked as inflight */\n"
      "\tassert(source == ctx->clipboard_inflight_client_data_source);\n"
      "\n"
      "\tif (source->is_canceled) {\n",
      "\tassert(source->data_source_fd == fd);\n"
      "\t/* this data source must be tracked as inflight */\n"
      "\tassert(source == ctx->clipboard_inflight_client_data_source);\n"
      "\t/* the event source is always registered from the compositor thread, so it\n"
      "\t   is set before this callback can possibly run; it's removed below. */\n"
      "\tassert(source->transfer_event_source);\n"
      "\n"
      "\tif (source->is_canceled) {\n")

patch('libweston/backend-rdp/rdpclip.c',
      "\t\tgoto fail;\n"
      "\t}\n"
      "\n"
      "\tif (!source->data_contents.data || !source->data_contents.size) {\n",
      "\t\tgoto fail;\n"
      "\t}\n"
      "\n"
      "\tif (mask & (WL_EVENT_ERROR | WL_EVENT_HANGUP)) {\n"
      "\t\t/* The requesting application already closed its end of the pipe,\n"
      "\t\t   e.g. the clipboard manager drops its pipe as soon as another\n"
      "\t\t   selection comes in while our request to the client is still\n"
      "\t\t   outstanding. write() could only fail with EPIPE (and raise\n"
      "\t\t   SIGPIPE), so give up right away. */\n"
      "\t\tsource->state = RDP_CLIPBOARD_SOURCE_FAILED;\n"
      "\t\tweston_log(\"RDP %s (%p:%s) requester closed the pipe, mask:0x%x\\\\n\",\n"
      "\t\t\t   __func__, source,\n"
      "\t\t\t   clipboard_data_source_state_to_string(source), mask);\n"
      "\t\tgoto fail;\n"
      "\t}\n"
      "\n"
      "\tif (!source->data_contents.data || !source->data_contents.size) {\n")

# 新增 compositor 线程任务 clipboard_data_source_received()，接在 _write() 之后
patch('libweston/backend-rdp/rdpclip.c',
      "\tctx->clipboard_inflight_client_data_source = NULL;\n"
      "\tclipboard_data_source_unref(source);\n"
      "\n"
      "\treturn 0;\n"
      "}\n",
      "\tctx->clipboard_inflight_client_data_source = NULL;\n"
      "\tclipboard_data_source_unref(source);\n"
      "\n"
      "\treturn 0;\n"
      "}\n"
      "\n"
      "/* client's reply with data for data request, start sending it to the\n"
      " * requesting application at server side */\n"
      "static void\n"
      "clipboard_data_source_received(bool freeOnly, void *arg)\n"
      "{\n"
      "\tstruct rdp_clipboard_data_source *source = wl_container_of(arg, source, task_base);\n"
      "\tfreerdp_peer *client = (freerdp_peer *)source->context;\n"
      "\tRdpPeerContext *ctx = (RdpPeerContext *)client->context;\n"
      "\tstruct rdp_backend *b = ctx->rdpBackend;\n"
      "\tstruct wl_event_loop *loop = wl_display_get_event_loop(b->compositor->wl_display);\n"
      "\n"
      "\trdp_debug_clipboard(b, \"RDP %s (%p:%s) fd:%d\\\\n\", __func__,\n"
      "\t\t\t    source,\n"
      "\t\t\t    clipboard_data_source_state_to_string(source),\n"
      "\t\t\t    source->data_source_fd);\n"
      "\n"
      "\tassert_compositor_thread(b);\n"
      "\n"
      "\t/* this data source must be tracked as inflight */\n"
      "\tassert(source == ctx->clipboard_inflight_client_data_source);\n"
      "\t/* transfer event source must not be set */\n"
      "\tassert(source->transfer_event_source == NULL);\n"
      "\t/* data has not been sent to write() yet, thus must be no inflight write. */\n"
      "\tassert(source->inflight_write_count == 0);\n"
      "\tassert(source->inflight_data_to_write == NULL);\n"
      "\tassert(source->inflight_data_size == 0);\n"
      "\n"
      "\tif (freeOnly) {\n"
      "\t\t/* peer context is going away, data is never going to be sent. */\n"
      "\t\tsource->state = RDP_CLIPBOARD_SOURCE_FAILED;\n"
      "\t\tgoto error_exit;\n"
      "\t}\n"
      "\n"
      "\t/* The event source must be added from the compositor thread: epoll\n"
      "\t * reports EPOLLERR/EPOLLHUP regardless of the requested mask, so if the\n"
      "\t * requesting application already closed its end of the pipe the write\n"
      "\t * callback runs as soon as the fd is registered, and it expects\n"
      "\t * transfer_event_source to be set by then. Registering from the\n"
      "\t * FreeRDP thread let the callback race with that store and call\n"
      "\t * wl_event_source_remove(NULL). */\n"
      "\tif (rdp_event_loop_add_fd(loop, source->data_source_fd, WL_EVENT_WRITABLE,\n"
      "\t\t\t\t  clipboard_data_source_write, source,\n"
      "\t\t\t\t  &source->transfer_event_source))\n"
      "\t\treturn;\n"
      "\n"
      "\tsource->state = RDP_CLIPBOARD_SOURCE_FAILED;\n"
      "\tweston_log(\"RDP %s (%p:%s) rdp_event_loop_add_fd failed\\\\n\",\n"
      "\t\t   __func__, source,\n"
      "\t\t   clipboard_data_source_state_to_string(source));\n"
      "\n"
      "error_exit:\n"
      "\t/* close fd to let the requesting application know there is no data. */\n"
      "\tclose(source->data_source_fd);\n"
      "\tsource->data_source_fd = -1;\n"
      "\t/* clear inflight data source from client to server. */\n"
      "\tctx->clipboard_inflight_client_data_source = NULL;\n"
      "\tclipboard_data_source_unref(source);\n"
      "}\n")

# clipboard_client_format_data_response()（FreeRDP 线程）：不再直接注册 fd，改为派发任务
patch('libweston/backend-rdp/rdpclip.c',
      "\tstruct wl_event_loop *loop = wl_display_get_event_loop(b->compositor->wl_display);\n"
      "\tstruct rdp_clipboard_data_source *source = ctx->clipboard_inflight_client_data_source;\n"
      "\tbool success = false;\n"
      "\tbool ret;\n",
      "\tstruct rdp_clipboard_data_source *source = ctx->clipboard_inflight_client_data_source;\n"
      "\tbool success = false;\n")

patch('libweston/backend-rdp/rdpclip.c',
      "\tif (source->transfer_event_source || (source->inflight_write_count != 0)) {\n"
      "\t\t/* here means client responded more than once for single data request */\n"
      "\t\tsource->state = RDP_CLIPBOARD_SOURCE_FAILED;\n"
      "\t\tweston_log(\"Client: %s (%p:%s) middle of write loop:%p, %d\\\\n\",\n"
      "\t\t\t   __func__, source, clipboard_data_source_state_to_string(source),\n"
      "\t\t\t   source->transfer_event_source, source->inflight_write_count);\n"
      "\t\treturn -1;\n"
      "\t}\n",
      "\t/* A response is only expected while the request is outstanding (or\n"
      "\t   canceled while outstanding). Anything else means the client responded\n"
      "\t   more than once for a single data request: either the previous response\n"
      "\t   is still queued for the compositor thread, or it's already being\n"
      "\t   written to the requesting application. */\n"
      "\tif (source->transfer_event_source || (source->inflight_write_count != 0) ||\n"
      "\t    (source->state != RDP_CLIPBOARD_SOURCE_REQUEST_DATA &&\n"
      "\t     source->state != RDP_CLIPBOARD_SOURCE_CANCEL_PENDING)) {\n"
      "\t\tweston_log(\"Client: %s (%p:%s) unexpected response, middle of write loop:%p, %d\\\\n\",\n"
      "\t\t\t   __func__, source, clipboard_data_source_state_to_string(source),\n"
      "\t\t\t   source->transfer_event_source, source->inflight_write_count);\n"
      "\t\tsource->state = RDP_CLIPBOARD_SOURCE_FAILED;\n"
      "\t\treturn -1;\n"
      "\t}\n")

patch('libweston/backend-rdp/rdpclip.c',
      "\tassert(source->transfer_event_source == NULL);\n"
      "\tif (success) {\n"
      "\t\tret = rdp_event_loop_add_fd(loop, source->data_source_fd, WL_EVENT_WRITABLE,\n"
      "\t\t\t\t\t    clipboard_data_source_write,\n"
      "\t\t\t\t\t    source, &source->transfer_event_source);\n"
      "\t\tif (!ret) {\n"
      "\t\t\tsource->state = RDP_CLIPBOARD_SOURCE_FAILED;\n"
      "\t\t\tweston_log(\"Client: %s (%p:%s) rdp_event_loop_add_fd failed\\\\n\",\n"
      "\t\t\t\t   __func__, source, clipboard_data_source_state_to_string(source));\n"
      "\t\t\treturn -1;\n"
      "\t\t}\n"
      "\t} else {\n"
      "\t\trdp_dispatch_task_to_display_loop(ctx, clipboard_data_source_fail, &source->task_base);\n"
      "\t}\n",
      "\tassert(source->transfer_event_source == NULL);\n"
      "\t/* Hand over to the compositor thread in both cases. The event loop is\n"
      "\t   not thread safe, and in particular the fd must not be registered from\n"
      "\t   here: see clipboard_data_source_received(). */\n"
      "\trdp_dispatch_task_to_display_loop(ctx,\n"
      "\t\t\t\t\t  success ? clipboard_data_source_received\n"
      "\t\t\t\t\t\t  : clipboard_data_source_fail,\n"
      "\t\t\t\t\t  &source->task_base);\n")

# rdp_event_loop_add_fd(): 写明只能在 compositor 线程调用及原因
patch('libweston/backend-rdp/rdputil.c',
      "bool\n"
      "rdp_event_loop_add_fd(struct wl_event_loop *loop, int fd, uint32_t mask, wl_event_loop_fd_func_t func, void *data, struct wl_event_source **event_source)\n"
      "{\n",
      "/* Must be called from the compositor (display loop) thread only.\n"
      " *\n"
      " * The fd is registered with an empty mask first so that *event_source is\n"
      " * already stored when the mask is enabled and the callback can fire. That\n"
      " * only holds on the thread running the loop: epoll reports EPOLLERR/EPOLLHUP\n"
      " * regardless of the mask, so from any other thread the callback could run\n"
      " * between wl_event_loop_add_fd() and the store. FreeRDP thread code must go\n"
      " * through rdp_dispatch_task_to_display_loop() instead. */\n"
      "bool\n"
      "rdp_event_loop_add_fd(struct wl_event_loop *loop, int fd, uint32_t mask, wl_event_loop_fd_func_t func, void *data, struct wl_event_source **event_source)\n"
      "{\n")
PY
grep -q "clipboard_data_source_received" libweston/backend-rdp/rdpclip.c || die "rdpclip.c 缺少 clipboard_data_source_received"
git add libweston/backend-rdp/rdpclip.c libweston/backend-rdp/rdputil.c
git commit -q --no-edit -m "rdp-backend: register clipboard response fd on the compositor thread"
git tag -f state-7 >/dev/null

# ------------------- rdprail-shell: 丢弃过期的工作区（见 0008 补丁说明）
log "patch: ignore stale desktop work area"
python3 - <<PY
import sys
$PYHELPERS
def patch(path, old, new):
    s, crlf = load(path)
    if old not in s:
        sys.exit('ERROR: %s 中找不到目标代码（上游/PR 可能已更新）:\n%s' % (path, old))
    save(path, s.replace(old, new, 1), crlf)

patch('rdprail-shell/shell.c',
      "\tif (shell_output) {\n"
      "\t\tstruct shell_workarea_change workarea_change;\n"
      "\t\tworkarea_change.output = output;\n",
      "\tif (shell_output) {\n"
      "\t\tint64_t cx, cy;\n"
      "\n"
      "\t\t/* The backend re-sends the work area on every display topology\n"
      "\t\t * change and can send one that belongs to a previous layout:\n"
      "\t\t * with the 4K monitor powered off and on again, the client sent\n"
      "\t\t * the single monitor 1920x1080 work area for rdp-0 right after\n"
      "\t\t * the correct 3840x2112 one (observed 2026-10-15). Every popup\n"
      "\t\t * of that output is then clamped into the stale rectangle by\n"
      "\t\t * weston_desktop_surface_constrain_popup() and ends up far away\n"
      "\t\t * from its parent window, e.g. pushed next to the window's left\n"
      "\t\t * edge or above the click point. Taskbars sit at the edges, so a\n"
      "\t\t * legitimate work area always contains the output's center;\n"
      "\t\t * reject anything else and keep the previous value. */\n"
      "\t\tcx = (int64_t)output->x + output->width / 2;\n"
      "\t\tcy = (int64_t)output->y + output->height / 2;\n"
      "\t\tif (workarea->width == 0 || workarea->height == 0 ||\n"
      "\t\t    cx < (int64_t)workarea->x ||\n"
      "\t\t    cx >= (int64_t)workarea->x + workarea->width ||\n"
      "\t\t    cy < (int64_t)workarea->y ||\n"
      "\t\t    cy >= (int64_t)workarea->y + workarea->height) {\n"
      "\t\t\tshell_rdp_debug(shell,\n"
      "\t\t\t\t\t\"%s: ignoring work area (%u,%u) %ux%u for output %s (%d,%d) %dx%d: it does not contain the output center\\\\n\",\n"
      "\t\t\t\t\t__func__,\n"
      "\t\t\t\t\tworkarea->x, workarea->y,\n"
      "\t\t\t\t\tworkarea->width, workarea->height,\n"
      "\t\t\t\t\toutput->name ? output->name : \"(unnamed)\",\n"
      "\t\t\t\t\toutput->x, output->y,\n"
      "\t\t\t\t\toutput->width, output->height);\n"
      "\t\t\treturn;\n"
      "\t\t}\n"
      "\n"
      "\t\tstruct shell_workarea_change workarea_change;\n"
      "\t\tworkarea_change.output = output;\n")
PY
grep -q "ignoring work area" rdprail-shell/shell.c || die "shell.c 缺少 work area 校验"
git add rdprail-shell/shell.c
git commit -q --no-edit -m "rdprail-shell: ignore desktop work areas that do not cover the output"
git tag -f state-8 >/dev/null

# ------------------------------------------------------------------ 0009：诊断
# 0009 是纯诊断代码（崩溃 backtrace + XWM 几何日志），全部由环境变量开关控制，
# 未配置时完全不执行。它在 0008 之上改动较大（新增 ~180 行），直接以补丁形式
# 应用，避免把大段文本再抄一遍；若将来基线升级导致无法套用，git apply 会失败并
# 由 set -e 中止，届时按提示调整即可。
log "应用 0009（诊断：崩溃 backtrace + XWM 几何日志）"
git apply --index "$here/0009-wslg-crash-and-xwm-geometry-trace.patch" \
  || die "0009 无法套用（基线可能已变化）"
grep -q "WSLG-XWM" xwayland/window-manager.c || die "0009 未生效（window-manager.c）"
grep -q "WSLG_CRASH_BT" compositor/main.c || die "0009 未生效（main.c）"
git commit -q --no-edit -m "diagnostics: opt-in crash backtrace and XWM geometry trace"
git tag -f state-9 >/dev/null

# ------------------------------------------------------------------ 校验合并结果
log "校验合并结果"
for m in TESTSUITE_TEXT_CONFIG_PATH exe_text_input_method_test TESTSUITE_INPUT_METHOD_ALLOW_CONFIG_PATH \
         "'name': 'input-method-bind'" TESTSUITE_RDPRAIL_INPUT_PANEL_CONFIG_PATH popup-constraint \
         window-state-sync "'rdpclip-fd'," "'rdprail-window-state.c'," "'rdpclip-fd.c',"; do
  grep -qF "$m" tests/meson.build || die "tests/meson.build 缺少 $m"
done
python3 - <<'PY'
s = open('tests/meson.build').read()
for a, b in (('(', ')'), ('[', ']')):
    if s.count(a) != s.count(b):
        raise SystemExit(f'ERROR: tests/meson.build 的 {a}{b} 不平衡')
PY
for f in $(git diff --name-only state-0 state-9); do
  if git show "state-9:$f" | grep -qE '^(<{7} |>{7} )'; then die "$f 含冲突标记"; fi
done

# ---------------------------------------------- 拆成线性补丁序列并写回本目录
log "生成线性补丁序列"
git branch -f linear state-0 && git checkout -q linear
# 固定作者与时间，使重复生成的补丁文件逐字节一致（只有内容变化时 diff 才有东西）
export GIT_AUTHOR_NAME=wslg-patches GIT_AUTHOR_EMAIL=patches@localhost
export GIT_COMMITTER_NAME=wslg-patches GIT_COMMITTER_EMAIL=patches@localhost
export GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000" GIT_COMMITTER_DATE="2026-01-01T00:00:00+0000"

stage() {  # stage <from-tag> <to-tag> <output-name> <<message
  git diff --binary "$1" "$2" | git apply --index
  git commit -q -F -
  [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse "$2^{tree}")" ] || die "stage $2 tree 不一致"
  git format-patch -q -1 --no-signature --no-numbered --zero-commit --stdout HEAD > "$here/$3.patch"
}

stage state-0 state-1 0001-weston-pr168-text-input-v3-bridge <<EOF
weston-mirror #168: bridge text-input-v3 to input-method-v1

Upstream PR:  https://github.com/microsoft/weston-mirror/pull/168
PR head:      $PR168
Merged onto:  $WESTON_BASE (working)

Lets clients that only implement zwp_text_input_v3 (GTK4, Qt6, JetBrains
Runtime, Chromium, ...) talk to an input-method-v1 provider such as fcitx5
running inside the WSL distro, instead of being limited to the RDP-side IME.
EOF

stage state-1 state-2 0002-weston-pr169-rdprail-input-panel <<EOF
weston-mirror #169: rdprail-shell input panel for external input methods

Upstream PR:  https://github.com/microsoft/weston-mirror/pull/169
PR head:      $PR169

Gives the external input method's candidate window a RAIL window of its
own, owned by the toplevel that holds the text_input focus.

Integration fixes bundled here (not part of the upstream PR):

- tests/meson.build: deterministic union of the #168 and #169 test
  registrations. Both PRs append adjacent entries to the same list, which
  git's 3-way merge cannot combine (and the built-in union driver
  interleaves the two sides and breaks the meson syntax).
- tests/meson.build: add rdprail-window-state.c to the test-rdp-teardown
  extract_objects list. rdprail.c now calls rdp_rail_prepare_window_state_
  order()/rdp_rail_send_window_state_order() defined in that new file, and
  \`ninja install\` builds the test executables, so without it the build
  fails with an undefined reference.
EOF

stage state-2 state-3 0003-weston-pr166-rdpclip-fd <<EOF
weston-mirror #166: rdp-backend keeps the active clipboard transfer fd

Upstream PR:  https://github.com/microsoft/weston-mirror/pull/166
PR head:      $PR166
Fixes:        microsoft/wslg#1407 (compositor crash on copy/paste, e.g. IDEA)

Integration fixes bundled here (not part of the upstream PR):

- tests/meson.build: restore the rdpclip-fd standalone test entry that the
  ort merge silently dropped (mid-list insert vs. end-of-list append).
- tests/meson.build: add rdpclip-fd.c to test-rdp-teardown's extract_objects.
  The upstream PR makes rdpclip.c call rdp_clipboard_take_fd() but forgot
  to add the new file to that list, so test-rdp-teardown fails to link.
EOF

stage state-3 state-4 0004-weston-pr172-popup-placement <<EOF
weston-mirror #172: rdp popup placement and window state synchronization

Upstream PR:  https://github.com/microsoft/weston-mirror/pull/172
PR head:      $PR172
Fixes:        microsoft/wslg#1439, #1265, #1299 (GTK4 popups / submenus)

Conflict resolution against #169 (bundled):

- include/libweston/backend-rdp.h: keep set_window_owner/set_window_visible
  from #169 and notify_popup_state from #172.
- libweston/backend-rdp/rdprail.c: keep #169's more precise
  \`state_fields & WINDOW_ORDER_FIELD_SHOW\` condition and put #172's
  z-order notify/flush inside it.
- tests/meson.build: re-add the popup-constraint / window-state-sync test
  entries that the merge driver discarded.
EOF

stage state-4 state-5 0005-popup-bufferless-commit-width-from-buffer <<'EOF'
libweston-desktop: detect bufferless popup commits via width_from_buffer

Follow-up to #172, which used surface->buffer_ref.buffer to decide whether
a popup commit carried a buffer (no buffer => unmap, and popup_unmapped is
sticky). libweston releases buffer_ref after every repaint of an SHM
surface (weston_output_repaint, backend without keep_buffer), so once the
popup had been drawn once, any later commit without a fresh attach — JBR's
frame-callback registration, set_window_geometry, ... — was taken as "no
buffer". The popup got unmapped, the client never received popup_done, and
IDEA menus / Ctrl+N dialogs flashed, vanished and kept eating keyboard
input invisibly (confirmed with WAYLAND_DEBUG, 2026-09-22).

width_from_buffer is only updated on wl_surface.attach and only becomes 0
on a NULL attach, which is the criterion we actually want.
EOF

stage state-5 state-6 0006-xdg-popup-rail-owner <<'EOF'
rdprail-shell: give xdg_popup RAIL windows their parent as owner

#169 makes the input panel a RAIL window owned by the toplevel holding the
text_input (JBR binds text-input on the toplevel). Windows raises the whole
owner tree when it activates an owned window, so an xdg_popup without an
owner (rdprail.c only sets one for wl_subsurface) drops behind its own
toplevel the instant the fcitx5 candidate window appears: the Ctrl+N popup
"disappears" and comes back when the candidate window closes and weston
resends the Z order. weston's own Z order and views are correct throughout;
the problem is purely on the Windows side.

Fix: when a popup is mapped (popup_state_changed hook from #172), set its
RAIL owner to its parent xdg surface via #169's set_window_owner.
weston_desktop_surface_get_parent() was only declared in internal.h and is
now exported for shell plugins.
EOF

stage state-6 state-7 0007-rdpclip-data-response-on-compositor-thread <<'EOF'
rdp-backend: register clipboard response fd on the compositor thread

Fixes the intermittent weston SIGSEGV in wl_event_source_remove() (RDI=0,
"segfault at 28 ... in libwayland-server.so") seen after copying in a
Wayland client such as IntelliJ IDEA, which took the whole WSLg session
down. It still occurred with #166 (patch 0003) applied.

clipboard_client_format_data_response() runs on the FreeRDP thread. When
the Windows side answered a data request it called rdp_event_loop_add_fd()
right there, i.e. registered the requester's pipe fd in the compositor's
wl_event_loop from the wrong thread. epoll reports EPOLLERR/EPOLLHUP no
matter which mask was requested, so if the requesting application had
already closed its read end the compositor thread woke up inside the
epoll_ctl(ADD) and ran clipboard_data_source_write() before the FreeRDP
thread had stored the new wl_event_source into transfer_event_source; the
callback then called wl_event_source_remove(NULL).

"Reader already gone" is the normal case, not a corner case: libweston's
clipboard manager requests the data of every new selection through a pipe
and unrefs (closes) that pipe as soon as the next selection arrives, and
with WSLg the next selection arrives all the time -- the Windows side
re-publishes a Linux copy about a second later (twice, ~15 ms apart), and
fcitx5's X11 clipboard monitor requests every selection too. Each of those
left a Windows data request outstanding on a pipe nobody reads any more,
and every response to it entered the race; whether it crashed depended on
the scheduler preempting the FreeRDP thread at syscall exit.

Fix: the response handler only caches the data (the PDU buffer is only
valid during the callback) and hands over to the compositor thread with
rdp_dispatch_task_to_display_loop(), like the failure path already did.
The new clipboard_data_source_received() task registers the fd there, so
transfer_event_source is always set before the write callback can run.
clipboard_data_source_write() now also gives up straight away when the fd
is reported with WL_EVENT_ERROR/HANGUP instead of write()ing into a pipe
without readers (EPIPE + SIGPIPE, which weston does not ignore), and the
duplicate-response check covers a response that is still queued for the
compositor thread.
EOF

stage state-7 state-8 0008-rdprail-shell-ignore-stale-workarea <<'EOF'
rdprail-shell: ignore desktop work areas that do not cover the output

Fixes misplaced context menus and other popups after a display topology
change. With an external 4K monitor powered off and on again, weston.log
shows the client sending three work areas in the same moment:

  [14:02:07.383] workArea (0,0)-(3840,2112) at rdp-0        correct
  [14:02:07.383] workArea (3840,534)-(5760,1566) at rdp-3   correct
  [14:02:07.441] workArea (0,0)-(1920,1080) at rdp-0        stale (58 ms later)

The stale rectangle is the work area of the single monitor layout the
desktop had while the 4K monitor was off. It was stored for rdp-0 and
never corrected, so from then on every popup of that output was clamped
into 1920x1080 by weston_desktop_surface_constrain_popup(): a menu in a
window at x=1920 got slid to x = -menu_width (its right edge at the
window's left edge, i.e. outside the window), and a right click near the
bottom of the window got slid up to y = 1080 - menu_height. Taskbars sit
at the edges, so a legitimate work area always contains the output's
center; anything else is now ignored, which keeps the previously stored
(or initial, full-output) work area.

Reproduced and verified by pressing Win+P on the Windows side, which makes
the client resend the layout: the correct (0,0)-(3840,2112) arrived and
the menus were placed correctly again.
EOF

tree=$(git rev-parse 'HEAD^{tree}')
sed -i "s/^EXPECTED_TREE=.*/EXPECTED_TREE=$tree/" "$here/series.conf"

stage state-8 state-9 0009-wslg-crash-and-xwm-geometry-trace <<'EOF'
diagnostics: opt-in crash backtrace and XWM geometry trace

weston has no handler for fatal signals and (in WSLg) is not dumpable, so
when it dies of SIGSEGV the only evidence is a single dmesg line, which
made the "weston dies inside libpixman (sse2_blt) while drawing a client
window decoration" crash very hard to pin down.

Adds two opt-in diagnostics, both inert unless the matching environment
variable is set (in WSLg: %USERPROFILE%\.wslgconfig, section
[system-distro-env]):

  WESTON_WSLG_CRASH_BT=1
      handler for SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE that appends the
      signal, fault address, general purpose registers and a backtrace to
      WESTON_WSLG_CRASH_BT_FILE (default /mnt/wslg/weston-crash.log), then
      re-raises the signal with the default disposition.

  WESTON_WSLG_TRACE_XWM=1
      log every case where the size handed to cairo_xcb_surface_set_size()
      differs from the frame drawable's real geometry.
EOF

echo
log "完成。补丁已写入 $here，EXPECTED_TREE=$tree"
log "请检查 'git -C $here/../.. status' 与 diff，确认后提交 patches/weston/"
