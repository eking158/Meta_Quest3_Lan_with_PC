#!/usr/bin/env bash
#
# install-desktop-shortcut.sh
#
# quest3-lan-setup.sh 를 우분투 데스크톱에서 "아이콘 더블클릭 한 번"으로 실행할 수 있게
# 만들어주는 설치 스크립트. 일반 사용자 권한으로 실행하세요 (sudo 붙이지 마세요).
#
#   ./install-desktop-shortcut.sh              # 아이콘 설치 (스크립트를 고친 뒤에도 다시 실행)
#   ./install-desktop-shortcut.sh --uninstall  # 아이콘과 복사본 제거 (네트워크 설정은 그대로)
#
# 실행하면:
#   1) quest3-lan-setup.sh 를 ~/.local/bin/ 에 복사
#   2) 바탕화면에 더블클릭용 아이콘(.desktop) 2개 생성
#      - "Quest 3 LAN 원터치 연결" : 안내 메뉴 (연결 설정 / 상태 확인 / 해제 / 준비물 안내)
#      - "Quest 3 LAN 연결 해제"   : 설정 해제
#      더블클릭하면 터미널 창이 열리고, 그 안에서 sudo 암호를 입력하면 진행됩니다.
#
# 참고: 이전 버전은 pkexec(그래픽 암호창)를 사용했는데, polkit 인증 에이전트가
# 데스크톱 환경에 없거나 활성 세션으로 인식되지 않으면 "Not authorized" /
# 암호창이 아예 안 뜨는 문제가 발생할 수 있습니다. 이 버전은 터미널 안에서
# 바로 sudo로 암호를 물어보도록 바꿔서 그 문제를 피합니다.
#
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "[오류] 이 스크립트는 sudo 없이 일반 사용자 권한으로 실행해주세요." >&2
  exit 1
fi

BIN_DIR="${HOME}/.local/bin"
DEST="${BIN_DIR}/quest3-lan-setup.sh"

# 바탕화면 폴더 (한국어 우분투는 ~/바탕화면 일 수 있음)
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [ -z "$DESKTOP_DIR" ] || [ "$DESKTOP_DIR" = "$HOME" ]; then
  DESKTOP_DIR="${HOME}/Desktop"
fi
LAUNCHER="${DESKTOP_DIR}/Quest3-LAN-Setup.desktop"
UNINSTALL_LAUNCHER="${DESKTOP_DIR}/Quest3-LAN-Uninstall.desktop"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$LAUNCHER" "$UNINSTALL_LAUNCHER" "$DEST"
  echo "[완료] 바탕화면 아이콘과 ${DEST} 를 제거했습니다."
  echo "[정보] 네트워크 설정은 그대로입니다. 설정까지 해제하려면 먼저 아래를 실행하세요:"
  echo "       sudo ./quest3-lan-setup.sh --uninstall"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/quest3-lan-setup.sh"
[ -f "$SRC" ] || { echo "[오류] quest3-lan-setup.sh 를 같은 폴더에서 찾을 수 없습니다." >&2; exit 1; }

mkdir -p "$BIN_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "[완료] 스크립트 설치: ${DEST}"

mkdir -p "$DESKTOP_DIR"

# $1 파일, $2 이름, $3 설명, $4 스크립트 인자, $5 아이콘
write_launcher() {
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Comment=$3
Exec=bash -c 'echo "이 PC의 로그인 암호를 입력하고 엔터를 누르세요."; echo "(입력하는 동안 화면에 글자가 보이지 않는 것이 정상입니다)"; echo; sudo "${DEST}" $4 || echo "[안내] 암호가 틀렸거나 관리자 권한이 없는 계정입니다. 아이콘을 다시 실행해주세요."; echo; read -p "엔터를 누르면 창이 닫힙니다..."'
Icon=$5
Terminal=true
Categories=Network;
EOF
  chmod +x "$1"
  # GNOME 최신 버전은 처음 만든 .desktop 아이콘을 "신뢰"로 표시해야 실행 가능
  if command -v gio >/dev/null 2>&1; then
    gio set "$1" "metadata::trusted" true 2>/dev/null || true
  fi
  echo "[완료] 바탕화면 아이콘 생성: $1"
}

write_launcher "$LAUNCHER" "Quest 3 LAN 원터치 연결" \
  "Meta Quest 3 - 우분투 PC 유선 랜 연결 설정" "" "network-wired"
write_launcher "$UNINSTALL_LAUNCHER" "Quest 3 LAN 연결 해제" \
  "Meta Quest 3 유선 랜 연결 설정 해제 (원래 상태로 되돌리기)" "--uninstall" "network-offline"

echo
echo "설치가 끝났습니다. 바탕화면의 아이콘을 더블클릭하세요:"
echo "  'Quest 3 LAN 원터치 연결' — 안내 메뉴 (연결 설정 / 상태 확인 / 해제 / 준비물 안내)"
echo "  'Quest 3 LAN 연결 해제'   — 바로 설정 해제"
echo "처음 실행할 때 '신뢰할 수 없는 실행 파일' 경고가 나오면 아이콘을 우클릭 → '실행 허용'을 누르세요."
