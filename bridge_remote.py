#!/usr/bin/env python3
"""Restricted SSH entry point for the Nabaztag's audio devices."""

import contextlib
import base64
import datetime
import io
import json
import math
import os
import platform
import random
import select
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path


DEVICE = "plughw:CARD=tagtagtagsound,DEV=0"
MAX_AUDIO = 8 * 1024 * 1024
MAX_STREAM_AUDIO = 90 * 24000 * 2
STREAM_PACKET_TIMEOUT = 30
STREAM_WALL_TIMEOUT = 150
DEFAULT_EFFECTS = ("small", "fixed", "002838")
LIGHT_PALETTE = ((56, 8, 32), (64, 28, 0), (8, 56, 24),
                 (8, 24, 64), (40, 12, 56), (0, 40, 56))


def parse_action(command):
    args = shlex.split(command)
    if args[:2] == ["/usr/bin/python3", "/usr/local/lib/nabaztag-mac/bridge_remote.py"]:
        args = args[2:]
    if args in (["diagnostic"], ["play"], ["play-animated"], ["watch-button"]):
        return args[0], None
    if len(args) == 4 and args[0] in ("play-animated", "play-stream"):
        ears, lights, color = args[1:]
        if ears in ("off", "small", "large") and lights in ("off", "fixed", "random") and \
                len(color) == 6 and all(character in "0123456789abcdefABCDEF" for character in color):
            return args[0], (ears, lights, color)
    if len(args) == 2 and args[0] == "record":
        duration = int(args[1])
        if 1 <= duration <= 15:
            return "record", duration
    raise ValueError("Commandes autorisées : diagnostic, record N (1..15), play, play-animated, play-stream, watch-button")


def validate_wav(data):
    if len(data) > MAX_AUDIO:
        raise ValueError("Audio supérieur à 8 Mio")
    with wave.open(io.BytesIO(data), "rb") as audio:
        channels, width, rate, frames, compression, _ = audio.getparams()
        if compression != "NONE" or width != 2 or channels not in (1, 2):
            raise ValueError("WAV PCM 16 bits mono ou stéréo requis")
        if rate not in (16000, 22050, 44100, 48000):
            raise ValueError("Fréquence WAV non prise en charge")
        if not 0 < frames <= 90 * rate:
            raise ValueError("Audio vide ou durée supérieure à 90 secondes")
        if len(audio.readframes(frames + 1)) != frames * channels * width:
            raise ValueError("Données WAV tronquées ou trames incomplètes")
        return frames / rate


def receive(sock, stream, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Délai de réponse nabd dépassé")
    sock.settimeout(remaining)
    line = stream.readline(65537)
    if not line or len(line) > 65536 or not line.endswith(b"\n"):
        raise ValueError("Réponse nabd absente ou invalide")
    packet = json.loads(line)
    if not isinstance(packet, dict):
        raise ValueError("Réponse nabd invalide")
    return packet


def send(sock, packet):
    sock.sendall(json.dumps(packet).encode("utf-8") + b"\r\n")


def watch_button():
    with socket.create_connection(("127.0.0.1", 10543), timeout=10) as sock:
        sock.settimeout(None)
        input_fd = sys.stdin.fileno()
        request_id = "mac-bridge-button"
        send(sock, {"type": "mode", "mode": "idle", "events": ["button"],
                    "request_id": request_id})
        deadline = time.monotonic() + 10
        ready = False
        buffered = b""
        while True:
            timeout = None if ready else max(0, deadline - time.monotonic())
            readable, _, _ = select.select([sock, input_fd], [], [], timeout)
            if not readable:
                raise TimeoutError("Délai de souscription au bouton dépassé")
            if input_fd in readable and not os.read(input_fd, 4096):
                return
            if sock not in readable:
                continue
            data = sock.recv(4096)
            if not data:
                raise ConnectionError("Connexion nabd fermée pendant l'écoute du bouton")
            # Read raw socket bytes so select cannot miss packets in a makefile buffer.
            buffered += data
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                if len(line) > 65536:
                    raise ValueError("Réponse nabd trop longue")
                packet = json.loads(line)
                if not isinstance(packet, dict):
                    raise ValueError("Réponse nabd invalide")
                if packet.get("request_id") == request_id:
                    if packet.get("status") != "ok":
                        raise ValueError("Souscription au bouton refusée : " + json.dumps(packet))
                    if not ready:
                        ready = True
                        print("ready", flush=True)
                elif ready and packet.get("type") == "button_event" and packet.get("event") == "click":
                    print("click", flush=True)
            if len(buffered) > 65536:
                raise ValueError("Réponse nabd trop longue")


@contextlib.contextmanager
def reserve():
    with socket.create_connection(("127.0.0.1", 10543), timeout=10) as sock:
        with sock.makefile("rb") as stream:
            deadline = time.monotonic() + 10
            while True:
                packet = receive(sock, stream, deadline)
                if packet.get("type") != "state":
                    continue
                state = packet.get("state")
                if state == "idle":
                    break
                if state == "asleep":
                    raise ValueError("Le lapin dort : réveille-le avant le test audio")
                if state == "interactive":
                    raise ValueError("Le lapin est déjà réservé par un autre service")
                if state not in ("playing", "recording"):
                    raise ValueError("État nabd inconnu : " + str(state))
            request_id = "mac-bridge-mode"
            # A timed-out client must not leave a stale reservation in nabd's queue.
            expiration = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=10)
            send(sock, {"type": "mode", "mode": "interactive", "events": ["button"],
                        "request_id": request_id, "expiration": expiration.isoformat()})
            acknowledged = interactive = False
            while not (acknowledged and interactive):
                packet = receive(sock, stream, deadline)
                if packet.get("request_id") == request_id:
                    if packet.get("status") != "ok":
                        raise ValueError("Réservation refusée : " + json.dumps(packet))
                    acknowledged = True
                if packet.get("type") == "state":
                    interactive = packet.get("state") == "interactive"
            # Closing this connection releases interactive mode, including after an error.
            yield sock, stream


def run_audio(args, timeout):
    result = subprocess.run(args, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise ValueError(args[0] + " : " + result.stderr.decode("utf-8", "replace").strip())


def write_beep(filename):
    with wave.open(str(filename), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes(b"".join(
            struct.pack("<h", round(1500 * math.sin(2 * math.pi * 880 * frame / 16000)))
            for frame in range(1600)
        ))


def record(duration):
    with reserve(), tempfile.TemporaryDirectory(prefix="nabaztag-mac-") as directory:
        filename = Path(directory) / "recording.wav"
        beep = Path(directory) / "ready.wav"
        write_beep(beep)
        deadline = time.monotonic() + duration + 5
        capture = subprocess.Popen(
            ["arecord", "-q", "-D", DEVICE, "-t", "wav", "-f", "S16_LE",
             "-r", "16000", "-c", "1", "-d", str(duration), str(filename)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        try:
            # Let ALSA open the microphone before announcing that recording is ready.
            time.sleep(0.2)
            if capture.poll() is not None:
                _, error = capture.communicate(timeout=5)
                raise ValueError("arecord : " + (error.decode("utf-8", "replace").strip()
                                               or "enregistrement terminé avant le signal"))
            run_audio(["aplay", "-q", "-D", DEVICE, str(beep)],
                      timeout=min(5, max(0.01, deadline - time.monotonic())))
            _, error = capture.communicate(timeout=max(0.01, deadline - time.monotonic()))
            if capture.returncode:
                raise ValueError("arecord : " + error.decode("utf-8", "replace").strip())
        finally:
            if capture.poll() is None:
                capture.kill()
            capture.communicate(timeout=5)
        data = filename.read_bytes()
        validate_wav(data)
        sys.stdout.buffer.write(data)


def response_choreography(duration, options=DEFAULT_EFFECTS, first_motor=0):
    ears, lights, color = options
    if ears == "off" and lights == "off":
        return None, 0
    slots = min(75, max(1, math.ceil(duration / 1.2)))
    if ears == "large":
        slots = min(74, slots + slots % 2)  # A large retreat and return need two 1.2 s slots.
    rgb = tuple(bytes.fromhex(color))
    peak = max(rgb)
    if peak > 64:
        rgb = tuple(round(value * 64 / peak) for value in rgb)
    choreography = bytearray([0, 1, 10])  # MTL frame duration: 100 ms.
    for slot in range(slots):
        colors = random.sample(LIGHT_PALETTE, 3) if lights == "random" else \
            [rgb] * 3 if lights == "fixed" and slot == 0 else []
        for led, (red, green, blue) in zip((1, 2, 3), colors):
            choreography.extend([0, 7, led, red, green, blue, 0, 0])
        # Keep every ear between rest and rest-delta, so idle returns in the forward direction.
        if ears == "small":
            motor = (first_motor + slot) % 2
            choreography.extend([
                0, 20, motor, 1, 0, 17, motor, 1, 0, 19,
                6, 20, motor, 0, 0, 17, motor, 1, 0, 19, 6, 0,
            ])
        elif ears == "large":
            motor, direction = (first_motor + slot // 2) % 2, 1 - slot % 2
            choreography.extend([0, 20, motor, direction, 0, 17, motor, 3, 0, 19, 12, 0])
        else:
            choreography.extend([12, 0])
    resource = "data:application/x-nabaztag-mtl-choreography;base64,"
    return resource + base64.b64encode(choreography).decode("ascii"), slots * 1.2


def finish_ears(sock, stream, request_id, deadline, cancel=False):
    cancel_packet = {"type": "cancel", "request_id": request_id}
    if cancel:
        send(sock, cancel_packet)
    error = None
    while True:
        packet = receive(sock, stream, deadline)
        if packet.get("type") != "response" or packet.get("request_id") != request_id:
            continue
        if packet.get("status") in ("ok", "canceled"):
            if error:
                raise error
            return
        if cancel and packet.get("class") == "NotPlaying":
            # perform() is scheduled asynchronously; an early cancel can precede its start.
            time.sleep(0.05)
            send(sock, cancel_packet)
        elif cancel and packet.get("class") == "NotCancelable":
            error = ValueError("Arrêt des oreilles refusé : " + json.dumps(packet))
        else:
            raise ValueError("Animation des oreilles refusée : " + json.dumps(packet))


def play(data, animate=False, options=None):
    duration = validate_wav(data)
    with reserve() as (sock, stream), tempfile.TemporaryDirectory(prefix="nabaztag-mac-") as directory:
        filename = Path(directory) / "reply.wav"
        filename.write_bytes(data)
        choreography, motion_duration = response_choreography(duration, options or DEFAULT_EFFECTS) \
            if animate else (None, 0)
        if choreography is None:
            run_audio(["aplay", "-q", "-D", DEVICE, str(filename)], timeout=duration + 5)
            return
        request_id = "mac-bridge-ears"
        motion_deadline = time.monotonic() + motion_duration + 5
        # shortcut: TCP loss leaves this finite sequence running; add nabd disconnect cancellation for strict teardown.
        send(sock, {"type": "command", "request_id": request_id, "cancelable": True,
                    "sequence": [{"choreography": choreography}]})
        failed = False
        try:
            run_audio(["aplay", "-q", "-D", DEVICE, str(filename)], timeout=duration + 5)
        except BaseException:
            failed = True
            raise
        finally:
            try:
                # Finish the compensated movement before idle, avoiding its cyan positioning light.
                finish_ears(sock, stream, request_id, max(motion_deadline, time.monotonic() + 5), cancel=failed)
            except Exception as error:
                if not failed:
                    raise
                print("Arrêt des oreilles : " + str(error), file=sys.stderr)


def stream_play(input_stream, options=DEFAULT_EFFECTS):
    deadline = time.monotonic() + STREAM_WALL_TIMEOUT
    with reserve() as (sock, stream), tempfile.TemporaryFile() as errors:
        player = subprocess.Popen(
            ["aplay", "-q", "-D", DEVICE, "-t", "raw", "-f", "S16_LE", "-r", "24000", "-c", "1"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errors, bufsize=0,
        )
        stop = threading.Event()
        animation_errors = []
        worker = None
        failed = False

        def animate():
            try:
                motor, sequence = 0, 0
                cycle = 2.4 if options[0] == "large" else 1.2
                while not stop.is_set():
                    choreography, duration = response_choreography(cycle, options, first_motor=motor)
                    request_id = "mac-bridge-stream-" + str(sequence)
                    # Finite cycles also bound residual motion if nabd loses this connection.
                    send(sock, {"type": "command", "request_id": request_id, "cancelable": True,
                                "sequence": [{"choreography": choreography}]})
                    finish_ears(sock, stream, request_id,
                                min(deadline + 8, time.monotonic() + duration + 5))
                    motor, sequence = 1 - motor, sequence + 1
            except Exception as error:
                animation_errors.append(error)
                stop.set()

        def check_player():
            if player.poll() is not None:
                errors.seek(0)
                detail = errors.read(8192).decode("utf-8", "replace").strip()
                raise ValueError("aplay : " + (detail or "lecture terminée avant la fin du flux"))
            if animation_errors:
                raise animation_errors[0]
            if time.monotonic() >= deadline:
                raise TimeoutError("Le flux audio a dépassé 150 secondes")

        try:
            output_fd = player.stdin.fileno()
            os.set_blocking(output_fd, False)
            input_fd = input_stream.fileno()
            print("ready", flush=True)
            total, pending = 0, b""
            packet_deadline = time.monotonic() + STREAM_PACKET_TIMEOUT
            while True:
                check_player()
                remaining = min(deadline, packet_deadline) - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Aucun paquet PCM reçu pendant 30 secondes")
                readable, _, _ = select.select([input_fd], [], [], min(1, remaining))
                if not readable:
                    continue
                data = os.read(input_fd, 16384)
                if not data:
                    if total == 0:
                        raise ValueError("Le flux PCM est vide")
                    if pending:
                        raise ValueError("Le flux PCM contient une demi-trame de 16 bits")
                    break
                packet_deadline = time.monotonic() + STREAM_PACKET_TIMEOUT
                total += len(data)
                if total > MAX_STREAM_AUDIO:
                    raise ValueError("Le flux PCM dépasse 90 secondes (4 320 000 octets)")
                data = pending + data
                even = len(data) - len(data) % 2
                pending = data[even:]
                data = memoryview(data)[:even]
                write_deadline = time.monotonic() + STREAM_PACKET_TIMEOUT
                while data:
                    check_player()
                    remaining = min(deadline, write_deadline) - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("Le lecteur PCM ne consomme plus le flux")
                    _, writable, _ = select.select([], [output_fd], [], min(1, remaining))
                    if not writable:
                        continue
                    try:
                        written = os.write(output_fd, data)
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        player.wait(timeout=5)
                        check_player()
                        raise
                    if written == 0:
                        raise ValueError("Écriture PCM interrompue")
                    data = data[written:]
                    if worker is None and options[:2] != ("off", "off"):
                        worker = threading.Thread(target=animate, name="nabaztag-stream-effects", daemon=True)
                        worker.start()
            player.stdin.close()
            player.stdin = None
            result = player.wait(timeout=max(0.01, min(10, deadline - time.monotonic())))
            if result:
                errors.seek(0)
                raise ValueError("aplay : " + errors.read(8192).decode("utf-8", "replace").strip())
        except BaseException:
            failed = True
            raise
        finally:
            stop.set()
            cleanup_error = None
            try:
                try:
                    if player.stdin is not None:
                        player.stdin.close()
                finally:
                    player.stdin = None
                    if player.poll() is None:
                        player.kill()
                    player.wait(timeout=5)
            except Exception as error:
                cleanup_error = error
            if worker is not None:
                worker.join(timeout=8)
                if worker.is_alive():
                    with contextlib.suppress(OSError):
                        sock.shutdown(socket.SHUT_RDWR)
                    worker.join(timeout=1)
                    cleanup_error = cleanup_error or TimeoutError("Fin des effets du flux audio trop longue")
                if worker.is_alive():
                    cleanup_error = RuntimeError("Le thread d’effets n’a pas pu se terminer")
            cleanup_error = cleanup_error or (animation_errors[0] if animation_errors else None)
            if cleanup_error is not None:
                if not failed:
                    raise cleanup_error
                print("Arrêt du flux : " + str(cleanup_error), file=sys.stderr)


def diagnostic():
    result = {"bridge_version": 1, "uname": platform.uname()._asdict(), "commands": {}}
    commands = [
        ["git", "-C", "/opt/pynab", "describe", "--tags", "--always"],
        ["systemctl", "is-active", "nabd.service", "nabweb.service", "nginx.service"],
        ["systemctl", "--failed", "--no-pager", "--no-legend"],
        ["vcgencmd", "get_throttled"], ["vcgencmd", "measure_temp"],
        ["aplay", "-l"], ["arecord", "-l"],
    ]
    for command in commands:
        try:
            completed = subprocess.run(command, capture_output=True, text=True, timeout=5)
            output = {"returncode": completed.returncode, "stdout": completed.stdout.strip(),
                      "stderr": completed.stderr.strip()}
        except (OSError, subprocess.TimeoutExpired) as error:
            output = {"returncode": None, "error": str(error)}
        result["commands"][shlex.join(command)] = output
    try:
        with socket.create_connection(("127.0.0.1", 10543), timeout=10) as sock:
            with sock.makefile("rb") as stream:
                send(sock, {"type": "gestalt", "request_id": "mac-bridge-gestalt"})
                deadline = time.monotonic() + 10
                while True:
                    packet = receive(sock, stream, deadline)
                    if packet.get("request_id") == "mac-bridge-gestalt":
                        result["gestalt"] = packet
                        break
    except (OSError, ValueError) as error:
        result["gestalt_error"] = str(error)
    print(json.dumps(result, ensure_ascii=False))


def main():
    try:
        command = os.environ.get("SSH_ORIGINAL_COMMAND", shlex.join(sys.argv[1:]))
        action, argument = parse_action(command)
        if action == "diagnostic":
            diagnostic()
        elif action == "record":
            record(argument)
        elif action == "watch-button":
            watch_button()
        elif action == "play-stream":
            stream_play(sys.stdin.buffer, options=argument)
        else:
            play(sys.stdin.buffer.read(MAX_AUDIO + 1), animate=action == "play-animated", options=argument)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, wave.Error, EOFError) as error:
        print("Nabaztag : " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
