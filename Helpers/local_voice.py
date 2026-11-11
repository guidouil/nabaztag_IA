#!/usr/bin/env python3
"""French Kokoro synthesis, offline WAV CLI or persistent JSON-lines worker."""

import os

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

import argparse
import base64
import contextlib
import json
import re
import sys
import textwrap
import uuid
from pathlib import Path


MAX_TEXT = 2000
SAMPLE_RATE = 24000
MAX_SECONDS = 90
MAX_PCM = MAX_SECONDS * SAMPLE_RATE * 2
MAX_REQUEST = 16384
MAX_RESPONSE = 6 * 1024 * 1024


def validate_text(text):
    if not isinstance(text, str):
        raise ValueError("Le texte à prononcer doit être une chaîne")
    text = text.strip()
    if not text:
        raise ValueError("Le texte à prononcer est vide")
    if len(text) > MAX_TEXT:
        raise ValueError(f"Le texte dépasse {MAX_TEXT} caractères ; demande une réponse plus courte")
    if "\0" in text:
        raise ValueError("Le texte contient un caractère nul invalide")
    return text


def validated_audio(results, numpy):
    samples = 0
    for result in results:
        if result.sample_rate != SAMPLE_RATE:
            raise ValueError("La voix Kokoro doit produire un audio de 24 kHz")
        audio = numpy.asarray(result.audio, dtype=numpy.float32)
        if audio.ndim != 1 or audio.size == 0 or not numpy.isfinite(audio).all():
            raise ValueError("La voix locale a produit un segment audio vide ou invalide")
        samples += audio.size
        if samples > MAX_SECONDS * SAMPLE_RATE:
            raise ValueError("La réponse audio dépasse 90 secondes ; demande une réponse plus courte")
        yield audio
    if not samples:
        raise ValueError("La voix locale n'a produit aucun audio")


def collect_audio(results, numpy):
    chunks = list(validated_audio(results, numpy))
    return numpy.concatenate(chunks)


def split_text(text):
    # Kokoro's French pipeline can truncate oversized phoneme sequences.
    sentences = re.split(r"(?<=[.!?…])\s+|\n+", text)
    segments = []
    for sentence in sentences:
        sentence = " ".join(sentence.split())
        while len(sentence) > 200:
            pauses = list(re.finditer(r"[,;:](?=\s)", sentence[:201]))
            end = pauses[-1].end() if pauses else len(textwrap.wrap(
                sentence, width=200, break_long_words=True, break_on_hyphens=False)[0])
            segments.append(sentence[:end])
            sentence = sentence[end:].lstrip()
        if sentence:
            segments.append(sentence)
    return "\n".join(segments)


def load_local_model(model_path):
    model_path = Path(model_path).expanduser().resolve()
    if not model_path.is_dir() or not (model_path / "config.json").is_file():
        raise ValueError("Modèle Kokoro local introuvable ou incomplet")
    import numpy
    from mlx_audio.tts.utils import load_model

    return load_model(str(model_path), model_type="kokoro"), numpy


def generate(model, text):
    return model.generate(text=split_text(text), voice="ff_siwis", lang_code="f", speed=1.0)


def pcm16(audio, numpy):
    # Explicit little endian and saturation also handle samples exactly equal to +1.
    return numpy.rint(numpy.clip(audio * 32768, -32768, 32767)).astype("<i2").tobytes()


def emit(output, packet):
    line = json.dumps(packet, ensure_ascii=True, separators=(",", ":")) + "\n"
    if len(line.encode("utf-8")) > MAX_RESPONSE:
        raise ValueError("Segment audio trop volumineux")
    output.write(line)
    output.flush()


def serve(model, numpy, input_stream, output):
    emit(output, {"type": "ready"})
    while True:
        line = input_stream.readline(MAX_REQUEST + 1)
        if not line:
            return
        request_id = None
        try:
            if len(line) > MAX_REQUEST or not line.endswith(b"\n"):
                while line and not line.endswith(b"\n"):
                    line = input_stream.readline(MAX_REQUEST + 1)
                raise ValueError("Requête vocale trop volumineuse ou incomplète")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Requête vocale JSON invalide")
            value = request.get("id")
            if not isinstance(value, str) or len(value) != 36 or str(uuid.UUID(value)) != value.lower():
                raise ValueError("Identifiant de requête vocale invalide")
            request_id = value
            if set(request) != {"id", "text"}:
                raise ValueError("Champs de requête vocale invalides")
            text = validate_text(request["text"])
            with contextlib.redirect_stdout(sys.stderr):
                for audio in validated_audio(generate(model, text), numpy):
                    emit(output, {"type": "chunk", "id": request_id,
                                  "pcm": base64.b64encode(pcm16(audio, numpy)).decode("ascii"),
                                  "sample_rate": SAMPLE_RATE})
            emit(output, {"type": "done", "id": request_id})
        except (BrokenPipeError, KeyboardInterrupt):
            raise
        except Exception as error:
            emit(output, {"type": "error", "id": request_id, "message": str(error)[:1000]})


def synthesize(text, model_path, output_path):
    text = validate_text(text)
    output_path = Path(output_path)
    if output_path.exists():
        raise ValueError("Le fichier audio de sortie existe déjà")
    model, numpy = load_local_model(model_path)
    import soundfile
    results = generate(model, text)
    audio = collect_audio(results, numpy)
    soundfile.write(str(output_path), audio, SAMPLE_RATE, format="WAV", subtype="PCM_16")


def main():
    parser = argparse.ArgumentParser(description="Synthèse vocale française Kokoro locale")
    parser.add_argument("--model", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output")
    mode.add_argument("--worker", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.worker:
            output = sys.stdout
            with contextlib.redirect_stdout(sys.stderr):
                model, numpy = load_local_model(arguments.model)
                for _ in validated_audio(generate(model, "Bonjour."), numpy):
                    pass
                serve(model, numpy, sys.stdin.buffer, output)
            return 0
        data = sys.stdin.buffer.read(MAX_TEXT * 4 + 1)
        if len(data) > MAX_TEXT * 4:
            raise ValueError("Entrée texte trop volumineuse")
        text = data.decode("utf-8")
        with contextlib.redirect_stdout(sys.stderr):
            synthesize(text, arguments.model, arguments.output)
        return 0
    except Exception as error:
        print("Voix locale : " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
