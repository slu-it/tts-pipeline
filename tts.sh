#!/usr/bin/env bash
#
# tts.sh - Local text-to-speech pipeline driver.
#
# Validates the input, ensures global dependencies are present (uv and
# espeak-ng), installs the Python dependencies via uv, then runs the Python
# synthesizer with absolute paths.
#
# Usage:
#   ./tts.sh [--input <file.txt|dir>] [--output <file.mp3|dir>]
#            [--voice-language <locale>] [--voice-gender <m|f>] [--voice <id>]
#
#   --input           Plain text (.txt) file, or a directory. A directory means
#                     "convert every .txt file directly inside it" (not
#                     recursive). Relative paths resolve against the directory
#                     you run the script from. Default: ./input.txt
#   --output          MP3 file, or a directory to write the MP3s into. A path
#                     that already is a directory, or that does not end in
#                     .mp3, is treated as a directory and created if needed.
#                     A directory input requires a directory output.
#                     Default: this script's directory, with each MP3 named
#                     after its input file.
#   --voice-language  Voice language: en_US or en_GB. Default: en_US.
#   --voice-gender    Voice gender: m or f. Default: f.
#   --voice           Explicit Kokoro voice id (e.g. af_heart). Overrides
#                     --voice-language and --voice-gender when set.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INPUT="./input.txt"
# Empty OUTPUT means: write next to this script, named after the input file.
OUTPUT=""
# Empty VOICE means: derive the voice from language + gender on the Python side.
VOICE=""
VOICE_LANGUAGE="en_US"
VOICE_GENDER="f"

# Directory containing this script (where pyproject.toml lives).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    # Print the leading comment block (lines 3 onward until the first
    # non-comment line), stripping the leading "# ".
    sed -n '3,/^[^#]/p' "$0" | sed -n 's/^# \{0,1\}//p'
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
        --voice-language)   VOICE_LANGUAGE="$2";      shift 2 ;;
        --voice-language=*) VOICE_LANGUAGE="${1#*=}"; shift ;;
        --voice-gender)     VOICE_GENDER="$2";        shift 2 ;;
        --voice-gender=*)   VOICE_GENDER="${1#*=}";   shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve paths to absolute form (relative to the current working directory).
# Done before any 'cd' so relative paths are interpreted from where the user
# invoked the script.
# ---------------------------------------------------------------------------

case "$INPUT" in
    /*) ABS_INPUT="$INPUT" ;;
    *)  ABS_INPUT="$PWD/$INPUT" ;;
esac

# The input must exist, so we can normalize it right away (this strips '.'
# and '..' segments) and tell a file apart from a directory.
if [ -d "$ABS_INPUT" ]; then
    INPUT_IS_DIR=1
    ABS_INPUT="$(cd "$ABS_INPUT" && pwd)"
elif [ -f "$ABS_INPUT" ]; then
    INPUT_IS_DIR=0
    ABS_INPUT="$(cd "$(dirname "$ABS_INPUT")" && pwd)/$(basename "$ABS_INPUT")"
else
    echo "error: input not found: $ABS_INPUT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Collect the input files.
# ---------------------------------------------------------------------------
# The element count is tracked in a plain variable: bash 3.2 (still the system
# bash on macOS) errors out under 'set -u' when an empty array is expanded.
INPUT_FILES=()
INPUT_COUNT=0
if [ "$INPUT_IS_DIR" -eq 1 ]; then
    # Only the .txt files directly inside the directory; subdirectories are
    # left alone. nullglob makes a non-matching glob expand to nothing instead
    # of to the literal pattern.
    shopt -s nullglob
    for f in "$ABS_INPUT"/*.txt; do
        INPUT_FILES+=("$f")
        INPUT_COUNT=$(( INPUT_COUNT + 1 ))
    done
    shopt -u nullglob
    if [ "$INPUT_COUNT" -eq 0 ]; then
        echo "error: no .txt files found in directory: $ABS_INPUT" >&2
        exit 1
    fi
else
    # A single file must really be a .txt (not Word, RTF, etc.).
    case "$ABS_INPUT" in
        *.txt) ;;
        *) echo "error: --input must have a .txt extension, got '$INPUT'" >&2; exit 1 ;;
    esac
    INPUT_FILES=("$ABS_INPUT")
    INPUT_COUNT=1
fi

# Drop files that hold nothing but whitespace: there is no speech in them, and
# 'file' reports such files as empty or binary rather than as text, which would
# otherwise abort the whole run over a single blank file.
KEPT_FILES=()
KEPT_COUNT=0
for f in "${INPUT_FILES[@]}"; do
    if grep -q '[^[:space:]]' "$f" 2>/dev/null; then
        KEPT_FILES+=("$f")
        KEPT_COUNT=$(( KEPT_COUNT + 1 ))
    else
        echo "skipping empty file: $f"
    fi
done
if [ "$KEPT_COUNT" -eq 0 ]; then
    echo "error: nothing to convert; every input file is empty." >&2
    exit 1
fi
INPUT_FILES=("${KEPT_FILES[@]}")
INPUT_COUNT="$KEPT_COUNT"

# Use 'file' to detect the real content type of every input. Only genuine plain
# text passes; Word (.doc/.docx), RTF, PDF, and binary files report other MIME
# types and are rejected here. Checking all of them up front means a bad file is
# reported before any (slow) synthesis starts.
for f in "${INPUT_FILES[@]}"; do
    MIME="$(file --mime-type -b "$f")"
    if [ "$MIME" != "text/plain" ]; then
        echo "error: input is not plain text (detected type: $MIME): $f" >&2
        echo "       Word documents, RTF, and other rich text formats are not supported." >&2
        echo "       Please provide plain UTF-8 .txt files." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Resolve the output. It is a directory when it already exists as one, when it
# does not end in .mp3, or when no --output was given at all (in which case the
# MP3s land next to this script). Directories may not exist yet, so create them.
# ---------------------------------------------------------------------------
if [ -z "$OUTPUT" ]; then
    OUTPUT_IS_DIR=1
    ABS_OUTPUT="$SCRIPT_DIR"
else
    case "$OUTPUT" in
        /*) ABS_OUTPUT="$OUTPUT" ;;
        *)  ABS_OUTPUT="$PWD/$OUTPUT" ;;
    esac

    if [ -d "$ABS_OUTPUT" ]; then
        OUTPUT_IS_DIR=1
    else
        case "$ABS_OUTPUT" in
            *.mp3) OUTPUT_IS_DIR=0 ;;
            *)     OUTPUT_IS_DIR=1 ;;
        esac
    fi
fi

if [ "$OUTPUT_IS_DIR" -eq 1 ]; then
    mkdir -p "$ABS_OUTPUT"
    ABS_OUTPUT="$(cd "$ABS_OUTPUT" && pwd)"
else
    if [ "$INPUT_IS_DIR" -eq 1 ]; then
        echo "error: --input is a directory, so --output must be a directory too," >&2
        echo "       not a single MP3 file: '$OUTPUT'" >&2
        exit 1
    fi
    OUT_DIR="$(dirname "$ABS_OUTPUT")"
    mkdir -p "$OUT_DIR"
    ABS_OUTPUT="$(cd "$OUT_DIR" && pwd)/$(basename "$ABS_OUTPUT")"
fi

# ---------------------------------------------------------------------------
# Pair every input file with its output file. main.py takes one --output per
# --input, in order, and synthesizes them all in a single process so the Kokoro
# model is loaded only once for the whole batch.
# ---------------------------------------------------------------------------
PY_ARGS=()
for f in "${INPUT_FILES[@]}"; do
    if [ "$OUTPUT_IS_DIR" -eq 1 ]; then
        BASE="$(basename "$f")"
        OUT_FILE="$ABS_OUTPUT/${BASE%.txt}.mp3"
    else
        OUT_FILE="$ABS_OUTPUT"
    fi
    PY_ARGS+=(--input "$f" --output "$OUT_FILE")
done

# ---------------------------------------------------------------------------
# Ensure global dependencies: uv and espeak-ng.
# ---------------------------------------------------------------------------
ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        return
    fi
    echo "uv not found. Attempting to install it ..."
    if command -v brew >/dev/null 2>&1; then
        brew install uv
    else
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # The installer drops uv in ~/.local/bin; make it visible for this session.
        export PATH="$HOME/.local/bin:$PATH"
    fi
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
if [ "$INPUT_COUNT" -gt 1 ]; then
    echo "  inputs:   $INPUT_COUNT .txt files in $ABS_INPUT"
    echo "  output:   $ABS_OUTPUT/ (one MP3 per input file)"
else
    echo "  input:    ${PY_ARGS[1]}"
    echo "  output:   ${PY_ARGS[3]}"
fi
if [ -n "$VOICE" ]; then
    echo "  voice:    $VOICE (explicit)"
else
    echo "  voice:    $VOICE_LANGUAGE / $VOICE_GENDER"
fi

# Time only the conversion itself (synthesis + MP3), not the dependency setup.
# 'date +%s' (integer seconds) is portable across macOS and Linux; BSD date on
# macOS does not support sub-second %N, so we stay with whole seconds.
START_TS="$(date +%s)"

# VOICE may be empty, in which case Python derives the voice from language and
# gender. An empty --voice argument is treated as "not set" on the Python side.
uv run main.py \
    "${PY_ARGS[@]}" \
    --voice "$VOICE" \
    --voice-language "$VOICE_LANGUAGE" \
    --voice-gender "$VOICE_GENDER"

ELAPSED="$(( $(date +%s) - START_TS ))"
if [ "$ELAPSED" -ge 60 ]; then
    printf 'Conversion took %dm %ds.\n' "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))"
else
    printf 'Conversion took %ds.\n' "$ELAPSED"
fi
