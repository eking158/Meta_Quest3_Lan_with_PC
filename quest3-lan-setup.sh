#!/usr/bin/env bash
#
# quest3-lan-setup.sh
#
# 라우터 없이, 우분투 PC ↔ Meta Quest 3 를 랜선 한 가닥으로 바로 연결하기 위한
# 원터치 설정 스크립트.
#
# 이 스크립트가 하는 일 (PDF "Meta Quest 3 : 라우터 없이 우분투 PC와 유선 랜 연결" 기준)
#   1. PC의 유선 랜 장치(내장/USB 랜 어댑터)를 읽어 목록으로 보여주고 선택 (케이블 꽂힌 장치가 기본값)
#   2. PC 쪽 고정 IP 결정
#      - 해당 인터페이스에 이미 manual(고정 IP)로 설정된 유선 프로필이 있으면 그대로 사용 (수정하지 않음)
#      - 없으면 IP를 입력받아 전용 프로필(quest3-direct)을 새로 만들어 설정 (기본 192.168.51.71/24)
#   3. dnsmasq 설치 (없으면, 서비스 없는 dnsmasq-base 패키지)
#   4. Quest 전용 dnsmasq 서비스(quest3-dnsmasq.service)와 설정(/etc/quest3-lan/dnsmasq.conf) 생성
#      - 시스템 dnsmasq(/etc/dnsmasq.d)와 분리되어 다른 설정과 충돌하지 않음
#      - bind-dynamic 이라 부팅 시 랜선이 안 꽂혀 있어도 실패하지 않고, 연결되면 자동으로 동작
#   5. 서비스 재시작 + 상태 확인
#   6. Quest 3 앱에 입력할 IP 안내
#
# 사용법:
#   sudo ./quest3-lan-setup.sh                 # 기존 manual 설정 사용, 없으면 IP 입력받음
#   sudo ./quest3-lan-setup.sh --iface enp4s0   # 인터페이스 직접 지정
#   sudo ./quest3-lan-setup.sh --uninstall      # 설정 해제(전용 서비스 + quest3-direct 프로필 제거)
#   ./quest3-lan-setup.sh --status              # 현재 설정 상태 보기
#   옵션 없이 터미널에서 실행하면(바탕화면 아이콘 포함) 처음 사용자를 위한 안내 메뉴가 나옵니다:
#     1) 연결 설정하기  2) 연결 상태 확인  3) 연결 해제  4) 준비물·연결 방법 안내  0) 종료
#
set -euo pipefail

# ── 색상 ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi
info()  { echo "${C_CYAN}[정보]${C_RESET} $*"; }
ok()    { echo "${C_GREEN}[완료]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[주의]${C_RESET} $*"; }
err()   { echo "${C_RED}[오류]${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

# ── 기본값 (PDF 예시 값과 동일) ──────────────────────────────────────
IFACE=""
DEFAULT_CIDR="192.168.51.71/24"
GATEWAY_ARG=""        # --gateway-ip 로 받은 값 (IP 또는 IP/prefix)
GATEWAY_IP=""
PREFIX=""
NETMASK=""
RANGE_START=""        # 비워두면 PC IP 기준으로 자동 계산 (/24 이하면 .150 ~ .199)
RANGE_END=""
LEASE="12h"
CONF_DIR="/etc/quest3-lan"
CONF_PATH="${CONF_DIR}/dnsmasq.conf"
SERVICE_NAME="quest3-dnsmasq"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
LEASE_FILE="/var/lib/misc/${SERVICE_NAME}.leases"
# 이전 버전이 쓰던 위치. /etc/dnsmasq.d 는 .bak 파일까지 읽어들여 "illegal repeated keyword" 오류를 냄
LEGACY_CONF="/etc/dnsmasq.d/quest-direct.conf"
LEGACY_BACKUP_DIR="/var/backups/quest3-lan"
STATE_FILE="${CONF_DIR}/state"   # 설정 해제 시 되돌릴 내용 기록 (예: 시스템 dnsmasq 를 껐는지)
CONN_NAME="quest3-direct"
MODE="install"
ASSUME_YES=0

usage() {
  cat <<EOF
사용법: sudo $0 [옵션]

옵션:
  --iface <NAME>         선택 메뉴 없이 유선 랜 인터페이스 이름을 직접 지정 (예: enp4s0)
  --gateway-ip <IP[/N]>  manual 프로필이 없을 때 쓸 PC 쪽 고정 IP (입력 프롬프트 생략)
                         (기본: ${DEFAULT_CIDR}, 기존 manual 프로필이 있으면 무시됨)
  --range-start <IP>     Quest 3에게 나눠줄 IP 범위 시작 (기본: PC IP 기준 x.x.x.150)
  --range-end <IP>       Quest 3에게 나눠줄 IP 범위 끝   (기본: PC IP 기준 x.x.x.199)
  --lease <TIME>         DHCP lease 유지 시간 (기본: ${LEASE})
  --uninstall            설정 해제: 전용 dnsmasq 서비스 / quest3-direct 프로필 제거 (되돌리기)
  --status               현재 설정 상태 보기 (sudo 불필요)
  -y, --yes              확인 질문 없이 진행 (--uninstall 과 함께 사용)
  -h, --help             도움말 출력

옵션 없이 실행하면 안내 메뉴(설정 / 상태 확인 / 해제 / 준비물 안내)가 나옵니다.
EOF
}

ARGC=$#   # 옵션 없이 실행했는지 (대화형 메뉴 표시 여부)
while [ $# -gt 0 ]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2 ;;
    --gateway-ip) GATEWAY_ARG="$2"; shift 2 ;;
    --range-start) RANGE_START="$2"; shift 2 ;;
    --range-end) RANGE_END="$2"; shift 2 ;;
    --lease) LEASE="$2"; shift 2 ;;
    --uninstall) MODE="uninstall"; shift ;;
    --status) MODE="status"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 옵션: $1  (--help 참고)" ;;
  esac
done

# ── IP 계산 도우미 ───────────────────────────────────────────────────
is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do
    [ $((10#${BASH_REMATCH[$i]})) -le 255 ] || return 1
  done
}
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}
int2ip() {
  echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}
prefix2mask() {
  echo $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF ))
}

# "IP" 또는 "IP/prefix" 를 GATEWAY_IP / PREFIX 로 분해 (prefix 생략 시 24)
parse_cidr() {
  local ip="${1%%/*}" pfx=24
  [[ "$1" == */* ]] && pfx="${1#*/}"
  is_ipv4 "$ip" || return 1
  [[ "$pfx" =~ ^[0-9]+$ ]] && [ "$pfx" -ge 8 ] && [ "$pfx" -le 30 ] || return 1
  GATEWAY_IP="$(int2ip "$(ip2int "$ip")")"   # 010 같은 앞자리 0 제거
  PREFIX="$((10#$pfx))"
}

# manual 설정이 없을 때 PC 쪽 고정 IP를 정한다: --gateway-ip > 사용자 입력 > 기본값
ask_gateway_cidr() {
  if [ -n "$GATEWAY_ARG" ]; then
    parse_cidr "$GATEWAY_ARG" || die "--gateway-ip 값이 올바르지 않습니다: ${GATEWAY_ARG} (예: 192.168.51.71/24)"
    return
  fi
  if [ ! -t 0 ]; then
    warn "입력을 받을 수 없는 환경이라 기본값 ${DEFAULT_CIDR} 을 사용합니다."
    parse_cidr "$DEFAULT_CIDR"
    return
  fi
  local answer
  echo "  이 PC가 Quest와 통신할 때 쓸 주소입니다. 잘 모르면 그냥 엔터를 누르세요 (기본값 사용)."
  while true; do
    read -rp "PC에 설정할 고정 IP를 입력하세요 (IP 또는 IP/prefix) [기본: ${DEFAULT_CIDR}]: " answer
    answer="${answer//[[:space:]]/}"
    [ -z "$answer" ] && answer="$DEFAULT_CIDR"
    if parse_cidr "$answer"; then
      return
    fi
    echo "올바른 형식이 아닙니다. 예: 192.168.51.71 또는 192.168.51.71/24 (prefix 8~30)"
  done
}

# PC IP/prefix 기준으로 NETMASK, DHCP 범위를 결정하고 검증
derive_range() {
  local gw mask net bcast start end
  gw="$(ip2int "$GATEWAY_IP")"
  mask="$(prefix2mask "$PREFIX")"
  net=$(( gw & mask ))
  bcast=$(( net | (~mask & 0xFFFFFFFF) ))
  NETMASK="$(int2ip "$mask")"

  if [ -z "$RANGE_START" ] && [ -z "$RANGE_END" ]; then
    if [ "$PREFIX" -le 24 ]; then
      # PDF 예시와 같은 방식: PC IP가 속한 /24 의 .150 ~ .199
      start=$(( (gw & 0xFFFFFF00) + 150 ))
      end=$(( (gw & 0xFFFFFF00) + 199 ))
      if [ "$gw" -ge "$start" ] && [ "$gw" -le "$end" ]; then
        start=$(( (gw & 0xFFFFFF00) + 200 ))
        end=$(( (gw & 0xFFFFFF00) + 249 ))
      fi
    elif [ $(( gw + 1 )) -lt "$bcast" ]; then
      start=$(( gw + 1 )); end=$(( bcast - 1 ))
    else
      start=$(( net + 1 )); end=$(( gw - 1 ))
    fi
    RANGE_START="$(int2ip "$start")"
    RANGE_END="$(int2ip "$end")"
    return
  fi

  [ -n "$RANGE_START" ] && [ -n "$RANGE_END" ] || die "--range-start 와 --range-end 는 함께 지정해야 합니다."
  is_ipv4 "$RANGE_START" || die "--range-start 값이 올바르지 않습니다: ${RANGE_START}"
  is_ipv4 "$RANGE_END"   || die "--range-end 값이 올바르지 않습니다: ${RANGE_END}"
  start="$(ip2int "$RANGE_START")"
  end="$(ip2int "$RANGE_END")"
  [ "$start" -le "$end" ] || die "DHCP 범위 시작이 끝보다 큽니다: ${RANGE_START} ~ ${RANGE_END}"
  if [ "$start" -le "$net" ] || [ "$end" -ge "$bcast" ]; then
    die "DHCP 범위(${RANGE_START} ~ ${RANGE_END})가 PC 네트워크 ${GATEWAY_IP}/${PREFIX} 밖에 있습니다."
  fi
  if [ "$gw" -ge "$start" ] && [ "$gw" -le "$end" ]; then
    die "DHCP 범위(${RANGE_START} ~ ${RANGE_END})에 PC IP ${GATEWAY_IP} 가 포함되어 있습니다."
  fi
}

# 물리 유선 이더넷 인터페이스 목록 (Wi-Fi, veth, docker/bridge 등 가상 장치 제외)
list_wired_ifaces() {
  local p
  for p in /sys/class/net/*; do
    [ "$(cat "$p/type" 2>/dev/null)" = "1" ] || continue
    [ -e "$p/device" ] || continue
    if [ -e "$p/wireless" ] || [ -e "$p/phy80211" ]; then
      continue
    fi
    echo "${p##*/}"
  done
}

# 인터페이스 한 개의 상태를 한 줄로 요약 (선택 메뉴용)
iface_carrier() {
  [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = "1" ]
}
describe_iface() {
  local n="$1" link mac driver addrs conn=""
  if iface_carrier "$n"; then link="${C_GREEN}연결됨${C_RESET}"; else link="${C_YELLOW}케이블 없음${C_RESET}"; fi
  mac="$(cat "/sys/class/net/$n/address" 2>/dev/null || echo "?")"
  driver="$(basename "$(readlink -f "/sys/class/net/$n/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")"
  addrs="$(ip -4 -o addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd, -)"
  if command -v nmcli >/dev/null 2>&1; then
    conn="$(nmcli -g GENERAL.CONNECTION device show "$n" 2>/dev/null || true)"
  fi
  printf '%-16s %s  MAC %s  드라이버 %s  IP %s  프로필 %s\n' \
    "$n" "$link" "$mac" "${driver:-?}" "${addrs:--}" "${conn:--}"
}

# PC의 유선 랜 장치를 보여주고 사용자가 고르게 한다. 결과는 IFACE 에 저장.
choose_iface() {
  local -a cands
  local i default=1 answer
  mapfile -t cands < <(list_wired_ifaces)
  [ "${#cands[@]}" -gt 0 ] \
    || die "유선(이더넷) 랜 장치를 찾지 못했습니다. USB 랜 어댑터라면 꽂혀 있는지 확인하거나 --iface 옵션으로 직접 지정해주세요."

  # 케이블이 꽂혀 있는(링크가 올라온) 첫 장치를 기본 선택으로
  for i in "${!cands[@]}"; do
    if iface_carrier "${cands[$i]}"; then default=$(( i + 1 )); break; fi
  done

  if [ ! -t 0 ]; then
    # 입력을 받을 수 없으면 후보가 하나이거나 케이블이 꽂힌 장치가 있을 때만 자동 선택
    if [ "${#cands[@]}" -eq 1 ] || iface_carrier "${cands[$((default - 1))]}"; then
      IFACE="${cands[$((default - 1))]}"
      ok "인터페이스 자동 선택: ${IFACE}"
      return
    fi
    die "유선 랜 장치가 여러 개라 자동으로 고를 수 없습니다. --iface 옵션으로 지정해주세요: ${cands[*]}"
  fi

  echo "PC에서 발견된 유선 랜 장치:"
  for i in "${!cands[@]}"; do
    printf '  %d) %s\n' "$(( i + 1 ))" "$(describe_iface "${cands[$i]}")"
  done
  echo "  (Quest 3와 랜선으로 연결된 장치는 보통 '연결됨'으로 표시됩니다)"
  while true; do
    read -rp "사용할 장치 번호를 선택하세요 [기본: ${default}]: " answer
    answer="${answer//[[:space:]]/}"
    [ -z "$answer" ] && answer="$default"
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#cands[@]}" ]; then
      IFACE="${cands[$((answer - 1))]}"
      return
    fi
    echo "1 ~ ${#cands[@]} 사이의 번호를 입력해주세요."
  done
}

# 이전 버전이 /etc/dnsmasq.d 에 만든 설정·백업 파일을 치운다 (시스템 dnsmasq 가 읽어서 충돌하므로)
cleanup_legacy_conf() {
  local f moved=0
  for f in "$LEGACY_CONF" "$LEGACY_CONF".bak.*; do
    [ -e "$f" ] || continue
    if [ "$1" = "backup" ]; then
      mkdir -p "$LEGACY_BACKUP_DIR"
      mv -f "$f" "$LEGACY_BACKUP_DIR/"
    else
      rm -f "$f"
    fi
    moved=1
  done
  if [ "$moved" -eq 1 ]; then
    if [ "$1" = "backup" ]; then
      info "이전 버전 설정을 /etc/dnsmasq.d 에서 ${LEGACY_BACKUP_DIR} 로 옮겼습니다."
    else
      ok "이전 버전 설정 제거: ${LEGACY_CONF}*"
    fi
  fi
}

# 시스템 dnsmasq.service 가 따로 쓰는 설정이 없는지 (기본 파일만 있으면 true)
system_dnsmasq_unused() {
  local f
  if [ -f /etc/dnsmasq.conf ] && grep -qEv '^[[:space:]]*(#|$)' /etc/dnsmasq.conf; then
    return 1
  fi
  for f in /etc/dnsmasq.d/*; do
    [ -e "$f" ] || continue
    case "${f##*/}" in
      README|ubuntu-fan|*.dpkg-dist|*.dpkg-old|*.dpkg-new) ;;
      *) return 1 ;;
    esac
  done
}

has_conn_profile() {
  command -v nmcli >/dev/null 2>&1 && nmcli -g NAME con show 2>/dev/null | grep -qx "$CONN_NAME"
}

# 이 스크립트로 설정한 흔적이 하나라도 있으면 true
is_configured() {
  local f
  [ -f "$UNIT_PATH" ] || [ -d "$CONF_DIR" ] && return 0
  for f in "$LEGACY_CONF" "$LEGACY_CONF".bak.*; do
    [ -e "$f" ] && return 0
  done
  has_conn_profile
}

# 현재 설정 상태 출력
show_status() {
  local iface="" range="-" svc="없음" addrs="-" leases=0
  if [ -f "$CONF_PATH" ]; then
    iface="$(sed -n 's/^interface=//p' "$CONF_PATH" | head -1)"
    range="$(sed -n 's/^dhcp-range=//p' "$CONF_PATH" | head -1 | awk -F, '{print $1" ~ "$2}')"
  fi
  if [ -f "$UNIT_PATH" ]; then
    svc="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true) (부팅 시 자동 시작: $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true))"
  fi
  if [ -n "$iface" ]; then
    addrs="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | paste -sd, -)"
  fi
  [ -r "$LEASE_FILE" ] && leases="$(grep -c . "$LEASE_FILE" 2>/dev/null || true)"
  echo "  인터페이스        : ${iface:--}"
  echo "  PC IP             : ${addrs:--}"
  echo "  Quest DHCP 범위   : ${range}"
  echo "  전용 서비스       : ${SERVICE_NAME} — ${svc}"
  echo "  전용 프로필       : ${CONN_NAME} — $(has_conn_profile && echo "있음" || echo "없음 (기존 프로필 사용 중이거나 미설정)")"
  echo "  IP 받은 기기 수   : ${leases}"
}

# 설정 해제: 이 스크립트가 만든 것만 제거하고, 바꿔놓은 것은 원래대로 돌려놓는다
do_uninstall() {
  if ! is_configured; then
    info "해제할 설정이 없습니다. (이 PC는 아직 설정되지 않았습니다)"
    return
  fi
  echo "${C_BOLD}=== Quest 3 유선 연결 설정 해제 ===${C_RESET}"
  show_status
  echo
  echo "제거할 항목: 전용 서비스(${SERVICE_NAME}), 설정(${CONF_DIR}), 전용 프로필(${CONN_NAME}), 이전 버전 파일·백업"
  echo "사용자가 직접 만든 유선 프로필(manual 등)은 그대로 둡니다."
  if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
    local answer
    read -rp "설정을 해제할까요? [y/N]: " answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) info "취소했습니다. 아무것도 바뀌지 않았습니다."; return ;;
    esac
  fi
  echo

  local restore_system_dnsmasq=0
  if [ -f "$STATE_FILE" ] && grep -qx 'system_dnsmasq_disabled=1' "$STATE_FILE"; then
    restore_system_dnsmasq=1
  fi

  if [ -f "$UNIT_PATH" ]; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    ok "서비스 중지·제거: ${SERVICE_NAME}"
  fi
  if [ -d "$CONF_DIR" ]; then
    rm -rf "$CONF_DIR"
    ok "설정 제거: ${CONF_DIR}"
  fi
  if [ -f "$LEASE_FILE" ]; then
    rm -f "$LEASE_FILE"
    ok "DHCP 임대 기록 제거: ${LEASE_FILE}"
  fi
  cleanup_legacy_conf delete
  if [ -d "$LEGACY_BACKUP_DIR" ]; then
    rm -rf "$LEGACY_BACKUP_DIR"
    ok "이전 버전 백업 제거: ${LEGACY_BACKUP_DIR}"
  fi
  if has_conn_profile; then
    nmcli con delete "$CONN_NAME" >/dev/null 2>&1 || true
    ok "NetworkManager 전용 프로필 삭제: ${CONN_NAME} (원래 쓰던 프로필이 있으면 자동으로 다시 연결됩니다)"
  fi
  if [ "$restore_system_dnsmasq" -eq 1 ]; then
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    if systemctl start dnsmasq 2>/dev/null; then
      ok "설정 때 꺼두었던 시스템 dnsmasq.service 를 다시 켰습니다."
    else
      warn "시스템 dnsmasq.service 를 다시 켰지만 시작에 실패했습니다: journalctl -u dnsmasq 확인"
    fi
  fi
  echo
  ok "설정 해제 완료."
}

# ── 처음 사용하는 사람을 위한 안내 ──────────────────────────────────
pause() {
  [ -t 0 ] || return 0
  echo
  read -rp "엔터를 누르면 메뉴로 돌아갑니다..." _ || true
}

show_guide() {
  cat <<EOF
${C_BOLD}=== 준비물과 연결 방법 ===${C_RESET}

${C_BOLD}이 도우미가 하는 일${C_RESET}
  라우터(공유기) 없이 랜선 한 가닥으로 이 PC와 Meta Quest 3를 연결합니다.
  이 PC가 Quest에게 IP 주소를 나눠주는 역할을 맡습니다.
  한 번 설정하면 재부팅 후에도 자동으로 유지됩니다.

${C_BOLD}준비물${C_RESET}
  1) USB-C 이더넷 어댑터(또는 허브)
     - Quest 3에는 랜선 구멍이 없어서 꼭 필요합니다.
     - 충전 포트(PD)가 있는 제품을 권장합니다. RTL8153 칩 제품이 잘 동작한다고 알려져 있습니다.
  2) 18W 이상 USB-C 충전기 (어댑터의 충전 포트에 연결, 사용 중 배터리 방전 방지)
  3) 일반 랜선 (Cat5e/Cat6). 크로스 케이블은 보통 필요 없습니다.
  4) 랜 포트가 있는 이 PC (없으면 PC용 USB 랜 어댑터)

${C_BOLD}연결 순서${C_RESET}
  1) Quest 3의 USB-C 포트에 이더넷 어댑터를 꽂습니다.
  2) 어댑터의 충전 포트에 충전기를 연결합니다. (권장)
  3) 랜선으로 어댑터와 이 PC의 랜 포트를 연결합니다.
  4) Quest 3를 켭니다. 테스트할 때는 Quest의 Wi-Fi를 꺼 두면 확실합니다.
  5) 메뉴에서 "1) 연결 설정하기"를 실행합니다.
  6) 마지막에 안내되는 "PC 주소"를 Quest 앱의 서버(PC) 주소 칸에 입력합니다.

${C_BOLD}알아두면 좋은 점${C_RESET}
  - Quest 설정 화면에 "유선 연결됨"이 표시되지 않을 수 있습니다. 그래도 정상일 수 있으니
    메뉴의 "2) 연결 상태 확인"으로 Quest가 응답하는지 확인하세요.
  - Quest OS 업데이트 후 어댑터 인식이 안 되는 경우가 있습니다. 어댑터를 뽑았다 다시 꽂아 보세요.
  - 이 PC의 그 랜 포트는 Quest 전용으로 쓰게 됩니다. 다시 공유기에 꽂아 쓰려면
    "3) 연결 해제"를 실행하세요.
EOF
}

# 설정 파일에 기록해 둔 PC 주소 (예: 192.168.10.71/24)
configured_pc_cidr() {
  local pc="" iface
  if [ -f "$CONF_PATH" ]; then
    pc="$(sed -n 's/^# pc-ip=//p' "$CONF_PATH" | head -1)"
    if [ -z "$pc" ]; then
      # 이전 버전 설정에는 기록이 없으므로 인터페이스의 현재 IP로 대신
      iface="$(sed -n 's/^interface=//p' "$CONF_PATH" | head -1)"
      pc="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')"
    fi
  fi
  echo "$pc"
}

# DHCP 로 IP를 받아간 기기 목록과 현재 응답 여부
show_quest_devices() {
  local exp mac ip host rest n=0
  if [ ! -s "$LEASE_FILE" ]; then
    echo "  아직 IP를 받아간 기기가 없습니다."
    return
  fi
  while read -r exp mac ip host rest; do
    n=$((n + 1))
    [ "$host" = "*" ] && host="이름 없음"
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      echo "  ${C_GREEN}●${C_RESET} ${ip}  (${host}, ${mac}) — ${C_GREEN}응답함, 연결 정상${C_RESET}"
    else
      echo "  ${C_YELLOW}○${C_RESET} ${ip}  (${host}, ${mac}) — ${C_YELLOW}응답 없음${C_RESET} (꺼져 있거나 랜선이 빠졌을 수 있음)"
    fi
  done < "$LEASE_FILE"
}

print_status_screen() {
  local pc
  echo "${C_BOLD}=== 연결 상태 ===${C_RESET}"
  if ! is_configured; then
    echo "  아직 설정되지 않았습니다. 메뉴의 \"1) 연결 설정하기\"를 먼저 실행하세요."
    return
  fi
  show_status
  pc="$(configured_pc_cidr)"
  [ -n "$pc" ] && echo "  Quest 앱에 입력할 PC 주소 : ${C_BOLD}${pc%%/*}${C_RESET}"
  echo
  echo "${C_BOLD}Quest(기기) 응답 확인${C_RESET}"
  show_quest_devices
}

# 케이블이 꽂힌 유선 장치가 하나도 없으면 연결을 안내하고 기다린다 (대화형일 때만)
wait_for_link() {
  local n answer
  [ -t 0 ] || return 0
  while true; do
    for n in $(list_wired_ifaces); do
      iface_carrier "$n" && return 0
    done
    echo
    warn "랜선 연결이 감지되지 않습니다. 아래를 확인해주세요:"
    echo "  - Quest 3에 USB-C 이더넷 어댑터가 꽂혀 있고, Quest가 켜져 있나요?"
    echo "  - 랜선이 어댑터와 이 PC의 랜 포트에 끝까지 꽂혀 있나요? (포트의 불빛이 켜지는지 확인)"
    echo "  - 준비물과 연결 순서는 메뉴의 \"4) 준비물·연결 방법 안내\"에 있습니다."
    read -rp "연결했으면 엔터(다시 확인), 그냥 진행하려면 s, 그만두려면 q: " answer || answer=q
    case "$answer" in
      s|S) return 0 ;;
      q|Q) info "설정을 그만둡니다."; exit 0 ;;
    esac
  done
}

# Quest 가 IP를 받아 응답할 때까지 기다린다 (대화형일 때만)
wait_for_quest() {
  local i ip
  [ -t 0 ] || return 0
  echo "${C_BOLD}Quest 3 연결 확인${C_RESET}"
  echo "Quest 3를 켜고 랜선이 연결된 상태로 두세요. Quest가 IP를 받을 때까지 기다립니다."
  echo "(최대 90초, 기다리지 않으려면 엔터)"
  for (( i = 0; i < 45; i++ )); do
    if [ -s "$LEASE_FILE" ]; then
      while read -r _ _ ip _; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
          echo
          ok "Quest 연결 확인! Quest가 받은 IP: ${ip}"
          return 0
        fi
      done < "$LEASE_FILE"
    fi
    printf '.'
    if read -rst 2 _; then
      echo
      info "확인을 건너뛰었습니다. 나중에 메뉴의 \"2) 연결 상태 확인\"으로 확인할 수 있습니다."
      return 1
    fi
  done
  echo
  warn "90초 안에 Quest의 응답을 확인하지 못했습니다. 아래를 확인해주세요:"
  echo "  - Quest가 켜져 있고 잠자기 상태가 아닌지 (헤드셋을 한 번 써서 깨워주세요)"
  echo "  - 어댑터를 Quest에서 뽑았다가 다시 꽂아보기"
  echo "  - Quest의 Wi-Fi를 끄고 다시 확인하기"
  echo "  - 다른 USB-C 이더넷 어댑터로 바꿔보기 (일부 칩셋은 Quest에서 인식되지 않음)"
  echo "  설정 자체는 끝났으므로, 연결되면 자동으로 동작합니다. 메뉴의 \"2) 연결 상태 확인\"으로 다시 확인하세요."
  return 1
}

# ── 설정 (1~6단계) ───────────────────────────────────────────────────
# IFACE 에 연결된(또는 IFACE 전용으로 지정된) 유선 프로필 UUID 목록. 현재 활성 프로필이 먼저.
find_wired_profiles() {
  local uuid type dev ifname
  while IFS=: read -r uuid type dev; do
    [ "$type" = "802-3-ethernet" ] || continue
    ifname="$(nmcli -g connection.interface-name con show "$uuid" 2>/dev/null || true)"
    if [ "$dev" = "$IFACE" ]; then
      echo "0 $uuid"
    elif [ "$ifname" = "$IFACE" ]; then
      echo "1 $uuid"
    fi
  done < <(nmcli -t -f UUID,TYPE,DEVICE con show 2>/dev/null) | sort -n | awk '{print $2}'
}

set_ip_with_nmcli() {
  local uuid method addrs manual_uuid="" manual_cidr="" manual_name active_dev
  for uuid in $(find_wired_profiles); do
    method="$(nmcli -g ipv4.method con show "$uuid" 2>/dev/null || true)"
    addrs="$(nmcli -g ipv4.addresses con show "$uuid" 2>/dev/null || true)"
    if [ "$method" = "manual" ] && [ -n "$addrs" ]; then
      manual_uuid="$uuid"
      manual_cidr="${addrs%%,*}"
      manual_cidr="${manual_cidr//[[:space:]]/}"
      break
    fi
  done

  if [ -n "$manual_uuid" ]; then
    # 이미 manual 로 설정된 프로필이 있으면 내용은 건드리지 않고 그대로 사용
    manual_name="$(nmcli -g connection.id con show "$manual_uuid")"
    parse_cidr "$manual_cidr" || die "기존 프로필 '${manual_name}' 의 IP(${manual_cidr})를 해석할 수 없습니다."
    ok "기존 manual 유선 프로필 사용: ${manual_name} (${GATEWAY_IP}/${PREFIX}) — 설정은 변경하지 않습니다."
    if [ -n "$GATEWAY_ARG" ] && [ "${GATEWAY_ARG%%/*}" != "$GATEWAY_IP" ]; then
      warn "--gateway-ip ${GATEWAY_ARG} 는 무시됩니다. 다른 IP를 쓰려면 '${manual_name}' 프로필을 직접 수정해주세요."
    fi

    active_dev="$(nmcli -g GENERAL.DEVICES con show "$manual_uuid" 2>/dev/null || true)"
    if [ "$active_dev" != "$IFACE" ]; then
      info "프로필 '${manual_name}' 을 ${IFACE} 에서 활성화합니다..."
      nmcli con up "$manual_uuid" ifname "$IFACE" >/dev/null \
        || die "프로필 활성화 실패. 랜선이 PC와 Quest 3에 꽂혀 있는지 확인 후 다시 실행해주세요."
    fi
    return
  fi

  # manual 프로필이 없으면 IP를 입력받아 전용 프로필 생성 (사용자의 기존 DHCP 프로필은 수정하지 않음)
  info "${IFACE} 에 고정 IP 설정이 없어 새로 만듭니다."
  ask_gateway_cidr
  info "새 NetworkManager 연결 프로필 생성: ${CONN_NAME} (${GATEWAY_IP}/${PREFIX})"
  nmcli con delete "$CONN_NAME" >/dev/null 2>&1 || true
  nmcli con add type ethernet ifname "$IFACE" con-name "$CONN_NAME" \
    ipv4.addresses "${GATEWAY_IP}/${PREFIX}" \
    ipv4.method manual \
    ipv6.method ignore \
    connection.autoconnect-priority 10 >/dev/null
  nmcli con up "$CONN_NAME" >/dev/null \
    || die "프로필 활성화 실패. 랜선이 PC와 Quest 3에 꽂혀 있는지 확인 후 다시 실행해주세요."
}

set_ip_with_iproute() {
  local existing
  warn "NetworkManager(nmcli)를 찾지 못해 'ip' 명령으로 확인/설정합니다."
  existing="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
  if [ -n "$existing" ]; then
    parse_cidr "$existing" || die "${IFACE} 의 기존 IP(${existing})를 해석할 수 없습니다."
    ok "${IFACE} 에 이미 설정된 IP 사용: ${GATEWAY_IP}/${PREFIX} — 설정은 변경하지 않습니다."
    ip link set "$IFACE" up
    return
  fi
  ask_gateway_cidr
  warn "(재부팅하면 사라집니다. 영구 적용하려면 netplan 설정을 직접 추가해주세요.)"
  ip addr add "${GATEWAY_IP}/${PREFIX}" dev "$IFACE"
  ip link set "$IFACE" up
}

show_service_log() {
  err "${SERVICE_NAME} 가 정상적으로 시작되지 못했습니다. 아래 로그를 확인해주세요:"
  journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
  exit 1
}

do_setup() {
  echo "${C_BOLD}=== 연결 설정하기 ===${C_RESET}"
  if is_configured; then
    info "이미 설정되어 있습니다. 새로 고른 장치·주소로 다시 설정합니다."
  fi

  # ── 1. 유선 랜 인터페이스 선택 ──
  echo
  echo "${C_BOLD}[1/4] 랜 장치 선택${C_RESET}"
  if [ -z "$IFACE" ]; then
    wait_for_link
    info "이 PC의 유선 랜 장치를 찾는 중..."
    choose_iface
  fi

  if [ ! -e "/sys/class/net/${IFACE}" ]; then
    die "인터페이스 '${IFACE}' 가 존재하지 않습니다. 'ip link show' 로 이름을 확인해주세요."
  fi
  if ! list_wired_ifaces | grep -qx "$IFACE"; then
    warn "'${IFACE}' 는 물리 유선 랜 장치로 보이지 않습니다 (Wi-Fi/가상 장치일 수 있음). 그대로 진행합니다."
  fi
  if ! iface_carrier "$IFACE"; then
    warn "'${IFACE}' 에 랜선 연결이 감지되지 않습니다. Quest 3와 연결 후 실행하는 것을 권장합니다."
  fi
  info "사용할 장치: ${C_BOLD}${IFACE}${C_RESET}"

  # ── 2. PC 쪽 고정 IP 설정 ──
  echo
  echo "${C_BOLD}[2/4] 이 PC의 주소(고정 IP) 설정${C_RESET}"
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    set_ip_with_nmcli
  else
    set_ip_with_iproute
  fi

  derive_range
  ok "PC 주소: ${GATEWAY_IP}/${PREFIX} (장치 ${IFACE})"
  info "Quest에게 나눠줄 주소 범위: ${RANGE_START} ~ ${RANGE_END}"

  # ── 3. dnsmasq 설치 ──
  echo
  echo "${C_BOLD}[3/4] 주소 배포 프로그램(dnsmasq) 준비${C_RESET}"
  if ! command -v dnsmasq >/dev/null 2>&1; then
    # dnsmasq-base: 프로그램만 설치 (시스템 dnsmasq 서비스가 같이 켜져 systemd-resolved 와 충돌하는 것 방지)
    info "dnsmasq가 설치되어 있지 않아 설치합니다. (인터넷 연결 필요, 1~2분 걸릴 수 있음)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq dnsmasq-base
    ok "dnsmasq 설치 완료"
  else
    info "dnsmasq가 이미 설치되어 있습니다."
  fi
  DNSMASQ_BIN="$(command -v dnsmasq)"

  cleanup_legacy_conf backup
  if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq 2>/dev/null; then
    if system_dnsmasq_unused; then
      # 다른 용도 설정이 없는 시스템 dnsmasq 는 이전 버전이 켠 것 → 전용 서비스로 대체
      systemctl disable --now dnsmasq >/dev/null 2>&1 || true
      mkdir -p "$CONF_DIR"
      echo "system_dnsmasq_disabled=1" > "$STATE_FILE"   # 설정 해제 시 다시 켜기 위해 기록
      info "사용하지 않는 시스템 dnsmasq.service 를 끄고 Quest 전용 서비스(${SERVICE_NAME})로 대체합니다."
    else
      info "시스템 dnsmasq.service 는 다른 설정이 있어 그대로 둡니다. (Quest 전용 서비스와는 별개로 동작)"
    fi
  fi

  # ── 4. 전용 dnsmasq 설정 + 서비스 생성, 시작 ──
  echo
  echo "${C_BOLD}[4/4] Quest 전용 서비스 설정 및 시작${C_RESET}"
  mkdir -p "$CONF_DIR"
  if [ -f "$CONF_PATH" ]; then
    cp "$CONF_PATH" "${CONF_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$CONF_PATH" <<EOF
# pc-ip=${GATEWAY_IP}/${PREFIX}
# Quest 3 전용 인터페이스에만 DHCP 서비스
interface=${IFACE}
# bind-dynamic: 부팅 시 인터페이스에 IP가 아직 없어도(랜선 미연결) 실패하지 않고, 생기면 자동으로 붙음
bind-dynamic
except-interface=lo

# 이 인터페이스에 대해 dnsmasq가 '권위있는' DHCP 서버로 동작
dhcp-authoritative

# Quest에게 나눠줄 IP 범위, 서브넷마스크, lease 유지시간
dhcp-range=${RANGE_START},${RANGE_END},${NETMASK},${LEASE}

# DNS 기능은 끄기 (필요 없음, systemd-resolved와 충돌 방지)
port=0
EOF

  # --conf-file 만 지정하므로 /etc/dnsmasq.conf, /etc/dnsmasq.d 는 읽지 않음
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=dnsmasq DHCP server for Meta Quest 3 direct LAN (${IFACE})
After=network.target NetworkManager.service
Wants=network.target

[Service]
Type=simple
ExecStartPre=${DNSMASQ_BIN} --test --conf-file=${CONF_PATH}
ExecStart=${DNSMASQ_BIN} -k --conf-file=${CONF_PATH} --pid-file=/run/${SERVICE_NAME}.pid --dhcp-leasefile=${LEASE_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" || show_service_log
  sleep 1
  systemctl is-active --quiet "$SERVICE_NAME" || show_service_log
  ok "Quest 전용 서비스(${SERVICE_NAME}) 동작 중 — 재부팅 후에도 자동으로 켜집니다."
  echo

  # ── 완료 안내 ──
  echo "${C_BOLD}${C_GREEN}=== 설정 완료 ===${C_RESET}"
  echo
  echo "  Quest 앱의 서버(PC) 주소 칸에 입력할 값:  ${C_BOLD}${GATEWAY_IP}${C_RESET}"
  echo
  wait_for_quest || true
  echo
  echo "이 창을 닫아도 연결 설정은 유지됩니다."
  if [ "$ARGC" -ne 0 ] || [ ! -t 0 ]; then
    echo "현재 상태 보기 : $0 --status"
    echo "설정 해제      : sudo $0 --uninstall"
  fi
}

# ── 메인 메뉴 ─────────────────────────────────────────────────────────
main_menu() {
  local choice default pc
  while true; do
    echo
    echo "${C_BOLD}==============================================${C_RESET}"
    echo "${C_BOLD}   Meta Quest 3 유선 랜 연결 도우미${C_RESET}"
    echo "${C_BOLD}==============================================${C_RESET}"
    echo "라우터 없이 랜선 하나로 이 PC와 Quest 3를 연결합니다."
    echo
    if is_configured; then
      pc="$(configured_pc_cidr)"
      echo "현재 상태: ${C_GREEN}설정됨${C_RESET}${pc:+ — Quest 앱에 입력할 PC 주소: ${C_BOLD}${pc%%/*}${C_RESET}}"
      default=2
    else
      echo "현재 상태: ${C_YELLOW}아직 설정 안 됨${C_RESET} — 처음이라면 4번 안내를 먼저 읽고 1번을 실행하세요."
      default=1
    fi
    echo
    echo "  1) 연결 설정하기"
    echo "  2) 연결 상태 확인 (Quest가 연결됐는지)"
    echo "  3) 연결 해제 (원래대로 되돌리기)"
    echo "  4) 준비물·연결 방법 안내"
    echo "  0) 종료"
    echo
    read -rp "번호를 입력하고 엔터를 누르세요 [기본: ${default}]: " choice || exit 0
    echo
    case "${choice:-$default}" in
      1) ( do_setup ) || true; pause ;;
      2) print_status_screen; pause ;;
      3) ( do_uninstall ) || true; pause ;;
      4) show_guide; pause ;;
      0|q|Q) echo "종료합니다."; exit 0 ;;
      *) warn "0 ~ 4 중에서 골라주세요." ;;
    esac
  done
}

# ── 실행 ─────────────────────────────────────────────────────────────
if [ "$MODE" = "status" ]; then
  print_status_screen
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  die "이 스크립트는 관리자 권한이 필요합니다. 'sudo $0' 로 다시 실행해주세요."
fi

if [ "$MODE" = "uninstall" ]; then
  do_uninstall
elif [ "$ARGC" -eq 0 ] && [ -t 0 ]; then
  main_menu
else
  do_setup
fi
