import base64
import io
import json
import os
import signal
import struct
import sys
import tempfile
import threading
import time
import unittest
import wave
from pathlib import Path
from unittest import mock

import bridge_remote as bridge


def wav_data(channels=1, width=2, rate=16000, frames=160):
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setparams((channels, width, rate, 0, "NONE", "not compressed"))
        audio.writeframes(b"\0" * channels * width * frames)
    return output.getvalue()


def decoded_choreography(resource):
    data = base64.b64decode(resource.split(",", 1)[1], validate=True)
    sizes = {0: 0, 1: 1, 7: 6, 8: 3, 17: 2, 19: 0, 20: 2}
    index, elapsed, frame_ms, events = 0, 0, 0, []
    while index < len(data):
        delay, opcode = data[index:index + 2]
        index += 2
        elapsed += delay * frame_ms / 1000
        assert opcode in sizes, "No MIDI or loop"
        operands = tuple(data[index:index + sizes[opcode]])
        assert len(operands) == sizes[opcode]
        index += sizes[opcode]
        events.append((elapsed, opcode, operands))
        if opcode == 1:
            frame_ms = operands[0] * 10
    return events, elapsed


class RemoteBridgeTests(unittest.TestCase):
    @bridge.contextlib.contextmanager
    def stream_fixture(self, data=None, early_failure=False, stalled=False):
        real_popen = bridge.subprocess.Popen
        players = []
        connection = mock.Mock()
        ready = threading.Event()

        class Output(io.StringIO):
            def write(self, text):
                result = super().write(text)
                if self.getvalue() == "ready\n":
                    ready.set()
                return result

        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "first-pcm"
            script = """import os, sys, time
from pathlib import Path
if sys.argv[2] == 'fail':
    sys.stderr.write('mock ALSA failure')
    sys.exit(7)
if sys.argv[2] == 'stall':
    time.sleep(10)
data = os.read(0, 2)
if data:
    Path(sys.argv[1]).write_bytes(data)
with Path(sys.argv[1] + '.pcm').open('wb') as output:
    output.write(data)
    while True:
        data = os.read(0, 16384)
        if not data:
            break
        output.write(data)
        output.flush()
"""

            def popen(arguments, **kwargs):
                self.assertEqual(arguments, ["aplay", "-q", "-D", bridge.DEVICE, "-t", "raw", "-f",
                                             "S16_LE", "-r", "24000", "-c", "1"])
                player = real_popen([sys.executable, "-c", script, str(marker),
                                     "fail" if early_failure else "stall" if stalled else "ok"], **kwargs)
                players.append(player)
                return player

            read_fd, write_fd = os.pipe()
            with os.fdopen(read_fd, "rb", buffering=0) as source, os.fdopen(write_fd, "wb", buffering=0) as writer:
                if data is not None:
                    writer.write(data)
                    writer.close()
                output = Output()
                with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((connection, io.BytesIO()))), \
                     mock.patch.object(bridge.subprocess, "Popen", side_effect=popen), \
                     mock.patch.object(bridge.sys, "stdout", output):
                    try:
                        yield source, writer, marker, ready, output, players, connection
                    finally:
                        writer.close()
                        for player in players:
                            if player.poll() is None:
                                player.kill()
                                player.wait(timeout=3)
                                self.fail("The PCM player must be reaped by stream_play")
                        self.assertFalse(any(thread.name == "nabaztag-stream-effects" and thread.is_alive()
                                             for thread in threading.enumerate()))

    def test_command_allowlist(self):
        self.assertEqual(bridge.parse_action("diagnostic"), ("diagnostic", None))
        self.assertEqual(bridge.parse_action("play"), ("play", None))
        self.assertEqual(bridge.parse_action("play-animated"), ("play-animated", None))
        self.assertEqual(bridge.parse_action("watch-button"), ("watch-button", None))
        self.assertEqual(bridge.parse_action("record 15"), ("record", 15))
        self.assertEqual(bridge.parse_action("record-until-stop"), ("record-until-stop", None))
        self.assertEqual(bridge.parse_action("think forward"), ("think", "forward"))
        self.assertEqual(bridge.parse_action("think backward"), ("think", "backward"))
        for command in ("", "sh", "diagnostic extra", "record", "record 0", "record 16",
                        "record 1; reboot", "play; reboot", "record $(id)", "record '1",
                        "watch-button extra", "watch-button; reboot", "play-animated extra", "play-animated; reboot",
                        "record-until-stop 90", "record-until-stop; reboot", "think", "think sideways",
                        "think forward extra", "think forward; reboot", "think $(id)"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                bridge.parse_action(command)

    def test_effect_options_allowlist(self):
        for ears in ("off", "on", "small", "large"):
            for lights in ("off", "fixed", "random"):
                options = (ears, lights, "12AbEF")
                command = "play-animated " + " ".join(options)
                self.assertEqual(bridge.parse_action(command), ("play-animated", options))
                self.assertEqual(bridge.parse_action(command.replace("play-animated", "play-stream")),
                                 ("play-stream", options))
                self.assertEqual(bridge.parse_action(command.replace("play-animated", "play-queue")),
                                 ("play-queue", options))
                self.assertEqual(bridge.parse_action(
                    "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py " + command),
                    ("play-animated", options))
        for command in (
            "play-animated small fixed", "play-animated small fixed 002838 extra",
            "play-animated medium fixed 002838", "play-animated small blink 002838",
            "play-animated small fixed #002838", "play-animated small fixed 00283",
            "play-animated small fixed 00283800", "play-animated small fixed 00283G",
            "play-animated small fixed ００２８３８", "play-animated small fixed '002838;id'",
            "play-animated small fixed 002838; reboot", "play-animated $(id) fixed 002838",
            "play-animated small fixed 002838\nreboot", "play-animated small fixed 002838 | sh",
        ):
            with self.subTest(command=command), self.assertRaises(ValueError):
                bridge.parse_action(command)
            with self.subTest(stream_command=command), self.assertRaises(ValueError):
                bridge.parse_action(command.replace("play-animated", "play-stream"))
            with self.subTest(queue_command=command), self.assertRaises(ValueError):
                bridge.parse_action(command.replace("play-animated", "play-queue"))
        self.assertRaises(ValueError, bridge.parse_action, "play-stream")
        self.assertRaises(ValueError, bridge.parse_action, "play-queue")

    def test_main_routes_stream_without_reading_whole_input(self):
        source = mock.Mock()
        with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": "play-stream large random 123456"}, clear=True), \
             mock.patch.object(bridge.sys, "stdin", mock.Mock(buffer=source)), \
             mock.patch.object(bridge, "stream_play") as stream:
            self.assertEqual(bridge.main(), 0)
        stream.assert_called_once_with(source, options=("large", "random", "123456"))
        source.read.assert_not_called()

        with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": "play-queue large random 123456"}, clear=True), \
             mock.patch.object(bridge.sys, "stdin", mock.Mock(buffer=source)), \
             mock.patch.object(bridge, "stream_play") as stream:
            self.assertEqual(bridge.main(), 0)
        stream.assert_called_once_with(source, options=("large", "random", "123456"), queued=True)
        source.read.assert_not_called()

    def test_exact_remote_prefix_is_allowed(self):
        prefix = "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py "
        for command in ("diagnostic", "play", "play-animated", "play-stream small fixed 002838", "play-queue small fixed 002838", "watch-button", "record 6", "record-until-stop", "think forward", "think backward"):
            with self.subTest(command=command):
                self.assertEqual(bridge.parse_action(prefix + command), bridge.parse_action(command))
        for command in (
            "/usr/bin/python /usr/local/lib/nabaztag-mac/bridge_remote.py record 6",
            "/usr/bin/python3 /tmp/bridge_remote.py record 6",
            "python3 /usr/local/lib/nabaztag-mac/bridge_remote.py record 6",
            prefix, prefix + "record 6; reboot", prefix + "play && reboot",
            prefix + "diagnostic | sh", prefix + "record $(id)",
            prefix + "diagnostic\nreboot", prefix + "watch-button > /tmp/events",
        ):
            with self.subTest(command=command), self.assertRaises(ValueError):
                bridge.parse_action(command)

    def test_main_accepts_normal_script_invocation(self):
        with mock.patch.dict(bridge.os.environ, {}, clear=True), \
             mock.patch.object(bridge.sys, "argv", ["bridge_remote.py", "record", "6"]), \
             mock.patch.object(bridge, "record") as record:
            self.assertEqual(bridge.main(), 0)
        record.assert_called_once_with(6)

    def test_main_routes_controlled_capture_and_thinking(self):
        for command, action, argument in (("record-until-stop", "record", None),
                                          ("think forward", "think", "forward"),
                                          ("think backward", "think", "backward")):
            with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": command}, clear=True), \
                 mock.patch.object(bridge, action) as routed:
                self.assertEqual(bridge.main(), 0)
            routed.assert_called_once_with(argument)

    def test_main_prefers_forced_ssh_command(self):
        command = "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py watch-button"
        with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": command}, clear=True), \
             mock.patch.object(bridge.sys, "argv", ["bridge_remote.py", "record", "6"]), \
             mock.patch.object(bridge, "watch_button") as watch:
            self.assertEqual(bridge.main(), 0)
        watch.assert_called_once_with()

    def test_empty_forced_command_does_not_fall_back_to_argv(self):
        with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": ""}, clear=True), \
             mock.patch.object(bridge.sys, "argv", ["bridge_remote.py", "record", "6"]), \
             mock.patch.object(bridge.sys, "stderr", io.StringIO()), \
             mock.patch.object(bridge, "record") as record:
            self.assertEqual(bridge.main(), 1)
        record.assert_not_called()

    def test_main_routes_plain_and_animated_playback(self):
        for action, animated, options in (("play", False, None), ("play-animated", True, None),
                                         ("play-animated large random ff8000", True, ("large", "random", "ff8000"))):
            stdin = mock.Mock(buffer=io.BytesIO(b"audio"))
            with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": action}, clear=True), \
                 mock.patch.object(bridge.sys, "stdin", stdin), \
                 mock.patch.object(bridge, "play") as play:
                self.assertEqual(bridge.main(), 0)
            play.assert_called_once_with(b"audio", animate=animated, options=options)

    def test_wav_validation(self):
        self.assertEqual(bridge.validate_wav(wav_data()), 0.01)
        self.assertEqual(bridge.validate_wav(wav_data(channels=2, rate=48000)), 160 / 48000)
        for data in (b"garbage", wav_data()[:-1], wav_data(width=1), wav_data(rate=8000),
                     wav_data(channels=3), wav_data(frames=0), b"x" * (bridge.MAX_AUDIO + 1)):
            with self.subTest(length=len(data)), self.assertRaises((ValueError, wave.Error, EOFError)):
                bridge.validate_wav(data)
        self.assertRaises(ValueError, bridge.validate_wav, wav_data(frames=90 * 16000 + 1))

    def fake_connection(self, packets):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.makefile.return_value = io.BytesIO(
            b"".join(json.dumps(packet).encode() + b"\r\n" for packet in packets)
        )
        return connection

    def test_reservation_waits_for_acknowledgement_and_state(self):
        connection = self.fake_connection([
            {"type": "state", "state": "playing"},
            {"type": "state", "state": "idle"},
            {"type": "response", "status": "ok", "request_id": "mac-bridge-mode"},
            {"type": "state", "state": "interactive"},
        ])
        with mock.patch.object(bridge.socket, "create_connection", return_value=connection):
            with bridge.reserve():
                pass
        packet = json.loads(connection.sendall.call_args.args[0])
        self.assertEqual(packet["mode"], "interactive")
        self.assertEqual(packet["events"], ["button"])
        connection.__exit__.assert_called_once()

    def test_reservation_refuses_sleep_and_other_owner(self):
        for state in ("asleep", "interactive"):
            connection = self.fake_connection([{"type": "state", "state": state}])
            with mock.patch.object(bridge.socket, "create_connection", return_value=connection):
                with self.subTest(state=state), self.assertRaises(ValueError):
                    with bridge.reserve():
                        self.fail("The reservation must be refused")
            connection.sendall.assert_not_called()
            connection.__exit__.assert_called_once()

    def test_reservation_releases_after_capture_failure(self):
        connection = self.fake_connection([
            {"type": "state", "state": "idle"},
            {"type": "state", "state": "interactive"},
            {"type": "response", "status": "ok", "request_id": "mac-bridge-mode"},
        ])
        with mock.patch.object(bridge.socket, "create_connection", return_value=connection):
            with self.assertRaises(RuntimeError):
                with bridge.reserve():
                    raise RuntimeError("capture failed")
        connection.__exit__.assert_called_once()

    def test_audio_errors_are_reported(self):
        result = mock.Mock(returncode=1, stderr=b"Device busy")
        with mock.patch.object(bridge.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "Device busy"):
                bridge.run_audio(["arecord"], timeout=5)

    def test_response_choreography_is_finite_and_keeps_effects_independent(self):
        for duration in (0.01, 6, 37, 90):
            for ears in ("off", "on", "small", "large"):
                for lights in ("off", "fixed", "random"):
                    with self.subTest(duration=duration, ears=ears, lights=lights):
                        resource, motion_duration = bridge.response_choreography(duration, (ears, lights, "002838"))
                        if ears == lights == "off":
                            self.assertIsNone(resource)
                            self.assertEqual(motion_duration, 0)
                            continue
                        events, elapsed = decoded_choreography(resource)
                        ear_events, led_events = [], []
                        for timestamp, opcode, operands in events:
                            if opcode == 7:
                                self.assertNotEqual(lights, "off")
                                led, red, green, blue, reserved1, reserved2 = operands
                                self.assertIn(led, (1, 2, 3))
                                self.assertEqual((reserved1, reserved2), (0, 0))
                                self.assertLessEqual(max(red, green, blue), 64)
                                if lights == "fixed":
                                    self.assertEqual((timestamp, red, green, blue), (0, 0, 40, 56))
                                led_events.append((timestamp, led, (red, green, blue)))
                            elif opcode == 8:
                                motor, position, direction = operands
                                self.assertNotEqual(ears, "off")
                                self.assertIn(motor, (0, 1))
                                self.assertIn(position, (0, 5, 10, 14))
                                self.assertEqual(direction, 0)
                                ear_events.append((timestamp, operands))
                            else:
                                self.assertIn(opcode, (0, 1))
                        if ears == "off":
                            self.assertEqual(ear_events, [])
                        else:
                            initial = ear_events[:2]
                            self.assertEqual([time for time, _ in initial], [0, 0])
                            self.assertEqual([values[0] for _, values in initial], [0, 1])
                            self.assertIn(tuple(values[1] for _, values in initial), ((0, 10), (10, 0)))
                            self.assertTrue(all(time >= 21.6 for time, _ in ear_events[2:]))
                        self.assertEqual(bool(led_events), lights != "off")
                        self.assertAlmostEqual(elapsed, motion_duration)
                        self.assertGreaterEqual(motion_duration, duration)
                        self.assertLessEqual(motion_duration, 90)

    def test_legacy_ear_modes_are_aliases_of_native_motion(self):
        for ears in ("on", "small", "large"):
            with mock.patch.object(bridge.random, "choice", side_effect=lambda values: values[0]), \
                 mock.patch.object(bridge.random, "randint", side_effect=lambda low, high: low):
                self.assertEqual(bridge.response_choreography(6),
                                 bridge.response_choreography(6, (ears, "fixed", "002838")))

    def test_native_ear_timing_probability_and_positions_survive_stream_cycles(self):
        state, ear_events = {}, []
        # Minimum native interval: 45 ticks * 160 ms * 3 loops = 21.6 seconds.
        choices = [(10, 0), 45, 5, 14, 45, 45, 0, 10, 45, 14, 5, 45]
        draws = [160, 3, 0, 160, 3, 1, 160, 3, 0, 160, 3, 0, 160, 3]
        with mock.patch.object(bridge.random, "choice", side_effect=choices), \
             mock.patch.object(bridge.random, "randint", side_effect=draws) as randint:
            for cycle in range(75):
                resource, duration = bridge.response_choreography(1.2, ("on", "off", "002838"), state)
                events, _ = decoded_choreography(resource)
                ear_events.extend((round(cycle * 1.2 + timestamp, 2), values)
                                  for timestamp, opcode, values in events if opcode == 8)
                self.assertEqual(duration, 1.2)
        self.assertEqual(ear_events, [
            (0, (0, 10, 0)), (0, (1, 0, 0)),
            (21.6, (0, 5, 0)), (21.6, (1, 14, 0)),
            (64.8, (0, 0, 0)), (64.8, (1, 10, 0)),
            (86.4, (0, 14, 0)), (86.4, (1, 5, 0)),
        ])
        self.assertEqual(randint.call_args_list, [
            mock.call(160, 250), mock.call(3, 20),
            mock.call(0, 0), mock.call(160, 250), mock.call(3, 20),
            mock.call(0, 1), mock.call(160, 250), mock.call(3, 20),
            mock.call(0, 1), mock.call(160, 250), mock.call(3, 20),
            mock.call(0, 2), mock.call(160, 250), mock.call(3, 20),
        ])

    def test_native_ears_hold_initial_pose_for_longest_interval(self):
        with mock.patch.object(bridge.random, "choice", side_effect=[(0, 10), 72]), \
             mock.patch.object(bridge.random, "randint", side_effect=[250, 20]):
            resource, _ = bridge.response_choreography(90, ("on", "off", "002838"))
        events, _ = decoded_choreography(resource)
        self.assertEqual([(timestamp, values) for timestamp, opcode, values in events if opcode == 8],
                         [(0, (0, 0, 0)), (0, (1, 10, 0))])

    def test_stream_delivers_first_pcm_before_eof_and_ready_precedes_input(self):
        failures = []
        with self.stream_fixture() as (source, writer, marker, ready, output, players, connection):
            def run():
                try:
                    bridge.stream_play(source, ("off", "off", "002838"))
                except BaseException as error:
                    failures.append(error)

            thread = threading.Thread(target=run)
            thread.start()
            try:
                self.assertTrue(ready.wait(2), "ACK must arrive before audio or EOF")
                self.assertFalse(marker.exists())
                writer.write(b"\x01")
                time.sleep(0.03)
                self.assertFalse(marker.exists(), "An odd packet must wait for its second sample byte")
                writer.write(b"\x02\x03\x04")
                until = time.monotonic() + 2
                while not marker.exists() and time.monotonic() < until:
                    time.sleep(0.01)
                self.assertEqual(marker.read_bytes(), b"\x01\x02")
                self.assertTrue(thread.is_alive(), "Playback must consume PCM while input is still open")
            finally:
                writer.close()
                thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(output.getvalue(), "ready\n")
            self.assertEqual(players[0].returncode, 0)
            connection.sendall.assert_not_called()

    def test_stream_rejects_empty_odd_oversized_and_stalled_input(self):
        for data, pattern in ((b"", "vide"), (b"\0", "demi-trame"), (b"\0" * 6, "90 secondes")):
            with self.subTest(data=data), self.stream_fixture(data) as fixture, \
                 mock.patch.object(bridge, "MAX_STREAM_AUDIO", 4):
                with self.assertRaisesRegex(ValueError, pattern):
                    bridge.stream_play(fixture[0], ("off", "off", "002838"))

    def test_queue_buffers_complete_segments_then_drains_all_pcm_in_order(self):
        failures = []
        first, second, third = b"\x01\x02\x03\x04", b"\x05\x06", b"\x07\x08\x09\x0a"
        with self.stream_fixture() as (source, writer, marker, ready, _, players, connection):
            def run():
                try:
                    bridge.stream_play(source, ("off", "off", "002838"), queued=True)
                except BaseException as error:
                    failures.append(error)

            thread = threading.Thread(target=run)
            thread.start()
            try:
                self.assertTrue(ready.wait(2))
                header = struct.pack("!I", len(first))
                writer.write(header[:2])
                time.sleep(0.03)
                self.assertFalse(marker.exists(), "A fragmented header cannot start playback")
                writer.write(header[2:] + first + struct.pack("!I", len(second)) + second[:1])
                time.sleep(0.03)
                self.assertFalse(marker.exists(), "Preroll requires two complete audio segments")
                writer.write(second[1:])
                until = time.monotonic() + 2
                while not marker.exists() and time.monotonic() < until:
                    time.sleep(0.01)
                self.assertEqual(marker.read_bytes(), first[:2])
                self.assertTrue(thread.is_alive(), "Queued playback must start before EOF")
                writer.write(struct.pack("!I", len(third)) + third)
                received = Path(str(marker) + ".pcm")
                until = time.monotonic() + 2
                while (not received.exists() or received.stat().st_size < len(first + second + third)) and time.monotonic() < until:
                    time.sleep(0.01)
                self.assertEqual(received.read_bytes(), first + second + third,
                                 "After preroll, one complete segment must play without waiting for another or EOF")
            finally:
                writer.close()
                thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(Path(str(marker) + ".pcm").read_bytes(), first + second + third)
            self.assertEqual(players[0].returncode, 0)
            self.assertEqual(len(players), 1, "Keep one PCM player across all segments")
            connection.sendall.assert_not_called()

    def test_queue_releases_single_segment_at_eof_and_rejects_invalid_frames(self):
        pcm = b"\x01\x02\x03\x04"
        with self.stream_fixture(struct.pack("!I", len(pcm)) + pcm) as fixture:
            bridge.stream_play(fixture[0], ("off", "off", "002838"), queued=True)
            self.assertEqual(Path(str(fixture[2]) + ".pcm").read_bytes(), pcm)
        with self.stream_fixture((struct.pack("!I", 2) + pcm[:2]) * 3) as fixture, \
             mock.patch.object(bridge, "MAX_STREAM_SEGMENTS", 2):
            with self.assertRaisesRegex(ValueError, "Trop de segments"):
                bridge.stream_play(fixture[0], ("off", "off", "002838"), queued=True)
        for data, pattern in (
                (b"", "vide"), (b"\0\0", "vide|tronqué"), (struct.pack("!I", 0), "invalide"),
                (struct.pack("!I", 3), "invalide"), (struct.pack("!I", 6), "90 secondes"),
                (struct.pack("!I", 4) + pcm[:2], "tronqué"),
                (struct.pack("!I", 2) + pcm[:2] + b"\0", "tronqué"),
                (struct.pack("!I", 4) + pcm + struct.pack("!I", 2), "90 secondes")):
            with self.subTest(data=data), self.stream_fixture(data) as fixture, \
                 mock.patch.object(bridge, "MAX_STREAM_AUDIO", 4):
                with self.assertRaisesRegex(ValueError, pattern):
                    bridge.stream_play(fixture[0], ("off", "off", "002838"), queued=True)

    def test_queue_times_out_if_pcm_player_stops_consuming(self):
        pcm = b"\0" * (256 * 1024)
        failures = []
        with self.stream_fixture(stalled=True) as fixture, \
             mock.patch.object(bridge, "STREAM_PACKET_TIMEOUT", 0.2):
            source, writer, _, ready, _, players, _ = fixture

            def feed():
                try:
                    if not ready.wait(2):
                        raise TimeoutError("No ready ACK")
                    writer.write(struct.pack("!I", len(pcm)) + pcm + struct.pack("!I", 2) + b"\0\0")
                except BaseException as error:
                    failures.append(error)
                finally:
                    writer.close()

            producer = threading.Thread(target=feed)
            producer.start()
            try:
                with self.assertRaisesRegex(TimeoutError, "ne consomme plus"):
                    bridge.stream_play(source, ("off", "off", "002838"), queued=True)
            finally:
                producer.join(timeout=3)
            self.assertFalse(producer.is_alive())
            self.assertEqual(failures, [])
            self.assertIsNotNone(players[0].returncode)
        for wall, packet in ((1, 0.03), (0.03, 1)):
            with self.subTest(wall=wall, packet=packet), self.stream_fixture() as fixture, \
                 mock.patch.object(bridge, "STREAM_WALL_TIMEOUT", wall), \
                 mock.patch.object(bridge, "STREAM_PACKET_TIMEOUT", packet):
                with self.assertRaises(TimeoutError):
                    bridge.stream_play(fixture[0], ("off", "off", "002838"))

    def test_stream_preserves_audio_and_animation_failures(self):
        with self.stream_fixture(b"\0" * 4, early_failure=True) as fixture:
            with self.assertRaisesRegex(ValueError, "mock ALSA failure"):
                bridge.stream_play(fixture[0], ("off", "off", "002838"))
        with self.stream_fixture(b"\0" * 4) as fixture, \
             mock.patch.object(bridge, "finish_ears", side_effect=ValueError("nabd failed")):
            with self.assertRaisesRegex(ValueError, "nabd failed"):
                bridge.stream_play(fixture[0], ("small", "off", "002838"))

    def test_stream_cleanup_shutdown_failure_keeps_original_audio_error(self):
        worker = mock.Mock()
        worker.is_alive.side_effect = [True, False]
        with self.stream_fixture(b"\0" * 4, early_failure=True) as fixture, \
             mock.patch.object(bridge.threading, "Thread", return_value=worker), \
             mock.patch.object(bridge.sys, "stderr", io.StringIO()) as stderr:
            fixture[-1].shutdown.side_effect = OSError("socket already disconnected")
            with self.assertRaisesRegex(ValueError, "mock ALSA failure"):
                bridge.stream_play(fixture[0], ("small", "off", "002838"))
        self.assertIn("Fin des effets", stderr.getvalue())
        worker.start.assert_called_once()
        self.assertEqual(worker.join.call_args_list, [mock.call(timeout=8), mock.call(timeout=1)])

    def test_stream_stops_after_current_natural_effect_cycle(self):
        failures, commands, completed = [], [], []
        two_cycles = threading.Event()
        with self.stream_fixture() as (source, writer, _, ready, _, _, connection):
            def send(data):
                packet = json.loads(data)
                self.assertEqual(packet["type"], "command")
                if commands:
                    self.assertIn(commands[-1]["request_id"], completed)
                commands.append(packet)
                if len(commands) == 2:
                    two_cycles.set()

            def finish(sock, stream, request_id, deadline):
                time.sleep(0.02)
                completed.append(request_id)

            def run():
                try:
                    bridge.stream_play(source, ("small", "off", "002838"))
                except BaseException as error:
                    failures.append(error)

            connection.sendall.side_effect = send
            with mock.patch.object(bridge, "finish_ears", side_effect=finish):
                thread = threading.Thread(target=run)
                thread.start()
                try:
                    self.assertTrue(ready.wait(2))
                    connection.sendall.assert_not_called()
                    writer.write(b"\0" * 4)
                    self.assertTrue(two_cycles.wait(2))
                finally:
                    writer.close()
                    thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(len(commands), len(completed))
            ear_commands = []
            for command in commands[:2]:
                events, _ = decoded_choreography(command["sequence"][0]["choreography"])
                ear_commands.append([values for _, opcode, values in events if opcode == 8])
            self.assertEqual(len(ear_commands[0]), 2)
            self.assertEqual(ear_commands[1], [])

    def test_fixed_colors_preserve_low_values_and_attenuate_high_values(self):
        for color, expected in (("002838", (0, 40, 56)), ("120a08", (18, 10, 8)),
                                ("ff8000", (64, 32, 0)), ("804020", (64, 32, 16)),
                                ("ffffff", (64, 64, 64)), ("000000", (0, 0, 0))):
            resource, _ = bridge.response_choreography(3, ("off", "fixed", color))
            events, _ = decoded_choreography(resource)
            colors = [(timestamp, values[0], values[1:4]) for timestamp, opcode, values in events if opcode == 7]
            self.assertEqual(colors, [(0, led, expected) for led in (1, 2, 3)])

    def test_random_lights_use_distinct_soft_colors_and_refresh_slowly(self):
        first, second = list(bridge.LIGHT_PALETTE[:3]), list(bridge.LIGHT_PALETTE[3:])
        with mock.patch.object(bridge.random, "sample", side_effect=[first, second, first]) as sample:
            resource, _ = bridge.response_choreography(3, ("off", "random", "002838"))
        self.assertEqual(sample.call_count, 3)
        events, _ = decoded_choreography(resource)
        groups = {}
        for timestamp, opcode, values in events:
            if opcode == 7:
                groups.setdefault(round(timestamp, 3), []).append(values[1:4])
        self.assertEqual(groups, {0: first, 1.2: second, 2.4: first})
        for colors in groups.values():
            self.assertEqual(len(set(colors)), 3)
            self.assertTrue(all(max(color) <= 64 for color in colors))

    def test_play_waits_for_ear_completion_on_success_and_audio_failure(self):
        for failure in (None, ValueError("aplay failed")):
            trace, packets = [], []
            terminal = {"type": "response", "request_id": "mac-bridge-ears", "status": "canceled" if failure else "ok"}
            data = json.dumps(terminal).encode() + b"\n"
            stream = io.BytesIO(data)
            connection = mock.Mock()

            def send(packet):
                packet = json.loads(packet)
                packets.append(packet)
                trace.append(packet["type"])

            @bridge.contextlib.contextmanager
            def reservation():
                try:
                    yield connection, stream
                finally:
                    self.assertEqual(stream.tell(), len(data), "Wait for the original terminal response")
                    trace.append("released")

            def audio(*args, **kwargs):
                trace.append("aplay")
                if failure:
                    raise failure

            connection.sendall.side_effect = send
            with mock.patch.object(bridge, "reserve", reservation), \
                 mock.patch.object(bridge, "run_audio", side_effect=audio):
                if failure:
                    with self.assertRaisesRegex(ValueError, "aplay failed"):
                        bridge.play(wav_data(), animate=True, options=("large", "off", "002838"))
                else:
                    bridge.play(wav_data(), animate=True, options=("large", "off", "002838"))
            self.assertEqual(trace, ["command", "aplay"] + (["cancel"] if failure else []) + ["released"])
            self.assertEqual(len(packets), 2 if failure else 1)
            if failure:
                self.assertEqual(packets[0]["request_id"], packets[1]["request_id"])
            self.assertEqual(set(packets[0]["sequence"][0]), {"choreography"})

    def test_plain_playback_sends_no_choreography(self):
        for animated, options in ((False, None), (True, ("off", "off", "002838"))):
            connection = mock.Mock()
            with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((connection, io.BytesIO()))), \
                 mock.patch.object(bridge, "run_audio") as audio, \
                 mock.patch.object(bridge, "finish_ears") as cleanup:
                bridge.play(wav_data(), animate=animated, options=options)
            audio.assert_called_once()
            connection.sendall.assert_not_called()
            cleanup.assert_not_called()

    def test_ear_cancel_retries_when_perform_has_not_started(self):
        packets = [
            {"type": "response", "request_id": "mac-bridge-ears", "status": "error", "class": "NotPlaying"},
            {"type": "button_event", "event": "click"},
            {"type": "response", "request_id": "mac-bridge-ears", "status": "canceled"},
        ]
        connection = self.fake_connection(packets)
        stream = connection.makefile.return_value
        with mock.patch.object(bridge.time, "sleep") as sleep:
            bridge.finish_ears(connection, stream, "mac-bridge-ears", bridge.time.monotonic() + 5, cancel=True)
        self.assertEqual(connection.sendall.call_count, 2)
        sleep.assert_called_once_with(0.05)

    def test_ear_cleanup_errors_do_not_hide_original_audio_error(self):
        connection = mock.Mock()
        failure = ValueError("Original ALSA failure")
        with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((connection, io.BytesIO()))), \
             mock.patch.object(bridge, "run_audio", side_effect=failure), \
             mock.patch.object(bridge, "receive", side_effect=TimeoutError("nabd timeout")), \
             mock.patch.object(bridge.sys, "stderr", io.StringIO()) as stderr:
            with self.assertRaises(ValueError) as raised:
                bridge.play(wav_data(), animate=True)
        self.assertIs(raised.exception, failure)
        self.assertIn("nabd timeout", stderr.getvalue())
        self.assertEqual(json.loads(connection.sendall.call_args.args[0])["type"], "cancel")

    def test_ear_protocol_errors_and_timeouts_are_reported(self):
        connection = mock.Mock()
        with mock.patch.object(bridge, "receive", side_effect=TimeoutError("nabd timeout")):
            with self.assertRaises(TimeoutError):
                bridge.finish_ears(connection, io.BytesIO(), "ears", bridge.time.monotonic() + 5, cancel=True)
        packets = [
            {"type": "response", "request_id": "ears", "status": "error", "class": "NotCancelable"},
            {"type": "response", "request_id": "ears", "status": "ok"},
        ]
        connection = self.fake_connection(packets)
        stream = connection.makefile.return_value
        with self.assertRaisesRegex(ValueError, "NotCancelable"):
            bridge.finish_ears(connection, stream, "ears", bridge.time.monotonic() + 5, cancel=True)
        self.assertEqual(stream.read(), b"", "Even a refused cancel must await natural completion")

    def test_natural_completion_reads_existing_response_without_cancel(self):
        connection = self.fake_connection([
            {"type": "button_event", "event": "click"},
            {"type": "response", "request_id": "ears", "status": "ok"},
        ])
        bridge.finish_ears(connection, connection.makefile.return_value, "ears", bridge.time.monotonic() + 5)
        connection.sendall.assert_not_called()

    def test_natural_completion_reports_timeout_and_protocol_failure(self):
        connection = mock.Mock()
        with self.assertRaises(TimeoutError):
            bridge.finish_ears(connection, io.BytesIO(), "ears", bridge.time.monotonic() - 1)
        connection.sendall.assert_not_called()
        connection = self.fake_connection([
            {"type": "response", "request_id": "ears", "status": "error", "class": "MalformedPacket"},
        ])
        with self.assertRaisesRegex(ValueError, "MalformedPacket"):
            bridge.finish_ears(connection, connection.makefile.return_value, "ears", bridge.time.monotonic() + 5)
        connection.sendall.assert_not_called()

    def test_ready_beep_is_short_and_quiet(self):
        with tempfile.TemporaryDirectory() as directory:
            filename = Path(directory) / "ready.wav"
            bridge.write_beep(filename)
            self.assertEqual(bridge.validate_wav(filename.read_bytes()), 0.1)
            with wave.open(str(filename), "rb") as audio:
                self.assertEqual(audio.getparams()[:4], (1, 2, 16000, 1600))
                samples = struct.unpack("<1600h", audio.readframes(1600))
            self.assertLessEqual(max(abs(value) for value in samples), 1500)
            crossings = sum(before <= 0 < after for before, after in zip(samples, samples[1:]))
            self.assertEqual(crossings, 88)

    def test_thinking_ears_rotate_together_oppositely_and_swap_between_requests(self):
        for direction, expected_directions in (("forward", [0, 1]), ("backward", [1, 0])):
            events, _ = decoded_choreography(bridge.thinking_choreography(direction))
            directions, positions, motors = [None, None], [0, 0], []
            for elapsed, opcode, operands in events:
                self.assertEqual(elapsed, 0, "Both motors start before the shared wait")
                if opcode == 20:
                    motor, value = operands
                    directions[motor] = value
                elif opcode == 17:
                    motor, steps = operands
                    self.assertEqual(steps, 17, "Each motor completes exactly one full turn")
                    positions[motor] = (positions[motor] + (1 if directions[motor] == 0 else -1) * steps) % 17
                    motors.append(motor)
            self.assertEqual(directions, expected_directions)
            self.assertEqual(motors, [0, 1])
            self.assertEqual(positions, [0, 0])
            self.assertEqual(events[-1][1], 19, "Wait for both motors before release; no LED or idle repositioning")

    def test_thinking_finishes_current_turn_before_eof_or_signal_release(self):
        for mode in ("eof", "signal"):
            trace = []
            connection, stdin = mock.Mock(), mock.Mock()
            stdin.fileno.return_value = 7

            @bridge.contextlib.contextmanager
            def reservation():
                try:
                    yield connection, io.BytesIO()
                finally:
                    trace.append("released")

            def finish(*args):
                trace.append("completed")
                if mode == "signal":
                    signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

            previous = signal.getsignal(signal.SIGTERM)
            with mock.patch.object(bridge, "reserve", side_effect=reservation), \
                 mock.patch.object(bridge.sys, "stdin", stdin), \
                 mock.patch.object(bridge.sys, "stdout", io.StringIO()) as output, \
                 mock.patch.object(bridge.select, "select", side_effect=[([], [], []), ([7], [], [])]), \
                 mock.patch.object(bridge.os, "read", return_value=b""), \
                 mock.patch.object(bridge, "finish_ears", side_effect=finish):
                connection.sendall.side_effect = lambda data: trace.append("command")
                bridge.think("forward")
            self.assertEqual(output.getvalue(), "ready\n")
            self.assertEqual(trace, ["command", "completed", "released"])
            self.assertIs(signal.getsignal(signal.SIGTERM), previous)
            packet = json.loads(connection.sendall.call_args.args[0])
            self.assertFalse(packet["cancelable"], "Normal stop finishes a full turn instead of canceling")

    def test_thinking_stops_before_start_and_preserves_errors(self):
        stdin, connection = mock.Mock(), mock.Mock()
        stdin.fileno.return_value = 7
        for control, error in ((b"", None), (b"invalid", ValueError)):
            with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((connection, io.BytesIO()))), \
                 mock.patch.object(bridge.sys, "stdin", stdin), \
                 mock.patch.object(bridge.sys, "stdout", io.StringIO()), \
                 mock.patch.object(bridge.select, "select", return_value=([7], [], [])), \
                 mock.patch.object(bridge.os, "read", return_value=control):
                if error:
                    with self.assertRaises(error):
                        bridge.think("forward")
                else:
                    bridge.think("forward")
        connection.sendall.assert_not_called()
        with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((connection, io.BytesIO()))), \
             mock.patch.object(bridge.sys, "stdin", stdin), \
             mock.patch.object(bridge.sys, "stdout", io.StringIO()), \
             mock.patch.object(bridge.select, "select", return_value=([], [], [])), \
             mock.patch.object(bridge, "finish_ears", side_effect=ValueError("nabd failed")):
            with self.assertRaisesRegex(ValueError, "nabd failed"):
                bridge.think("forward")

    def test_controlled_record_stops_on_second_button_or_fragmented_stop(self):
        for mode in ("button", "stdin", "alsa-error", "limit"):
            connection, stdin, capture = mock.Mock(), mock.Mock(), mock.Mock()
            stdin.fileno.return_value = 7
            capture.returncode = None
            capture.poll.side_effect = [None, 0, 0] if mode == "limit" else lambda: capture.returncode
            filenames = []

            def popen(arguments, **kwargs):
                self.assertEqual(arguments[-2], "90", "The safety limit replaces the fixed six-second capture")
                filenames.append(Path(arguments[-1]))
                filenames[-1].write_bytes(wav_data(frames=1600))
                return capture

            def communicate(**kwargs):
                capture.returncode = 0 if mode == "limit" else 1
                return None, b"ALSA capture failure" if mode == "alsa-error" else b""

            capture.communicate.side_effect = communicate
            ready = [connection] if mode == "button" else [7]
            output = mock.Mock(buffer=io.BytesIO())
            with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((connection, io.BytesIO()))), \
                 mock.patch.object(bridge.sys, "stdin", stdin), \
                 mock.patch.object(bridge.sys, "stdout", output), \
                 mock.patch.object(bridge.subprocess, "Popen", side_effect=popen), \
                 mock.patch.object(bridge, "run_audio"), mock.patch.object(bridge.time, "sleep"), \
                 mock.patch.object(bridge.select, "select", return_value=(ready, [], [])), \
                 mock.patch.object(bridge.os, "read", side_effect=[b"st", b"op\n"]), \
                 mock.patch.object(bridge, "receive", side_effect=[{"type": "button_event", "event": "up"},
                                                                 {"type": "button_event", "event": "click"}]):
                if mode == "alsa-error":
                    with self.assertRaisesRegex(ValueError, "ALSA capture failure"):
                        bridge.record()
                else:
                    bridge.record()
            if mode == "limit":
                capture.send_signal.assert_not_called()
            else:
                capture.send_signal.assert_called_once_with(signal.SIGINT)
            capture.kill.assert_not_called()
            self.assertEqual(output.buffer.getvalue(), b"" if mode == "alsa-error" else wav_data(frames=1600))
            self.assertTrue(all(not filename.exists() for filename in filenames))

    def test_controlled_record_cancels_on_eof_and_rejects_invalid_stop(self):
        stdin = mock.Mock()
        stdin.fileno.return_value = 7
        for control in (b"", b"invalid", b"stop\nextra"):
            capture = mock.Mock()
            capture.poll.return_value = None
            capture.communicate.return_value = (None, b"")
            with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext((mock.Mock(), io.BytesIO()))), \
                 mock.patch.object(bridge.sys, "stdin", stdin), \
                 mock.patch.object(bridge.sys, "stdout", mock.Mock(buffer=io.BytesIO())) as output, \
                 mock.patch.object(bridge.subprocess, "Popen", return_value=capture), \
                 mock.patch.object(bridge, "run_audio"), mock.patch.object(bridge.time, "sleep"), \
                 mock.patch.object(bridge.select, "select", return_value=([7], [], [])), \
                 mock.patch.object(bridge.os, "read", return_value=control):
                with self.assertRaises(ValueError):
                    bridge.record()
            capture.kill.assert_called_once()
            capture.communicate.assert_called_once_with(timeout=5)
            capture.send_signal.assert_not_called()
            self.assertEqual(output.buffer.getvalue(), b"")

    def test_capture_is_killed_and_reaped_when_beep_fails(self):
        capture = mock.Mock()
        capture.poll.return_value = None
        capture.communicate.return_value = (None, b"")
        with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext()), \
             mock.patch.object(bridge.subprocess, "Popen", return_value=capture), \
             mock.patch.object(bridge.time, "sleep"), \
             mock.patch.object(bridge, "run_audio", side_effect=ValueError("aplay failed")):
            with self.assertRaisesRegex(ValueError, "aplay failed"):
                bridge.record(6)
        capture.kill.assert_called_once()
        capture.communicate.assert_called_once_with(timeout=5)

    def test_capture_is_killed_and_reaped_after_timeout(self):
        capture = mock.Mock()
        capture.poll.return_value = None
        capture.communicate.side_effect = [bridge.subprocess.TimeoutExpired("arecord", 11),
                                           (None, b"")]
        with mock.patch.object(bridge, "reserve", return_value=bridge.contextlib.nullcontext()), \
             mock.patch.object(bridge.subprocess, "Popen", return_value=capture), \
             mock.patch.object(bridge.time, "sleep"), \
             mock.patch.object(bridge, "run_audio"):
            with self.assertRaises(bridge.subprocess.TimeoutExpired):
                bridge.record(6)
        capture.kill.assert_called_once()
        self.assertEqual(capture.communicate.call_count, 2)
        self.assertEqual(capture.communicate.call_args, mock.call(timeout=5))

    def test_button_watch_subscribes_and_emits_only_short_clicks(self):
        packets = [
            {"type": "state", "state": "idle"},
            {"type": "button_event", "event": "click"},
            {"type": "response", "request_id": "mac-bridge-button", "status": "ok"},
        ] + [{"type": "button_event", "event": event}
             for event in ("down", "up", "hold", "double_click", "triple_click", "click")]
        data = b"".join(json.dumps(packet).encode() + b"\r\n" for packet in packets)
        connection = self.fake_connection([])
        connection.recv.side_effect = [data[:17], data[17:]]
        stdin = mock.Mock()
        stdin.fileno.return_value = 7
        stdout = io.StringIO()
        with mock.patch.object(bridge.socket, "create_connection", return_value=connection), \
             mock.patch.object(bridge.select, "select", side_effect=[
                 ([connection], [], []), ([connection], [], []), ([7], [], [])]), \
             mock.patch.object(bridge.os, "read", return_value=b""), \
             mock.patch.object(bridge.sys, "stdin", stdin), \
             mock.patch.object(bridge.sys, "stdout", stdout):
            bridge.watch_button()
        self.assertEqual(stdout.getvalue(), "ready\nclick\n")
        packet = json.loads(connection.sendall.call_args.args[0])
        self.assertEqual(packet["mode"], "idle")
        self.assertEqual(packet["events"], ["button"])
        connection.__exit__.assert_called_once()

    def test_button_watch_exits_on_stdin_eof_before_ack(self):
        connection = self.fake_connection([])
        stdin = mock.Mock()
        stdin.fileno.return_value = 7
        with mock.patch.object(bridge.socket, "create_connection", return_value=connection), \
             mock.patch.object(bridge.select, "select", return_value=([7], [], [])), \
             mock.patch.object(bridge.os, "read", return_value=b""), \
             mock.patch.object(bridge.sys, "stdin", stdin), \
             mock.patch.object(bridge.sys, "stdout", io.StringIO()) as stdout:
            bridge.watch_button()
        self.assertEqual(stdout.getvalue(), "")
        connection.recv.assert_not_called()
        connection.__exit__.assert_called_once()

    def test_button_watch_reports_nabd_disconnect(self):
        connection = self.fake_connection([])
        connection.recv.return_value = b""
        with mock.patch.object(bridge.socket, "create_connection", return_value=connection), \
             mock.patch.object(bridge.select, "select", return_value=([connection], [], [])), \
             mock.patch.object(bridge.sys, "stdin"):
            with self.assertRaises(ConnectionError):
                bridge.watch_button()
        connection.__exit__.assert_called_once()


if __name__ == "__main__":
    unittest.main()
