#!/bin/zsh
set -eu
cd -- "${0:A:h}"
RADIO_TARGET="${1:-pi@192.168.68.54}"
echo "Installation de la radio sur $RADIO_TARGET."
echo "Utilise le mot de passe SSH habituel du lapin si Terminal le demande."
echo "La clé dédiée de l'application ne permet pas cette installation."
/usr/bin/ssh -T -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$RADIO_TARGET" '
set -eu
radio_update=$(mktemp)
trap '\''rm -f "$radio_update"'\'' EXIT
cat > "$radio_update"
python3 - "$radio_update" <<'\''PY'\''
import pathlib, sys
source = pathlib.Path(sys.argv[1])
compile(source.read_bytes(), str(source), "exec")
PY
if ! command -v curl >/dev/null || ! command -v mpg123 >/dev/null; then
    sudo -n apt-get install -y --no-install-recommends curl mpg123 </dev/null
fi
radio_bridge=/usr/local/lib/nabaztag-mac/bridge_remote.py
sudo -n install -d -m 755 /usr/local/lib/nabaztag-mac
if test -f "$radio_bridge" && ! test -e "$radio_bridge.before-radio"; then
    sudo -n cp -p "$radio_bridge" "$radio_bridge.before-radio"
fi
sudo -n install -m 755 "$radio_update" "$radio_bridge"
echo "Relais radio installé."
' < bridge_remote.py
echo "Installation terminée. Les trois stations sont disponibles dans Nabaztag IA."
