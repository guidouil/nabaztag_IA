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
import re
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from collections import deque
from pathlib import Path


DEVICE = "plughw:CARD=tagtagtagsound,DEV=0"
PLAYBACK_DEVICE = "nabaztag_mac"
MAX_AUDIO = 8 * 1024 * 1024
MAX_STREAM_AUDIO = 90 * 24000 * 2
MAX_STREAM_SEGMENTS = 2000
STREAM_PACKET_TIMEOUT = 30
STREAM_WALL_TIMEOUT = 150
MAX_CAPTURE_SECONDS = 90
THINK_WALL_TIMEOUT = 210
FIRST_AUDIO_TIMEOUT = THINK_WALL_TIMEOUT + 120  # Keep the voice worker's synthesis allowance after the AI wait.
THINK_CYCLE_TIMEOUT = 15
DEFAULT_EFFECTS = ("on", "fixed", "002838")
LIGHT_PALETTE = ((56, 8, 32), (64, 28, 0), (8, 56, 24),
                 (8, 24, 64), (40, 12, 56), (0, 40, 56))
RADIO_STREAMS = {
    "nova": "https://novazz.ice.infomaniak.ch/novazz-128.mp3",
    "franceinfo": "https://icecast.radiofrance.fr/franceinfo-midfi.mp3",
    "phenix": "https://live.radio-campus.org:8002/caen.mp3",
}
RADIO_START_TIMEOUT = 12
RADIO_STALL_TIMEOUT = 20


def parse_action(command):
    args = shlex.split(command)
    if args[:2] == ["/usr/bin/python3", "/usr/local/lib/nabaztag-mac/bridge_remote.py"]:
        args = args[2:]
    if args and args[0] == "volume":
        canonical = " ".join(args)
        if command in (canonical, "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py " + canonical):
            if len(args) == 1:
                return "volume", None
            if len(args) == 2 and args[1].isascii() and args[1].isdecimal():
                value = int(args[1])
                if 0 <= value <= 100 and str(value) == args[1]:
                    return "volume", value
    if args in (["diagnostic"], ["play"], ["play-animated"], ["watch-button"], ["record-until-stop"]):
        return args[0], None
    if len(args) == 2 and args[0] == "think" and args[1] in ("forward", "backward"):
        return "think", args[1]
    if len(args) in (2, 3) and args[0] == "radio" and args[1] in RADIO_STREAMS:
        ears = args[2] if len(args) == 3 else "on"
        if ears in ("off", "on"):
            return "radio", (args[1], ears)
    if len(args) in (4, 5) and args[0] in ("play-animated", "play-stream", "play-queue"):
        ears, lights, color = args[1:4]
        thinking = args[4:] if args[0] in ("play-stream", "play-queue") else []
        if ears in ("off", "on", "small", "large") and lights in ("off", "fixed", "random") and \
                len(color) == 6 and all(character in "0123456789abcdefABCDEF" for character in color) and \
                (len(args) == 4 or thinking in (["forward"], ["backward"])):
            return args[0], (ears, lights, color, *thinking)
    if len(args) == 2 and args[0] == "record":
        duration = int(args[1])
        if 1 <= duration <= 15:
            return "record", duration
    raise ValueError("Commandes autorisées : diagnostic, volume [0..100], record N (1..15), record-until-stop, think forward|backward, radio nova|franceinfo|phenix, play, play-animated, play-stream, play-queue, watch-button")


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
        # select() must see every remaining packet, including button events after the reservation ACK.
        with sock.makefile("rb", buffering=0) as stream:
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


def playback_environment():
    return dict(os.environ, ALSA_CONFIG_PATH=str(Path(__file__).with_name("alsa.conf")))


def volume(value=None):
    if value is not None and (type(value) is not int or not 0 <= value <= 100):
        raise ValueError("Le volume doit être un entier de 0 à 100")
    command = ["amixer", "-c", "tagtagtagsound", "cget" if value is None else "cset", "name=Nabaztag IA"]
    if value is not None:
        command.append("{0},{0}".format(value))
    result = subprocess.run(command, capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, LC_ALL="C"))
    if result.returncode:
        raise ValueError("Volume indisponible : relancer setup-radio.command pour initialiser le contrôle audio. " +
                         result.stderr.strip())
    metadata = re.search(r"(?m)^\s*; type=INTEGER,access=[^,\n]+,values=2,min=0,max=100,step=[0-9]+\s*$", result.stdout)
    levels = re.search(r"(?m)^\s*: values=([0-9]+),([0-9]+)\s*$", result.stdout)
    if not metadata or not levels:
        raise ValueError("Réponse du volume du lapin invalide")
    left, right = (int(level) for level in levels.groups())
    if left != right or not 0 <= left <= 100 or any(str(int(level)) != level for level in levels.groups()):
        raise ValueError("Niveaux stéréo du volume du lapin invalides")
    return left


def run_audio(args, timeout):
    result = subprocess.run(args, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, timeout=timeout, env=playback_environment())
    if result.returncode:
        raise ValueError(args[0] + " : " + result.stderr.decode("utf-8", "replace").strip())


def record(duration=None):
    with reserve() as reservation, tempfile.TemporaryDirectory(prefix="nabaztag-mac-") as directory:
        filename = Path(directory) / "recording.wav"
        limit = MAX_CAPTURE_SECONDS if duration is None else duration
        deadline = time.monotonic() + limit + 5
        capture = subprocess.Popen(
            ["arecord", "-q", "-D", DEVICE, "-t", "wav", "-f", "S16_LE",
             "-r", "16000", "-c", "1", "-d", str(limit), str(filename)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        try:
            # Let ALSA open the microphone before announcing that recording is ready.
            time.sleep(0.2)
            if capture.poll() is not None:
                _, error = capture.communicate(timeout=5)
                raise ValueError("arecord : " + (error.decode("utf-8", "replace").strip()
                                               or "enregistrement terminé avant le signal"))
            run_audio(["mpg123", "--quiet", "--no-control", "-o", "alsa", "-a", PLAYBACK_DEVICE,
                       "/opt/pynab/nabd/sounds/asr/listen.mp3"],
                      timeout=min(5, max(0.01, deadline - time.monotonic())))
            stopped = False
            if duration is None:
                sock, stream = reservation
                input_fd, control = sys.stdin.fileno(), b""
                while capture.poll() is None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("Délai d’enregistrement dépassé")
                    readable, _, _ = select.select([sock, input_fd], [], [], min(0.2, remaining))
                    if input_fd in readable:
                        data = os.read(input_fd, 64)
                        if not data:
                            raise ValueError("Enregistrement annulé : connexion fermée")
                        control += data
                        if not b"stop\n".startswith(control):
                            raise ValueError("Commande d’arrêt d’enregistrement invalide")
                        stopped = control == b"stop\n"
                    if sock in readable:
                        packet = receive(sock, stream, deadline)
                        stopped = stopped or (packet.get("type") == "button_event" and packet.get("event") == "click")
                    if stopped:
                        capture.send_signal(signal.SIGINT)
                        break
            _, error = capture.communicate(timeout=max(0.01, deadline - time.monotonic()))
            # arecord finalizes its WAV on SIGINT and normally returns EXIT_FAILURE (1).
            if capture.returncode and not (stopped and capture.returncode == 1 and not error.strip()):
                raise ValueError("arecord : " + error.decode("utf-8", "replace").strip())
        finally:
            if capture.poll() is None:
                capture.kill()
            capture.communicate(timeout=5)
        data = filename.read_bytes()
        validate_wav(data)
        sys.stdout.buffer.write(data)


def thinking_choreography(direction):
    first = 0 if direction == "forward" else 1
    # Pynab: 17 relative steps make a full turn; opcode 19 waits for both motors.
    choreography = bytes([0, 1, 10, 0, 20, 0, first, 0, 20, 1, 1 - first,
                          0, 17, 0, 17, 0, 17, 1, 17, 0, 19])
    return "data:application/x-nabaztag-mtl-choreography;base64," + base64.b64encode(choreography).decode("ascii")


def think(direction):
    deadline = time.monotonic() + FIRST_AUDIO_TIMEOUT
    choreography = thinking_choreography(direction)
    with reserve() as (sock, stream):
        stopping = False

        def stop(signum, frame):
            nonlocal stopping
            stopping = True

        handlers = {}
        try:
            for signum in (signal.SIGTERM, signal.SIGHUP):
                handlers[signum] = signal.signal(signum, stop)
            print("ready", flush=True)
            input_fd = sys.stdin.fileno()
            sequence = 0
            pause_until = 0
            while not stopping:
                readable, _, _ = select.select([input_fd], [], [],
                                                max(0, min(deadline, pause_until) - time.monotonic()))
                if readable:
                    if os.read(input_fd, 64):
                        raise ValueError("La réflexion s’arrête en fermant son entrée")
                    return
                if stopping:
                    return
                if time.monotonic() >= deadline:
                    raise TimeoutError("La réflexion a dépassé %g secondes" % FIRST_AUDIO_TIMEOUT)
                request_id = "mac-bridge-thinking-" + str(sequence)
                send(sock, {"type": "command", "request_id": request_id, "cancelable": False,
                            "sequence": [{"choreography": choreography}]})
                # Finish the whole turn before releasing the reservation, preserving the resting position.
                finish_ears(sock, stream, request_id, min(deadline, time.monotonic() + THINK_CYCLE_TIMEOUT))
                sequence += 1
                pause_until = time.monotonic() + 3
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)


def radio(station, ears="on"):
    url = RADIO_STREAMS[station]
    if not all(shutil.which(command) for command in ("curl", "mpg123")):
        raise ValueError("Radio indisponible : installer curl et mpg123 sur le lapin, puis réessayer")
    with reserve() as (sock, stream), contextlib.ExitStack() as effects:
        children, diagnostics = [], {}
        animation_errors, effects_started, clicked = [], False, threading.Event()

        def on_event(packet):
            if packet.get("type") == "button_event" and packet.get("event") == "click":
                clicked.set()

        try:
            network = subprocess.Popen(
                ["curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--no-buffer",
                 "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "5",
                 "--connect-timeout", "10", "--speed-limit", "1", "--speed-time", "15",
                 "--header", "Icy-MetaData: 0", url],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            children.append(network)
            player = subprocess.Popen(
                ["mpg123", "--quiet", "--no-control", "-o", "alsa", "-a", PLAYBACK_DEVICE, "-"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=playback_environment(),
            )
            children.append(player)
            output_fd = player.stdin.fileno()
            os.set_blocking(output_fd, False)
            input_fd, network_fd = sys.stdin.fileno(), network.stdout.fileno()
            errors = {child.stderr.fileno(): child for child in children}
            diagnostics = {child: b"" for child in children}
            started = last_write = time.monotonic()
            first_write, ready, pending = None, False, b""
            while True:
                if animation_errors:
                    raise animation_errors[0]
                if clicked.is_set():
                    if not ready:
                        print("ready", flush=True)
                    return
                now = time.monotonic()
                if not ready and now - started >= RADIO_START_TIMEOUT:
                    raise TimeoutError("La radio n’a pas démarré dans le délai prévu")
                if pending and now - last_write >= RADIO_STALL_TIMEOUT:
                    raise TimeoutError("Le lecteur radio ne consomme plus l’audio")
                readable, writable, _ = select.select(
                    ([] if effects_started else [sock]) + [input_fd] + list(errors) +
                    ([network_fd] if len(pending) < 32768 else []),
                    [output_fd] if pending else [], [], 0.1,
                )
                if input_fd in readable:
                    if os.read(input_fd, 64):
                        raise ValueError("La radio s’arrête en fermant son entrée")
                    if not ready:
                        print("ready", flush=True)
                    return
                if sock in readable:
                    packet = receive(sock, stream, time.monotonic() + 1)
                    if packet.get("type") == "button_event" and packet.get("event") == "click":
                        if not ready:
                            print("ready", flush=True)
                        return
                for descriptor in list(errors):
                    if descriptor in readable:
                        data = os.read(descriptor, 4096)
                        child = errors[descriptor]
                        diagnostics[child] = (diagnostics[child] + data)[-2048:]
                        if not data:
                            del errors[descriptor]
                for child, name in ((network, "Flux radio"), (player, "mpg123")):
                    if child.poll() is not None:
                        detail = diagnostics[child].decode("utf-8", "replace").strip()
                        raise ValueError(name + " interrompu : " + (detail or "connexion ou lecture terminée"))
                if network_fd in readable:
                    data = os.read(network_fd, 16384)
                    if not data:
                        detail = diagnostics[network].decode("utf-8", "replace").strip()
                        raise ValueError("Le flux radio a fermé la connexion" + (" : " + detail if detail else ""))
                    if not pending:
                        last_write = time.monotonic()
                    pending += data
                if output_fd in writable:
                    try:
                        count = os.write(output_fd, pending)
                    except BlockingIOError:
                        count = 0
                    if count:
                        pending = pending[count:]
                        last_write = time.monotonic()
                        if first_write is None:
                            first_write = last_write
                            if ears != "off":
                                animation_errors = effects.enter_context(response_effects(
                                    sock, stream, (ears, "off", "002838"), on_event=on_event))
                                effects_started = True
                # Data has reached the decoder; give immediate ALSA failures time to surface.
                if not ready and first_write is not None and time.monotonic() - first_write >= 0.2:
                    print("ready", flush=True)
                    ready = True
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
            for child in children:
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
                for handle in (child.stdin, child.stdout, child.stderr):
                    if handle is not None:
                        handle.close()


def response_choreography(duration, options=DEFAULT_EFFECTS, ear_state=None):
    ears, lights, color = options
    if ears == "off" and lights == "off":
        return None, 0
    frames = min(9000, max(1, math.ceil(duration * 100)))
    events = []
    if ears != "off":
        state = ear_state if ear_state is not None else {}
        start = state.get("elapsed", 0)
        end = start + frames
        next_frame = state.get("next", 0)
        while next_frame < end:
            movement = state.get("movements", 0)
            if movement % 3 == 2:
                direction = (movement // 3) % 2
                for motor in (0, 1):
                    events.append((next_frame - start, [20, motor, direction ^ motor]))
                    events.append((next_frame - start, [17, motor, 17]))
            else:
                previous = state.get("positions")
                if previous is None:
                    positions = random.choice(((0, 10), (10, 0)))
                else:
                    positions = random.choice(tuple((left, right) for left in (0, 5, 10, 14)
                                                    for right in (0, 5, 10, 14) if (left, right) != previous))
                for motor, position in enumerate(positions):
                    events.append((next_frame - start, [8, motor, position, 0]))
                state["positions"] = positions
            # Wait for both motors before the 3–6 second pause; 17 calibrated steps make a full turn.
            events.append((next_frame - start, [19]))
            state["movements"] = movement + 1
            next_frame += random.randint(300, 600)
            state["next"] = next_frame
        state["elapsed"] = end
    rgb = tuple(bytes.fromhex(color))
    peak = max(rgb)
    if peak > 64:
        rgb = tuple(round(value * 64 / peak) for value in rgb)
    for slot in range(math.ceil(frames / 120)):
        colors = random.sample(LIGHT_PALETTE, 3) if lights == "random" else \
            [rgb] * 3 if lights == "fixed" and slot == 0 else []
        for led, (red, green, blue) in zip((1, 2, 3), colors):
            events.append((slot * 120, [7, led, red, green, blue, 0, 0]))
    events.append((frames, [0]))
    choreography = bytearray([0, 1, 1])  # MTL frame duration: 10 ms.
    previous_frame = 0
    for frame, instruction in sorted(events, key=lambda event: (event[0], event[1][0] == 19)):
        delay = frame - previous_frame
        while delay > 255:
            choreography.extend([255, 0])
            delay -= 255
        choreography.extend([delay] + instruction)
        previous_frame = frame
    resource = "data:application/x-nabaztag-mtl-choreography;base64,"
    return resource + base64.b64encode(choreography).decode("ascii"), frames / 100


def finish_ears(sock, stream, request_id, deadline, cancel=False, on_event=None):
    cancel_packet = {"type": "cancel", "request_id": request_id}
    if cancel:
        send(sock, cancel_packet)
    error = None
    while True:
        packet = receive(sock, stream, deadline)
        if packet.get("type") != "response" or packet.get("request_id") != request_id:
            if on_event is not None:
                on_event(packet)
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


@contextlib.contextmanager
def response_effects(sock, stream, options, deadline=float("inf"), on_event=None,
                     thinking=None, audio_started=None):
    errors = []
    if options[:2] == ("off", "off"):
        yield errors
        return
    stop = threading.Event()
    audio_started = audio_started if audio_started is not None else threading.Event()
    if thinking is None:
        audio_started.set()

    def animate():
        try:
            ear_state, sequence = {}, 0
            while not stop.is_set():
                waiting = thinking is not None and not audio_started.is_set()
                if waiting and options[0] == "off":
                    stop.wait(0.1)
                    continue
                choreography, duration = (thinking_choreography(thinking), 0) if waiting else \
                    response_choreography(1.2, options, ear_state)
                request_id = "mac-bridge-effects-" + str(sequence)
                # Each finite cycle waits for its motors; the same reader handles radio button events.
                send(sock, {"type": "command", "request_id": request_id, "cancelable": True,
                            "sequence": [{"choreography": choreography}]})
                finish_ears(sock, stream, request_id,
                            min(deadline + THINK_CYCLE_TIMEOUT, time.monotonic() + duration + THINK_CYCLE_TIMEOUT),
                            on_event=on_event)
                sequence += 1
                if waiting:
                    stop.wait(3)
        except Exception as error:
            errors.append(error)
            stop.set()

    worker = threading.Thread(target=animate, name="nabaztag-stream-effects", daemon=True)
    worker.start()
    failure = None
    try:
        yield errors
    except BaseException as error:
        failure = error
        raise
    finally:
        stop.set()
        worker.join(timeout=THINK_CYCLE_TIMEOUT + 2)
        cleanup_error = None
        if worker.is_alive():
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
            worker.join(timeout=1)
            cleanup_error = TimeoutError("Fin des effets du flux audio trop longue")
        if worker.is_alive():
            cleanup_error = RuntimeError("Le thread d’effets n’a pas pu se terminer")
        cleanup_error = cleanup_error or (errors[0] if errors else None)
        if cleanup_error is not None:
            if failure is None:
                raise cleanup_error
            if cleanup_error is not failure:
                print("Arrêt du flux : " + str(cleanup_error), file=sys.stderr)


def play(data, animate=False, options=None):
    duration = validate_wav(data)
    options = (options or DEFAULT_EFFECTS) if animate else ("off", "off", "002838")
    with reserve() as (sock, stream), tempfile.TemporaryDirectory(prefix="nabaztag-mac-") as directory:
        filename = Path(directory) / "reply.wav"
        filename.write_bytes(data)
        with response_effects(sock, stream, options):
            run_audio(["aplay", "-q", "-D", PLAYBACK_DEVICE, str(filename)], timeout=duration + 5)


def stream_play(input_stream, options=DEFAULT_EFFECTS, queued=False, thinking=None):
    wall_timeout = STREAM_WALL_TIMEOUT + (FIRST_AUDIO_TIMEOUT if thinking is not None else 0)
    deadline = time.monotonic() + wall_timeout
    with reserve() as (sock, stream), tempfile.TemporaryFile() as errors, contextlib.ExitStack() as effects:
        player = subprocess.Popen(
            ["aplay", "-q", "-D", PLAYBACK_DEVICE, "-t", "raw", "-f", "S16_LE", "-r", "24000", "-c", "1"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errors, bufsize=0, env=playback_environment(),
        )
        animation_errors, effects_started = [], False
        audio_started = threading.Event()
        failed = False

        def check_player():
            if player.poll() is not None:
                errors.seek(0)
                detail = errors.read(8192).decode("utf-8", "replace").strip()
                raise ValueError("aplay : " + (detail or "lecture terminée avant la fin du flux"))
            if animation_errors:
                raise animation_errors[0]
            if time.monotonic() >= deadline:
                raise TimeoutError("Le flux audio a dépassé %g secondes" % wall_timeout)

        try:
            output_fd = player.stdin.fileno()
            os.set_blocking(output_fd, False)
            input_fd = input_stream.fileno()
            print("ready", flush=True)
            if thinking is not None:
                animation_errors = effects.enter_context(response_effects(
                    sock, stream, options, deadline, thinking=thinking, audio_started=audio_started))
                effects_started = True
            total, segment_count, pending, segments = 0, 0, bytearray(), deque()
            expected = None
            input_done, playing = False, not queued
            packet_deadline = time.monotonic() + (FIRST_AUDIO_TIMEOUT if thinking is not None else STREAM_PACKET_TIMEOUT)
            write_deadline = packet_deadline
            while not input_done or segments:
                check_player()
                now = time.monotonic()
                if not input_done and now >= packet_deadline:
                    interval = FIRST_AUDIO_TIMEOUT if thinking is not None and not audio_started.is_set() else STREAM_PACKET_TIMEOUT
                    raise TimeoutError("Aucun paquet PCM reçu pendant %g secondes" % interval)
                if playing and segments and now >= write_deadline:
                    raise TimeoutError("Le lecteur PCM ne consomme plus le flux")
                remaining = min(deadline, packet_deadline if not input_done else deadline,
                                write_deadline if playing and segments else deadline) - now
                if remaining <= 0:
                    raise TimeoutError("Le flux audio a dépassé %g secondes" % wall_timeout)
                had_output = playing and bool(segments)
                readable, writable, _ = select.select(
                    [] if input_done else [input_fd], [output_fd] if playing and segments else [], [],
                    min(1, remaining))
                if readable:
                    data = os.read(input_fd, 16384)
                    packet_deadline = time.monotonic() + (FIRST_AUDIO_TIMEOUT if thinking is not None and
                                                          not audio_started.is_set() else STREAM_PACKET_TIMEOUT)
                    if not data:
                        input_done = True
                        if total == 0:
                            raise ValueError("Le flux PCM est vide")
                        if pending or expected is not None:
                            raise ValueError("Segment PCM tronqué" if queued else "Le flux PCM contient une demi-trame de 16 bits")
                    else:
                        pending.extend(data)
                        if queued:
                            while True:
                                if expected is None:
                                    if len(pending) < 4:
                                        break
                                    expected = struct.unpack("!I", pending[:4])[0]
                                    del pending[:4]
                                    if not expected or expected % 2:
                                        raise ValueError("Taille de segment PCM invalide")
                                    segment_count += 1
                                    if segment_count > MAX_STREAM_SEGMENTS:
                                        raise ValueError("Trop de segments PCM")
                                    total += expected
                                    if total > MAX_STREAM_AUDIO:
                                        raise ValueError("Le flux PCM dépasse 90 secondes (4 320 000 octets)")
                                if len(pending) < expected:
                                    break
                                segments.append(memoryview(bytes(pending[:expected])))
                                del pending[:expected]
                                expected = None
                        else:
                            total += len(data)
                            if total > MAX_STREAM_AUDIO:
                                raise ValueError("Le flux PCM dépasse 90 secondes (4 320 000 octets)")
                            even = len(pending) - len(pending) % 2
                            if even:
                                segments.append(memoryview(bytes(pending[:even])))
                                del pending[:even]
                    if not playing and (segments or input_done):
                        playing = True
                    if not had_output and playing and segments:
                        write_deadline = time.monotonic() + STREAM_PACKET_TIMEOUT
                if writable:
                    try:
                        written = os.write(output_fd, segments[0])
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        player.wait(timeout=5)
                        check_player()
                        raise
                    if written == 0:
                        raise ValueError("Écriture PCM interrompue")
                    segments[0] = segments[0][written:]
                    if not segments[0]:
                        segments.popleft()
                    write_deadline = time.monotonic() + STREAM_PACKET_TIMEOUT
                    if not audio_started.is_set():
                        audio_started.set()
                        packet_deadline = time.monotonic() + STREAM_PACKET_TIMEOUT
                    if not effects_started:
                        animation_errors = effects.enter_context(response_effects(sock, stream, options, deadline))
                        effects_started = True
            player.stdin.close()
            player.stdin = None
            result = player.wait(timeout=max(0.01, min(total / 48000 + 5, deadline - time.monotonic())))
            if result:
                errors.seek(0)
                raise ValueError("aplay : " + errors.read(8192).decode("utf-8", "replace").strip())
        except BaseException:
            failed = True
            raise
        finally:
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
            if cleanup_error is not None:
                if not failed:
                    raise cleanup_error
                print("Arrêt du flux : " + str(cleanup_error), file=sys.stderr)


def diagnostic():
    result = {"bridge_version": 1, "uname": platform.uname()._asdict(), "commands": {}}
    missing_radio = [command for command in ("curl", "mpg123") if not shutil.which(command)]
    result["radio"] = {"available": not missing_radio, "missing_commands": missing_radio}
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
        elif action == "volume":
            print(json.dumps({"volume": volume(argument)}))
        elif action in ("record", "record-until-stop"):
            record(argument)
        elif action == "think":
            think(argument)
        elif action == "radio":
            radio(*argument)
        elif action == "watch-button":
            watch_button()
        elif action in ("play-stream", "play-queue"):
            options, thinking = argument[:3], argument[3] if len(argument) == 4 else None
            if action == "play-queue":
                stream_play(sys.stdin.buffer, options=options, queued=True, thinking=thinking)
            else:
                stream_play(sys.stdin.buffer, options=options, thinking=thinking)
        else:
            play(sys.stdin.buffer.read(MAX_AUDIO + 1), animate=action == "play-animated", options=argument)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, wave.Error, EOFError) as error:
        print("Nabaztag : " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    def interrupt(signum, frame):
        raise InterruptedError("Commande interrompue")

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    sys.exit(main())
