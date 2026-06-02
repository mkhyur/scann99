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
RAW_DIR="$(mktemp -d "$TMPDIR/android_adb_raw_${TIMESTAMP}_XXXXXX")"
STATUS_FILE="$RAW_DIR/status_comandos.txt"
SUSPECT_FILE="$RAW_DIR/resumo_suspeitos.txt"
REVIEW_FILE="$RAW_DIR/resumo_revisao.txt"
REPORT=""
SUSPECT_COUNT=0
REVIEW_COUNT=0
STEP=0
TOTAL_STEPS=51

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
  read -r -p "Pressione ENTER para continuar..." _
}

header() {
  clear_screen
  echo "========================================"
  echo "      ANDROID ADB SCANNER - TERMUX"
  echo "========================================"
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
    echo "A pasta Download do Termux ainda nao esta liberada."
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
    echo "ADB nao encontrado."
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
  echo "Mais de um dispositivo ADB conectado:"
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
  echo "Dispositivos ADB:"
  echo
  adb devices
  pause_enter
}

pair_and_connect() {
  header
  echo "PAREAR E CONECTAR ADB SEM FIO"
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
    echo "Porta e codigo de pareamento sao obrigatorios."
    pause_enter
    return 1
  fi

  echo "Pareando em 127.0.0.1:$pair_port..."
  adb pair "127.0.0.1:$pair_port" "$pair_code"
  local pair_rc=$?

  if [ "$pair_rc" -ne 0 ]; then
    echo
    echo "Falha no pareamento. Confira a porta e o codigo."
    pause_enter
    return 1
  fi

  echo
  read -r -p "Porta de CONEXAO: " connect_port

  if [ -z "$connect_port" ]; then
    echo "Porta de conexao obrigatoria."
    pause_enter
    return 1
  fi

  echo
  echo "Conectando em 127.0.0.1:$connect_port..."
  adb connect "127.0.0.1:$connect_port"
  echo
  adb devices

  if choose_device; then
    echo
    echo "ADB conectado: $SERIAL"
  else
    echo
    echo "Nenhum dispositivo autorizado encontrado."
  fi

  pause_enter
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
  printf '[%02d/%02d] Coletando: %s\n' "$STEP" "$TOTAL_STEPS" "$filename"

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
    echo "[00/$TOTAL_STEPS] Bugreport pulada por --no-bugreport"
    echo "bugreport|SKIPPED|--no-bugreport" >> "$STATUS_FILE"
    return
  fi

  echo "[00/$TOTAL_STEPS] Coletando: bugreport.zip"
  {
    echo "COMMAND: adb ${ADB_SERIAL_ARGS[*]} bugreport $RAW_DIR/bugreport.zip"
    echo "START: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
  } > "$RAW_DIR/bugreport_command_output.txt"

  adb "${ADB_SERIAL_ARGS[@]}" bugreport "$RAW_DIR/bugreport.zip" >> "$RAW_DIR/bugreport_command_output.txt" 2>&1
  local rc=$?

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

finding_report() {
  local title="$1"
  local regex="$2"
  local max_lines="${3:-120}"
  local bucket="${4:-review}"
  local tmp="$RAW_DIR/finding_$(echo "$title" | tr ' /' '__' | tr -cd 'A-Za-z0-9_').txt"
  local count=0

  section "$title"

  grep -RInE -i "$regex" "$RAW_DIR"/*.txt 2>/dev/null \
    | sed "s|$RAW_DIR/||" \
    | head -n "$max_lines" > "$tmp" || true

  count="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Nenhuma ocorrencia encontrada."
  else
    cat "$tmp" >> "$REPORT"

    if [ "$bucket" = "suspect" ]; then
      SUSPECT_COUNT=$((SUSPECT_COUNT + count))
      {
        echo
        echo "$title"
        echo "----------------------------------------"
        cat "$tmp"
      } >> "$SUSPECT_FILE"
    else
      REVIEW_COUNT=$((REVIEW_COUNT + count))
      {
        echo
        echo "$title"
        echo "----------------------------------------"
        cat "$tmp"
      } >> "$REVIEW_FILE"
    fi
  fi
}

extract_ip_report() {
  section "REDE / IPS PUBLICOS PARA REVISAO"

  local tmp="$RAW_DIR/ips_publicos.txt"
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
    | head -n 200 > "$tmp" || true

  local count
  count="$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')"
  count="${count:-0}"

  if [ "$count" -eq 0 ]; then
    line "Nenhum IP publico foi extraido dos arquivos analisados."
  else
    line "IPs publicos encontrados para revisao. Isso nao prova invasao."
    line ""
    cat "$tmp" >> "$REPORT"
    REVIEW_COUNT=$((REVIEW_COUNT + count))
    {
      echo
      echo "REDE / IPS PUBLICOS PARA REVISAO"
      echo "----------------------------------------"
      sed 's/^/ip_publico: /' "$tmp"
    } >> "$REVIEW_FILE"
  fi
}

write_report_header() {
  : > "$REPORT"
  line "RELATORIO DE TRIAGEM ANDROID VIA ADB / TERMUX"
  line "Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
  line "Dispositivo ADB: ${SERIAL:-nao definido}"
  line ""

  section "LIMITACOES"
  line "- Esta e uma triagem defensiva via ADB, nao uma pericia forense completa."
  line "- O scanner nao apaga logs do Android."
  line "- O scanner nao desinstala apps."
  line "- O scanner nao altera configuracoes."
  line "- Os arquivos brutos sao temporarios e sao apagados ao final."
  line "- O unico arquivo final mantido e este relatorio em Downloads."
  line "- Logcat e rotativo; eventos antigos podem ter sido sobrescritos naturalmente."
}

analyze() {
  echo
  echo "[analise] Gerando relatorio final..."

  SUSPECT_COUNT=0
  REVIEW_COUNT=0
  : > "$SUSPECT_FILE"
  : > "$REVIEW_FILE"

  write_report_header

  section "RESUMO DA COLETA"
  line "Relatorio final: $REPORT"
  line "Arquivos brutos: temporarios, apagados automaticamente ao final."
  line ""
  line "Comandos executados:"
  wc -l "$STATUS_FILE" >> "$REPORT" 2>/dev/null || true
  line ""
  line "Comandos com retorno diferente de zero:"
  awk -F'|' '$2 != "0" && $2 != "SKIPPED" {print "- " $1 " | rc=" $2 " | " $3}' "$STATUS_FILE" >> "$REPORT" 2>/dev/null || true

  section "BUGREPORT"
  if ls "$RAW_DIR"/*.zip >/dev/null 2>&1; then
    line "Bugreport gerada temporariamente e usada durante a coleta."
  else
    line "Nenhuma bugreport .zip encontrada na coleta temporaria."
  fi

  section "PACOTES INSTALADOS"
  local total_pkgs user_pkgs system_pkgs
  total_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_full.txt" 2>/dev/null || echo 0)"
  user_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_user_apps.txt" 2>/dev/null || echo 0)"
  system_pkgs="$(grep -c '^package:' "$RAW_DIR/pm_packages_system_apps.txt" 2>/dev/null || echo 0)"

  line "Total de pacotes detectados: $total_pkgs"
  line "Pacotes de usuario detectados: $user_pkgs"
  line "Pacotes de sistema detectados: $system_pkgs"

  finding_report "RASTROS SUSPEITOS: ROOT / MODIFICACAO" \
    'magisk|zygisk|supersu|kingroot|kingoroot|xposed|lsposed|riru|frida|substrate|init\.svc\.magisk|ro\.secure\].*\[0\]|ro\.debuggable\].*\[1\]|service\.adb\.root\].*\[1\]|uid=0\(root\)|SELinux.*permissive|\bpermissive\b' \
    200 "suspect"

  finding_report "RASTROS SUSPEITOS: ACESSO REMOTO / CONTROLE" \
    'anydesk|teamviewer|airmirror|airdroid|rustdesk|vnc|scrcpy|spyware|stalkerware|metasploit|frida-server' \
    200 "suspect"

  finding_report "RASTROS SUSPEITOS: POSSIVEL LIMPEZA OU MANIPULACAO DE LOG" \
    'logcat -c|clear log|reset logs|log buffer.*cleared|cleared.*log buffer|logd.*cleared' \
    160 "suspect"

  finding_report "ITENS PARA REVISAO: INSTALACAO / REMOCAO / SUBSTITUICAO DE APPS" \
    'PACKAGE_ADDED|PACKAGE_REMOVED|PACKAGE_REPLACED|android.intent.action.PACKAGE_ADDED|android.intent.action.PACKAGE_REMOVED|Removing package|installPackage|deletePackage|\bINSTALL\b|\bUNINSTALL\b' \
    220 "review"

  finding_report "ITENS PARA REVISAO: USB / ADB / MTP" \
    'mtp|ptp|adb|usb|configured|mCurrentFunctions|mScreenUnlockedFunctions|mUsbDataUnlocked|UsbDevice|UsbAccessory' \
    220 "review"

  extract_ip_report

  finding_report "ITENS PARA REVISAO: SERVICOS INIT.SVC PARADOS" \
    '\[init\.svc\..*\]: \[stopped\]' \
    220 "review"

  finding_report "ITENS PARA REVISAO: PERMISSOES SENSIVEIS / APP OPS" \
    'SYSTEM_ALERT_WINDOW|BIND_ACCESSIBILITY_SERVICE|READ_SMS|SEND_SMS|RECORD_AUDIO|CAMERA|ACCESS_FINE_LOCATION|PACKAGE_USAGE_STATS|REQUEST_INSTALL_PACKAGES|MANAGE_EXTERNAL_STORAGE|QUERY_ALL_PACKAGES|DEVICE_ADMIN|android.permission.BIND_DEVICE_ADMIN' \
    260 "review"

  finding_report "ITENS PARA REVISAO: ATIVIDADE EM SEGUNDO PLANO / JOBS / ALARMES" \
    'JobStatus|jobscheduler|alarm|wakeup|wakelock|RUNNING|ACTIVE|bg-|foreground service|FGS' \
    260 "review"

  section "RESULTADO FINAL"
  if [ "$SUSPECT_COUNT" -gt 0 ]; then
    line "RESULTADO: RASTRO SUSPEITO ENCONTRADO"
    line "Ocorrencias suspeitas encontradas: $SUSPECT_COUNT"
    line ""
    cat "$SUSPECT_FILE" >> "$REPORT"
  else
    line "RESULTADO: DISPOSITIVO LIMPO"
    line "Nenhum rastro suspeito foi encontrado pelos criterios do scanner."
  fi

  if [ "$REVIEW_COUNT" -gt 0 ]; then
    line ""
    line "Itens para revisao encontrados: $REVIEW_COUNT"
    line "Esses itens nao provam invasao sozinhos, mas foram registrados para contexto."
  fi

  section "OBSERVACOES FINAIS"
  line "- Rastro suspeito nao significa prova definitiva de invasao."
  line "- Dispositivo limpo significa que nada suspeito foi encontrado pelos criterios deste scanner."
  line "- IP publico, USB, MTP, ADB, instalacao/remocao de app ou servico parado podem ser normais."
  line "- Para uma conclusao mais forte, cruze horario, app, permissao, conexao e comportamento observado."
}

show_final_result() {
  header

  if [ "$SUSPECT_COUNT" -gt 0 ]; then
    echo "RESULTADO: RASTRO SUSPEITO ENCONTRADO"
    echo "Ocorrencias suspeitas: $SUSPECT_COUNT"
    echo
    echo "O que foi encontrado e em qual arquivo:"
    echo
    sed -n '1,80p' "$SUSPECT_FILE" 2>/dev/null || true
    echo
    echo "Relatorio completo salvo em:"
    echo "$REPORT"
  else
    echo "RESULTADO: DISPOSITIVO LIMPO"
    echo
    echo "Nenhum rastro suspeito foi encontrado pelos criterios do scanner."
    echo
    echo "Relatorio salvo em:"
    echo "$REPORT"
  fi

  echo
  echo "Arquivos brutos temporarios: apagados."
  pause_enter
}

start_scanner() {
  header

  if ! choose_device; then
    echo "Nenhum dispositivo ADB autorizado encontrado."
    echo
    echo "Use a opcao 1 para parear/conectar primeiro."
    pause_enter
    return 1
  fi

  echo "Dispositivo selecionado: $SERIAL"
  echo "Relatorio sera salvo em: $OUT_DIR"
  echo
  echo "Iniciando coleta e analise..."
  echo

  collect_all
  analyze
  show_final_result
}

menu() {
  while true; do
    header
    echo "1) Parear e conectar ADB sem fio"
    echo "2) Iniciar scanner, gerar relatorio e analisar"
    echo "3) Ver dispositivos ADB"
    echo "0) Sair"
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
