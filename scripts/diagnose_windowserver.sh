#!/bin/bash
# 诊断长时间使用外接显示器后 WindowServer 卡顿的“元凶”。
#
# 思路：WindowServer 卡顿多为内存/资源随时间累积，背后常有某个进程持续喂活。
# 本脚本定期采样 WindowServer 的内存(RSS)与 CPU，以及系统按 CPU 排序的高负载进程，
# 写入 TSV 日志。卡顿发生时，对照 ws_rss_mb 的增长时段里持续出现的进程即可定位。
#
# 用法:
#   ./diagnose_windowserver.sh [间隔秒, 默认 60]
#   日志默认写到 ~/ws_diag_<时间>.tsv，可用环境变量 LOG=路径 覆盖。
# 停止:
#   Ctrl-C，或 kill 掉本进程。
# 长期后台运行（关掉终端/Claude 也继续）:
#   nohup ./diagnose_windowserver.sh 60 >/tmp/ws_diag.out 2>&1 &

set -u
INTERVAL="${1:-60}"
LOG="${LOG:-$HOME/ws_diag_$(date +%Y%m%d_%H%M%S).tsv}"

printf 'timestamp\tws_rss_mb\tws_cpu\tws_delta_mb\ttop_cpu_procs\n' > "$LOG"
echo "采样中 → $LOG   (每 ${INTERVAL}s 一次, Ctrl-C 停止)"

prev=0
while true; do
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # WindowServer 的 RSS(KB) 与 CPU%
  line=$(ps -axo rss,%cpu,comm | awk '/[W]indowServer/{print $1"\t"$2; exit}')
  ws_rss_kb=$(printf '%s' "$line" | cut -f1); ws_rss_kb=${ws_rss_kb:-0}
  ws_cpu=$(printf '%s' "$line" | cut -f2);   ws_cpu=${ws_cpu:-0}
  ws_mb=$(( ws_rss_kb / 1024 ))
  delta=$(( ws_mb - prev )); prev=$ws_mb

  # 系统按 CPU 排序、占用 >2% 的前 6 个进程（短名=CPU%），用于关联“喂活大户”
  tops=$(ps -axo %cpu,comm -r | awk 'NR>1 && $1+0>2 {n=$2; sub(/.*\//,"",n); printf "%s=%s ", n, $1; if(++c>=6) exit}')

  printf '%s\t%s\t%s\t%+d\t%s\n' "$ts" "$ws_mb" "$ws_cpu" "$delta" "$tops" >> "$LOG"
  printf '[%s] WS=%4sMB (Δ%+d)  CPU=%s%%  | %s\n' "$ts" "$ws_mb" "$delta" "$ws_cpu" "$tops"

  sleep "$INTERVAL"
done
