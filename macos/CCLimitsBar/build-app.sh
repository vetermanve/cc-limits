#!/bin/sh
# Собирает CCLimitsBar.app из сборки SwiftPM.
#
# Бандл нужен не ради красоты: без Info.plist система не считает приложение
# приложением - не даёт ни иконки, ни подписи, ни регистрации в автозапуске
# через SMAppService.
#
# Подпись: по умолчанию ad-hoc, её хватает для запуска на своей машине.
# Для раздачи другим нужен Developer ID:
#   SIGN_ID="Developer ID Application: Имя (TEAMID)" ./build-app.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/CCLimitsBar.app"
SIGN_ID="${SIGN_ID:--}"

cd "$HERE"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/CCLimitsBar"
[ -x "$BIN" ] || { echo "не нашёл собранный бинарник: $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CCLimitsBar"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP" && echo "подпись: $SIGN_ID"

echo "собрано: $APP"
echo
echo "поставить: cp -R \"$APP\" /Applications/"
echo "запустить: open \"$APP\""
