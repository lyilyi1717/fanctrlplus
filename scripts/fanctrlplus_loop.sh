#!/bin/bash
# fanctrlplus_loop.sh - 实际运行的风扇控制脚本（支持 Disk + CPU 温控合并）

cfg_file="$1"
[[ -f "$cfg_file" ]] || exit 1
source "$cfg_file"
max="${max:-255}"

# ===== Fan Speed on Idle (ABS) =====
# 最小档（绝对值）：cfg 里的 pwm 就是 Min
min_pwm_abs="${pwm:-0}"

if [[ -n "${idle:-}" ]]; then
  idle_pwm_abs="$idle"
elif [[ -n "${idle_percent:-}" ]]; then
  idle_pwm_abs=$(( (idle_percent * 255 + 50) / 100 ))
else
  idle_pwm_abs=0
fi

# 基本夹值到 [0, max]
(( idle_pwm_abs < 0 )) && idle_pwm_abs=0
(( idle_pwm_abs > max )) && idle_pwm_abs="$max"

# Idle 不高于 Min
if (( idle_pwm_abs > min_pwm_abs )); then
  idle_pwm_abs="$min_pwm_abs"
fi

plugin="fanctrlplus"
custom="${custom:-$(basename "$cfg_file" .cfg)}"
controller_enable="${controller}_enable"

# 推导 RPM 读取路径
if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
  fan_index="${BASH_REMATCH[1]}"
  fan_path="$(dirname "$controller")/fan${fan_index}_input"
else
  fan_path=""
fi

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

# 将 cpu_sensor（支持逗号/空格分隔的多路径，以及 auto:CHIP:LABEL 形式）
# 展开为当前可读的 temp*_input 路径
resolve_cpu_sensors() {
  local spec rest chip label
  for spec in ${cpu_sensor//,/ }; do
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

prev_pwm=-1
failsafe_active=0

while true; do
  # === CPU 温度（多传感器取最大值） ===
  cpu_pwm_val=0
  if [[ "${cpu_enable:-0}" == "1" && -n "$cpu_sensor" ]]; then
    cpu_temp=""
    for sensor in $(resolve_cpu_sensors); do
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

  # 避免空写入
  if [[ ! "$max_temp" =~ ^[0-9]+$ ]]; then
    max_temp="*"
    temp_origin=""
  fi

  # 若无任何有效温度源 → 覆盖为 idle，并标注来源
  # （CPU 监控开启但读不到任何温度时，改为满速 failsafe，避免过热）
  if [[ "$max_temp" == "*" ]]; then
    if [[ "${cpu_enable:-0}" == "1" && ! "$cpu_temp" =~ ^[0-9]+$ ]]; then
      pwm_val="$max"
      temp_origin="(Failsafe)"
      if [[ "$failsafe_active" != "1" ]]; then
        logger -t fanctrlplus "[${custom}] No readable temperature source; failing safe to FULL speed (PWM=$max)"
        failsafe_active=1
      fi
    else
      pwm_val="$idle_pwm_abs"
      temp_origin="(Idle)"
    fi
  else
    failsafe_active=0
  fi

  # 每轮都写入 Dashboard 缓存
  echo "${max_temp} ${temp_origin}" > "/var/tmp/fanctrlplus/temp_${plugin}_${custom}"

  # === 若 PWM 有明显变化，或首次 ===
  if [[ "$prev_pwm" == -1 ]]; then
    [[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
    echo "$pwm_val" > "$controller"
    sleep 4
    if [[ -n "$fan_path" && -f "$fan_path" ]]; then
      rpm=$(cat "$fan_path")
    else
      rpm="?"
    fi

    # 无条件写一次
    label="[${custom}]"
    logger -t fanctrlplus "$label Temp=${max_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"
    prev_pwm=$pwm_val
  else
    if (( pwm_val - prev_pwm >= 5 || prev_pwm - pwm_val >= 5 )); then
      [[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
      echo "$pwm_val" > "$controller"
      sleep 4
      if [[ -n "$fan_path" && -f "$fan_path" ]]; then
        rpm=$(cat "$fan_path")
      else
        rpm="?"
      fi

      label="[${custom}]"
      log_enable=$(grep '^syslog=' "$cfg_file" | cut -d'"' -f2)
      if [[ -z "$log_enable" || "$log_enable" == "1" ]]; then
        logger -t fanctrlplus "$label Temp=${max_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"
      fi

      prev_pwm=$pwm_val
    fi
  fi

  sleep $((interval * 60))
done