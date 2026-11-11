#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p .build
python3 -m unittest discover -s tests -v
SUPPORT=(Sources/Bridge.swift Sources/SSHSettings.swift Sources/AIProvider.swift Sources/AppConfiguration.swift Sources/ButtonWatcher.swift Sources/SSHTrust.swift Sources/LocalVoice.swift Sources/ClaudeCode.swift Sources/GrokBuild.swift Sources/StreamPlayback.swift Sources/Weather.swift Sources/News.swift)
for CHECK in tests/*Checks.swift; do
  NAME="${CHECK:t:r}"
  xcrun swiftc -swift-version 5 -parse-as-library "${SUPPORT[@]}" "$CHECK" \
    -framework Speech -framework Security -o ".build/$NAME"
  ".build/$NAME"
done
"./Nabaztag IA.app/Contents/MacOS/NabaztagIA" --self-test
