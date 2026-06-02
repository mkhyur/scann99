#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail

OUT_DIR="$HOME/android_adb_audit_result"
KEEP_RAW=0
NO_BUGREPORT=0
SERIAL=""
ADB_SERIAL_ARGS=()
ADB_HOST="127.0.0.1"

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

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"

if [ "$KEEP_RAW" -eq 1 ]; then
  RAW_DIR="$OUT_DIR/arquivos_brutos_$TIMESTAMP"
  mkdir -p "$RAW_DIR"
else
  RAW_DIR="$(mktemp -d "$TMPDIR/android_adb_raw_${TIMESTAMP}_XXXXXX")"
fi

REPORT="$OUT_DIR/relatorio_android_adb_$TIMESTAMP.txt"
STATUS_FILE="$RAW_DIR/status_comandos.txt"

cleanup() {
  if [ "$KEEP_RAW" -eq 0 ] && [ -d "$RAW_DIR" ]; then
    rm -rf "$RAW_DIR"
  fi
}

trap cleanup EXIT

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

require_adb() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "ADB não encontrado."
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
  echo "Mais de um dispositivo ADB conectado:"
  adb devices | awk 'NR > 1 && $2 == "device" {print NR-1 ") " $1}'

  echo
  read -r -p "Digite o serial/IP do dispositivo que deseja analisar: " SERIAL

  if [ -z "$SERIAL" ]; then
    echo "Nenhum dispositivo escolhido."
    exit 1
  fi

  ADB_SERIAL_ARGS=(-s "$SERIAL")
}

ask_adb_connection() {
  echo "Verificando dispositivos ADB..."
  adb devices

  if choose_device; then
    echo "Dispositivo selecionado: $SERIAL"
    return 0
  fi

  echo
  echo "Nenhum dispositivo ADB autorizado foi encontrado."
  echo
  echo "Escolha uma opção:"
  echo "1) Parear e conectar ADB sem fio"
  echo "2) Iniciar se já estiver conectado"
  echo "0) Sair"
  echo

  while true; do
    read -r -p "Opção: " opt

    case "$opt" in
      1)
        echo
        echo "No Android, abra:"
        echo "Configurações > Opções do desenvolvedor > Depuração sem fio"
        echo
        echo "Esta versão usa automaticamente: $ADB_HOST"
        echo "Você só precisa informar as portas e o código."
        echo

        read -r -p "Digite a PORTA DE PAREAMENTO: " pair_port
        read -r -p "Digite o CÓDIGO DE PAREAMENTO: " pair_code

        if [ -z "$pair_port" ] || [ -z "$pair_code" ]; then
          echo "Porta de pareamento ou código vazio. Tente novamente."
          continue
        fi

        echo
        echo "Pareando com $ADB_HOST:$pair_port..."
        adb pair "$ADB_HOST:$pair_port" "$pair_code"
        pair_rc=$?

        if [ "$pair_rc" -ne 0 ]; then
          echo
          echo "Pareamento falhou. Confira a porta e o código exibidos na tela de pareamento."
          echo "Se o Android gerar outro código, use a nova porta e o novo código."
          continue
        fi

        echo
        read -r -p "Digite a PORTA DE CONEXÃO: " connect_port

        if [ -z "$connect_port" ]; then
          echo "Porta de conexão vazia. Tente novamente."
          continue
        fi

        echo
        echo "Conectando em $ADB_HOST:$connect_port..."
        adb connect "$ADB_HOST:$connect_port"

        echo
        adb devices

        if choose_device; then
          echo "Dispositivo selecionado: $SERIAL"
          return 0
        fi
        ;;

      2)
        adb devices

        if choose_device; then
          echo "Dispositivo selecionado: $SERIAL"
          return 0
        fi
        ;;

      0)
        exit 0
        ;;

      *)
        echo "Opção inválida."
        ;;
    esac

    echo
    echo "Ainda não encontrei um dispositivo autorizado."
    echo "Confirme se a depuração sem fio está ligada e se o pareamento foi aceito."
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

  echo "[coleta] $filename"

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
    echo "[coleta] bugreport pulada por --no-bugreport"
    echo "bugreport|SKIPPED|--no-bugreport" >> "$STATUS_FILE"
    return
  fi

  echo "[coleta] bugreport.zip"
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
  : > "$STATUS_FILE"

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

  section "$title"

  local result
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

analyze() {
  echo "[análise] gerando relatório..."

  : > "$REPORT"

  line "RELATÓRIO DE TRIAGEM ANDROID VIA ADB / TERMUX"
  line "Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
  line "Dispositivo ADB: ${SERIAL:-não definido}"
  line ""

  section "LIMITAÇÕES"
  line "- verificando..."

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
  total_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_full.txt" 2>/dev/null || echo 0)"
  user_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_user_apps.txt" 2>/dev/null || echo 0)"
  system_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_system_apps.txt" 2>/dev/null || echo 0)"

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

main() {
  echo "=== Android ADB Audit para Termux ==="
  echo

  require_adb
  ask_adb_connection

  echo
  echo "Arquivos finais ficarão em:"
  echo "$OUT_DIR"
  echo

  collect_all
  analyze

  echo
  echo "Relatório gerado:"
  echo "$REPORT"

  if [ "$KEEP_RAW" -eq 1 ]; then
    echo
    echo "Arquivos brutos mantidos em:"
    echo "$RAW_DIR"
  else
    echo
    echo "Arquivos temporários foram apagados automaticamente."
  fi

  echo
  echo "Concluído."
}

main