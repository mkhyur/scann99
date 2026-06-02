#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail

OUT_DIR="$HOME/storage/downloads/android_audit_result"
NO_BUGREPORT=0
SERIAL=""
ADB_SERIAL_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-bugreport)
      NO_BUGREPORT=1
      ;;
    --out)
      shift
      OUT_DIR="${1:-$OUT_DIR}"
      ;;
    *)
      echo "Opcao desconhecida: $1"
      echo "Uso: bash $0 [--no-bugreport] [--out PASTA]"
      exit 1
      ;;
  esac
  shift
done

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TMP_BASE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
mkdir -p "$TMP_BASE"
RAW_DIR="$(mktemp -d "$TMP_BASE/android_adb_raw_${TIMESTAMP}_XXXXXX")"
STATUS_FILE="$RAW_DIR/status_comandos.txt"
STRICT_FILE="$RAW_DIR/resultado_rastros.txt"
REVIEW_FILE="$RAW_DIR/resultado_revisao.txt"
REPORT=""
STRICT_COUNT=0
REVIEW_COUNT=0
AREA_IDX=0
STEP=0
TOTAL_STEPS=66

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
  if [ -d "$RAW_DIR" ]; then
    rm -rf "$RAW_DIR"
  fi
}
trap cleanup EXIT

clear_screen() {
  clear 2>/dev/null || printf '\033c'
}

pause_enter() {
  echo
  read -r -p "↩️  Pressione ENTER para continuar..." _
}

header() {
  clear_screen
  echo "╔══════════════════════════════════════╗"
  echo "║     🛡️  ANDROID ADB SCANNER          ║"
  echo "║          Termux Audit Panel          ║"
  echo "╚══════════════════════════════════════╝"
  echo
}

line() {
  printf '%s\n' "$*" >> "$REPORT"
}

section() {
  {
    echo
    echo "$1"
    echo "========================================"
  } >> "$REPORT"
}

ensure_downloads() {
  if [ ! -d "$HOME/storage/downloads" ]; then
    header
    echo "📁 A pasta Download do Termux ainda nao esta liberada."
    echo
    echo "Vou solicitar permissao de armazenamento agora."
    echo "Depois de aceitar no Android, volte para o Termux."
    echo

    if command -v termux-setup-storage >/dev/null 2>&1; then
      termux-setup-storage
      echo
      read -r -p "Depois de aceitar a permissao, pressione ENTER..." _
    fi
  fi

  if [ ! -d "$HOME/storage/downloads" ]; then
    echo "Nao consegui acessar ~/storage/downloads."
    echo "Execute manualmente: termux-setup-storage"
    exit 1
  fi

  mkdir -p "$OUT_DIR"
  REPORT="$OUT_DIR/relatorio_android_adb_$TIMESTAMP.txt"
}

require_adb() {
  if ! command -v adb >/dev/null 2>&1; then
    header
    echo "❌ ADB nao encontrado."
    echo
    echo "Instale com:"
    echo "pkg install android-tools"
    exit 1
  fi
}

device_count() {
  adb devices | awk 'NR > 1 && $2 == "device" {count++} END {print count+0}'
}

choose_device() {
  local count
  count="$(device_count)"

  if [ "$count" -eq 0 ]; then
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
    ADB_SERIAL_ARGS=(-s "$SERIAL")
    return 0
  fi

  echo
  echo "📱 Mais de um dispositivo ADB conectado:"
  adb devices | awk 'NR > 1 && $2 == "device" {print NR-1 ") " $1}'
  echo
  read -r -p "Digite o serial/IP do dispositivo: " SERIAL

  if [ -z "$SERIAL" ]; then
    echo "Nenhum dispositivo escolhido."
    return 1
  fi

  ADB_SERIAL_ARGS=(-s "$SERIAL")
  return 0
}

show_devices() {
  header
  echo "📱 Dispositivos ADB:"
  echo
  adb devices
  pause_enter
}

pair_and_connect() {
  header
  echo "🔗 PAREAR E CONECTAR ADB SEM FIO"
  echo
  echo "No Android, abra:"
  echo "Configuracoes > Opcoes do desenvolvedor > Depuracao sem fio"
  echo
  echo "Use as portas mostradas na tela do Android."
  echo "Nao precisa digitar o IP; sera usado 127.0.0.1."
  echo

  read -r -p "Porta de PAREAMENTO: " pair_port
  read -r -p "Codigo de PAREAMENTO: " pair_code
  echo

  if [ -z "$pair_port" ] || [ -z "$pair_code" ]; then
    echo "❌ Porta e codigo de pareamento sao obrigatorios."
    pause_enter
    return 1
  fi

  echo "🔐 Pareando em 127.0.0.1:$pair_port..."
  adb pair "127.0.0.1:$pair_port" "$pair_code"
  local pair_rc=$?

  if [ "$pair_rc" -ne 0 ]; then
    echo
    echo "❌ Falha no pareamento. Confira a porta e o codigo."
    pause_enter
    return 1
  fi

  echo
  read -r -p "Porta de CONEXAO: " connect_port

  if [ -z "$connect_port" ]; then
    echo "❌ Porta de conexao obrigatoria."
    pause_enter
    return 1
  fi

  echo
  echo "🔌 Conectando em 127.0.0.1:$connect_port..."
  adb connect "127.0.0.1:$connect_port"
  echo
  adb devices

  if choose_device; then
    echo
    echo "✅ ADB conectado: $SERIAL"
  else
    echo
    echo "⚠️ Nenhum dispositivo autorizado encontrado."
  fi

  pause_enter
}

spin_wait() {
  local pid="$1"
  local label="$2"
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s %s" "${frames[$((i % ${#frames[@]}))]}" "$label"
    i=$((i + 1))
    sleep 0.12
  done
}

run_adb_shell() {
  local filename="$1"
  local seconds="$2"
  local remote_cmd="$3"
  local out="$RAW_DIR/$filename"
  local tmpout="$RAW_DIR/${filename}.stdout.tmp"
  local tmperr="$RAW_DIR/${filename}.stderr.tmp"
  local rc=0

  STEP=$((STEP + 1))
  local label="[$STEP/$TOTAL_STEPS] Coletando $filename"

  {
    echo "COMMAND: adb ${ADB_SERIAL_ARGS[*]} shell $remote_cmd"
    echo "START: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
  } > "$out"

  if command -v timeout >/dev/null 2>&1; then
    (timeout "$seconds" adb "${ADB_SERIAL_ARGS[@]}" shell "$remote_cmd" > "$tmpout" 2> "$tmperr") &
  else
    (adb "${ADB_SERIAL_ARGS[@]}" shell "$remote_cmd" > "$tmpout" 2> "$tmperr") &
  fi

  local pid=$!
  spin_wait "$pid" "$label"
  wait "$pid"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    printf "\r✅ [%02d/%02d] %s\n" "$STEP" "$TOTAL_STEPS" "$filename"
  else
    printf "\r⚠️  [%02d/%02d] %s retornou rc=%s\n" "$STEP" "$TOTAL_STEPS" "$filename" "$rc"
  fi

  {
    echo "RETURNCODE: $rc"
    echo "END: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "STDOUT:"
    cat "$tmpout" 2>/dev/null
    echo
    echo "STDERR:"
    cat "$tmperr" 2>/dev/null
  } >> "$out"

  printf '%s|%s|%s\n' "$filename" "$rc" "$remote_cmd" >> "$STATUS_FILE"
  rm -f "$tmpout" "$tmperr"
}

collect_bugreport() {
  if [ "$NO_BUGREPORT" -eq 1 ]; then
    echo "⏭️  Bugreport pulada por --no-bugreport"
    echo "bugreport|SKIPPED|--no-bugreport" >> "$STATUS_FILE"
    return
  fi

  echo "📦 Coletando bugreport temporaria..."
  {
    echo "COMMAND: adb ${ADB_SERIAL_ARGS[*]} bugreport $RAW_DIR/bugreport.zip"
    echo "START: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
  } > "$RAW_DIR/bugreport_command_output.txt"

  (adb "${ADB_SERIAL_ARGS[@]}" bugreport "$RAW_DIR/bugreport.zip" >> "$RAW_DIR/bugreport_command_output.txt" 2>&1) &
  local pid=$!
  spin_wait "$pid" "Gerando bugreport temporaria"
  wait "$pid"
  local rc=$?

  if [ "$rc" -eq 0 ]; then
    printf "\r✅ Bugreport coletada\n"
  else
    printf "\r⚠️ Bugreport retornou rc=%s\n" "$rc"
  fi

  echo "RETURNCODE: $rc" >> "$RAW_DIR/bugreport_command_output.txt"
  echo "bugreport.zip|$rc|adb bugreport" >> "$STATUS_FILE"
}

collect_all() {
  : > "$STATUS_FILE"
  STEP=0

  collect_bugreport

  run_adb_shell "logcat_main.txt" 120 "logcat -d -v threadtime"
  run_adb_shell "logcat_system.txt" 120 "logcat -b system -d -v threadtime"
  run_adb_shell "logcat_events.txt" 120 "logcat -b events -d -v threadtime"
  run_adb_shell "logcat_crash.txt" 120 "logcat -b crash -d -v threadtime"
  run_adb_shell "logcat_all.txt" 180 "logcat -b all -d -v threadtime"

  run_adb_shell "dumpsys_all.txt" 240 "dumpsys"
  run_adb_shell "dumpsys_services_list.txt" 60 "dumpsys -l"

  run_adb_shell "dumpsys_connectivity.txt" 90 "dumpsys connectivity"
  run_adb_shell "dumpsys_netstats.txt" 120 "dumpsys netstats"
  run_adb_shell "dumpsys_network_management.txt" 90 "dumpsys network_management"
  run_adb_shell "dumpsys_wifi.txt" 120 "dumpsys wifi"
  run_adb_shell "ip_addr.txt" 60 "ip addr show"
  run_adb_shell "ip_route.txt" 60 "ip route show"
  run_adb_shell "ss_connections.txt" 60 "ss -tunap"
  run_adb_shell "netstat_connections.txt" 60 "netstat -tunap"
  run_adb_shell "proc_net_tcp.txt" 60 "cat /proc/net/tcp"
  run_adb_shell "proc_net_udp.txt" 60 "cat /proc/net/udp"
  run_adb_shell "proc_net_tcp6.txt" 60 "cat /proc/net/tcp6"
  run_adb_shell "proc_net_udp6.txt" 60 "cat /proc/net/udp6"

  run_adb_shell "pm_packages_full.txt" 90 "pm list packages -f -U -i"
  run_adb_shell "pm_packages_user_apps.txt" 90 "pm list packages -3 -f -U -i"
  run_adb_shell "pm_packages_system_apps.txt" 90 "pm list packages -s -f -U -i"
  run_adb_shell "dumpsys_package.txt" 180 "dumpsys package"
  run_adb_shell "dumpsys_package_packages.txt" 180 "dumpsys package packages"
  run_adb_shell "dumpsys_package_dexopt.txt" 120 "dumpsys package dexopt"
  run_adb_shell "dumpsys_shortcut.txt" 120 "dumpsys shortcut"

  run_adb_shell "dumpsys_usagestats.txt" 180 "dumpsys usagestats"
  run_adb_shell "dumpsys_appops.txt" 180 "dumpsys appops"
  run_adb_shell "dumpsys_permission.txt" 180 "dumpsys permission"

  run_adb_shell "dumpsys_usb.txt" 90 "dumpsys usb"
  run_adb_shell "dumpsys_mount.txt" 90 "dumpsys mount"
  run_adb_shell "dumpsys_input.txt" 90 "dumpsys input"

  run_adb_shell "getprop_all.txt" 90 "getprop"
  run_adb_shell "selinux_status.txt" 60 "getenforce"
  run_adb_shell "shell_id.txt" 60 "id"
  run_adb_shell "which_su.txt" 60 "which su"
  run_adb_shell "su_version.txt" 60 "su -v"
  run_adb_shell "su_id.txt" 60 "su -c id"
  run_adb_shell "processes.txt" 90 "ps -A"
  run_adb_shell "processes_detailed.txt" 90 "ps -A -o USER,PID,PPID,NAME,ARGS"
  run_adb_shell "service_list.txt" 90 "service list"
  run_adb_shell "overlay_list.txt" 90 "cmd overlay list"
  run_adb_shell "settings_global.txt" 90 "settings list global"
  run_adb_shell "settings_secure.txt" 90 "settings list secure"
  run_adb_shell "settings_system.txt" 90 "settings list system"

  run_adb_shell "root_paths.txt" 90 "for p in /data/adb /data/adb/modules /data/adb/modules_update /data/adb/ksu /data/adb/ap /data/adb/apatch /data/adb/service.d /data/adb/post-fs-data.d /sbin/.magisk /debug_ramdisk/.magisk /cache/magisk.log /dev/.magisk_unblock; do echo --- \$p; ls -la \$p 2>&1; done"
  run_adb_shell "root_modules.txt" 120 "for base in /data/adb/modules /data/adb/modules_update /data/adb/ksu/modules /data/adb/ap/modules /data/adb/apatch/modules; do echo BASE=\$base; for d in \$base/*; do [ -d \"\$d\" ] || continue; echo MODULE_DIR=\$d; [ -f \"\$d/module.prop\" ] && cat \"\$d/module.prop\"; [ -f \"\$d/disable\" ] && echo FLAG=disable; [ -f \"\$d/remove\" ] && echo FLAG=remove; done; done 2>&1"
  run_adb_shell "root_service_scripts.txt" 90 "for p in /data/adb/service.d /data/adb/post-fs-data.d /data/adb/modules/*/service.sh /data/adb/modules/*/post-fs-data.sh /data/adb/modules/*/customize.sh; do echo --- \$p; ls -la \$p 2>&1; done"
  run_adb_shell "root_binaries.txt" 90 "for p in /system/bin/su /system/xbin/su /sbin/su /su/bin/su /apex/com.android.runtime/bin/su /data/adb/magisk /data/adb/ksu/bin/ksud /data/adb/ap/bin/apd /sbin/.magisk/mirror/system/bin/su; do echo --- \$p; ls -la \$p 2>&1; done"
  run_adb_shell "root_framework_props.txt" 60 "getprop | grep -Ei 'magisk|zygisk|kernelsu|ksu|apatch|xposed|riru|supersu|selinux|adb|secure|debuggable' 2>/dev/null"
  run_adb_shell "mounts.txt" 90 "mount"
  run_adb_shell "proc_mounts.txt" 90 "cat /proc/mounts"
  run_adb_shell "kernel_info.txt" 60 "uname -a; cat /proc/version 2>/dev/null; cat /proc/filesystems 2>/dev/null"
  run_adb_shell "boot_status.txt" 60 "getprop ro.boot.verifiedbootstate; getprop ro.boot.flash.locked; getprop ro.boot.vbmeta.device_state; getprop ro.boot.veritymode; getprop ro.boot.warranty_bit; getprop ro.warranty_bit"
  run_adb_shell "device_policy.txt" 120 "dumpsys device_policy"
  run_adb_shell "accessibility.txt" 60 "settings get secure enabled_accessibility_services; settings get secure accessibility_enabled"

  run_adb_shell "dumpsys_batterystats.txt" 180 "dumpsys batterystats"
  run_adb_shell "dumpsys_battery.txt" 60 "dumpsys battery"
  run_adb_shell "dumpsys_deviceidle.txt" 90 "dumpsys deviceidle"
  run_adb_shell "dumpsys_jobscheduler.txt" 180 "dumpsys jobscheduler"
  run_adb_shell "dumpsys_alarm.txt" 180 "dumpsys alarm"

  run_adb_shell "dumpsys_dropbox.txt" 180 "dumpsys dropbox"
  run_adb_shell "dumpsys_activity_crashes.txt" 120 "dumpsys activity crashes"
  run_adb_shell "dumpsys_activity_processes.txt" 120 "dumpsys activity processes"
  run_adb_shell "dumpsys_activity_services.txt" 180 "dumpsys activity services"
  run_adb_shell "dumpsys_activity_broadcasts.txt" 180 "dumpsys activity broadcasts"
}

scan_files() {
  local regex="$1"
  local exclude_regex="${2:-}"
  local output="$3"

  : > "$output"
  rm -f "$output.raw" "$output.clean"

  for f in "$RAW_DIR"/*.txt; do
    [ -f "$f" ] || continue
    local base
    base="$(basename "$f")"
    case "$base" in
      finding_*|resultado_*|status_comandos.txt)
        continue
        ;;
    esac

    grep -nE -i "$regex" "$f" 2>/dev/null | sed "s|^|$base:|" >> "$output.raw" || true
  done

  if [ -f "$output.raw" ]; then
    grep -viE 'COMMAND:|^.*:START:|^.*:END:|^.*:RETURNCODE:|^.*:STDERR:|^.*:STDOUT:' "$output.raw" > "$output.clean" || true

    if [ -n "$exclude_regex" ]; then
      grep -viE "$exclude_regex" "$output.clean" > "$output" || true
    else
      cat "$output.clean" > "$output"
    fi
  fi

  rm -f "$output.raw" "$output.clean"
}

append_bucket() {
  local bucket="$1"
  local icon="$2"
  local title="$3"
  local file="$4"
  local max_screen="${5:-12}"
  local count
  count="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  [ "$count" -eq 0 ] && return 0

  if [ "$bucket" = "strict" ]; then
    STRICT_COUNT=$((STRICT_COUNT + count))
    {
      echo
      echo "$icon $title"
      echo "----------------------------------------"
      sed -n "1,${max_screen}p" "$file"
      if [ "$count" -gt "$max_screen" ]; then
        echo "... +$((count - max_screen)) ocorrencia(s) no relatorio."
      fi
    } >> "$STRICT_FILE"
  else
    REVIEW_COUNT=$((REVIEW_COUNT + count))
    {
      echo
      echo "$icon $title"
      echo "----------------------------------------"
      sed -n "1,${max_screen}p" "$file"
      if [ "$count" -gt "$max_screen" ]; then
        echo "... +$((count - max_screen)) ocorrencia(s) no relatorio."
      fi
    } >> "$REVIEW_FILE"
  fi
}

finding_area() {
  local icon="$1"
  local title="$2"
  local regex="$3"
  local bucket="$4"
  local max_lines="${5:-28}"
  local exclude_regex="${6:-Permission denied|No such file|not found|inaccessible|Operation not permitted|Unknown option|cmd: Failure|SecurityException|Exception occurred|^.*:COMMAND:|\/sdcard\/Android\/data\/com\.termux|com\.termux}"

  AREA_IDX=$((AREA_IDX + 1))
  local tmp="$RAW_DIR/finding_${AREA_IDX}.txt"
  local count=0

  section "$icon $title"
  scan_files "$regex" "$exclude_regex" "$tmp"

  count="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Resumo: nada encontrado nesta area."
    return 0
  fi

  line "Resumo: $count ocorrencia(s)."
  line "O que apareceu e onde apareceu:"
  sed -n "1,${max_lines}p" "$tmp" >> "$REPORT"

  if [ "$count" -gt "$max_lines" ]; then
    line "... +$((count - max_lines)) ocorrencia(s) omitidas para manter o relatorio resumido."
  fi

  append_bucket "$bucket" "$icon" "$title" "$tmp" 10
}

flush_module() {
  local out="$1"
  local dir="$2"
  local id="$3"
  local name="$4"
  local version="$5"
  local author="$6"
  local flags="$7"

  [ -z "$dir" ] && return 0

  if [ -z "$id" ]; then
    id="$(basename "$dir")"
  fi
  [ -z "$name" ] && name="sem nome no module.prop"
  [ -z "$version" ] && version="sem versao"
  [ -z "$author" ] && author="autor nao informado"
  [ -z "$flags" ] && flags="ativo/sem flag detectada"

  printf 'modulo=%s | id=%s | versao=%s | autor=%s | estado=%s | dir=%s\n' \
    "$name" "$id" "$version" "$author" "$flags" "$dir" >> "$out"
}

detect_root_modules() {
  section "🧩 ROOT / MODULOS DETECTADOS"

  local f="$RAW_DIR/root_modules.txt"
  local out="$RAW_DIR/finding_root_modules_parsed.txt"
  local dir="" id="" name="" version="" author="" flags=""
  : > "$out"

  if [ -f "$f" ]; then
    while IFS= read -r line; do
      case "$line" in
        MODULE_DIR=*)
          flush_module "$out" "$dir" "$id" "$name" "$version" "$author" "$flags"
          dir="${line#MODULE_DIR=}"
          id=""; name=""; version=""; author=""; flags=""
          ;;
        id=*)
          id="${line#id=}"
          ;;
        name=*)
          name="${line#name=}"
          ;;
        version=*)
          version="${line#version=}"
          ;;
        author=*)
          author="${line#author=}"
          ;;
        FLAG=*)
          if [ -z "$flags" ]; then
            flags="${line#FLAG=}"
          else
            flags="$flags,${line#FLAG=}"
          fi
          ;;
      esac
    done < "$f"
    flush_module "$out" "$dir" "$id" "$name" "$version" "$author" "$flags"
  fi

  local count
  count="$(wc -l < "$out" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Resumo: nenhum modulo root legivel foi encontrado em /data/adb/modules e caminhos parecidos."
  else
    line "Resumo: $count modulo(s) root encontrado(s)."
    line "Modulos identificados:"
    sed -n '1,25p' "$out" >> "$REPORT"
    append_bucket "strict" "🧩" "ROOT / MODULOS DETECTADOS" "$out" 12
  fi
}

detect_root_frameworks() {
  section "🧬 FRAMEWORK ROOT / TIPO DETECTADO"

  local out="$RAW_DIR/finding_root_frameworks.txt"
  : > "$out"

  scan_files 'magisk|zygisk|kernelsu|\bksu\b|apatch|superkey|susfs|shamiko|riru|lsposed|edxposed|xposed|zygisknext|magiskpolicy|resetprop|ksud|apd|magiskd' \
    'Permission denied|No such file|not found|COMMAND:|com\.termux|android_adb_audit|scanner' \
    "$out.tmp"

  if grep -qi 'magisk\|magiskd\|magiskpolicy\|resetprop\|/data/adb/magisk' "$out.tmp" 2>/dev/null; then
    echo "tipo=Magisk | arquivo/linha: $(grep -i 'magisk\|magiskd\|magiskpolicy\|resetprop\|/data/adb/magisk' "$out.tmp" | head -n 1)" >> "$out"
  fi
  if grep -qi 'zygisk\|zygisknext' "$out.tmp" 2>/dev/null; then
    echo "tipo=Zygisk/ZygiskNext | arquivo/linha: $(grep -i 'zygisk\|zygisknext' "$out.tmp" | head -n 1)" >> "$out"
  fi
  if grep -qi 'kernelsu\|\bksu\b\|ksud' "$out.tmp" 2>/dev/null; then
    echo "tipo=KernelSU/KSU | arquivo/linha: $(grep -i 'kernelsu\|\bksu\b\|ksud' "$out.tmp" | head -n 1)" >> "$out"
  fi
  if grep -qi 'apatch\|superkey\|apd' "$out.tmp" 2>/dev/null; then
    echo "tipo=APatch | arquivo/linha: $(grep -i 'apatch\|superkey\|apd' "$out.tmp" | head -n 1)" >> "$out"
  fi
  if grep -qi 'susfs' "$out.tmp" 2>/dev/null; then
    echo "tipo=SUSFS | arquivo/linha: $(grep -i 'susfs' "$out.tmp" | head -n 1)" >> "$out"
  fi
  if grep -qi 'shamiko' "$out.tmp" 2>/dev/null; then
    echo "tipo=Shamiko | arquivo/linha: $(grep -i 'shamiko' "$out.tmp" | head -n 1)" >> "$out"
  fi
  if grep -qi 'riru\|lsposed\|edxposed\|xposed' "$out.tmp" 2>/dev/null; then
    echo "tipo=Xposed/LSPosed/Riru | arquivo/linha: $(grep -i 'riru\|lsposed\|edxposed\|xposed' "$out.tmp" | head -n 1)" >> "$out"
  fi

  rm -f "$out.tmp"

  local count
  count="$(wc -l < "$out" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Resumo: nenhum framework root identificado por nome."
  else
    line "Resumo: framework(s) root identificado(s)."
    sed -n '1,20p' "$out" >> "$REPORT"
    append_bucket "strict" "🧬" "FRAMEWORK ROOT / TIPO DETECTADO" "$out" 10
  fi
}

detect_root_services() {
  section "⚙️ SERVICOS / BINARIOS ROOT"

  local out="$RAW_DIR/finding_root_services_detail.txt"
  : > "$out"

  scan_files 'init\.svc\.(magisk|zygisk|su|ksu|kernelsu|apatch)|\b(magiskd|zygisk|ksud|apd|su_daemon|supersu|daemonsu|frida-server)\b|uid=0\(root\)|/system/(xbin|bin)/su|/sbin/su|/su/bin/su|/data/adb/.*/service\.sh|/data/adb/service\.d|/data/adb/post-fs-data\.d' \
    'Permission denied|No such file|not found|COMMAND:|com\.termux|android_adb_audit|scanner' \
    "$out"

  local count
  count="$(wc -l < "$out" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Resumo: nenhum servico/binario root direto foi encontrado."
  else
    line "Resumo: $count ocorrencia(s)."
    line "Servico/binario e arquivo de origem:"
    sed -n '1,30p' "$out" >> "$REPORT"
    append_bucket "strict" "⚙️" "SERVICOS / BINARIOS ROOT" "$out" 10
  fi
}

detect_usb_connection_types() {
  section "🔌 USB / ADB / TIPO DE CONEXAO"

  local out="$RAW_DIR/finding_connection_types.txt"
  : > "$out"

  if [ -n "$SERIAL" ]; then
    if echo "$SERIAL" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$|^127\.0\.0\.1:[0-9]+$|^localhost:[0-9]+$'; then
      echo "tipo=ADB sem fio/TCP | destino=$SERIAL | origem=adb devices" >> "$out"
    else
      echo "tipo=ADB USB ou serial local | serial=$SERIAL | origem=adb devices" >> "$out"
    fi
  fi

  grep -nE '\[sys\.usb\.(config|state)\]|\[persist\.sys\.usb\.config\]|\[init\.svc\.adbd\]' "$RAW_DIR/getprop_all.txt" 2>/dev/null \
    | sed 's/^/getprop_all.txt:/' >> "$out" || true

  grep -nE -i 'mCurrentFunctions|mScreenUnlockedFunctions|mUsbDataUnlocked|current functions|configured|mtp|ptp|rndis|midi|accessory|adb' "$RAW_DIR/dumpsys_usb.txt" 2>/dev/null \
    | grep -viE 'COMMAND:|Permission denied|not found' \
    | head -n 35 \
    | sed 's/^/dumpsys_usb.txt:/' >> "$out" || true

  local count
  count="$(wc -l < "$out" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Resumo: nenhum tipo USB/ADB extraido."
  else
    line "Resumo: conexoes USB/ADB identificadas para contexto."
    line "Tipo e origem:"
    sed -n '1,40p' "$out" >> "$REPORT"
    line "Falso positivo: USB, MTP, PTP ou ADB nao contam como rastro suspeito sozinhos."
    append_bucket "review" "🔌" "USB / ADB / TIPO DE CONEXAO" "$out" 10
  fi
}

extract_ip_report() {
  section "🌐 REDE / TIPO DE CONEXAO"

  local tmp="$RAW_DIR/conexoes_publicas.txt"
  : > "$tmp"

  awk '
    BEGIN{IGNORECASE=1}
    /^(tcp|udp)/ {
      proto=$1; state=""; remote="";
      for (i=1;i<=NF;i++) {
        if ($i ~ /^(ESTAB|ESTABLISHED|SYN-SENT|LISTEN|UNCONN|CLOSE-WAIT|TIME-WAIT)$/) state=$i;
      }
      remote=$(NF-1);
      if (remote ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/) {
        split(remote,a,":"); ip=a[1];
        if (ip !~ /^(0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|224\.|239\.|255\.255\.255\.255)/ && ip !~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
          print "tipo=" toupper(proto) " | estado=" state " | remoto=" remote " | arquivo=ss_connections.txt"
        }
      }
    }
  ' "$RAW_DIR/ss_connections.txt" 2>/dev/null | sort -u | head -n 40 >> "$tmp" || true

  awk '
    BEGIN{IGNORECASE=1}
    /^(tcp|udp)/ {
      proto=$1; remote=$5;
      if (remote ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/) {
        split(remote,a,":"); ip=a[1];
        if (ip !~ /^(0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|224\.|239\.|255\.255\.255\.255)/ && ip !~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
          print "tipo=" toupper(proto) " | remoto=" remote " | arquivo=netstat_connections.txt"
        }
      }
    }
  ' "$RAW_DIR/netstat_connections.txt" 2>/dev/null | sort -u | head -n 40 >> "$tmp" || true

  sort -u "$tmp" -o "$tmp" 2>/dev/null || true

  local count
  count="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Resumo: nenhuma conexao TCP/UDP publica extraida de ss/netstat."
    return 0
  fi

  line "Resumo: $count conexao(oes) publica(s) TCP/UDP extraida(s)."
  line "Tipo de conexao, destino e arquivo:"
  sed -n '1,30p' "$tmp" >> "$REPORT"
  line "Falso positivo: conexao publica nao conta como rastro suspeito sozinha. Pode ser app, Google, CDN, notificacao, operadora ou sistema."

  append_bucket "review" "🌐" "REDE / TIPO DE CONEXAO" "$tmp" 10
}

write_report_header() {
  : > "$REPORT"
  line "RELATORIO RESUMIDO DE TRIAGEM ANDROID VIA ADB / TERMUX"
  line "Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
  line "Dispositivo ADB: ${SERIAL:-nao definido}"
  line "Relatorio salvo em: $REPORT"
  line ""

  section "📌 COMO LER ESTE RELATORIO"
  line "- Separado por area, sem ranking de maior/pior."
  line "- Rastro de root/modificacao/log limpo aparece como achado direto."
  line "- IP, USB, ADB, MTP, servico parado, permissao sensivel e instalacao de app ficam como contexto para revisar, nao como prova."
  line "- Os arquivos brutos foram temporarios e sao apagados ao final."
  line "- O scanner nao apaga logs do Android, nao desinstala apps e nao altera configuracoes."
}

analyze() {
  echo
  echo "🧠 Analisando por area e reduzindo falsos positivos..."

  STRICT_COUNT=0
  REVIEW_COUNT=0
  AREA_IDX=0
  : > "$STRICT_FILE"
  : > "$REVIEW_FILE"

  write_report_header

  section "📦 COLETA"
  line "Comandos executados: $(wc -l < "$STATUS_FILE" 2>/dev/null | tr -d ' ')"
  line "Arquivos brutos: temporarios, apagados automaticamente ao final."
  line "Arquivo final mantido: somente este relatorio em Downloads."
  line ""
  line "Comandos que falharam ou foram bloqueados, comum sem root:"
  awk -F'|' '$2 != "0" && $2 != "SKIPPED" {print "- " $1 " | rc=" $2 " | " $3}' "$STATUS_FILE" >> "$REPORT" 2>/dev/null || true

  section "📱 PACOTES INSTALADOS"
  local total_pkgs user_pkgs system_pkgs
  total_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_full.txt" 2>/dev/null || echo 0)"
  user_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_user_apps.txt" 2>/dev/null || echo 0)"
  system_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_system_apps.txt" 2>/dev/null || echo 0)"
  line "Total de pacotes detectados: $total_pkgs"
  line "Pacotes de usuario detectados: $user_pkgs"
  line "Pacotes de sistema detectados: $system_pkgs"

  detect_root_modules
  detect_root_frameworks
  detect_root_services

  finding_area "🔐" "PROPRIEDADES DE SISTEMA / ADB ROOT / SELINUX" \
    '\[ro\.secure\]: \[0\]|\[ro\.debuggable\]: \[1\]|\[service\.adb\.root\]: \[1\]|\[ro\.adb\.secure\]: \[0\]|SELinux.*permissive|^selinux_status\.txt:[0-9]+:Permissive$|\bsetenforce 0\b' \
    "strict" 25

  finding_area "🧱" "BOOTLOADER / VERIFIED BOOT / VERITY" \
    '\[ro\.boot\.verifiedbootstate\]: \[(orange|yellow|red)\]|\[ro\.boot\.flash\.locked\]: \[0\]|\[ro\.boot\.vbmeta\.device_state\]: \[unlocked\]|\[ro\.boot\.veritymode\]: \[(eio|disabled)\]|\[ro\.boot\.warranty_bit\]: \[1\]|\[ro\.warranty_bit\]: \[1\]' \
    "review" 20

  finding_area "🧪" "HOOK / INJECAO / ANALISE" \
    'frida-server|/data/local/tmp/frida|objection|substrate|cydia|lsposed|edxposed|riru|zygisknext|shamiko|xposed' \
    "strict" 25

  finding_area "🧹" "POSSIVEL LIMPEZA OU MANIPULACAO DE LOG" \
    'logcat -c|clear log|reset logs|log buffer.*cleared|cleared.*log buffer|logd.*cleared|dropbox.*clear|tombstone.*removed' \
    "strict" 25

  finding_area "🧭" "APPS DE ACESSO REMOTO / CONTROLE" \
    'anydesk|teamviewer|airmirror|airdroid|rustdesk|vnc|scrcpy|remotedesktop|remote\.control|spyware|stalkerware' \
    "review" 25

  finding_area "📦" "INSTALACAO / REMOCAO / SUBSTITUICAO DE APPS" \
    'PACKAGE_ADDED|PACKAGE_REMOVED|PACKAGE_REPLACED|android.intent.action.PACKAGE_ADDED|android.intent.action.PACKAGE_REMOVED|Removing package|installPackage|deletePackage|\bINSTALL\b|\bUNINSTALL\b' \
    "review" 25

  detect_usb_connection_types
  extract_ip_report

  finding_area "🛑" "SERVICOS INIT.SVC PARADOS" \
    '\[init\.svc\..*\]: \[stopped\]' \
    "review" 20

  finding_area "🛡️" "PERMISSOES SENSIVEIS / APP OPS" \
    'SYSTEM_ALERT_WINDOW|BIND_ACCESSIBILITY_SERVICE|READ_SMS|SEND_SMS|RECORD_AUDIO|CAMERA|ACCESS_FINE_LOCATION|ACCESS_COARSE_LOCATION|PACKAGE_USAGE_STATS|REQUEST_INSTALL_PACKAGES|MANAGE_EXTERNAL_STORAGE|QUERY_ALL_PACKAGES|DEVICE_ADMIN|android.permission.BIND_DEVICE_ADMIN|WRITE_SECURE_SETTINGS|DUMP' \
    "review" 25

  finding_area "⏰" "JOBS / ALARMES / ATIVIDADE EM SEGUNDO PLANO" \
    'JobStatus|jobscheduler|alarm|wakeup|wakelock|foreground service|FGS|RECEIVER|broadcast' \
    "review" 25

  section "🧯 FILTROS DE FALSO POSITIVO USADOS"
  line "- Linhas geradas pela propria coleta foram ignoradas."
  line "- Permission denied, not found e no such file foram ignorados como achados."
  line "- Termux foi filtrado para nao virar falso positivo de app tecnico."
  line "- USB/ADB/MTP/PTP aparecem como tipo de conexao, mas nao contam como rastro suspeito sozinhos."
  line "- Conexao TCP/UDP publica aparece com tipo e destino, mas nao conta como rastro suspeito sozinha."
  line "- App instalado/removido, servico parado e permissao sensivel ficam como contexto."
  line "- Modulo root so entra como rastro quando ha modulo/propriedade/servico/binario/framework detectavel, nao por erro de permissao."

  section "✅ RESULTADO FINAL"
  if [ "$STRICT_COUNT" -gt 0 ]; then
    line "RASTROS ENCONTRADOS nas areas abaixo."
    line "Total de ocorrencias diretas: $STRICT_COUNT"
    cat "$STRICT_FILE" >> "$REPORT"
  else
    line "DISPOSITIVO LIMPO para rastros de root/modificacao/log/hook pelos criterios do scanner."
  fi

  if [ "$REVIEW_COUNT" -gt 0 ]; then
    section "📝 CONTEXTO PARA REVISAO"
    line "Total de ocorrencias contextuais: $REVIEW_COUNT"
    line "Esses achados foram separados para reduzir falso positivo e nao contam sozinhos como rastro suspeito."
    cat "$REVIEW_FILE" >> "$REPORT"
  fi
}

show_final_result() {
  header

  if [ "$STRICT_COUNT" -gt 0 ]; then
    echo -e "${RED}🚨 RASTROS ENCONTRADOS${NC}"
    echo
    echo "O que foi encontrado, separado por area:"
    sed -n '1,140p' "$STRICT_FILE" 2>/dev/null || true
  else
    echo -e "${GREEN}✅ DISPOSITIVO LIMPO${NC}"
    echo
    echo "Nenhum rastro de root/modificacao/log/hook foi encontrado pelos criterios do scanner."
  fi

  if [ "$REVIEW_COUNT" -gt 0 ]; then
    echo
    echo -e "${YELLOW}📝 Contexto encontrado, sem contar como rastro suspeito:${NC}"
    echo "Mostrando tipo de conexao, USB/ADB, apps, permissoes ou eventos relevantes quando existirem."
    sed -n '1,110p' "$REVIEW_FILE" 2>/dev/null || true
  fi

  echo
  echo "📄 Relatorio salvo em Downloads:"
  echo "$REPORT"
  echo
  echo "🧹 Arquivos brutos temporarios: apagados."
  pause_enter
}

start_scanner() {
  header

  if ! choose_device; then
    echo "⚠️ Nenhum dispositivo ADB autorizado encontrado."
    echo
    echo "Use a opcao 1 para parear/conectar primeiro."
    pause_enter
    return 1
  fi

  echo "📱 Dispositivo selecionado: $SERIAL"
  echo "📄 Relatorio sera salvo em: $OUT_DIR"
  echo
  echo "🚀 Iniciando scanner..."
  echo

  collect_all
  analyze
  show_final_result
}

menu() {
  while true; do
    header
    echo "1) 🔗 Parear e conectar ADB sem fio"
    echo "2) 🚀 Iniciar scanner, gerar relatorio e analisar"
    echo "3) 📱 Ver dispositivos ADB"
    echo "0) 🚪 Sair"
    echo
    read -r -p "Opcao: " opt

    case "$opt" in
      1)
        pair_and_connect
        ;;
      2)
        start_scanner
        ;;
      3)
        show_devices
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Opcao invalida."
        sleep 1
        ;;
    esac
  done
}

main() {
  require_adb
  ensure_downloads
  menu
}

main
