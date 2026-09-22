"""Local text-to-speech pipeline.

Reads plain text files and synthesizes speech with Kokoro, streaming each audio
chunk straight into the MP3 as it is produced (via soundfile / libsndfile). Only
one chunk is held in memory at a time, so memory use does not grow with the
length of the audio.

--input and --output may be repeated to convert several files in one run; the
nth --input is written to the nth --output and the Kokoro model is loaded once
for the whole batch. All paths must be absolute; the accompanying shell script
(tts.sh) turns relative paths into absolute ones and expands a directory into
the .txt files inside it.
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

# Maps (language locale, gender) to a concrete Kokoro voice id. Kokoro-82M only
# ships American and British English among the locales of interest here; it has
# no German or Australian English voices, so those locales are intentionally
# absent and will raise a clear error rather than be silently substituted.
# To add a locale later, add its (locale, gender) -> voice id entries here.
VOICE_MAP = {
    ("en_US", "f"): "af_heart",
    ("en_US", "m"): "am_michael",
    ("en_GB", "f"): "bf_emma",
    ("en_GB", "m"): "bm_george",
}


def normalize_locale(locale: str) -> str:
    """Canonicalize a locale string, e.g. 'en-gb' or 'EN_US' -> 'en_GB' / 'en_US'."""
    parts = locale.replace("-", "_").split("_")
    language = parts[0].lower()
    if len(parts) > 1 and parts[1]:
        return f"{language}_{parts[1].upper()}"
    return language


def resolve_voice(voice: str, language: str, gender: str) -> str:
    """Pick the voice id. An explicit --voice wins; otherwise map language+gender."""
    if voice:
        return voice

    key = (normalize_locale(language), gender)
    if key not in VOICE_MAP:
        supported = ", ".join(sorted({loc for loc, _ in VOICE_MAP}))
        sys.exit(
            f"error: no Kokoro voice for language '{language}' with gender '{gender}'.\n"
            f"       Supported languages: {supported} (each with gender 'm' or 'f').\n"
            f"       Kokoro-82M has no German or Australian English voices. Use an\n"
            f"       explicit --voice <id> if you want a voice outside this table."
        )
    return VOICE_MAP[key]


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
    """Read and return the stripped contents of the input file.

    An empty result is returned as-is rather than treated as an error here, so
    that a batch can skip an empty file and carry on with the rest.
    """
    if not path.is_file():
        sys.exit(f"error: input file not found: {path}")
    return path.read_text(encoding="utf-8").strip()


def build_pipeline(lang_code: str):
    """Load the Kokoro pipeline once, so a batch does not reload it per file."""
    # Imported lazily so that --help and argument errors do not pay the cost of
    # loading torch and the Kokoro model.
    from kokoro import KPipeline

    return KPipeline(lang_code=lang_code, repo_id="hexgrad/Kokoro-82M")


def synthesize_to_mp3(
        pipeline,
        text: str,
        voice: str,
        output_path: Path,
        compression_level: float,
) -> float:
    """Stream Kokoro's audio chunks directly into an MP3 file.

    Each chunk Kokoro yields is written to the MP3 encoder immediately and then
    discarded, so peak memory holds at most a single chunk rather than the whole
    recording. Returns the duration of the written audio in seconds.
    """
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
    parser.add_argument(
        "--input",
        required=True,
        action="append",
        metavar="PATH",
        help="Absolute path to an input .txt file. May be repeated; the nth "
             "--input is paired with the nth --output.",
    )
    parser.add_argument(
        "--output",
        required=True,
        action="append",
        metavar="PATH",
        help="Absolute path to the output .mp3 file. Must be given as often as "
             "--input.",
    )
    parser.add_argument(
        "--voice",
        default="",
        help="Explicit Kokoro voice id (for example af_heart, bm_george). When "
             "set, it overrides --voice-language and --voice-gender.",
    )
    parser.add_argument(
        "--voice-language",
        default="en_US",
        help="Voice language as an ISO locale: en_US (American English) or "
             "en_GB (British English). Default: en_US.",
    )
    parser.add_argument(
        "--voice-gender",
        default="f",
        choices=["m", "f"],
        help="Voice gender: 'm' or 'f'. Default: f.",
    )
    parser.add_argument(
        "--lang-code",
        default=None,
        help="Kokoro language code. Defaults to the first letter of the resolved "
             "voice id (for example 'a' for af_heart, 'b' for bf_emma).",
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

    if len(args.input) != len(args.output):
        sys.exit(
            f"error: got {len(args.input)} --input and {len(args.output)} --output "
            f"values. Each --input needs exactly one matching --output."
        )

    pairs = [
        (require_absolute(in_path, "input"), require_absolute(out_path, "output"))
        for in_path, out_path in zip(args.input, args.output)
    ]

    voice = resolve_voice(args.voice, args.voice_language, args.voice_gender)
    # The Kokoro language code must match the voice; default to the voice prefix.
    lang_code = args.lang_code or (voice[:1] or "a")
    quality = min(max(args.mp3_quality, 0.0), MAX_COMPRESSION_LEVEL)

    # Read every input before loading the model, so a missing file fails fast.
    texts = [read_text(in_path) for in_path, _ in pairs]
    if not any(texts):
        sys.exit("error: nothing to synthesize; every input file is empty.")

    pipeline = build_pipeline(lang_code)

    written = 0
    for index, ((input_path, output_path), text) in enumerate(zip(pairs, texts), start=1):
        # Number the lines only when there is actually a batch to follow.
        prefix = f"[{index}/{len(pairs)}] " if len(pairs) > 1 else ""
        if not text:
            print(f"{prefix}Skipping {input_path}: file is empty.")
            continue
        print(f"{prefix}Synthesizing {len(text)} characters from {input_path.name} "
              f"with voice '{voice}' ...")
        duration = synthesize_to_mp3(pipeline, text, voice, output_path, quality)
        written += 1
        print(f"{prefix}Done. Wrote {output_path} ({duration:.1f}s of audio).")

    if written == 0:
        sys.exit("error: nothing was synthesized; every input file was empty.")


if __name__ == "__main__":
    main()
