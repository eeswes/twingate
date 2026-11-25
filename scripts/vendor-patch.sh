#!/bin/sh
# 给 vendor/ 下的上游源码打 TwinGate 的本地补丁。
#
# vendor/ 不入库（由 scripts/fetch-vendor.sh 按固定 commit 拉取），因此本地
# 修改不能直接改 vendor 里的文件：重新拉取就会丢。补丁存放在 vendor-patches/
# 随仓库分发，构建前幂等应用。
#
# 约定：补丁用 `git -C vendor/<dir> diff` 生成，统一 -p1 应用。

twin_patch_bin() {
    command -v patch 2>/dev/null || true
}

# twin_vendor_patch <项目根> <vendor 子目录> <补丁名>
# 返回 0 = 已应用或无需应用；1 = 补丁打不上（上游变了）
twin_vendor_patch() {
    _vp_root=$1
    _vp_dir=$2
    _vp_name=$3
    _vp_file="$_vp_root/vendor-patches/$_vp_name.patch"

    [ -f "$_vp_file" ] || return 0
    [ -d "$_vp_root/vendor/$_vp_dir" ] || return 0

    _vp_patch=$(twin_patch_bin)
    if [ -z "$_vp_patch" ]; then
        echo "[patch] 缺少 patch 命令，$_vp_name 未应用（Termux: pkg install patch）" >&2
        return 1
    fi

    # 反向试打成功 = 已经在里面了，重复构建不再动它。
    if (cd "$_vp_root/vendor/$_vp_dir" && "$_vp_patch" -p1 -R --dry-run -s -f) \
            < "$_vp_file" >/dev/null 2>&1; then
        echo "[patch] $_vp_name：已应用"
        return 0
    fi

    if (cd "$_vp_root/vendor/$_vp_dir" && "$_vp_patch" -p1 --dry-run -s -f) \
            < "$_vp_file" >/dev/null 2>&1; then
        if (cd "$_vp_root/vendor/$_vp_dir" && "$_vp_patch" -p1 -s -f) \
                < "$_vp_file" >/dev/null 2>&1; then
            echo "[patch] $_vp_name：已应用"
            return 0
        fi
    fi

    echo "[patch] $_vp_name：打不上，上游源码可能已变更" >&2
    echo "[patch] 补丁：$_vp_file" >&2
    return 1
}

# 一次性打完全部已知补丁。新增补丁时在这里追加一行（顺序有意义）。
twin_vendor_patch_all() {
    _vpa_root=$1
    # 会话缓存的补丁是基于「已打 NODELAY」的源码生成的，必须排在后面。
    twin_vendor_patch "$_vpa_root" ttp ttp-nodelay || return 1
    twin_vendor_patch "$_vpa_root" ttp ttp-session-cache || return 1
    return 0
}
