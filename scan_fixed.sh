#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail

OUT_DIR="$HOME/android_adb_audit_result"
KEEP_RAW=0
NO_BUGREPORT=0
SERIAL=""
ADB_SERIAL_ARGS=()
ADB_HOST="127.0.0.1"
RAW_DIR=""
REPORT=""
STATUS_FILE=""
TIMESTAMP=""
STEP=0
TOTAL_STEPS=49

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-raw)
      KEEP_RAW=1
      ;;
    --no-bugreport)
      NO_BUGREPORT=1
      ;;
    --out)
      shift
      OUT_DIR="${1:-$OUT_DIR}"
      ;;
    *)
      echo "Opção desconhecida: $1"
      echo "Uso: bash $0 [--keep-raw] [--no-bugreport] [--out PASTA]"
      exit 1
      ;;
  esac
  shift
done

clear_screen() {
  if command -v clear >/dev/null 2>&1; then
    clear
  else
    printf '\033c'
  fi
}

pause_screen() {
  echo
  read -r -p "Pressione ENTER para continuar... " _
}

cleanup_current_raw() {
  if [ "$KEEP_RAW" -eq 0 ] && [ -n "${RAW_DIR:-}" ] && [ -d "$RAW_DIR" ]; then
    rm -rf "$RAW_DIR"
  fi
}

cleanup_leftovers() {
  local tmp_base
  tmp_base="${TMPDIR:-/tmp}"

  rm -rf "$tmp_base"/android_adb_raw_* 2>/dev/null || true
  find "$OUT_DIR" -type f \( -name '*.stdout.tmp' -o -name '*.stderr.tmp' -o -name '*.tmp' \) -delete 2>/dev/null || true
}

trap cleanup_current_raw EXIT

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

panel_header() {
  clear_screen
  echo "========================================"
  echo "        ANDROID ADB AUDIT - TERMUX"
  echo "========================================"
  echo "ADB local: $ADB_HOST"
  echo "Saída: $OUT_DIR"
  if [ -n "${SERIAL:-}" ]; then
    echo "Dispositivo: $SERIAL"
  else
    echo "Dispositivo: não selecionado"
  fi
  echo "========================================"
  echo
}

progress_screen() {
  local title="$1"
  local detail="${2:-}"

  clear_screen
  echo "========================================"
  echo "        SCANNER EM EXECUÇÃO"
  echo "========================================"
  echo "Etapa: $STEP/$TOTAL_STEPS"
  echo "Agora: $title"
  if [ -n "$detail" ]; then
    echo "Item: $detail"
  fi
  echo
  echo "Relatório final:"
  echo "$REPORT"
  echo
  echo "Aguarde. Não feche o Termux."
}

require_adb() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "ADB não encontrado. Instale com:"
    echo "pkg install android-tools"
    exit 1
  fi
}

device_count() {
  adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" {count++} END {print count+0}'
}

choose_device() {
  local count
  count="$(device_count)"

  if [ "$count" -eq 0 ]; then
    SERIAL=""
    ADB_SERIAL_ARGS=()
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
    ADB_SERIAL_ARGS=(-s "$SERIAL")
    return 0
  fi

  echo "Mais de um dispositivo ADB conectado:"
  adb devices | awk 'NR > 1 && $2 == "device" {print "- " $1}'
  echo
  read -r -p "Digite o serial/IP do dispositivo que deseja analisar: " SERIAL

  if [ -z "$SERIAL" ]; then
    echo "Nenhum dispositivo escolhido."
    return 1
  fi

  ADB_SERIAL_ARGS=(-s "$SERIAL")
  return 0
}

show_devices() {
  panel_header
  echo "Dispositivos ADB:"
  echo
  adb devices
  pause_screen
}

pair_and_connect() {
  local pair_port pair_code connect_port pair_out pair_rc connect_out connect_rc

  panel_header
  echo "Parear e conectar ADB sem fio"
  echo
  echo "No Android, abra:"
  echo "Configurações > Opções do desenvolvedor > Depuração sem fio"
  echo
  echo "Use a opção 'Parear dispositivo com código de pareamento'."
  echo "Não precisa digitar IP. Este scanner usa $ADB_HOST."
  echo

  read -r -p "Porta de pareamento: " pair_port
  read -r -p "Código de pareamento: " pair_code

  if [ -z "$pair_port" ] || [ -z "$pair_code" ]; then
    echo
    echo "Porta ou código vazio. Pareamento cancelado."
    pause_screen
    return 1
  fi

  echo
  echo "Pareando..."
  pair_out="$(adb pair "$ADB_HOST:$pair_port" "$pair_code" 2>&1)"
  pair_rc=$?

  if [ "$pair_rc" -ne 0 ]; then
    echo "Falha no pareamento."
    echo "$pair_out"
    echo
    echo "Confira a porta e o código. Se o Android gerar outro código, use os novos dados."
    pause_screen
    return 1
  fi

  echo "Pareamento concluído."
  echo
  read -r -p "Porta de conexão: " connect_port

  if [ -z "$connect_port" ]; then
    echo
    echo "Porta de conexão vazia. Conexão cancelada."
    pause_screen
    return 1
  fi

  echo
  echo "Conectando..."
  connect_out="$(adb connect "$ADB_HOST:$connect_port" 2>&1)"
  connect_rc=$?
  echo "$connect_out"

  if [ "$connect_rc" -ne 0 ]; then
    echo
    echo "Falha na conexão ADB."
    pause_screen
    return 1
  fi

  sleep 1

  if choose_device; then
    echo
    echo "ADB conectado: $SERIAL"
    echo "Agora volte ao painel e escolha: 2) Iniciar scanner"
  else
    echo
    echo "Conexão feita, mas nenhum dispositivo autorizado apareceu em 'adb devices'."
    echo "Confirme a autorização na tela do Android."
  fi

  pause_screen
}

init_scan_paths() {
  TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUT_DIR"

  if [ "$KEEP_RAW" -eq 1 ]; then
    RAW_DIR="$OUT_DIR/arquivos_brutos_$TIMESTAMP"
    mkdir -p "$RAW_DIR"
  else
    RAW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/android_adb_raw_${TIMESTAMP}_XXXXXX")"
  fi

  REPORT="$OUT_DIR/relatorio_android_adb_$TIMESTAMP.txt"
  STATUS_FILE="$RAW_DIR/status_comandos.txt"
  : > "$STATUS_FILE"

  if [ "$NO_BUGREPORT" -eq 1 ]; then
    TOTAL_STEPS=48
  else
    TOTAL_STEPS=49
  fi
  STEP=0
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
  progress_screen "Coletando dados" "$filename"

  {
    echo "COMMAND: adb ${ADB_SERIAL_ARGS[*]} shell $remote_cmd"
    echo "START: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
  } > "$out"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" adb "${ADB_SERIAL_ARGS[@]}" shell "$remote_cmd" > "$tmpout" 2> "$tmperr"
    rc=$?
  else
    adb "${ADB_SERIAL_ARGS[@]}" shell "$remote_cmd" > "$tmpout" 2> "$tmperr"
    rc=$?
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
    echo "bugreport|SKIPPED|--no-bugreport" >> "$STATUS_FILE"
    return
  fi

  STEP=$((STEP + 1))
  progress_screen "Gerando bugreport" "bugreport.zip"

  {
    echo "COMMAND: adb ${ADB_SERIAL_ARGS[*]} bugreport $RAW_DIR/bugreport.zip"
    echo "START: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
  } > "$RAW_DIR/bugreport_command_output.txt"

  adb "${ADB_SERIAL_ARGS[@]}" bugreport "$RAW_DIR/bugreport.zip" >> "$RAW_DIR/bugreport_command_output.txt" 2>&1
  rc=$?

  echo "RETURNCODE: $rc" >> "$RAW_DIR/bugreport_command_output.txt"
  echo "bugreport.zip|$rc|adb bugreport" >> "$STATUS_FILE"
}

collect_all() {
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

grep_report() {
  local title="$1"
  local regex="$2"
  local max_lines="${3:-120}"
  local result

  section "$title"

  result="$(grep -RInE -i "$regex" "$RAW_DIR"/*.txt 2>/dev/null | head -n "$max_lines" || true)"

  if [ -z "$result" ]; then
    line "Nenhuma ocorrência encontrada."
  else
    printf '%s\n' "$result" >> "$REPORT"
  fi
}

extract_ip_report() {
  section "REDE / IPS ENCONTRADOS"

  line "IPs encontrados em arquivos de rede e conectividade:"
  line ""

  grep -RIEoh '([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?' \
    "$RAW_DIR"/dumpsys_connectivity.txt \
    "$RAW_DIR"/dumpsys_netstats.txt \
    "$RAW_DIR"/dumpsys_wifi.txt \
    "$RAW_DIR"/ss_connections.txt \
    "$RAW_DIR"/netstat_connections.txt \
    "$RAW_DIR"/ip_addr.txt \
    "$RAW_DIR"/ip_route.txt 2>/dev/null \
    | sed -E 's/:([0-9]+)$//' \
    | grep -Ev '^(0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|224\.|239\.|255\.255\.255\.255)' \
    | grep -Ev '^172\.(1[6-9]|2[0-9]|3[0-1])\.' \
    | sort -u \
    | head -n 200 >> "$REPORT" || true

  line ""
  line "Observação: IP público encontrado não prova invasão. Pode ser servidor normal de app, Google, operadora, CDN ou serviço do sistema."
}

count_packages_in_file() {
  local file="$1"
  if [ -f "$file" ]; then
    grep -c '^package:' "$file" 2>/dev/null || true
  else
    echo 0
  fi
}

analyze() {
  STEP=$((STEP + 1))
  progress_screen "Analisando dados" "relatório final"

  : > "$REPORT"

  line "RELATÓRIO DE TRIAGEM ANDROID VIA ADB / TERMUX"
  line "Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
  line "Dispositivo ADB: ${SERIAL:-não definido}"
  line ""

  section "LIMITAÇÕES"
  line "- Esta é uma triagem defensiva via ADB, não uma perícia forense completa."
  line "- O script não apaga logs do Android."
  line "- O script não desinstala apps."
  line "- O script não altera configurações."
  line "- Arquivos brutos temporários são apagados ao final, exceto com --keep-raw."
  line "- Alguns comandos podem falhar sem root ou por restrição do fabricante."
  line "- Logcat é rotativo; eventos antigos podem ter sido sobrescritos naturalmente."

  section "RESUMO DA COLETA"
  line "Pasta temporária dos brutos: $RAW_DIR"
  line "Relatório final: $REPORT"
  line ""
  line "Comandos executados:"
  wc -l "$STATUS_FILE" >> "$REPORT" 2>/dev/null || true
  line ""
  line "Comandos com retorno diferente de zero:"
  awk -F'|' '$2 != "0" && $2 != "SKIPPED" {print "- " $1 " | rc=" $2 " | " $3}' "$STATUS_FILE" >> "$REPORT" 2>/dev/null || true

  section "BUGREPORT"
  if ls "$RAW_DIR"/*.zip >/dev/null 2>&1; then
    line "Bugreport gerada durante a coleta."
    ls -lh "$RAW_DIR"/*.zip >> "$REPORT" 2>/dev/null || true
  else
    line "Nenhuma bugreport .zip encontrada na pasta temporária."
    line "Pode ter sido pulada, falhado ou gerada com outro nome pelo adb."
  fi

  section "PACOTES INSTALADOS"
  local total_pkgs user_pkgs system_pkgs
  total_pkgs="$(count_packages_in_file "$RAW_DIR/pm_packages_full.txt")"
  user_pkgs="$(count_packages_in_file "$RAW_DIR/pm_packages_user_apps.txt")"
  system_pkgs="$(count_packages_in_file "$RAW_DIR/pm_packages_system_apps.txt")"

  line "Total de pacotes detectados: $total_pkgs"
  line "Pacotes de usuário detectados: $user_pkgs"
  line "Pacotes de sistema detectados: $system_pkgs"

  grep_report "POSSÍVEIS INDICADORES DE ROOT / MODIFICAÇÃO" \
    'magisk|zygisk|supersu|kingroot|kingoroot|xposed|lsposed|riru|frida|substrate|busybox|init\.svc\.magisk|ro\.secure\].*\[0\]|ro\.debuggable\].*\[1\]|service\.adb\.root\].*\[1\]|permissive|uid=0\(root\)' \
    160

  grep_report "APPS / TERMOS QUE MERECEM ATENÇÃO" \
    'magisk|zygisk|supersu|kingroot|xposed|lsposed|frida|shizuku|termux|anydesk|teamviewer|airmirror|airdroid|vnc|spy|stalker|monitor|remote|rat|metasploit' \
    160

  grep_report "INSTALAÇÃO / REMOÇÃO / SUBSTITUIÇÃO DE APPS" \
    'PACKAGE_ADDED|PACKAGE_REMOVED|PACKAGE_REPLACED|android.intent.action.PACKAGE_ADDED|android.intent.action.PACKAGE_REMOVED|Removing package|installPackage|deletePackage|INSTALL|UNINSTALL' \
    200

  grep_report "USB / ADB / MTP" \
    'mtp|ptp|adb|usb|configured|mCurrentFunctions|mScreenUnlockedFunctions|mUsbDataUnlocked|UsbDevice|UsbAccessory' \
    200

  extract_ip_report

  grep_report "SERVIÇOS INIT.SVC PARADOS" \
    '\[init\.svc\..*\]: \[stopped\]' \
    200

  grep_report "SERVIÇOS INIT.SVC RODANDO" \
    '\[init\.svc\..*\]: \[running\]' \
    120

  grep_report "POSSÍVEIS INDÍCIOS DE LIMPEZA / MANIPULAÇÃO DE LOG" \
    'logcat -c|clear log|logd|dropbox|log buffer|cleared|reset logs|auditd|tombstone' \
    160

  grep_report "PERMISSÕES SENSÍVEIS / APP OPS" \
    'SYSTEM_ALERT_WINDOW|BIND_ACCESSIBILITY_SERVICE|READ_SMS|SEND_SMS|RECORD_AUDIO|CAMERA|ACCESS_FINE_LOCATION|PACKAGE_USAGE_STATS|REQUEST_INSTALL_PACKAGES|MANAGE_EXTERNAL_STORAGE|QUERY_ALL_PACKAGES|DEVICE_ADMIN|android.permission.BIND_DEVICE_ADMIN' \
    220

  grep_report "ATIVIDADE EM SEGUNDO PLANO / JOBS / ALARMES" \
    'JobStatus|jobscheduler|alarm|wakeup|wakelock|RUNNING|ACTIVE|bg-|foreground service|FGS' \
    220

  section "OBSERVAÇÕES FINAIS"
  line "- Termos encontrados são indícios, não prova final."
  line "- MTP, ADB ou serviços parados não significam invasão automaticamente."
  line "- IPs externos podem ser normais, principalmente de apps, Google, operadora, CDN ou notificações push."
  line "- Para afirmar invasão, é preciso cruzar horário, app, permissão, conexão e comportamento."
}

start_scanner() {
  if ! choose_device; then
    panel_header
    echo "Nenhum dispositivo ADB autorizado encontrado."
    echo
    echo "Use primeiro a opção 1 para parear/conectar."
    pause_screen
    return 1
  fi

  cleanup_leftovers
  init_scan_paths
  collect_all
  analyze

  local final_report="$REPORT"
  local final_raw="$RAW_DIR"

  cleanup_current_raw
  RAW_DIR=""

  panel_header
  echo "Scanner concluído."
  echo
  echo "Relatório gerado:"
  echo "$final_report"

  if [ "$KEEP_RAW" -eq 1 ]; then
    echo
    echo "Arquivos brutos mantidos em:"
    echo "$final_raw"
  else
    echo
    echo "Arquivos brutos temporários foram apagados."
    echo "Ficou apenas o relatório final."
  fi

  pause_screen
}

main_menu() {
  while true; do
    choose_device >/dev/null 2>&1 || true
    panel_header
    echo "1) Parear e conectar ADB sem fio"
    echo "2) Iniciar scanner, gerar arquivos e analisar"
    echo "3) Ver dispositivos ADB"
    echo "0) Sair"
    echo
    read -r -p "Opção: " opt

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
        clear_screen
        echo "Saindo."
        exit 0
        ;;
      *)
        echo "Opção inválida."
        sleep 1
        ;;
    esac
  done
}

main() {
  mkdir -p "$OUT_DIR"
  require_adb
  cleanup_leftovers
  main_menu
}

main
