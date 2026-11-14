#!/bin/zsh
set -eu
cd -- "${0:A:h}"
APP="$PWD/Nabaztag IA.app"
if pgrep -x NabaztagIA >/dev/null; then
  echo "Ferme Nabaztag IA avant de lancer la compilation. L’application ouverte n’a pas été modifiée."
  exit 1
fi
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -parse-as-library Sources/SSHSettings.swift Helpers/SSHAskpass.swift \
  -framework Security -o "$APP/Contents/MacOS/NabaztagSSHAskpass"
codesign --force --sign - "$APP/Contents/MacOS/NabaztagSSHAskpass"
mkdir -p "$APP/Contents/Resources"
cp bridge_remote.py Helpers/local_voice.py README.md Assets/AppIcon.icns Assets/MenuBarIcon.png setup-voice.command setup-radio.command requirements-local-voice.txt "$APP/Contents/Resources/"
xcrun swiftc -swift-version 5 -parse-as-library Sources/*.swift \
  -framework SwiftUI -framework Speech -framework Security -o "$APP/Contents/MacOS/NabaztagIA"
codesign --force --sign - "$APP"
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Application prête : $APP"
