#!/bin/bash
set -e

STAGING="/tmp/QuickSnap_DMG_Staging"
RW_DMG="/tmp/QuickSnap_2.0_rw.dmg"
FINAL_DMG="$HOME/Desktop/QuickSnap_2.0.dmg"
VOL_NAME="QuickSnap 2.0"

hdiutil detach "/Volumes/$VOL_NAME" -force 2>/dev/null || true
rm -rf "$STAGING" "$RW_DMG" "$FINAL_DMG"
mkdir -p "$STAGING"

swift -e '
import Cocoa

let w: CGFloat = 640
let h: CGFloat = 460
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()

// Чистый светлый фон (системный стиль macOS, на нём идеально читаются чёрные подписи иконок)
let bgGrad = NSGradient(
    starting: NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.95, alpha: 1.0)
)!
bgGrad.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// Заголовок сверху
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1.0)
]
let titleStr = "Перетащите QuickSnap 2.0 в папку Программы" as NSString
let titleSize = titleStr.size(withAttributes: titleAttrs)
titleStr.draw(at: NSPoint(x: (w - titleSize.width) / 2, y: h - 44), withAttributes: titleAttrs)

// Синяя направляющая стрелка между иконками верхнего ряда (y=305)
let arrowY: CGFloat = 305
let startX: CGFloat = 265
let endX: CGFloat = 375

let path = NSBezierPath()
path.lineWidth = 3.0
path.lineCapStyle = .round
path.lineJoinStyle = .round
path.move(to: NSPoint(x: startX, y: arrowY))
path.line(to: NSPoint(x: endX, y: arrowY))
path.move(to: NSPoint(x: endX - 12, y: arrowY + 10))
path.line(to: NSPoint(x: endX, y: arrowY))
path.line(to: NSPoint(x: endX - 12, y: arrowY - 10))

NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.96, alpha: 0.95).setStroke()
path.stroke()

// Тонкий разделитель перед нижним рядом утилит
let sep = NSBezierPath()
sep.lineWidth = 1.0
sep.move(to: NSPoint(x: 56, y: 205))
sep.line(to: NSPoint(x: w - 56, y: 205))
NSColor.black.withAlphaComponent(0.09).setStroke()
sep.stroke()

img.unlockFocus()

if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try! png.write(to: URL(fileURLWithPath: "/tmp/QuickSnap_DMG_Staging/bg.png"))
}
'

cp -R "/Applications/QuickSnap 2.0.app" "$STAGING/" && xattr -cr "$STAGING"
ln -s /Applications "$STAGING/Applications"

cat << 'EOF' > "$STAGING/Снять карантин.command"
#!/bin/bash
APP_PATH="/Applications/QuickSnap 2.0.app"
if [ -d "$APP_PATH" ]; then
    xattr -cr "$APP_PATH"
    echo "✅ Карантин снят! Запускаю QuickSnap 2.0..."
    open "$APP_PATH"
    (sleep 1.2 && osascript -e 'tell application "Terminal" to close (every window whose name contains "QuickSnap" or name contains ".command") saving no') >/dev/null 2>&1 &
    exit 0
else
    echo "⚠️ Сначала перетащите «QuickSnap 2.0» в папку «Applications» (Программы), затем запустите этот файл снова."
    read -r -p "Нажмите Enter, чтобы закрыть окно..."
    exit 1
fi
EOF
chmod +x "$STAGING/Снять карантин.command"

cat << 'EOF' > "$STAGING/Сбросить и удалить.command"
#!/bin/bash
APP_PATH="/Applications/QuickSnap 2.0.app"
BUNDLE_ID="com.viktor.quicksnap2"

if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    DETECTED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
    if [ -n "$DETECTED_ID" ]; then
        BUNDLE_ID="$DETECTED_ID"
    fi
fi

echo "🧹 Останавливаем QuickSnap 2.0..."
pkill -f "QuickSnap" 2>/dev/null || true

echo "🗑 Удаляем приложение и кэши..."
rm -rf "/Applications/QuickSnap 2.0.app" "$HOME/Applications/QuickSnap 2.0.app"
rm -rf "$HOME/Library/Caches/"*QuickSnap*
rm -rf "$HOME/Library/Saved Application State/"*QuickSnap*
rm -rf "$HOME/Library/Logs/DiagnosticReports/"QuickSnap*

echo "⚙️ Сбрасываем настройки ($BUNDLE_ID) и системные разрешения..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -rf "$HOME/Library/Preferences/"*QuickSnap*
killall cfprefsd 2>/dev/null || true
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true

echo ""
echo "✅ QuickSnap 2.0, настройки и разрешения полностью удалены."
read -r -p "Нажмите Enter, чтобы закрыть окно..."
(sleep 0.3 && osascript -e 'tell application "Terminal" to close (every window whose name contains "QuickSnap" or name contains ".command") saving no') >/dev/null 2>&1 &
exit 0
EOF
chmod +x "$STAGING/Сбросить и удалить.command"

cat << 'EOF' > "$STAGING/README — Установка и возможности.txt"
============================================================
QuickSnap 2.0 — Быстрые скриншоты и запись экрана для macOS
============================================================

О ПРОГРАММЕ
QuickSnap 2.0 — лёгкая нативная утилита в строке меню (menu bar)
для мгновенных скриншотов, разметки и записи видео с экрана.

Что умеет:
• Скриншот выбранной области или отдельного окна с 1:1 Retina-чёткостью.
• Встроенный редактор разметки (стрелки, рамки, размытие).
• Плавающее превью после снимка: быстрое копирование в буфер, переход
  к разметке, показ файла в Finder или удаление в один клик.
• Запись видео с экрана в MP4 (HEVC / H.265) с выбором 30 или 60 FPS.
• Запись системного звука (звука приложений) и голоса с микрофона
  (на базе нативного ScreenCaptureKit — без виртуальных драйверов).
• История последних снимков прямо в поповере из меню-бара.
• Настраиваемые глобальные горячие клавиши и автозапуск при входе в систему.

------------------------------------------------------------
УСТАНОВКА И ПЕРВЫЙ ЗАПУСК
------------------------------------------------------------

1. Перетащите «QuickSnap 2.0» в папку «Applications» (Программы)
   рядом в этом окне.

2. Снятие карантина macOS (обязательно перед первым запуском):
   Так как сборка тестовая (без платного сертификата Apple Developer ID),
   после скачивания из мессенджера macOS может написать «Файл повреждён»
   или «Не удаётся проверить разработчика».

   Способ А (проще): дважды кликните по файлу «Снять карантин.command»
   в этом окне — он сам снимет блокировку и запустит программу.

   Способ Б (через Терминал): выполните команду:
   xattr -cr "/Applications/QuickSnap 2.0.app"

3. Настройка прав при первом запуске:
   • Выберите папку для сохранения снимков (по умолчанию Desktop/Screenshots).
   • В верхнем меню-баре появится иконка приложения.
   • При первом скриншоте или записи видео разрешите доступ к «Записи экрана»
     и «Микрофону» в Системных настройках -> Конфиденциальность и безопасность.

------------------------------------------------------------
ЕСЛИ ЧТО-ТО ПОШЛО НЕ ТАК / ПОЛНОЕ УДАЛЕНИЕ
------------------------------------------------------------
Если нужно сбросить все настройки, системные разрешения (Запись экрана /
Микрофон) или полностью удалить программу с Mac:

• Дважды кликните по файлу «Сбросить и удалить.command» в этом образе.
  Скрипт закроет программу, удалит её из «Программ», очистит кэши,
  UserDefaults и сбросит записи в «Конфиденциальность и безопасность».
  (Сами сохранённые скриншоты и видео в вашей папке при этом не трогаются.)

------------------------------------------------------------
ГОРЯЧИЕ КЛАВИШИ ПО УМОЛЧАНИЮ
(можно изменить в Настройки -> Горячие клавиши)
------------------------------------------------------------
• Option + 1  — Снимок выбранной области
• Option + 2  — Снимок выбранного окна
• Option + 3  — Запись видео с экрана (Старт / Стоп)
EOF

hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW "$RW_DMG"
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | grep "/Volumes/$VOL_NAME" | awk -F'\t' '{print $3}')

osascript << EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {260, 180, 900, 668}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 84
        set text size of viewOptions to 12
        set background picture of viewOptions to POSIX file "$MOUNT_DIR/bg.png"

        set position of item "QuickSnap 2.0.app" of container window to {185, 145}
        set position of item "Applications" of container window to {455, 145}
        set position of item "README — Установка и возможности.txt" of container window to {135, 325}
        set position of item "Снять карантин.command" of container window to {320, 325}
        set position of item "Сбросить и удалить.command" of container window to {505, 325}

        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

chflags hidden "$MOUNT_DIR/bg.png"
sync
hdiutil detach "$MOUNT_DIR" -force

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG"
rm -rf "$STAGING" "$RW_DMG"

echo "✅ Готово! Чистый образ сохранён: $FINAL_DMG"
