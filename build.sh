#!/bin/sh
# TreeFinder 빌드 스크립트 — README의 xcodebuild 커맨드를 한 줄로 (제작자 요청 2026-07-21)
#
#   ./build.sh            Release 빌드
#   ./build.sh -d         Debug 빌드
#   ./build.sh -i         빌드 후 /Applications 에 설치
#   ./build.sh -i -r      설치 후 실행 (-r 만 주면 빌드한 자리에서 실행)
#
# TF_SIGN_IDENTITY="인증서 이름" 을 지정하면 설치 전에 재서명합니다 —
# ad-hoc 서명은 빌드마다 지문이 바뀌어 전체 디스크 접근 승인이 풀리는데,
# 자가 서명 인증서로 고정하면 재빌드에도 승인이 유지됩니다(README 각주).
#
# 설치(-i)를 마치면 빌드 캐시(build/ 통째로, 약 1.4GB)를 지웁니다 — 캐시가 깨져서
# 빌드가 실패하는 일을 없애기 위함(제작자 지시 2026-07-28). 다음 빌드는 전체 재빌드.

set -eu
cd "$(dirname "$0")"

CONFIG=Release
INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        -d|--debug)   CONFIG=Debug ;;
        -i|--install) INSTALL=1 ;;
        -r|--run)     RUN=1 ;;
        -h|--help)    sed -n '2,15p' "$0" | cut -c 3-; exit 0 ;;
        *) echo "알 수 없는 옵션: $arg  (도움말: ./build.sh -h)" >&2; exit 2 ;;
    esac
done

# xcode-select가 Command Line Tools를 가리키는 환경 대비 — 이미 Xcode면 무해 (README)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "▶︎ $CONFIG 빌드…"
if ! xcodebuild -project TreeFinder.xcodeproj -scheme TreeFinder \
                -configuration "$CONFIG" -derivedDataPath build/dd build; then
    echo >&2
    echo "✗ 빌드 실패. \"cannot execute tool 'metal'\" 오류라면 최초 1회만:" >&2
    echo "    xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

APP="build/dd/Build/Products/$CONFIG/TreeFinder.app"
TARGET="$APP"

if [ -n "${TF_SIGN_IDENTITY:-}" ]; then
    echo "▶︎ 재서명: $TF_SIGN_IDENTITY"
    codesign --force --deep -s "$TF_SIGN_IDENTITY" "$APP"
fi

if [ "$INSTALL" = 1 ]; then
    # 실행 중이면 ditto가 덮어쓴 뒤에도 옛 프로세스가 남아 혼동 — 먼저 종료
    osascript -e 'tell application "TreeFinder" to quit' 2>/dev/null || true
    echo "▶︎ /Applications/TreeFinder.app 로 설치…"
    ditto "$APP" /Applications/TreeFinder.app
    TARGET=/Applications/TreeFinder.app
fi

if [ "$RUN" = 1 ]; then
    echo "▶︎ 실행: $TARGET"
    open "$TARGET"
fi

# 캐시 삭제는 설치한 경우에만 — -i 없이 지우면 방금 만든 앱까지 사라지고,
# -r 로 그 자리에서 실행 중인 앱은 실행 파일이 사라져 죽는다.
# build/ 통째로 지운다(.gitignore 대상) — 옛 빌드 방식이 남긴 build/ddr·build/Debug 같은
# 잔재까지 한 번에 정리하려고. build/ 안에는 빌드 산출물 말고 아무것도 두지 말 것.
if [ "$INSTALL" = 1 ]; then
    echo "▶︎ 빌드 캐시 삭제: build/"
    rm -rf build
else
    echo "▶︎ 빌드 캐시 유지 — 앱이 build/dd 안에 있음 (-i 로 설치하면 삭제)"
fi

echo "✓ 완료 — $TARGET"
