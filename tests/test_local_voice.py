import importlib.util
import base64
import contextlib
import io
import json
import os
import struct
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock
import uuid


HELPER = Path(__file__).resolve().parents[1] / "Helpers" / "local_voice.py"
spec = importlib.util.spec_from_file_location("local_voice", HELPER)
voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voice)


class Audio:
    def __init__(self, values, ndim=1, size=None):
        self.values = list(values)
        self.ndim = ndim
        self.size = len(self.values) if size is None else size

    def __mul__(self, value):
        return Audio(sample * value for sample in self.values)

    def astype(self, dtype):
        assert dtype == "<i2"
        return types.SimpleNamespace(tobytes=lambda: struct.pack("<" + "h" * len(self.values), *self.values))


class FakeNumpy:
    float32 = "float32"

    @staticmethod
    def asarray(audio, dtype):
        return audio

    @staticmethod
    def isfinite(audio):
        return types.SimpleNamespace(all=lambda: all(value == value and abs(value) != float("inf") for value in audio.values))

    @staticmethod
    def concatenate(chunks):
        return Audio(value for chunk in chunks for value in chunk.values)

    @staticmethod
    def clip(audio, minimum, maximum):
        return Audio(max(minimum, min(maximum, value)) for value in audio.values)

    @staticmethod
    def rint(audio):
        return Audio(round(value) for value in audio.values)


def result(values, rate=voice.SAMPLE_RATE, **audio_options):
    return types.SimpleNamespace(audio=Audio(values, **audio_options), sample_rate=rate)


class LocalVoiceTests(unittest.TestCase):
    def test_text_validation(self):
        self.assertEqual(voice.validate_text("  Bonjour !\n"), "Bonjour !")
        for text in ("", " \n", "a" * (voice.MAX_TEXT + 1), "a\0b", None, 1):
            with self.subTest(text=text), self.assertRaises(ValueError):
                voice.validate_text(text)

    def test_chunks_are_joined_in_order(self):
        audio = voice.collect_audio(iter([result([0.1, 0.2]), result([-0.3])]), FakeNumpy)
        self.assertEqual(audio.values, [0.1, 0.2, -0.3])

    def test_long_text_is_split_without_losing_words(self):
        text = "Une longue phrase française qui doit être prononcée entièrement. " * 20
        split = voice.split_text(text)
        self.assertTrue(all(len(line) <= 200 for line in split.splitlines()))
        self.assertEqual("".join(split.split()), "".join(text.split()))
        self.assertTrue(all(len(line) <= 200 for line in voice.split_text("x" * 600).splitlines()))
        self.assertEqual(voice.split_text("Bonjour. Comment vas-tu ? Très bien !"),
                         "Bonjour.\nComment vas-tu ?\nTrès bien !")

    def test_invalid_audio_is_refused(self):
        for results in ([], [result([])], [result([0.1], rate=16000)],
                        [result([0.1], ndim=2)], [result([float("nan")])],
                        [result([float("inf")])],
                        [result([0.1], size=voice.MAX_SECONDS * voice.SAMPLE_RATE), result([0.2])]):
            with self.subTest(results=results), self.assertRaises(ValueError):
                voice.collect_audio(results, FakeNumpy)

    def test_local_model_french_voice_and_pcm16_file(self):
        model = mock.Mock()
        model.generate.return_value = iter([result([0.1]), result([0.2])])
        load_model = mock.Mock(return_value=model)
        soundfile = mock.Mock()
        modules = {
            "numpy": FakeNumpy,
            "soundfile": soundfile,
            "mlx_audio": types.ModuleType("mlx_audio"),
            "mlx_audio.tts": types.ModuleType("mlx_audio.tts"),
            "mlx_audio.tts.utils": types.SimpleNamespace(load_model=load_model),
        }
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            model_path = path / "model"
            model_path.mkdir()
            (model_path / "config.json").write_text("{}")
            output = path / "output.wav"
            with mock.patch.dict("sys.modules", modules):
                voice.synthesize(" Bonjour. ", model_path, output)
            load_model.assert_called_once_with(str(model_path.resolve()), model_type="kokoro")
            model.generate.assert_called_once_with(text="Bonjour.", voice="ff_siwis", lang_code="f", speed=1.0)
            arguments, options = soundfile.write.call_args
            self.assertEqual(arguments[0], str(output))
            self.assertEqual(arguments[1].values, [0.1, 0.2])
            self.assertEqual(arguments[2], 24000)
            self.assertEqual(options, {"format": "WAV", "subtype": "PCM_16"})

    def test_missing_model_and_existing_output_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            with self.assertRaisesRegex(ValueError, "Modèle Kokoro"):
                voice.synthesize("Bonjour", path / "missing", path / "out.wav")
            (path / "config.json").write_text("{}")
            output = path / "existing.wav"
            output.write_bytes(b"keep")
            with self.assertRaisesRegex(ValueError, "existe déjà"):
                voice.synthesize("Bonjour", path, output)
            self.assertEqual(output.read_bytes(), b"keep")

    def test_legacy_output_cli_remains_available(self):
        output, errors = io.StringIO(), io.StringIO()
        input_stream = io.TextIOWrapper(io.BytesIO("Bonjour !".encode("utf-8")), encoding="utf-8")
        with mock.patch.object(voice, "synthesize") as synthesize, \
                mock.patch.object(voice.sys, "argv", ["local_voice.py", "--model", "local", "--output", "reply.wav"]), \
                mock.patch.object(voice.sys, "stdin", input_stream), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(voice.main(), 0)
        synthesize.assert_called_once_with("Bonjour !", "local", "reply.wav")
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(), "")

    def test_offline_flags_are_set_before_model_imports(self):
        self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
        self.assertEqual(os.environ["TRANSFORMERS_OFFLINE"], "1")

    def test_pcm_is_saturated_little_endian_16_bit(self):
        pcm = voice.pcm16(Audio([-2, -1, -0.5, 0, 0.5, 1, 2]), FakeNumpy)
        self.assertEqual(struct.unpack("<7h", pcm), (-32768, -32768, -16384, 0, 16384, 32767, 32767))

    def test_worker_loads_once_and_emits_ordered_audio_for_two_requests(self):
        request_ids = [str(uuid.uuid4()), str(uuid.uuid4()).upper()]
        data = b"".join((json.dumps({"id": identifier, "text": text}) + "\n").encode()
                        for identifier, text in zip(request_ids, ["Bonjour. Deuxième phrase !", "Salut."]))
        model = mock.Mock()
        warmup_complete = False
        output, errors = io.StringIO(), io.StringIO()

        def generate(**arguments):
            nonlocal warmup_complete
            print("model diagnostic")
            yield result([0.5])
            yield result([-0.5])
            if arguments["text"] == "Bonjour.":
                self.assertEqual(output.getvalue(), "")
                warmup_complete = True

        emit = voice.emit

        def checked_emit(destination, packet):
            if packet["type"] == "ready":
                self.assertTrue(warmup_complete)
            emit(destination, packet)

        model.generate.side_effect = generate
        input_stream = io.TextIOWrapper(io.BytesIO(data), encoding="utf-8")
        with mock.patch.object(voice, "load_local_model", return_value=(model, FakeNumpy)) as load, \
                mock.patch.object(voice, "emit", side_effect=checked_emit), \
                mock.patch.object(voice.sys, "argv", ["local_voice.py", "--worker", "--model", "local"]), \
                mock.patch.object(voice.sys, "stdin", input_stream), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(voice.main(), 0)
        load.assert_called_once_with("local")
        self.assertEqual(model.generate.call_args_list, [
            mock.call(text="Bonjour.", voice="ff_siwis", lang_code="f", speed=1.0),
            mock.call(text="Bonjour.\nDeuxième phrase !", voice="ff_siwis", lang_code="f", speed=1.0),
            mock.call(text="Salut.", voice="ff_siwis", lang_code="f", speed=1.0)])
        packets = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([packet["type"] for packet in packets], ["ready", "chunk", "chunk", "done", "chunk", "chunk", "done"])
        self.assertEqual([packet.get("id") for packet in packets[1:]], [request_ids[0]] * 3 + [request_ids[1]] * 3)
        self.assertEqual(base64.b64decode(packets[1]["pcm"]), struct.pack("<h", 16384))
        self.assertEqual(base64.b64decode(packets[2]["pcm"]), struct.pack("<h", -16384))
        self.assertEqual(packets[1]["sample_rate"], 24000)
        self.assertNotIn("model diagnostic", output.getvalue())
        self.assertEqual(errors.getvalue().count("model diagnostic"), 3)

    def test_worker_rejects_bad_requests_and_continues(self):
        identifier = str(uuid.uuid4())
        lines = [b"oops\n", b"[]\n", b'{"id":"bad","text":"hello"}\n',
                 (json.dumps({"id": identifier, "text": ""}) + "\n").encode(),
                 (json.dumps({"id": identifier, "text": "hi", "path": "/tmp/output"}) + "\n").encode(),
                 b"x" * (voice.MAX_REQUEST + 20) + b"\n",
                 (json.dumps({"id": identifier, "text": "Bonjour"}) + "\n").encode()]
        model = mock.Mock()
        model.generate.return_value = iter([result([0.25])])
        output = io.StringIO()
        voice.serve(model, FakeNumpy, io.BytesIO(b"".join(lines)), output)
        packets = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([packet["type"] for packet in packets], ["ready"] + ["error"] * 6 + ["chunk", "done"])
        self.assertEqual(packets[-1]["id"], identifier)
        model.generate.assert_called_once()

    def test_generation_error_after_chunk_has_no_done_and_next_request_works(self):
        identifiers = [str(uuid.uuid4()), str(uuid.uuid4())]
        data = b"".join((json.dumps({"id": identifier, "text": "Bonjour"}) + "\n").encode()
                        for identifier in identifiers)

        def broken_results():
            yield result([0.1])
            raise ValueError("generation failed")

        model = mock.Mock()
        model.generate.side_effect = [broken_results(), iter([result([0.2])])]
        output = io.StringIO()
        voice.serve(model, FakeNumpy, io.BytesIO(data), output)
        packets = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([packet["type"] for packet in packets], ["ready", "chunk", "error", "chunk", "done"])
        self.assertEqual(packets[2]["message"], "generation failed")

    def test_worker_enforces_total_duration_and_response_line_limit(self):
        model = mock.Mock()
        model.generate.return_value = iter([result([0.1], size=voice.SAMPLE_RATE * voice.MAX_SECONDS + 1)])
        output = io.StringIO()
        data = (json.dumps({"id": str(uuid.uuid4()), "text": "Bonjour"}) + "\n").encode()
        voice.serve(model, FakeNumpy, io.BytesIO(data), output)
        self.assertEqual([json.loads(line)["type"] for line in output.getvalue().splitlines()], ["ready", "error"])
        with mock.patch.object(voice, "MAX_RESPONSE", 20), self.assertRaisesRegex(ValueError, "volumineux"):
            voice.emit(io.StringIO(), {"type": "error", "message": "long"})


if __name__ == "__main__":
    unittest.main()
