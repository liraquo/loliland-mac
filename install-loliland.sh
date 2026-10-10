#!/bin/bash
# macOS installer: download the launcher directly; no Windows bootstrapper needed.
set -euo pipefail
umask 022

if [[ -t 1 ]]; then B=$'\033[1m' G=$'\033[32m' R=$'\033[31m' N=$'\033[0m'; else B='' G='' R='' N=''; fi
die() { printf '\n%sОшибка:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }
step() { printf '\n%s[%s/3] %s%s\n' "$B" "$1" "$2" "$N"; }
ok() { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
[[ "$(uname -s)" == Darwin ]] || die 'Этот установщик предназначен для macOS.'
[[ $# == 0 ]] || die 'Запуск: bash install-loliland.sh'
APP="$ROOT/LoliLand.app"
ID='local.loliland.launcher'
for tool in curl tar unzip sips shasum plutil; do
  command -v "$tool" >/dev/null || die "Не найдена системная утилита: $tool"
done
# Never replace the app while it is running.
check_old_app() {
  [[ -e "$APP" ]] || return 0
  local procs; procs="$(ps -axo command=)"
  [[ "$procs" != *"$APP/Contents/"* ]] || die 'LoliLand сейчас запущен. Закройте его и повторите установку.'
}
check_old_app
# uname -m reports x86_64 under Rosetta, so ask the hardware.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then ARCH=aarch64
elif [[ "$(uname -m)" == x86_64 ]]; then ARCH=x64
else die 'Неизвестная архитектура Mac.'
fi

# Work on the same filesystem; publish only a fully verified application.
WORK="$(mktemp -d "$ROOT/.loliland-install.XXXXXX")"
cleanup() { [[ -z "${WORK:-}" ]] || rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# download URL FILE [--progress-bar]; small files download silently.
download() {
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 300 --retry 2 --show-error "${3:---silent}" \
    --output "$2" "$1"
}

# Public launcher endpoint, verified independently of the Windows bootstrapper.
SOURCE='https://klauncher.loliland.pro'

BUNDLE="$WORK/LoliLand.app"
RES="$BUNDLE/Contents/Resources"
mkdir -p "$BUNDLE/Contents/MacOS" "$RES/runtimes"
printf '%sУстановщик LoliLand для macOS%s\n' "$B" "$N"
step 1 'Лаунчер LoliLand'
download "$SOURCE/api/updater/win64" "$WORK/manifest.json" \
  || die 'Не удалось получить манифест LoliLand. Проверьте сеть и доступность сервера.'
SIZE="$(plutil -extract launcher.size raw -o - "$WORK/manifest.json" 2>/dev/null)" \
  || die 'Сервер вернул некорректный манифест лаунчера.'
[[ "$SIZE" =~ ^[0-9]+$ && "$SIZE" -gt 0 ]] || die 'Некорректный размер лаунчера в манифесте.'
ok 'Манифест получен'
printf '  Скачиваю launcher.jar (%s МБ)…\n' "$((SIZE / 1048576))"
download "$SOURCE/api/updater/load/launcher" "$RES/launcher.jar" --progress-bar \
  || die 'Не удалось скачать launcher.jar. Проверьте сеть и доступность сервера.'
[[ "$(stat -f %z "$RES/launcher.jar")" == "$SIZE" ]] || die 'Размер launcher.jar не совпадает с манифестом.'
ok 'Размер совпадает с манифестом'
unzip -tq "$RES/launcher.jar" >/dev/null || die 'Архив launcher.jar повреждён.'
unzip -p "$RES/launcher.jar" META-INF/MANIFEST.MF | tr -d '\r' | grep -x 'Main-Class: loliland.launcher.app.Main' >/dev/null \
  || die 'В JAR не найден основной класс лаунчера LoliLand.'
ok 'Архив цел, лаунчер на месте'

step 2 "Java (JetBrains Runtime с JCEF, $ARCH)"
RUNTIME="jbr_jcef-17.0.11-osx-$ARCH-b1312.2"
URL="https://cache-redirector.jetbrains.com/intellij-jbr/$RUNTIME.tar.gz"
printf '  Скачиваю %s…\n' "$RUNTIME"
download "$URL" "$WORK/$RUNTIME.tar.gz" --progress-bar \
  || die 'Не удалось скачать Java с сервера JetBrains. Проверьте сеть.'
download "$URL.checksum" "$WORK/checksum" \
  || die 'Не удалось скачать контрольную сумму Java.'
EXPECTED="$(awk 'NR == 1 {print $1}' "$WORK/checksum")"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{128}$ ]] || die 'Некорректная контрольная сумма JetBrains.'
ACTUAL="$(shasum -a 512 "$WORK/$RUNTIME.tar.gz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || die 'SHA-512 архива Java не совпадает. Установка остановлена.'
ok 'SHA-512 совпадает с JetBrains'
printf '  Распаковываю…\n'
tar -xzf "$WORK/$RUNTIME.tar.gz" -C "$RES/runtimes"
JAVA_HOME_LOCAL="$RES/runtimes/$RUNTIME/Contents/Home"
"$JAVA_HOME_LOCAL/bin/java" -version >/dev/null 2>&1 || die 'Скачанная Java не запускается.'
"$JAVA_HOME_LOCAL/bin/java" --list-modules | grep -E '^jcef(@|$)' >/dev/null || die 'В Java отсутствует JCEF.'
ok 'Java запускается, JCEF на месте'

step 3 'Сборка LoliLand.app'
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LoliLand</string>
<key>CFBundleDisplayName</key><string>LoliLand</string>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>LoliLand</string>
<key>CFBundleIconFile</key><string>LoliLand.icns</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$RUNTIME" > "$RES/runtime-name.txt"
cat > "$BUNDLE/Contents/MacOS/LoliLand" <<'LAUNCH'
#!/bin/zsh
set -euo pipefail
RES="${0:A:h:h}/Resources"
RUNTIME="$(< "$RES/runtime-name.txt")"
export JAVA_HOME="$RES/runtimes/$RUNTIME/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
DATA="$HOME/Library/Application Support/LoliLand"
LOG="$DATA/macos-app.log"
mkdir -p "$DATA"
cd -- "$DATA"
# Keep only the current and the previous launch.
[[ ! -f "$LOG" ]] || mv -f -- "$LOG" "$LOG.1"
exec "$JAVA_HOME/bin/java" \
  -Xdock:name=LoliLand "-Xdock:icon=$RES/LoliLand.icns" \
  --add-exports=java.desktop/com.apple.eawt=ALL-UNNAMED \
  -jar "$RES/launcher.jar" "$@" > "$LOG" 2>&1
LAUNCH
chmod +x "$BUNDLE/Contents/MacOS/LoliLand"
unzip -p "$RES/launcher.jar" loliland/application/public/favicon.ico > "$WORK/favicon.ico"
sips -s format png "$WORK/favicon.ico" --out "$WORK/icon.png" >/dev/null
sips -s format icns "$WORK/icon.png" --out "$RES/LoliLand.icns" >/dev/null
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
/bin/zsh -n "$BUNDLE/Contents/MacOS/LoliLand"
printf 'Launcher source: %s/api/updater/load/launcher\nRuntime source: %s\nRuntime SHA-512: %s\n' \
  "$SOURCE" "$URL" "$ACTUAL" > "$RES/install-info.txt"
shasum -a 256 "$RES/launcher.jar" | awk '{print "Launcher SHA-256: " $1}' >> "$RES/install-info.txt"
ok 'Приложение собрано'
check_old_app
# The old app goes into WORK, so the EXIT trap deletes it after a successful swap.
if [[ -e "$APP" ]]; then
  mv -- "$APP" "$WORK/old.app"
  ok 'Предыдущая версия LoliLand.app заменена'
fi
mv -- "$BUNDLE" "$APP" || { mv -- "$WORK/old.app" "$APP" 2>/dev/null; die 'Не удалось установить новое приложение; старое восстановлено.'; }

printf '\n%s%s✓ Готово:%s %s\n\n' "$G" "$B" "$N" "$APP"
printf '%sОсталось одно действие:%s перетащите LoliLand.app в папку «Программы»\n' "$B" "$N"
printf '(в боковой панели Finder). Тогда LoliLand появится в Launchpad и Spotlight,\n'
printf 'и его можно будет закрепить в Dock. Окно Finder с приложением сейчас откроется.\n\n'
open -R "$APP" 2>/dev/null || true
