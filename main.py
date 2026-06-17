"""Local text-to-speech pipeline.

Reads a plain text file and synthesizes speech with Kokoro, streaming each audio
chunk straight into the MP3 as it is produced (via soundfile / libsndfile). Only
one chunk is held in memory at a time, so memory use does not grow with the
length of the audio. Input and output must be absolute paths; the accompanying
shell script (tts.sh) turns relative paths into absolute ones.
"""

import argparse
import sys
import warnings
from pathlib import Path

import numpy as np
import soundfile as sf

# Two warnings are emitted from inside Kokoro's model definition and torch
# internals, not from this code. They are informational and do not affect the
# output, so we silence them to keep the tool's output readable. Delete these
# two lines if you ever want to see them while debugging.
warnings.filterwarnings("ignore", message=r"dropout option adds dropout")
warnings.filterwarnings("ignore", message=r"`torch\.nn\.utils\.weight_norm` is deprecated")

# Kokoro always outputs mono audio at 24 kHz.
SAMPLE_RATE = 24000

# soundfile's MP3 compression_level accepts a value in [0.0, 1.0), where 0.0 is
# the highest quality (largest file). Exactly 1.0 crashes libsndfile, so we cap
# just below it.
MAX_COMPRESSION_LEVEL = 0.99


def require_absolute(path_str: str, label: str) -> Path:
    """Return a Path, exiting if the given path is not absolute."""
    path = Path(path_str)
    if not path.is_absolute():
        sys.exit(
            f"error: --{label} must be an absolute path, got '{path_str}'. "
            f"Run this through tts.sh, which converts relative paths to absolute."
        )
    return path


def read_text(path: Path) -> str:
    """Read and return the stripped contents of the input file."""
    if not path.is_file():
        sys.exit(f"error: input file not found: {path}")
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        sys.exit(f"error: input file is empty: {path}")
    return text


def synthesize_to_mp3(
        text: str,
        voice: str,
        lang_code: str,
        output_path: Path,
        compression_level: float,
) -> float:
    """Stream Kokoro's audio chunks directly into an MP3 file.

    Each chunk Kokoro yields is written to the MP3 encoder immediately and then
    discarded, so peak memory holds at most a single chunk rather than the whole
    recording. Returns the duration of the written audio in seconds.
    """
    # Imported lazily so that --help and argument errors do not pay the cost of
    # loading torch and the Kokoro model.
    from kokoro import KPipeline

    pipeline = KPipeline(lang_code=lang_code, repo_id="hexgrad/Kokoro-82M")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # The writer is opened lazily on the first chunk so that, if Kokoro yields
    # nothing, we do not leave an empty MP3 behind.
    writer = None
    total_frames = 0
    try:
        for _, _, audio in pipeline(text, voice=voice):
            chunk = np.asarray(audio, dtype=np.float32)
            if writer is None:
                writer = sf.SoundFile(
                    str(output_path),
                    mode="w",
                    samplerate=SAMPLE_RATE,
                    channels=1,
                    format="MP3",
                    compression_level=compression_level,
                )
            writer.write(chunk)
            total_frames += len(chunk)
    finally:
        if writer is not None:
            writer.close()

    if total_frames == 0:
        sys.exit("error: Kokoro produced no audio for the given input.")

    return total_frames / SAMPLE_RATE


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Synthesize speech from a text file and write an MP3."
    )
    parser.add_argument("--input", required=True, help="Absolute path to the input .txt file.")
    parser.add_argument("--output", required=True, help="Absolute path to the output .mp3 file.")
    parser.add_argument(
        "--voice",
        default="af_heart",
        help="Kokoro voice id (default: af_heart, American English).",
    )
    parser.add_argument(
        "--lang-code",
        default=None,
        help="Kokoro language code. Defaults to the first letter of the voice id "
             "(for example 'a' for af_heart, 'b' for bf_emma).",
    )
    parser.add_argument(
        "--mp3-quality",
        type=float,
        default=0.0,
        help="MP3 quality as soundfile compression_level: 0.0 is best quality, "
             "values closer to 1.0 produce smaller files (default: 0.0).",
    )
    return parser.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)

    input_path = require_absolute(args.input, "input")
    output_path = require_absolute(args.output, "output")

    # The Kokoro language code must match the voice; default to the voice prefix.
    lang_code = args.lang_code or (args.voice[:1] or "a")
    quality = min(max(args.mp3_quality, 0.0), MAX_COMPRESSION_LEVEL)

    text = read_text(input_path)
    print(f"Synthesizing {len(text)} characters with voice '{args.voice}' ...")

    duration = synthesize_to_mp3(text, args.voice, lang_code, output_path, quality)
    print(f"Done. Wrote {output_path} ({duration:.1f}s of audio).")


if __name__ == "__main__":
    main()
