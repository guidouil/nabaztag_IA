#!/bin/zsh
set -eu
cd -- "${0:A:h}"
RADIO_TARGET="${1:-pi@192.168.68.54}"
echo "Installation de la radio et du volume sur $RADIO_TARGET."
echo "Utilise le mot de passe SSH habituel du lapin si Terminal le demande."
echo "La clé dédiée de l'application ne permet pas cette installation."
COPYFILE_DISABLE=1 tar --no-xattrs -cf - bridge_remote.py alsa.conf | /usr/bin/ssh -T -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$RADIO_TARGET" '
set -eu
radio_update=$(mktemp -d)
trap '\''rm -rf "$radio_update"'\'' EXIT
tar -xf - -C "$radio_update" --no-same-owner --no-same-permissions
python3 - "$radio_update/bridge_remote.py" <<'\''PY'\''
import pathlib, sys
source = pathlib.Path(sys.argv[1])
compile(source.read_bytes(), str(source), "exec")
PY
if ! command -v curl >/dev/null || ! command -v mpg123 >/dev/null; then
    sudo -n apt-get install -y --no-install-recommends curl mpg123 </dev/null
fi
python3 - "$radio_update" <<'\''PY'\''
import sys
sys.path.insert(0, sys.argv[1])
import bridge_remote as bridge
with bridge.reserve():
    bridge.run_audio(["aplay", "-q", "-D", bridge.PLAYBACK_DEVICE, "-t", "raw", "-f", "S16_LE",
                      "-r", "24000", "-c", "2", "-s", "1", "/dev/zero"], timeout=5)
bridge.volume()
PY
test -r /opt/pynab/nabd/sounds/asr/listen.mp3
radio_bridge=/usr/local/lib/nabaztag-mac/bridge_remote.py
sudo -n install -d -m 755 /usr/local/lib/nabaztag-mac
if test -f "$radio_bridge" && ! test -e "$radio_bridge.before-radio"; then
    sudo -n cp -p "$radio_bridge" "$radio_bridge.before-radio"
fi
if test -f "$radio_bridge" && ! test -e "$radio_bridge.before-volume"; then
    sudo -n cp -p "$radio_bridge" "$radio_bridge.before-volume"
fi
sudo -n install -m 644 "$radio_update/alsa.conf" /usr/local/lib/nabaztag-mac/alsa.conf
sudo -n install -m 755 "$radio_update/bridge_remote.py" "$radio_bridge"
sudo -n alsactl store tagtagtagsound
echo "Relais audio installé."
'
echo "Installation terminée. Radio, volume et signal vocal natif sont disponibles."
