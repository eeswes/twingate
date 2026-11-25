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

clone_or_update() {
    url=$1 dir=$2 commit=$3
    if [ -d "$dir/.git" ]; then
        echo "[vendor] 已存在: $dir"
    else
        echo "[vendor] 克隆 $url -> $dir"
        git clone --depth 1 "$url" "$dir"
    fi
    (
        cd "$dir"
        # 浅克隆可能没有目标 commit 时再抓取一次
        git cat-file -e "${commit}^{commit}" 2>/dev/null || git fetch --depth 1 origin "$commit"
        git checkout --detach "$commit"
    )
}

mkdir -p "$VENDOR"

# 注意：ttp 的 BearSSL 子模块来自 bearssl.org，不总是能从 GitHub 镜像取到，
# 因此这里手动克隆，避开部分环境下 git-submodule 辅助脚本缺失的问题。
clone_or_update https://github.com/3proxy/3proxy.git "$VENDOR/3proxy-lts" "$PROXY_LTS_COMMIT"
# master(1.0) 作为可选参考保留；TwinGate 默认不依赖它（需要 OpenSSL 开发库）。
[ "${TWIN_FETCH_MASTER:-0}" = 1 ] && \
    clone_or_update https://github.com/3proxy/3proxy.git "$VENDOR/3proxy" "$PROXY_MASTER_COMMIT"
clone_or_update https://github.com/Theldus/ttp.git "$VENDOR/ttp" "$TTP_COMMIT"
clone_or_update https://www.bearssl.org/git/BearSSL "$VENDOR/ttp/BearSSL" "$BEARSSL_COMMIT"

# 拉完立刻打本地补丁：checkout 出来的始终是干净上游，改动静默丢失太隐蔽。
. "$ROOT/scripts/vendor-patch.sh"
twin_vendor_patch_all "$ROOT" || echo "[vendor] 警告：本地补丁未应用，构建会再试一次" >&2

echo "[vendor] 完成。提交："
echo "  3proxy(0.9 LTS) $PROXY_LTS_COMMIT"
echo "  ttp             $TTP_COMMIT"
echo "  BearSSL         $BEARSSL_COMMIT"
