#!/bin/sh
# TwinGate 进程生命周期辅助：重复启动拦截、遗留进程发现与清理。
#
# 为什么需要它：3proxy / ttp / tgmux 的 pid 只记录在 run/*.pid 里。若在已运行时
# 再启动一次，新进程会因端口被占而立刻退出，并把 pid 文件覆盖成这些"刚死掉"的 pid；
# 老进程还在监听却再也没有记录，于是 stop 杀不到、start 又抢不到端口——只能重启容器。
# 这里的 guard 让重复启动直接失败，sweep 让 stop/start 能回收这种遗留进程。
#
# 源码树：scripts/start.sh / scripts/stop.sh / scripts/tg-runtime.sh 通过 source 加载。
# 安装模式：scripts/install.sh 把本文件内嵌进单文件 twingate。
# 依赖 twin_init_paths 已执行；所有函数都接受显式传入的 run 目录，便于测试。

# pid 会被系统复用：上一条记录的进程早死了，同一个 pid 可能已经属于别的程序，
# 这时 kill -0 依然成功，pid 文件看起来"还活着"，于是 start 被永久拒绝。
# 能读到 /proc/<pid>/cmdline 就核对一下是不是我们的程序；读不到（无 /proc）按活着算。
twin_pid_is_ours() {
    _pp=$1
    _pname=$2
    [ -r "/proc/$_pp/cmdline" ] || return 0
    case "$_pname" in
        3proxy) _ppat=3proxy ;;
        tgmux)  _ppat=tgmux ;;
        ttp*)   _ppat=ttp ;;
        *)      return 0 ;;
    esac
    tr '\0' ' ' < "/proc/$_pp/cmdline" 2>/dev/null | grep -q -- "$_ppat"
}

# 仍存活的 pid 文件记录：每行 "name pid"。
twin_alive_pids() {
    _rd=${1:-${TWIN_RUN_DIR:-}}
    [ -n "$_rd" ] || return 0
    for _pf in "$_rd"/*.pid; do
        [ -f "$_pf" ] || continue
        _p=$(cat "$_pf" 2>/dev/null || true)
        [ -n "$_p" ] || continue
        kill -0 "$_p" 2>/dev/null || continue
        twin_pid_is_ours "$_p" "$(basename "$_pf" .pid)" || continue
        printf '%s %s\n' "$(basename "$_pf" .pid)" "$_p"
    done
}

# 删掉指向已退出进程的 pid 文件（上次崩溃或被 kill -9 的残留）。
twin_prune_stale_pids() {
    _rd=${1:-${TWIN_RUN_DIR:-}}
    [ -n "$_rd" ] || return 0
    for _pf in "$_rd"/*.pid; do
        [ -f "$_pf" ] || continue
        _p=$(cat "$_pf" 2>/dev/null || true)
        if [ -z "$_p" ] || ! kill -0 "$_p" 2>/dev/null || \
           ! twin_pid_is_ours "$_p" "$(basename "$_pf" .pid)"; then
            rm -f "$_pf" 2>/dev/null || :
        fi
    done
}

# 扫描 /proc，找出由本 runtime 目录启动、却已没有 pid 文件记录的进程。
# 每行 "pid 程序名"。只看 $TWIN_RUN_DIR/runtime-dir 记录的那个目录，
# 所以不会误伤别的安装或别的程序。
twin_orphan_pids() {
    _rd=${1:-${TWIN_RUN_DIR:-}}
    [ -n "$_rd" ] || return 0
    [ -r "$_rd/runtime-dir" ] || return 0
    _bindir=$(cat "$_rd/runtime-dir" 2>/dev/null || true)
    [ -n "$_bindir" ] || return 0
    for _d in /proc/[0-9]*; do
        _pid=${_d#/proc/}
        [ "$_pid" = "$$" ] && continue
        [ -r "$_d/cmdline" ] || continue
        _cmd=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null) || continue
        case "$_cmd" in
            "$_bindir/3proxy"*|"$_bindir/ttp"*|"$_bindir/tgmux"*)
                printf '%s %s\n' "$_pid" "$(basename "${_cmd%% *}")"
                ;;
        esac
    done
}

# 启动前检查。返回 0 = 可以启动；1 = 已有实例在运行。
# 顺带清掉死掉的 pid 文件，并回收没有记录的遗留进程（否则端口仍被占）。
twin_start_guard() {
    _rd=${1:-${TWIN_RUN_DIR:-}}
    [ -n "$_rd" ] || return 0

    _alive=$(twin_alive_pids "$_rd")
    if [ -n "$_alive" ]; then
        echo "[start] 已经在运行，没有重复启动：" >&2
        printf '%s\n' "$_alive" | while IFS=' ' read -r _n _p; do
            echo "[start]   $_n pid=$_p" >&2
        done
        echo "[start] 要重启请先停止（控制台 2），或直接用控制台 3 重启。" >&2
        return 1
    fi

    twin_prune_stale_pids "$_rd"
    _orph=$(twin_orphan_pids "$_rd")
    [ -n "$_orph" ] || return 0
    echo "[start] 发现上次未正常停止的进程，先清理：" >&2
    printf '%s\n' "$_orph" | while IFS=' ' read -r _p _c; do
        echo "[start]   $_c (pid=$_p)" >&2
    done
    _pids=$(printf '%s\n' "$_orph" | sed 's/ .*//')
    for _p in $_pids; do kill "$_p" 2>/dev/null || : ; done
    sleep 1
    for _p in $_pids; do kill -0 "$_p" 2>/dev/null && { kill -9 "$_p" 2>/dev/null || : ; }; done
    sleep 1
    return 0
}

# 停止时回收没有 pid 文件记录的遗留进程。
twin_sweep_orphans() {
    _rd=${1:-${TWIN_RUN_DIR:-}}
    _orph=$(twin_orphan_pids "$_rd")
    [ -n "$_orph" ] || return 0
    printf '%s\n' "$_orph" | while IFS=' ' read -r _p _c; do
        echo "[stop] killed 遗留 $_c ($_p)"
    done
    _pids=$(printf '%s\n' "$_orph" | sed 's/ .*//')
    for _p in $_pids; do kill "$_p" 2>/dev/null || : ; done
    sleep 1
    for _p in $_pids; do kill -0 "$_p" 2>/dev/null && { kill -9 "$_p" 2>/dev/null || : ; }; done
    return 0
}

# 启动后自检：pid 文件里的进程必须还活着。有服务秒退说明端口没抢到 / 配置有错。
# 返回 1 时把失败服务的日志尾部打到 stderr，调用方负责收尾。
twin_check_started() {
    _rd=$1
    _ld=${2:-}
    _bad=""
    for _pf in "$_rd"/*.pid; do
        [ -f "$_pf" ] || continue
        _n=$(basename "$_pf" .pid)
        _p=$(cat "$_pf" 2>/dev/null || true)
        kill -0 "$_p" 2>/dev/null || _bad="$_bad $_n"
    done
    [ -z "$_bad" ] && return 0
    for _n in $_bad; do
        echo "[start] $_n 启动失败" >&2
        [ -n "$_ld" ] && [ -f "$_ld/$_n.out" ] && \
            tail -n 5 "$_ld/$_n.out" 2>/dev/null | sed 's/^/[start]   /' >&2
    done
    return 1
}

# 按 pid 文件停掉本 run 目录下记录的服务（不扫描遗留进程）。
twin_kill_pidfiles() {
    _rd=${1:-${TWIN_RUN_DIR:-}}
    _pids=""
    for _pf in "$_rd"/*.pid; do
        [ -f "$_pf" ] || continue
        _p=$(cat "$_pf" 2>/dev/null || true)
        [ -n "$_p" ] || continue
        if kill -0 "$_p" 2>/dev/null; then
            kill "$_p" 2>/dev/null && echo "[stop] killed $(basename "$_pf" .pid) ($_p)"
        fi
        _pids="$_pids $_p"
        rm -f "$_pf"
    done
    [ -n "$_pids" ] || return 0
    _i=0
    while [ "$_i" -lt 5 ]; do
        _alive=0
        for _p in $_pids; do
            kill -0 "$_p" 2>/dev/null && _alive=1
        done
        [ "$_alive" = 0 ] && break
        sleep 1
        _i=$((_i + 1))
    done
}
