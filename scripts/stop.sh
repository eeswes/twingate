#!/bin/sh
# 停止 TwinGate 全部进程。
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/paths.sh"
twin_init_paths "$0"
. "$ROOT/scripts/lifecycle.sh"
RUNDIR=${TWIN_RUN_DIR:-$TWIN_DATA/run}
twin_kill_pidfiles "$RUNDIR"
# 上次可能因为重复启动把 pid 文件覆盖成了死 pid，老进程仍在监听；按 runtime 目录回收。
twin_sweep_orphans "$RUNDIR"
