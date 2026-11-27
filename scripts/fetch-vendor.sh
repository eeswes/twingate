#!/bin/sh
# 拉取并固定 TwinGate 使用的上游版本。可重复执行。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VENDOR="$ROOT/vendor"

# 已验证可构建的提交（2026-11-21）
# TwinGate 默认使用 0.9 LTS：不需要 OpenSSL 开发库，在 Android/bionic 下更容易构建。
PROXY_LTS_COMMIT=4f7a611cbe24c6a4f3249b7557fc600c4dd020a6
PROXY_MASTER_COMMIT=8b298657ce53f70d926572d5f215a100c3fb930d
TTP_COMMIT=24f055f4acc9c3cb51e372fb31935a5c04acad41
BEARSSL_COMMIT=7bea48e5e850ab4cafbe68d3765cdaba13a86d6f

# 目录准备：所有上游走同一套逻辑（3proxy / ttp / BearSSL 没有例外）。
#
# 用 -e 而不是 -d 判断 .git：BearSSL 是 ttp 的 git 子模块，子模块目录里的 .git
# 是一个文件（指向 .git/modules/...），-d 会误判成"没拉过"，然后 git clone 到
# 一个非空目录上直接失败。
prepare_dir() {
    _pd_dir=$1
    [ -e "$_pd_dir/.git" ] && return 0
    if [ -d "$_pd_dir" ] && [ -n "$(ls -A "$_pd_dir" 2>/dev/null)" ]; then
        # 目录在但不是 git 仓库：多半是上次中断留下的半成品。
        # vendor/ 完全可再生，清掉重拉比在这里猜更可靠。
        echo "[vendor] 清理残留目录（不是 git 仓库）: $_pd_dir"
        rm -rf "$_pd_dir"
    fi
    return 0
}

clone_or_update() {
    url=$1 dir=$2 commit=$3
    prepare_dir "$dir"
    if [ -e "$dir/.git" ]; then
        echo "[vendor] 已存在: $dir"
    else
        echo "[vendor] 克隆 $url -> $dir"
        mkdir -p "$(dirname -- "$dir")"
        git clone --depth 1 "$url" "$dir"
    fi
    if ! (
        cd "$dir"
        # 浅克隆可能没有目标 commit 时再抓取一次
        git cat-file -e "${commit}^{commit}" 2>/dev/null || git fetch --depth 1 origin "$commit"
        git checkout --detach "$commit"
    ); then
        echo "[vendor] $dir 无法切换到 $commit（网络问题，或该 commit 已不存在）" >&2
        return 1
    fi
}

mkdir -p "$VENDOR"

# 注意：ttp 的 BearSSL 子模块来自 bearssl.org，不总是能从 GitHub 镜像取到，
# 因此这里手动克隆，避开部分环境下 git-submodule 辅助脚本缺失的问题。
# 但它和 3proxy / ttp 走的是同一个 clone_or_update：判断、清理、切 commit 都一样。
clone_or_update https://github.com/3proxy/3proxy.git "$VENDOR/3proxy-lts" "$PROXY_LTS_COMMIT"
# master(1.0) 作为可选参考保留；TwinGate 默认不依赖它（需要 OpenSSL 开发库）。
if [ "${TWIN_FETCH_MASTER:-0}" = 1 ]; then
    clone_or_update https://github.com/3proxy/3proxy.git "$VENDOR/3proxy" "$PROXY_MASTER_COMMIT"
fi
clone_or_update https://github.com/Theldus/ttp.git "$VENDOR/ttp" "$TTP_COMMIT"
clone_or_update https://www.bearssl.org/git/BearSSL "$VENDOR/ttp/BearSSL" "$BEARSSL_COMMIT"

# 拉完立刻打本地补丁并校验：checkout 出来的始终是干净上游，改动静默丢失太隐蔽。
# 校验不过直接失败——继续下去只会产出一个"看起来正常但少了 NODELAY 和会话复用"的二进制。
. "$ROOT/scripts/vendor-patch.sh"
if ! twin_vendor_patch_all "$ROOT"; then
    echo "[vendor] 补丁未就绪，已停止。" >&2
    exit 1
fi

echo "[vendor] 完成。提交："
echo "  3proxy(0.9 LTS) $PROXY_LTS_COMMIT"
echo "  ttp             $TTP_COMMIT"
echo "  BearSSL         $BEARSSL_COMMIT"
