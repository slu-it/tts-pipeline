#!/usr/bin/env bash
#
# tts.sh - Local text-to-speech pipeline driver.
#
# Validates the input, ensures global dependencies are present (uv and
# espeak-ng), installs the Python dependencies via uv, then runs the Python
# synthesizer with absolute paths.
#
# Usage:
#   ./tts.sh [--input <file.txt>] [--output <file.mp3>] [--voice <voice_id>]
#
#   --input    Path to a plain text (.txt) file. Relative paths are resolved
#              against the directory you run the script from. Default: ./input.txt
#   --output   Path to the MP3 to write. Default: ./output.mp3
#   --voice    Kokoro voice id. Default: af_heart (American English).

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INPUT="./input.txt"
OUTPUT="./output.mp3"
VOICE="af_heart"

# Directory containing this script (where pyproject.toml lives).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --input)   INPUT="$2";          shift 2 ;;
        --input=*) INPUT="${1#*=}";     shift ;;
        --output)  OUTPUT="$2";         shift 2 ;;
        --output=*) OUTPUT="${1#*=}";   shift ;;
        --voice)   VOICE="$2";          shift 2 ;;
        --voice=*) VOICE="${1#*=}";     shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve paths to absolute form (relative to the current working directory).
# Done before any 'cd' so relative paths are interpreted from where the user
# invoked the script.
# ---------------------------------------------------------------------------

# Provisional absolute input path (normalized properly after we confirm it exists).
case "$INPUT" in
    /*) ABS_INPUT="$INPUT" ;;
    *)  ABS_INPUT="$PWD/$INPUT" ;;
esac

# Output directory may not exist yet; create it, then normalize the directory.
case "$OUTPUT" in
    /*) ABS_OUTPUT="$OUTPUT" ;;
    *)  ABS_OUTPUT="$PWD/$OUTPUT" ;;
esac
OUT_DIR="$(dirname "$ABS_OUTPUT")"
mkdir -p "$OUT_DIR"
ABS_OUTPUT="$(cd "$OUT_DIR" && pwd)/$(basename "$ABS_OUTPUT")"

# ---------------------------------------------------------------------------
# Validate that the input really is a plain .txt file (not Word, RTF, etc.)
# ---------------------------------------------------------------------------
case "$INPUT" in
    *.txt) ;;
    *) echo "error: --input must have a .txt extension, got '$INPUT'" >&2; exit 1 ;;
esac

if [ ! -f "$ABS_INPUT" ]; then
    echo "error: input file not found: $ABS_INPUT" >&2
    exit 1
fi

# Now that the file exists, normalize its directory (strips '.' and '..').
ABS_INPUT="$(cd "$(dirname "$ABS_INPUT")" && pwd)/$(basename "$ABS_INPUT")"

# Use 'file' to detect the real content type. Only genuine plain text passes;
# Word (.doc/.docx), RTF, PDF, and binary files report other MIME types and are
# rejected here.
MIME="$(file --mime-type -b "$ABS_INPUT")"
if [ "$MIME" != "text/plain" ]; then
    echo "error: input is not plain text (detected type: $MIME)." >&2
    echo "       Word documents, RTF, and other rich text formats are not supported." >&2
    echo "       Please provide a plain UTF-8 .txt file." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Ensure global dependencies: uv and espeak-ng.
# ---------------------------------------------------------------------------
ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        return
    fi
    echo "uv not found. Installing uv via the official installer ..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # The installer drops uv in ~/.local/bin; make it visible for this session.
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv >/dev/null 2>&1; then
        echo "error: uv installation appears to have failed. Install it manually" >&2
        echo "       from https://docs.astral.sh/uv/ and re-run." >&2
        exit 1
    fi
}

ensure_espeak() {
    # Kokoro needs the espeak-ng system library for grapheme to phoneme work.
    if command -v espeak-ng >/dev/null 2>&1; then
        return
    fi
    echo "espeak-ng not found. Attempting to install it ..."
    if command -v brew >/dev/null 2>&1; then
        brew install espeak-ng
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y espeak-ng
    else
        echo "error: could not find Homebrew or apt-get to install espeak-ng." >&2
        echo "       Please install 'espeak-ng' with your package manager, then re-run." >&2
        exit 1
    fi
}

ensure_uv
ensure_espeak

# ---------------------------------------------------------------------------
# Install the Python dependencies (Kokoro, soundfile, numpy) into the uv-managed
# environment, then run the synthesizer with absolute paths.
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"

# --inexact keeps packages that are present but not in the lock file. Kokoro's
# G2P layer installs the spaCy model 'en_core_web_sm' at runtime; a plain
# 'uv sync' would prune it every time and force a re-download on the next run.
echo "Syncing Python dependencies (this also installs Kokoro on first run) ..."
uv sync --inexact

# On macOS, assume an Apple Silicon (M-series) machine and enable PyTorch's
# Metal (MPS) GPU backend. The fallback flag lets any op MPS does not implement
# run on the CPU instead of erroring out. uv run inherits this exported value.
if [ "$(uname -s)" = "Darwin" ]; then
    export PYTORCH_ENABLE_MPS_FALLBACK=1
    echo "macOS detected: enabling MPS GPU acceleration (PYTORCH_ENABLE_MPS_FALLBACK=1)."
fi

echo "Running synthesis ..."
echo "  input:  $ABS_INPUT"
echo "  output: $ABS_OUTPUT"
echo "  voice:  $VOICE"

# Time only the conversion itself (synthesis + MP3), not the dependency setup.
# 'date +%s' (integer seconds) is portable across macOS and Linux; BSD date on
# macOS does not support sub-second %N, so we stay with whole seconds.
START_TS="$(date +%s)"

uv run main.py --input "$ABS_INPUT" --output "$ABS_OUTPUT" --voice "$VOICE"

ELAPSED="$(( $(date +%s) - START_TS ))"
if [ "$ELAPSED" -ge 60 ]; then
    printf 'Conversion took %dm %ds.\n' "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))"
else
    printf 'Conversion took %ds.\n' "$ELAPSED"
fi
