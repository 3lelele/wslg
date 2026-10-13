#!/bin/bash
# 准备 vendor/weston：检出固定的上游基线提交，再套用本目录的补丁序列。
#
# 用法: ./patches/weston/apply.sh [目标目录，默认 vendor/weston]
#
#   目标目录不存在      → 克隆 microsoft/weston-mirror 的 working 分支，检出 WESTON_BASE
#   已存在且工作区干净  → 检出 WESTON_BASE（本地没有该提交时自动 fetch），套用补丁
#   补丁已套用          → 直接跳过（幂等，可重复运行）
#   有来历不明的改动    → 报错退出，不碰任何文件
#
# 补丁用 git apply --index 套用，不产生提交：HEAD 始终停在上游基线提交上，
# 这样 build-and-export.sh 写进 /etc/versions.txt 的 WESTON_COMMIT 仍是能在
# 上游查到的提交；"套用了哪些补丁"由 wslg 仓库本身的提交记录决定。
#
# 套用完成后用 `git write-tree` 与 series.conf 里的 EXPECTED_TREE 比对，
# 补丁缺失、顺序错乱或基线不对都会在这里被拦下并自动回滚。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=series.conf
. "$here/series.conf"

dest=${1:-$here/../../vendor/weston}

log() { echo "[weston-patches] $*"; }
die() { echo "[weston-patches] ERROR: $*" >&2; exit 1; }
g()   { git -C "$dest" "$@"; }

if [ -e "$dest" ] && [ ! -d "$dest/.git" ]; then
  die "$dest 已存在但不是 git 仓库（tarball 解压的？）。请删除后重试，或手动套用 $here/*.patch"
fi

if [ ! -d "$dest/.git" ]; then
  log "克隆 $WESTON_REPO ($WESTON_BRANCH) → $dest"
  git clone --single-branch -b "$WESTON_BRANCH" "$WESTON_REPO" "$dest"
fi

# 幂等：HEAD 在基线上、index 的 tree 已是期望值且工作区干净 → 什么都不用做
if [ "$(g rev-parse HEAD)" = "$WESTON_BASE" ] \
   && [ "$(g write-tree)" = "$EXPECTED_TREE" ] && g diff --quiet; then
  log "补丁已套用（tree ${EXPECTED_TREE:0:12}），跳过"
  exit 0
fi

# 其余情况要求工作区与 index 都干净，避免把用户的本地改动卷进去或覆盖掉
if ! g diff --quiet || ! g diff --cached --quiet; then
  die "$dest 有未提交的改动。请先执行:
    git -C '$dest' reset --hard && git -C '$dest' clean -fd
  或者直接删除该目录，然后重新运行本脚本"
fi

if [ "$(g rev-parse HEAD)" != "$WESTON_BASE" ]; then
  if ! g cat-file -e "$WESTON_BASE^{commit}" 2>/dev/null; then
    log "本地没有基线提交 ${WESTON_BASE:0:12}，fetch $WESTON_BRANCH…"
    g fetch origin "$WESTON_BRANCH"
    g cat-file -e "$WESTON_BASE^{commit}" 2>/dev/null \
      || die "基线提交 $WESTON_BASE 不在 $WESTON_REPO 的 $WESTON_BRANCH 分支上，请检查 series.conf"
  fi
  g checkout -q --detach "$WESTON_BASE"
fi

log "基线 $(g rev-parse --short HEAD) ($(g log -1 --format=%s | cut -c1-60))"
n=0
for p in "$here"/*.patch; do
  n=$((n + 1))
  log "  套用 $(basename "$p")"
  if ! g apply --index "$p"; then
    g reset -q --hard
    die "套用 $(basename "$p") 失败，已回滚到基线。基线被改动过？请检查 series.conf 与补丁是否匹配"
  fi
done

tree=$(g write-tree)
if [ "$tree" != "$EXPECTED_TREE" ]; then
  g reset -q --hard
  die "套用后 tree=$tree 与期望 $EXPECTED_TREE 不符，已回滚。补丁或 series.conf 可能被改动，请运行 regenerate.sh 重新生成"
fi
log "完成：$n 个补丁已套用，tree ${tree:0:12} 校验通过"
