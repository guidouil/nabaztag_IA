#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

if (( $# == 1 )) && [[ "$1" == --preview ]]; then
  MODE=preview
elif (( $# == 2 )) && [[ "$1" == --archive && "$2" == "Developer ID Application: "* ]]; then
  MODE=archive
  IDENTITY="$2"
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
  if [[ "$IDENTITIES" != *"\"$IDENTITY\""* ]]; then
    print -u2 -- "Certificat Developer ID Application introuvable dans le Trousseau."
    exit 1
  fi
  if [[ ! "$IDENTITY" =~ '\(([A-Z0-9]{10})\)$' ]]; then
    print -u2 -- "Team ID introuvable dans le nom du certificat."
    exit 1
  fi
  TEAM_ID="$match[1]"
elif (( $# == 2 )) && [[ "$1" == --package && -n "$2" ]]; then
  MODE=package
  EXPORTED_APP="${2:A}"
else
  print -u2 -- "Usage : $0 --preview"
  print -u2 -- "     ou $0 --archive 'Developer ID Application: Nom (TEAMID)'"
  print -u2 -- "     ou $0 --package '/chemin/export/Nabaztag IA.app'"
  exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
  print -u2 -- "Version invalide dans Info.plist."
  exit 1
fi
NAME="Nabaztag-IA-$VERSION-arm64"
ARCHIVE="$PWD/.build/release/$NAME.xcarchive"
if [[ "$MODE" == archive && -e "$ARCHIVE" ]]; then
  print -u2 -- "Archive déjà présente, conservée : $ARCHIVE"
  exit 1
fi
if [[ "$MODE" == package ]]; then
  if [[ ! -d "$EXPORTED_APP" || \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXPORTED_APP/Contents/Info.plist")" != local.gui.nabaztag-ia || \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXPORTED_APP/Contents/Info.plist")" != "$VERSION" ]]; then
    print -u2 -- "L'app exportée doit être Nabaztag IA version $VERSION."
    exit 1
  fi
  codesign --verify --deep --strict "$EXPORTED_APP"
  codesign --verify --strict "$EXPORTED_APP/Contents/MacOS/NabaztagSSHAskpass"
  for EXECUTABLE in NabaztagIA NabaztagSSHAskpass; do
    SIGNATURE="$(codesign -d --verbose=4 "$EXPORTED_APP/Contents/MacOS/$EXECUTABLE" 2>&1)"
    if [[ ! "$SIGNATURE" =~ 'flags=0x[[:xdigit:]]+\([^)]*runtime[^)]*\)' ]]; then
      print -u2 -- "Hardened runtime absent : $EXECUTABLE"
      exit 1
    fi
  done
  xcrun stapler validate "$EXPORTED_APP"
  spctl --assess --type execute --verbose=2 "$EXPORTED_APP"
fi

mkdir -p .build/release
WORK="$(mktemp -d "$PWD/.build/release/package.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
BUILD=(xcodebuild -quiet -project 'Nabaztag IA.xcodeproj' -scheme 'Nabaztag IA'
  -configuration Release -destination 'generic/platform=macOS'
  -derivedDataPath "$PWD/.build/release/DerivedData"
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=14.0 ENABLE_HARDENED_RUNTIME=YES)
if [[ "$MODE" == archive ]]; then
  "${BUILD[@]}" -archivePath "$WORK/$NAME.xcarchive" CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp archive
  mv "$WORK/$NAME.xcarchive" "$ARCHIVE"
  print -- "Archive signée : $ARCHIVE"
  print -- "Ouvre-la dans Xcode Organizer : Direct Distribution, puis Export Notarized App."
  exit 0
fi
mkdir "$WORK/image"
APP="$WORK/image/Nabaztag IA.app"
if [[ "$MODE" == preview ]]; then
  "${BUILD[@]}" CODE_SIGNING_ALLOWED=NO build
  ditto '.build/release/DerivedData/Build/Products/Release/Nabaztag IA.app' "$APP"
  codesign --force --options runtime --sign - "$APP/Contents/MacOS/NabaztagSSHAskpass"
  codesign --force --options runtime --sign - "$APP"
  codesign --verify --deep --strict "$APP"
  NAME+="-non-notarise"
else
  ditto "$EXPORTED_APP" "$APP"
fi
ln -s /Applications "$WORK/image/Applications"
cp DISTRIBUTION.md "$WORK/image/Installation.md"
DMG="$WORK/$NAME.dmg"
# shortcut: DMG non signé avec app déjà staplée ; notariser aussi le DMG si une cible macOS l'exige.
hdiutil create -quiet -volname 'Nabaztag IA' -srcfolder "$WORK/image" -format UDZO "$DMG"
mkdir -p dist
mv -f "$DMG" "dist/$NAME.dmg"
if [[ "$MODE" == preview ]]; then
  print -- "Aperçu local non notarisé, à ne pas publier : $PWD/dist/$NAME.dmg"
else
  print -- "DMG contenant l'app notarisée et staplée prêt pour GitHub Releases : $PWD/dist/$NAME.dmg"
fi
