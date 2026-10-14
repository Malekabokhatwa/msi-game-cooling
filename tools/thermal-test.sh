#!/usr/bin/env bash
# Watchdog-protected thermal test. Run as root:
#   sudo tools/thermal-test.sh <label> <seconds> <load command...>
# Logs every 2 s (temps, CPU/GPU watts, EC fan duty, Cooler Boost, GPU throttle
# reasons) and kills the load if an EC sensor reaches SEN_MAX (default 85 C), or
# CPU/GPU/THRM stay at their limits for 3 samples. Reads the EC with writes off.
label=$1 dur=$2; shift 2
OUT=${OUT_DIR:-.}/thermal-test-$label.log
SEN_MAX=${SEN_MAX:-85} CPU_MAX=97 GPU_MAX=88 THRM_MAX=97
RAPL=/sys/class/powercap/intel-rapl:0
modprobe ec_sys write_support=0
zt() { local z; for z in /sys/class/thermal/thermal_zone*; do [[ $(<"$z/type") == "$1" ]] && { echo $(($(<"$z/temp") / 1000)); return; }; done; echo 0; }
ec() { od -An -tu1 -j "$1" -N1 /sys/kernel/debug/ec/ec0/io | tr -d ' '; }

setsid "$@" >/dev/null 2>&1 &
pg=$!
echo "# $label: $* (pgid $pg)" | tee "$OUT"
echo "t cpuC cpuW gpuC gpuW SEN2 SEN3 SEN4 THRM fanCPU% fanGPU% CB gpuThrottle" | tee -a "$OUT"
hc=0 hg=0 ht=0
start=$(date +%s) reason="duration reached"
e0=$(<"$RAPL/energy_uj") t0=$(date +%s%N)
while :; do
  sleep 2
  e1=$(<"$RAPL/energy_uj") t1=$(date +%s%N)
  cw=$(( (e1 - e0) * 1000 / (t1 - t0) )); e0=$e1 t0=$t1
  read -r gw gt thr < <(nvidia-smi --query-gpu=power.draw,temperature.gpu,clocks_event_reasons.active --format=csv,noheader,nounits 2>/dev/null | tr -d ',' | awk '{printf "%d %s %s\n",$1,$2,$3}')
  c=$(zt x86_pkg_temp) s2=$(zt SEN2) s3=$(zt SEN3) s4=$(zt SEN4) th=$(zt acpitz)
  t=$(( $(date +%s) - start ))
  echo "$t $c $cw $gt $gw $s2 $s3 $s4 $th $(ec 0x71) $(ec 0x89) $((($(ec 0x98) >> 7) & 1)) $thr" | tee -a "$OUT"
  # EC sensors (what makes the EC cut power): abort at once.
  for v in "SEN2 $s2" "SEN3 $s3" "SEN4 $s4"; do
    set -- $v; (( $2 >= SEN_MAX )) && { reason="ABORT: $1=$2 >= $SEN_MAX"; break 2; }
  done
  # CPU/GPU/THRM: one-sample boost spikes are normal; abort if hot 3 samples in a row.
  (( c >= CPU_MAX )) && hc=$((hc+1)) || hc=0
  (( ${gt:-0} >= GPU_MAX )) && hg=$((hg+1)) || hg=0
  (( th >= THRM_MAX )) && ht=$((ht+1)) || ht=0
  (( hc >= 3 )) && { reason="ABORT: CPU >= $CPU_MAX for 3 samples"; break; }
  (( hg >= 3 )) && { reason="ABORT: GPU >= $GPU_MAX for 3 samples"; break; }
  (( ht >= 3 )) && { reason="ABORT: THRM >= $THRM_MAX for 3 samples"; break; }
  kill -0 "$pg" 2>/dev/null || { reason="load exited"; break; }
  (( t >= dur )) && break
done
kill -TERM -- -"$pg" 2>/dev/null; sleep 2; kill -KILL -- -"$pg" 2>/dev/null
echo "# stopped: $reason" | tee -a "$OUT"
