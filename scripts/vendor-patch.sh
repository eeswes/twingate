#!/bin/sh
# 给 vendor/ 下的上游源码打 TwinGate 的本地补丁。
#
# vendor/ 不入库（由 scripts/fetch-vendor.sh 按固定 commit 拉取），因此本地
# 修改不能直接改 vendor 里的文件：重新拉取就会丢。补丁存放在 vendor-patches/
# 随仓库分发，构建前幂等应用。
#
# 约定：补丁用 `git -C vendor/<dir> diff` 生成，统一 -p1 应用。
#
# 校验分三层，任何一层不过都算"补丁没打对"：
#   1. 文件完整性   vendor-patches/SHA256SUMS —— 补丁被截断/改坏时 patch 仍可能"成功"
#   2. 双向确认     反向 dry-run 必须成功（内容在源码里），正向 dry-run 必须失败
#                  （否则说明还能再打一遍，即上次没真正落盘）
#   3. 期望特征     <补丁>.expect 里列出的代码片段必须真的出现在源码里
# 重新生成 SHA256SUMS：sh scripts/vendor-patch.sh

twin_patch_bin() {
    command -v patch 2>/dev/null || true
}

# 补丁文件完整性校验（内容哈希固定下来）。返回 0 = 通过或无法校验。
twin_patch_checksum_verify() {
    _pc_root=$1
    _pc_sums="$_pc_root/vendor-patches/SHA256SUMS"
    [ -f "$_pc_sums" ] || return 0
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "[patch] 没有 sha256sum，跳过补丁文件完整性校验" >&2
        return 0
    fi
    # LC_ALL=C：否则中文/其它 locale 下输出是"成功/失败"，下面的 grep 过滤不掉。
    if (cd "$_pc_root/vendor-patches" && LC_ALL=C sha256sum -c SHA256SUMS) >/dev/null 2>&1; then
        return 0
    fi
    echo "[patch] 补丁文件校验失败：内容与 vendor-patches/SHA256SUMS 不符。" >&2
    (cd "$_pc_root/vendor-patches" && LC_ALL=C sha256sum -c SHA256SUMS 2>&1 | grep -vF ': OK' >&2) || :
    echo "[patch] 补丁被改动过、被截断，或仓库不完整。若是有意修改补丁，" >&2
    echo "[patch] 请重新生成哈希：sh scripts/vendor-patch.sh" >&2
    return 1
}

# 重新生成 vendor-patches/SHA256SUMS（补丁改了之后必须跑一次）。
twin_patch_write_sums() {
    _pw_root=$1
    _pw_dir="$_pw_root/vendor-patches"
    [ -d "$_pw_dir" ] || return 1
    command -v sha256sum >/dev/null 2>&1 || {
        echo "[patch] 没有 sha256sum，无法生成校验文件（Termux: pkg install coreutils）" >&2
        return 1
    }
    ( cd "$_pw_dir" && sha256sum ./*.patch ./*.expect 2>/dev/null > SHA256SUMS ) || return 1
    echo "[patch] 已更新 $_pw_dir/SHA256SUMS："
    sed 's/^/         /' "$_pw_dir/SHA256SUMS"
}

# 诊断：补丁里每个文件的 "+" 行有多少已经出现在源码里。
# 全命中 = 该文件已含补丁；一条都没中 = 没打；介于两者 = 打了一半（半打状态）。
# 半打最常见的原因是上一次手工 `git checkout -- 某个文件`，只还原了一部分。
twin_patch_file_states() {
    _pfs_patch=$1
    _pfs_where=$2
    awk -v where="$_pfs_where" '
        /^--- a\// { f = substr($0, 7); next }
        /^\+\+\+/  { next }
        /^\+/ && f != "" {
            pat = substr($0, 2)
            if (pat == "") next
            if (!(f in total)) { order[++n] = f; total[f] = 0; hit[f] = 0 }
            total[f]++
            file = where "/" f
            while ((getline line < file) > 0)
                if (index(line, pat) > 0) { hit[f]++; break }
            close(file)
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                if (hit[k] == total[k])  state = "已含补丁"
                else if (hit[k] == 0)    state = "未打补丁"
                else                     state = "部分匹配（多为半打）"
                printf "         %-20s %d/%d 条匹配  %s\n", k, hit[k], total[k], state
            }
        }
    ' "$_pfs_patch"
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
    echo "[patch] 各文件现状：" >&2
    twin_patch_file_states "$_vp_file" "$_vp_root/vendor/$_vp_dir" >&2
    echo "[patch] 补丁：$_vp_file" >&2
    echo "[patch] 若上游没变，多半是上次只还原了部分文件（半打状态）。修复：" >&2
    echo "[patch]   git -C \"$_vp_root/vendor/$_vp_dir\" checkout -- . 然后重新 make build" >&2
    return 1
}

# twin_vendor_patch_verify <项目根> <vendor 子目录> <补丁名>
# 不只是看 patch 的返回值：确认源码里真的有补丁内容，且不是"打了一半"。
twin_vendor_patch_verify() {
    _pv_root=$1
    _pv_dir=$2
    _pv_name=$3
    _pv_file="$_pv_root/vendor-patches/$_pv_name.patch"
    _pv_where="$_pv_root/vendor/$_pv_dir"

    [ -f "$_pv_file" ] || return 0
    [ -d "$_pv_where" ] || return 0

    _pv_patch=$(twin_patch_bin)
    [ -n "$_pv_patch" ] || return 1

    if ! (cd "$_pv_where" && "$_pv_patch" -p1 -R --dry-run -s -f) \
            < "$_pv_file" >/dev/null 2>&1; then
        echo "[patch] $_pv_name：校验失败——源码里没有完整的补丁内容" >&2
        echo "[patch] 各文件现状：" >&2
        twin_patch_file_states "$_pv_file" "$_pv_where" >&2
        return 1
    fi

    if (cd "$_pv_where" && "$_pv_patch" -p1 --dry-run -s -f) \
            < "$_pv_file" >/dev/null 2>&1; then
        echo "[patch] $_pv_name：校验失败——补丁还能再打一遍，说明上次没真正写入源码" >&2
        return 1
    fi

    _pv_expect="$_pv_root/vendor-patches/$_pv_name.expect"
    if [ -f "$_pv_expect" ]; then
        _pv_bad=0
        while IFS= read -r _pv_line || [ -n "$_pv_line" ]; do
            case "$_pv_line" in
                ''|'#'*) continue ;;
            esac
            _pv_f=${_pv_line%%:*}
            _pv_pat=${_pv_line#*:}
            if ! grep -q -F -e "$_pv_pat" "$_pv_where/$_pv_f" 2>/dev/null; then
                echo "[patch] $_pv_name：$_pv_f 里找不到期望的代码「$_pv_pat」" >&2
                _pv_bad=1
            fi
        done < "$_pv_expect"
        [ "$_pv_bad" = 0 ] || return 1
    fi

    echo "[patch] $_pv_name：校验通过"
    return 0
}

# 一次性打完全部已知补丁并逐个校验。新增补丁时在列表里追加（顺序有意义）。
twin_vendor_patch_all() {
    _vpa_root=$1
    _vpa_rc=0

    twin_patch_checksum_verify "$_vpa_root" || return 1

    # 会话缓存的补丁是基于「已打 NODELAY」的源码生成的，必须排在后面。
    for _vpa_item in "ttp:ttp-nodelay" "ttp:ttp-session-cache"; do
        _vpa_dir=${_vpa_item%%:*}
        _vpa_name=${_vpa_item#*:}
        if twin_vendor_patch "$_vpa_root" "$_vpa_dir" "$_vpa_name"; then
            twin_vendor_patch_verify "$_vpa_root" "$_vpa_dir" "$_vpa_name" || _vpa_rc=1
        else
            _vpa_rc=1
        fi
    done

    if [ "$_vpa_rc" != 0 ]; then
        echo "[patch] 补丁链未就绪：这样构建出来的二进制没有 TCP_NODELAY、也没有 TLS 会话复用。" >&2
        echo "[patch] 先确认 vendor/ 是按 scripts/fetch-vendor.sh 里的 commit 拉的；" >&2
        echo "[patch] 上游若已变更，需要按新源码重新生成 vendor-patches/*.patch 与 *.expect。" >&2
        return 1
    fi
    return 0
}

# 直接执行本文件 = 重新生成 SHA256SUMS（改了补丁之后跑一次）。
case "${0##*/}" in
    vendor-patch.sh)
        _vpw_self=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        twin_patch_write_sums "$(CDPATH= cd -- "$_vpw_self/.." && pwd)" || exit 1
        ;;
esac
