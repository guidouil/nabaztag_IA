#!/bin/zsh
set -eu
cd -- "${0:A:h}"
VOICE_RUNTIME="$HOME/Library/Application Support/NabaztagIA/Voice"
VOICE_UV="$(command -v uv || true)"
if [[ -z "$VOICE_UV" ]]; then
  echo "Installe uv depuis https://docs.astral.sh/uv/getting-started/installation/ puis relance ce fichier."
  exit 1
fi
mkdir -p "$VOICE_RUNTIME"
if [[ ! -x "$VOICE_RUNTIME/venv/bin/python" ]]; then
  "$VOICE_UV" venv --python 3.12 "$VOICE_RUNTIME/venv"
fi
"$VOICE_UV" pip sync --python "$VOICE_RUNTIME/venv/bin/python" requirements-local-voice.txt
"$VOICE_RUNTIME/venv/bin/python" - "$VOICE_RUNTIME/model" <<'PY'
import os
import sys

os.environ.pop("HF_HUB_OFFLINE", None)
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="mlx-community/Kokoro-82M-bf16",
    revision="a71e4d38b236d968966a2002c4c895dbd12b1c3c",
    local_dir=sys.argv[1],
    allow_patterns=["config.json", "kokoro-v1_0.safetensors", "voices/ff_siwis.safetensors"],
)
PY
echo "Voix locale installée. Rouvre Nabaztag IA et choisis Siwis dans Réglages → Voix."
