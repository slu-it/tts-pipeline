# tts-pipeline

A small local text-to-speech pipeline. It reads a plain text file, synthesizes
speech with [Kokoro](https://github.com/hexgrad/kokoro), and writes an MP3.

## How it works

1. `tts.sh` parses arguments, turns relative paths into absolute ones,
   validates that the input is a real plain text file, and makes sure the
   global dependencies (`uv` and `espeak-ng`) are installed.
2. It runs `main.py` through `uv`, passing absolute paths.
3. `main.py` reads the text and runs Kokoro, streaming each audio chunk
   straight into the MP3 as it is produced, using `soundfile` (libsndfile),
   which already ships with the MP3 encoder, so no system `ffmpeg` is required.
   Only one chunk is held in memory at a time, so memory use stays flat
   regardless of how long the audio is.

## Requirements

The script installs what it can on its own:

- `uv` (installed automatically via the official installer if missing).
- `espeak-ng` (installed via Homebrew on macOS or apt on Debian/Ubuntu if
  missing; on other systems install it yourself).
- Python dependencies (`kokoro`, `soundfile`, `numpy`) are installed into the
  uv-managed environment by `uv sync`. Python is pinned to 3.12, since Kokoro
  requires Python 3.10 to 3.12.

On first run, Kokoro downloads its model weights from Hugging Face, so the very
first synthesis needs network access and takes a little longer.

## Usage

```bash
# Defaults: ./input.txt -> ./output.mp3
./tts.sh

# Explicit paths (relative paths resolve against your current directory)
./tts.sh --input ./speech.txt --output ./out/speech.mp3

# Pick a different voice
./tts.sh --input ./speech.txt --output ./speech.mp3 --voice bf_emma
```

Make the script executable once:

```bash
chmod +x tts.sh
```

## Options

- `--input <file.txt>`: input plain text file. Default `./input.txt`.
- `--output <file.mp3>`: output MP3. Default `./output.mp3`.
- `--voice <voice_id>`: Kokoro voice id. Default `af_heart`. The language code
  is taken from the first letter of the voice (for example `a` for American
  English voices `af_*` and `am_*`, `b` for British English `bf_*` and `bm_*`).

## Why soundfile for the MP3 step

`soundfile` is already needed for the WAV side, and recent builds bundle a
libsndfile with a working MP3 encoder, so the same single library handles both
WAV and MP3 with no extra system packages. The trade-off is coarser bitrate
control than a dedicated LAME or ffmpeg path. Quality is controlled in `main.py`
via `--mp3-quality` (soundfile `compression_level`): `0.0` is best quality,
values closer to `1.0` produce smaller files.

## Running the Python directly

`main.py` requires absolute paths (the shell script provides them):

```bash
uv run main.py --input /abs/path/in.txt --output /abs/path/out.mp3 --voice af_heart
```
