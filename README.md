# **FanCtrl Plus**

> ### Threadripper fork (lyilyi1717/fanctrlplus, v1.3.3-tr2)
>
> This fork of [ck9393/fanctrlplus](https://github.com/ck9393/fanctrlplus) adds five fixes aimed at multi-die AMD CPUs (e.g. Threadripper 1950X, whose k10temp exposes two Tdie sensors and whose hwmon indexes reshuffle across driver reloads):
>
> 1. **Multi-sensor CPU max** — `cpu_sensor` may hold several paths (space/comma separated) or `auto:CHIP:LABEL` (e.g. `auto:k10temp:Tdie`); the daemon reads all matches and uses the highest temperature. The settings page offers an "All k10temp Tdie (max of N)" option when a chip exposes the same label more than once.
> 2. **Fail-to-full** — if CPU monitoring is enabled and no temperature (CPU or disk) can be read, the fan is driven at 100% instead of idle, and the event is logged to syslog.
> 3. **Sensor path re-resolution** — stored sensor paths are verified by chip name + label each cycle and re-located when hwmon renumbering moves or replaces them (mirrors the existing controller-path migration).
> 4. **Seconds-granularity interval** — interval accepts an `s` suffix (e.g. `10s` = 10 seconds); plain integers remain minutes. Recommended for CPU-based control: `10s`.
> 5. **Aux/Motherboard sensor source (tr2)** — each fan can additionally track a SuperIO temperature (e.g. nct6779 `SYSTIN`) via new cfg keys `aux_enable`, `aux_sensor` (same syntax as `cpu_sensor`, incl. `auto:CHIP:LABEL`), `aux_min_temp`, `aux_max_temp` (defaults 35/55 °C). Final PWM = max(disk, CPU, aux); dashboard/syslog show `(MB)` when aux wins. Dead 0-reading channels (unwired `PCH_*`) are hidden from the dropdown. Suggested: SYSTIN 38 °C → min speed, 55 °C → 100 %.
>
> Install: `plugin install https://raw.githubusercontent.com/lyilyi1717/fanctrlplus/main/unraid/fanctrlplus.plg`

**FanCtrl Plus** is an Unraid plugin that provides automatic fan control based on the temperatures of HDDs, NVMe drives, Unassigned Devices, and optionally the CPU.  
Each fan configuration can monitor specific drives or the CPU, define a temperature range, and scale fan speed automatically using a linear control algorithm.  
Configuration is done through a user-friendly interface, with custom thresholds, intervals, and labels available per fan.

## ✨ Features

- Full-featured Web UI for configuration and monitoring
- Supports temporary fan configuration with safe validation and custom naming
- Automatically starts with the Unraid array for hands-free operation
- Set custom thresholds and intervals per fan
- Control multiple PWM fans independently
- Monitor temps from array disks, NVMe, unassigned devices, and optionally the CPU
- Uses a linear control algorithm to smoothly adjust fan speed (PWM) based on the current temperature (disk or CPU) between your defined low/high values
- Identify and label PWM controllers to match physical fans easily
- Dashboard tile and system integration
- Optional FCP Airflow Dashboard tile, similar to Unraid’s built-in Airflow tile but enhanced with support for custom fan labels
- Drag and drop fan configuration boxes to reorder them as you like. The new order is saved and reflected in both the UI and Dashboard.

---

## 🔧 Manual Installation

**FanCtrl Plus** is available in Community Apps (CA). Just search for “**FanCtrl Plus**” to install.

Support / Issues
- https://forums.unraid.net/topic/191722-plugin-fancrtl-plus/

- If you find this plugin helpful, consider buying me a coffee!

<p align="left">
  <a href="https://www.paypal.com/paypalme/cck9393" target="_blank">
    <img src="https://raw.githubusercontent.com/ck9393/fanctrlplus/main/.github/assets/donate.png" alt="Donate" width="90">
  </a>
</p>

