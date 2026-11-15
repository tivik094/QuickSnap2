#!/bin/bash
set -e

APP_NAME="QuickSnap 2.0.app"
APP_PATH="/Applications/$APP_NAME"
PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🛑 Останавливаем старый процесс..."
killall -9 QuickSnap2 2>/dev/null || true

echo "📦 Подготавливаем бандл $APP_PATH..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$PROJ_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJ_DIR/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

echo "🔨 Компилируем Swift-модули..."
SWIFT_FILES=()
while IFS= read -r -d '' file; do
    SWIFT_FILES+=("$file")
done < <(find "$PROJ_DIR/Sources" -name "*.swift" -print0)

swiftc "${SWIFT_FILES[@]}" \
    -framework Cocoa \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework Carbon \
    -framework ServiceManagement \
    -o "$APP_PATH/Contents/MacOS/QuickSnap2"

echo "🔏 Подписываем сертификатом QuickSnapDev..."
plutil -replace NSMicrophoneUsageDescription -string "QuickSnap использует микрофон для записи голоса при захвате видео с экрана." "/Applications/QuickSnap 2.0.app/Contents/Info.plist"
codesign --force --deep --sign "QuickSnapDev" "$APP_PATH"

echo "🚀 Запускаем QuickSnap 2.0..."
open -a "$APP_PATH"
echo "✅ Готово!"

if [[ " $* " == *" --dmg "* ]]; then
    echo "📦 Запускаем сборку DMG-образа..."
    /Users/v/Dev/QuickSnap2/release_dmg.sh
fi
