import base64
import io
import json
import os
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
    sizes = {0: 0, 1: 1, 7: 6, 17: 2, 19: 0, 20: 2}
    index, elapsed, frame_ms, events = 0, 0, 0, []
    while index < len(data):
        delay, opcode = data[index:index + 2]
        index += 2
        elapsed += delay * frame_ms / 1000
        assert opcode in sizes, "No absolute movement, MIDI or loop"
        operands = tuple(data[index:index + sizes[opcode]])
        assert len(operands) == sizes[opcode]
        index += sizes[opcode]
        events.append((elapsed, opcode, operands))
        if opcode == 1:
            frame_ms = operands[0] * 10
    return events, elapsed


class RemoteBridgeTests(unittest.TestCase):
    @bridge.contextlib.contextmanager
    def stream_fixture(self, data=None, early_failure=False):
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
            script = """import os, sys
from pathlib import Path
if sys.argv[2] == 'fail':
    sys.stderr.write('mock ALSA failure')
    sys.exit(7)
data = os.read(0, 2)
if data:
    Path(sys.argv[1]).write_bytes(data)
while os.read(0, 16384):
    pass
"""

            def popen(arguments, **kwargs):
                self.assertEqual(arguments, ["aplay", "-q", "-D", bridge.DEVICE, "-t", "raw", "-f",
                                             "S16_LE", "-r", "24000", "-c", "1"])
                player = real_popen([sys.executable, "-c", script, str(marker),
                                     "fail" if early_failure else "ok"], **kwargs)
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
        for command in ("", "sh", "diagnostic extra", "record", "record 0", "record 16",
                        "record 1; reboot", "play; reboot", "record $(id)", "record '1",
                        "watch-button extra", "watch-button; reboot", "play-animated extra", "play-animated; reboot"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                bridge.parse_action(command)

    def test_effect_options_allowlist(self):
        for ears in ("off", "small", "large"):
            for lights in ("off", "fixed", "random"):
                options = (ears, lights, "12AbEF")
                command = "play-animated " + " ".join(options)
                self.assertEqual(bridge.parse_action(command), ("play-animated", options))
                self.assertEqual(bridge.parse_action(command.replace("play-animated", "play-stream")),
                                 ("play-stream", options))
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
        self.assertRaises(ValueError, bridge.parse_action, "play-stream")

    def test_main_routes_stream_without_reading_whole_input(self):
        source = mock.Mock()
        with mock.patch.dict(bridge.os.environ, {"SSH_ORIGINAL_COMMAND": "play-stream large random 123456"}, clear=True), \
             mock.patch.object(bridge.sys, "stdin", mock.Mock(buffer=source)), \
             mock.patch.object(bridge, "stream_play") as stream:
            self.assertEqual(bridge.main(), 0)
        stream.assert_called_once_with(source, options=("large", "random", "123456"))
        source.read.assert_not_called()

    def test_exact_remote_prefix_is_allowed(self):
        prefix = "/usr/bin/python3 /usr/local/lib/nabaztag-mac/bridge_remote.py "
        for command in ("diagnostic", "play", "play-animated", "play-stream small fixed 002838", "watch-button", "record 6"):
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

    def test_ear_choreography_is_finite_relative_and_compensated(self):
        for duration in (0.01, 6, 37, 90):
            for ears in ("off", "small", "large"):
                for lights in ("off", "fixed", "random"):
                    with self.subTest(duration=duration, ears=ears, lights=lights):
                        resource, motion_duration = bridge.response_choreography(duration, (ears, lights, "002838"))
                        if ears == lights == "off":
                            self.assertIsNone(resource)
                            self.assertEqual(motion_duration, 0)
                            continue
                        events, elapsed = decoded_choreography(resource)
                        directions, positions, moved = [None, None], [0, 0], []
                        led_events = []
                        bound = 3 if ears == "large" else 1
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
                            elif opcode == 20:
                                self.assertNotEqual(ears, "off")
                                directions[operands[0]] = operands[1]
                            elif opcode == 17:
                                motor, delta = operands
                                self.assertNotEqual(ears, "off")
                                self.assertEqual(delta, bound)
                                positions[motor] += -delta if directions[motor] else delta
                                self.assertTrue(all(-bound <= position <= 0 for position in positions))
                                moved.append((timestamp, motor))
                        self.assertEqual(positions, [0, 0])
                        self.assertEqual([motor for _, motor in moved],
                                         [motor for pulse in range(len(moved) // 2)
                                          for motor in (pulse % 2, pulse % 2)])
                        if ears == "off":
                            self.assertEqual(moved, [])
                        else:
                            self.assertTrue(moved)
                            for start, end in zip(moved[::2], moved[1::2]):
                                self.assertGreaterEqual(round(end[0] - start[0], 6), 1.2 if ears == "large" else 0.6)
                        self.assertEqual(bool(led_events), lights != "off")
                        self.assertAlmostEqual(elapsed, motion_duration)
                        self.assertLessEqual(motion_duration, 90)

    def test_legacy_effect_defaults_are_unchanged(self):
        self.assertEqual(bridge.response_choreography(6),
                         bridge.response_choreography(6, ("small", "fixed", "002838")))

    def test_stream_effect_cycles_alternate_initial_motor_and_remain_compensated(self):
        for ears, duration, delta in (("small", 1.2, 1), ("large", 2.4, 3)):
            for first_motor in (0, 1):
                resource, actual_duration = bridge.response_choreography(
                    duration, (ears, "off", "002838"), first_motor=first_motor)
                events, _ = decoded_choreography(resource)
                self.assertEqual(actual_duration, duration)
                directions, positions, motors = [0, 0], [0, 0], []
                for _, opcode, values in events:
                    if opcode == 20:
                        directions[values[0]] = values[1]
                    elif opcode == 17:
                        motor, amount = values
                        self.assertEqual(amount, delta)
                        positions[motor] += -amount if directions[motor] else amount
                        self.assertTrue(all(-delta <= position <= 0 for position in positions))
                        motors.append(motor)
                self.assertEqual(motors, [first_motor, first_motor])
                self.assertEqual(positions, [0, 0])

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
            first_motors = []
            for command in commands[:2]:
                events, _ = decoded_choreography(command["sequence"][0]["choreography"])
                first_motors.append(next(values[0] for _, opcode, values in events if opcode == 17))
            self.assertEqual(first_motors, [0, 1])

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
