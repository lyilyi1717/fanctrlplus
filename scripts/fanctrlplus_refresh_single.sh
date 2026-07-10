#!/bin/bash
# fanctrlplus_refresh_single.sh
plugin="fanctrlplus"
cfg_path="/boot/config/plugins/$plugin"
custom="$1"
cfg_file="$cfg_path/${plugin}_$custom.cfg"
[[ -f "$cfg_file" ]] || exit 1
source "$cfg_file"
max="${max:-255}"
controller_enable="${controller}_enable"

# ===== CPU sensor helpers =====
# 打印所有 name 为 $1 且 temp*_label 为 $2 的 hwmon temp*_input 路径
find_cpu_inputs_by_chip_label() {
  local chip="$1" want="$2" dir lf in
  for dir in /sys/class/hwmon/hwmon*; do
    [[ -r "$dir/name" && "$(cat "$dir/name" 2>/dev/null)" == "$chip" ]] || continue
    for lf in "$dir"/temp*_label; do
      [[ -r "$lf" && "$(cat "$lf" 2>/dev/null)" == "$want" ]] || continue
      in="${lf%_label}_input"
      [[ -r "$in" ]] && echo "$in"
    done
  done
}

# 将传感器串 $1（支持逗号/空格分隔的多路径，以及 auto:CHIP:LABEL 形式）
# 展开为当前可读的 temp*_input 路径
resolve_cpu_sensors() {
  local spec rest chip label
  for spec in ${1//,/ }; do
    case "$spec" in
      auto:*:*)
        rest="${spec#auto:}"
        chip="${rest%%:*}"
        label="${rest#*:}"
        find_cpu_inputs_by_chip_label "$chip" "$label"
        ;;
      *)
        [[ -r "$spec" ]] && echo "$spec"
        ;;
    esac
  done
}

# === CPU 温度（多传感器取最大值） ===
cpu_pwm_val=0
if [[ "${cpu_enable:-0}" == "1" && -n "$cpu_sensor" ]]; then
  cpu_temp=""
  for sensor in $(resolve_cpu_sensors "$cpu_sensor"); do
    raw=$(cat "$sensor" 2>/dev/null)
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    t=$((raw / 1000))
    if [[ -z "$cpu_temp" ]] || (( t > cpu_temp )); then
      cpu_temp=$t
    fi
  done

  if [[ -z "$cpu_temp" ]]; then
    cpu_temp="-"
  elif (( cpu_temp <= cpu_min_temp )); then
    cpu_pwm_val=$pwm
  elif (( cpu_temp >= cpu_max_temp )); then
    cpu_pwm_val=$max
  else
    delta=$((cpu_temp - cpu_min_temp))
    range=$((cpu_max_temp - cpu_min_temp))
    cpu_pwm_val=$((pwm + delta * (max - pwm) / range))
  fi
else
  cpu_temp="-"
fi

# === Aux/主板 温度（多传感器取最大值，语法同 cpu_sensor） ===
aux_pwm_val=0
if [[ "${aux_enable:-0}" == "1" && -n "${aux_sensor:-}" ]]; then
  aux_lo="${aux_min_temp:-35}"
  aux_hi="${aux_max_temp:-55}"
  aux_temp=""
  for sensor in $(resolve_cpu_sensors "$aux_sensor"); do
    raw=$(cat "$sensor" 2>/dev/null)
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    t=$((raw / 1000))
    if [[ -z "$aux_temp" ]] || (( t > aux_temp )); then
      aux_temp=$t
    fi
  done

  if [[ -z "$aux_temp" ]]; then
    aux_temp="-"
  elif (( aux_temp <= aux_lo )); then
    aux_pwm_val=$pwm
  elif (( aux_temp >= aux_hi )); then
    aux_pwm_val=$max
  else
    delta=$((aux_temp - aux_lo))
    range=$((aux_hi - aux_lo))
    aux_pwm_val=$((pwm + delta * (max - pwm) / range))
  fi
else
  aux_temp="-"
fi

# === Disk 温控 PWM ===
disk_pwm_val=0
disk_max="*"

# 有勾选 disk 时才处理
if [ -n "$disks" ]; then
  disk_max_valid=0
  found_valid_temp=0

  IFS=',' read -ra disks_list <<< "$disks"
  for disk in "${disks_list[@]}"; do
    disk_path="/dev/disk/by-id/$disk"
    real_path=$(realpath "$disk_path" 2>/dev/null)
    [[ ! -b "$real_path" ]] && continue

    # 跳过休眠磁盘
    smartctl -n standby -A "$real_path" | grep -q "Device is in STANDBY" && continue

    # 获取温度
    if [[ "$real_path" == /dev/nvme* ]]; then
      temp=$(smartctl -A "$real_path" | awk '/Temperature:/ {print $2; exit}')
    else
      temp=$(smartctl -A "$real_path" | awk '
        $1 == 190 || $1 == 194                   { print $10; exit }
        $1 == "Temperature_Celsius"             { print $10; exit }
        $1 == "Airflow_Temperature_Cel"         { print $10; exit }
        $1 == "Current" && $3 == "Temperature:" { print $4; exit }
      ')
    fi

    # 有效温度，更新最大值
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      (( temp > disk_max_valid )) && disk_max_valid=$temp
      found_valid_temp=1
    fi
  done

  # 若取得有效温度，再执行 PWM 推算
  if (( found_valid_temp == 1 )); then
    disk_max=$disk_max_valid

    if (( disk_max <= low )); then
      disk_pwm_val=$pwm
    elif (( disk_max >= high )); then
      disk_pwm_val=$max
    else
      delta=$((disk_max - low))
      range=$((high - low))
      disk_pwm_val=$((pwm + delta * (max - pwm) / range))
    fi
  fi
fi
  
# === 取较高 PWM 作为最终值，同时设定 max_temp 与来源 ===
if (( cpu_pwm_val > disk_pwm_val )); then
  pwm_val=$cpu_pwm_val
  max_temp=$cpu_temp
  temp_origin="(CPU)"
else
  pwm_val=$disk_pwm_val
  max_temp=$disk_max
  temp_origin=$([ -n "$disks" ] && echo "(Disk)" || echo "(CPU)")
fi

# Aux/主板 若更高则胜出
if (( aux_pwm_val > pwm_val )); then
  pwm_val=$aux_pwm_val
  max_temp=$aux_temp
  temp_origin="(MB)"
fi

# 避免空写入
if [[ ! "$max_temp" =~ ^[0-9]+$ ]]; then
  max_temp="*"
  temp_origin=""
fi

# CPU/Aux 监控开启但全部读不到温度 → 满速 failsafe，避免过热
hw_enabled=0
hw_readable=0
if [[ "${cpu_enable:-0}" == "1" ]]; then
  hw_enabled=1
  [[ "$cpu_temp" =~ ^[0-9]+$ ]] && hw_readable=1
fi
if [[ "${aux_enable:-0}" == "1" ]]; then
  hw_enabled=1
  [[ "$aux_temp" =~ ^[0-9]+$ ]] && hw_readable=1
fi
if [[ "$max_temp" == "*" ]] && (( hw_enabled == 1 && hw_readable == 0 )); then
  pwm_val="$max"
  temp_origin="(Failsafe)"
  logger -t fanctrlplus "Manual Run [${custom}] No readable temperature source; failing safe to FULL speed (PWM=$max)"
fi

# 强制写 PWM
[[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
echo "$pwm_val" > "$controller"
sleep 4

# 采集 RPM
fan_index=""
if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
  fan_index="${BASH_REMATCH[1]}"
  fan_path="$(dirname "$controller")/fan${fan_index}_input"
fi
if [[ -n "$fan_path" && -f "$fan_path" ]]; then
  rpm=$(cat "$fan_path")
else
  rpm="?"
fi

label="[${custom}]"
logger -t fanctrlplus "Manual Run $label Temp=${max_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"

echo "${max_temp} ${temp_origin}" > "/var/tmp/fanctrlplus/temp_${plugin}_${custom}"