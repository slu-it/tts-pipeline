# tts-pipeline

A small local text-to-speech pipeline. It reads a plain text file (or a whole
directory of them), synthesizes speech with
[Kokoro](https://github.com/hexgrad/kokoro), and writes an MP3 per input file.

## How it works

1. `tts.sh` parses arguments, turns relative paths into absolute ones, expands
   a directory input into the `.txt` files inside it, pairs every input with
   its output file, validates that each input is a real plain text file, and
   makes sure the global dependencies (`uv` and `espeak-ng`) are installed.
2. It runs `main.py` once through `uv`, passing absolute paths, so the Kokoro
   model is loaded a single time no matter how many files are converted.
3. `main.py` reads the text and runs Kokoro, streaming each audio chunk
   straight into the MP3 as it is produced, using `soundfile` (libsndfile),
   which already ships with the MP3 encoder, so no system `ffmpeg` is required.
   Only one chunk is held in memory at a time, so memory use stays flat
   regardless of how long the audio is.

## Requirements

The script installs what it can on its own:

- `uv` (installed via Homebrew on macOS or via the official installer on 
  Debian/Ubuntu if missing; on other systems install it yourself).
- `espeak-ng` (installed via Homebrew on macOS or apt on Debian/Ubuntu if
  missing; on other systems install it yourself).
- Python dependencies (`kokoro`, `soundfile`, `numpy`) are installed into the
  uv-managed environment by `uv sync`. Python is pinned to 3.12, since Kokoro
  requires Python 3.10 to 3.12.

On first run, Kokoro downloads its model weights from Hugging Face, so the very
first synthesis needs network access and takes a little longer.

## Usage

```bash
# Defaults: ./input.txt -> input.mp3 next to the script, American English
# female voice
./tts.sh

# Explicit paths (relative paths resolve against your current directory)
./tts.sh --input ./speech.txt --output ./out/speech.mp3

# Output directory: writes ./out/speech.mp3
./tts.sh --input ./speech.txt --output ./out

# Directory input: converts every .txt in ./texts into ./out/<name>.mp3
./tts.sh --input ./texts --output ./out

# Pick a voice by language and gender
./tts.sh --input ./speech.txt --output ./speech.mp3 --voice-language en_GB --voice-gender m

# Or name a specific voice directly (overrides language/gender)
./tts.sh --input ./speech.txt --output ./speech.mp3 --voice bm_george
```

Make the script executable once:

```bash
chmod +x tts.sh
```

## Options

- `--input <file.txt|dir>`: input plain text file, or a directory. A directory
  is converted file by file: every `.txt` directly inside it (subdirectories
  are not searched). Default `./input.txt`.
- `--output <file.mp3|dir>`: output MP3, or a directory to write the MP3s into.
  A path that already is a directory, or that does not end in `.mp3`, is taken
  as a directory and created if it does not exist yet. A directory input
  requires a directory output. Default: this script's own directory.
- `--voice-language <locale>`: voice language as an ISO locale. Supported:
  `en_US` (American English) and `en_GB` (British English). Default `en_US`.
- `--voice-gender <m|f>`: voice gender. Default `f`.
- `--voice <voice_id>`: an explicit Kokoro voice id (for example `af_heart`,
  `bm_george`). When set, it overrides `--voice-language` and `--voice-gender`.

The language code Kokoro uses is taken from the first letter of the resolved
voice id (`a` for American English voices, `b` for British English).

Naming rules for the output:

| `--input` | `--output` | Result |
|---|---|---|
| file | omitted | `<script dir>/<input name>.mp3` |
| file | directory | `<output dir>/<input name>.mp3` |
| file | `*.mp3` file | exactly that file |
| directory | omitted | `<script dir>/<name>.mp3` per `.txt` file |
| directory | directory | `<output dir>/<name>.mp3` per `.txt` file |
| directory | `*.mp3` file | error |

Empty text files are skipped with a note rather than aborting a batch.

### Supported languages and the mapping

Kokoro-82M only includes American and British English among common Western
locales. It has no German and no Australian English voices, so `de` and `en_AU`
are not available and will produce a clear error. The current language and
gender combinations map to these voices:

| Language | Locale | Female | Male |
|---|---|---|---|
| American English | `en_US` | `af_heart` | `am_michael` |
| British English | `en_GB` | `bf_emma` | `bm_george` |

To add a locale later, add its `(locale, gender)` entries to `VOICE_MAP` in
`main.py`. Note that adding `de` would also require a model that actually
provides German voices; Kokoro-82M does not.

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

`--input` and `--output` may be repeated to convert a batch in one process; the
nth input is written to the nth output:

```bash
uv run main.py \
    --input /abs/a.txt --output /abs/a.mp3 \
    --input /abs/b.txt --output /abs/b.mp3
```
