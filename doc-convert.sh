#!/bin/bash
# doc-convert: Convert documents between formats using Marker OCR + Pandoc
#
# Usage:
#   doc-convert input.pdf                      # → markdown (default)
#   doc-convert input.pdf -f epub              # → epub
#   doc-convert input.pdf --translate           # → auto-detect language, translate to English
#   doc-convert input.pdf -f epub --translate   # → translate + epub
#   doc-convert input.pdf -f txt               # → plain text
#   doc-convert input.pdf -f html              # → html
#   doc-convert input.pdf --ocr                # force OCR (for scanned docs)
#   doc-convert input.pdf --llm                # use LLM for higher accuracy
#
# Supported output formats: markdown (md), epub, html, txt, docx
# Translation: auto-detects source language, translates to English by default.
#   Change default target with: --translate-to <lang>
#
# Dependencies: marker-pdf, pandoc (pypandoc), argos-translate (for translation)
# All run locally on GPU — nothing leaves the machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Marker venv path — set DOC_CONVERT_VENV or edit this default
MARKER_VENV="${DOC_CONVERT_VENV:-${HOME}/marker-env}"

CONFIG_DIR="${HOME}/.config/doc-convert"
CONFIG_FILE="${CONFIG_DIR}/settings.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default settings (overridden by config file)
DEFAULT_TRANSLATE_TO="en"
DEFAULT_FORMAT="md"

# Load user config if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

usage() {
    echo -e "${BLUE}doc-convert${NC} — Convert documents with GPU-powered OCR"
    echo ""
    echo -e "Usage: ${GREEN}doc-convert${NC} <input-file> [options]"
    echo ""
    echo "Options:"
    echo "  -f, --format FORMAT      Output format: md, epub, html, txt, docx (default: ${DEFAULT_FORMAT})"
    echo "  --translate              Auto-detect language and translate to ${DEFAULT_TRANSLATE_TO}"
    echo "  --translate-to LANG      Set target language (default: ${DEFAULT_TRANSLATE_TO})"
    echo "  -o, --output PATH        Output file path (default: auto-named next to input)"
    echo "  --ocr                    Force OCR on all pages (for scanned PDFs)"
    echo "  --llm                    Use LLM for higher accuracy (slower)"
    echo "  --title TITLE            Set document title (auto-detected if not set)"
    echo "  --author AUTHOR          Set author name (auto-detected if not set)"
    echo "  --config                 Show/edit settings (target language, default format, etc.)"
    echo "  -h, --help               Show this help"
    echo ""
    echo "Examples:"
    echo "  doc-convert paper.pdf                         # PDF → Markdown"
    echo "  doc-convert book.pdf -f epub                  # PDF → EPUB (auto-detects title/author)"
    echo "  doc-convert book.pdf -f epub --ocr            # Scanned book → EPUB"
    echo "  doc-convert russian-paper.pdf --translate      # Russian PDF → English markdown"
    echo "  doc-convert article.pdf -f epub --translate    # Auto-detect → English EPUB"
    echo "  doc-convert slides.pptx -f md                 # PowerPoint → Markdown"
    echo ""
    echo "Environment:"
    echo "  DOC_CONVERT_VENV         Path to marker-pdf virtualenv (default: ~/marker-env)"
    echo ""
    echo "Settings: ${CONFIG_FILE}"
    echo "  Edit to change default target language, output format, etc."
}

show_config() {
    echo -e "${BLUE}doc-convert settings${NC}"
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "Config file: ${GREEN}${CONFIG_FILE}${NC}"
        echo ""
        cat "$CONFIG_FILE"
    else
        echo "No config file yet. Creating with defaults..."
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" << 'CONF'
# doc-convert settings
# Edit these to change defaults.

# Default target language for --translate (ISO 639-1 code)
# Common: en, ru, es, fr, de, zh, ja, ko
DEFAULT_TRANSLATE_TO="en"

# Default output format (md, epub, html, txt, docx)
DEFAULT_FORMAT="md"
CONF
        echo -e "${GREEN}Created:${NC} ${CONFIG_FILE}"
        echo ""
        cat "$CONFIG_FILE"
    fi
    echo ""
    echo -e "Edit with: ${YELLOW}nano ${CONFIG_FILE}${NC}"
}

# Parse arguments
INPUT=""
FORMAT="$DEFAULT_FORMAT"
DO_TRANSLATE=""
TRANSLATE_TO="$DEFAULT_TRANSLATE_TO"
OUTPUT=""
FORCE_OCR=""
USE_LLM=""
TITLE=""
AUTHOR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--format) FORMAT="$2"; shift 2 ;;
        --translate) DO_TRANSLATE="yes"; shift ;;
        --translate-to) TRANSLATE_TO="$2"; DO_TRANSLATE="yes"; shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        --ocr) FORCE_OCR="--force_ocr"; shift ;;
        --llm) USE_LLM="--use_llm"; shift ;;
        --title) TITLE="$2"; shift 2 ;;
        --author) AUTHOR="$2"; shift 2 ;;
        --config) show_config; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
        *) INPUT="$1"; shift ;;
    esac
done

if [[ -z "$INPUT" ]]; then
    echo -e "${RED}Error: No input file specified${NC}"
    usage
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo -e "${RED}Error: File not found: $INPUT${NC}"
    exit 1
fi

# Check marker venv exists
if [[ ! -d "$MARKER_VENV" ]]; then
    echo -e "${RED}Error: Marker virtualenv not found at ${MARKER_VENV}${NC}"
    echo -e "Set DOC_CONVERT_VENV to your marker-pdf venv path, or install:"
    echo -e "  python3 -m venv ~/marker-env"
    echo -e "  source ~/marker-env/bin/activate"
    echo -e "  pip install marker-pdf pypandoc"
    exit 1
fi

# Derive output filename
BASENAME="$(basename "$INPUT")"
BASENAME_NOEXT="${BASENAME%.*}"
INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"

case "$FORMAT" in
    md|markdown) EXT="md"; MARKER_FMT="markdown" ;;
    epub)        EXT="epub"; MARKER_FMT="markdown" ;;
    html)        EXT="html"; MARKER_FMT="html" ;;
    txt|text)    EXT="txt"; MARKER_FMT="markdown" ;;
    docx)        EXT="docx"; MARKER_FMT="markdown" ;;
    *) echo -e "${RED}Unknown format: $FORMAT${NC}"; exit 1 ;;
esac

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="${INPUT_DIR}/${BASENAME_NOEXT}.${EXT}"
fi

# Activate marker venv
source "${MARKER_VENV}/bin/activate"

# Step 0: Auto-detect metadata from PDF
if [[ -z "$TITLE" || -z "$AUTHOR" ]]; then
    echo -e "${BLUE}[0/3]${NC} Detecting metadata..."
    METADATA=$(python3 - "$INPUT" << 'PYEOF'
import sys
try:
    import fitz
    doc = fitz.open(sys.argv[1])
    meta = doc.metadata or {}
    title = meta.get("title", "").strip()
    author = meta.get("author", "").strip()

    # If no metadata, try to extract from first page text
    if not title or not author:
        for i in range(min(5, len(doc))):
            text = doc[i].get_text().strip()
            if text:
                lines = [l.strip() for l in text.split('\n') if l.strip()]
                if not title and lines:
                    for line in lines:
                        if len(line) > 3 and len(line) < 200:
                            title = line
                            break
                if not author and len(lines) > 1:
                    for line in lines[1:5]:
                        if line.lower().startswith("by "):
                            author = line[3:].strip()
                            break
                        elif len(line) > 3 and len(line) < 80 and not any(c.isdigit() for c in line):
                            author = line
                            break
                if title:
                    break

    # Try to get from filename as last resort
    if not title:
        import os
        fname = os.path.splitext(os.path.basename(sys.argv[1]))[0]
        title = fname.replace('_', ' ').replace('-', ' ')

    print(f"TITLE={title}")
    print(f"AUTHOR={author}")
except Exception as e:
    print(f"TITLE=")
    print(f"AUTHOR=")
PYEOF
    )

    if [[ -z "$TITLE" ]]; then
        TITLE=$(echo "$METADATA" | grep "^TITLE=" | cut -d= -f2-)
    fi
    if [[ -z "$AUTHOR" ]]; then
        AUTHOR=$(echo "$METADATA" | grep "^AUTHOR=" | cut -d= -f2-)
    fi

    if [[ -n "$TITLE" ]]; then
        echo -e "  Title:  ${GREEN}${TITLE}${NC}"
    fi
    if [[ -n "$AUTHOR" ]]; then
        echo -e "  Author: ${GREEN}${AUTHOR}${NC}"
    fi
fi

# Step 1: OCR with Marker
echo -e "${BLUE}[1/3]${NC} Extracting text with Marker (GPU OCR)..."
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

MARKER_ARGS=("$INPUT" "--output_dir" "$TMPDIR" "--output_format" "$MARKER_FMT")
if [[ -n "$FORCE_OCR" ]]; then
    MARKER_ARGS+=("--force_ocr")
fi
if [[ -n "$USE_LLM" ]]; then
    MARKER_ARGS+=("--use_llm")
fi

marker_single "${MARKER_ARGS[@]}" 2>&1 | grep -v "^$" | while IFS= read -r line; do
    echo -e "  ${YELLOW}marker:${NC} $line"
done

# Find marker output
MARKER_OUTPUT=$(find "$TMPDIR" -type f \( -name "*.md" -o -name "*.html" \) | head -1)

if [[ -z "$MARKER_OUTPUT" || ! -f "$MARKER_OUTPUT" ]]; then
    echo -e "${RED}Error: Marker produced no output${NC}"
    echo "Contents of temp dir:"
    find "$TMPDIR" -type f
    exit 1
fi

echo -e "  ${GREEN}✓${NC} Extracted $(wc -c < "$MARKER_OUTPUT" | tr -d ' ') bytes of text"

# Step 2: Translate (optional)
if [[ -n "$DO_TRANSLATE" ]]; then
    echo -e "${BLUE}[2/3]${NC} Detecting language and translating → ${TRANSLATE_TO}..."

    python3 - "$MARKER_OUTPUT" "$TRANSLATE_TO" << 'PYEOF'
import sys

input_file = sys.argv[1]
target_lang = sys.argv[2]

with open(input_file, 'r') as f:
    text = f.read()

# Auto-detect source language
try:
    from langdetect import detect
    src_lang = detect(text[:5000])
    print(f"  Detected language: {src_lang}")
except ImportError:
    src_lang = None
    print("  Warning: langdetect not installed, trying argos detection...")

if src_lang == target_lang:
    print(f"  Document is already in {target_lang}, skipping translation.")
    sys.exit(0)

import argostranslate.package
import argostranslate.translate

argostranslate.package.update_package_index()
available = argostranslate.package.get_available_packages()

if src_lang:
    pkg = next((p for p in available if p.from_code == src_lang and p.to_code == target_lang), None)
else:
    for try_lang in ['ru', 'es', 'fr', 'de', 'zh', 'ja', 'ko', 'pt', 'it']:
        pkg = next((p for p in available if p.from_code == try_lang and p.to_code == target_lang), None)
        if pkg:
            src_lang = try_lang
            print(f"  Trying {try_lang}→{target_lang}...")
            break

if not pkg:
    print(f"  Error: No translation package available for {src_lang}→{target_lang}")
    sys.exit(1)

installed = argostranslate.package.get_installed_packages()
if not any(p.from_code == src_lang and p.to_code == target_lang for p in installed):
    print(f"  Installing {src_lang}→{target_lang} language pack...")
    argostranslate.package.install_from_path(pkg.download())

print(f"  Translating {src_lang}→{target_lang}...")
translated = argostranslate.translate.translate(text, src_lang, target_lang)
with open(input_file, 'w') as f:
    f.write(translated)

print(f"  ✓ Translation complete ({src_lang}→{target_lang})")
PYEOF
else
    echo -e "${BLUE}[2/3]${NC} No translation requested, skipping"
fi

# Step 3: Convert to final format
if [[ "$FORMAT" == "md" || "$FORMAT" == "markdown" ]]; then
    echo -e "${BLUE}[3/3]${NC} Output is already markdown"
    cp "$MARKER_OUTPUT" "$OUTPUT"
elif [[ "$FORMAT" == "txt" || "$FORMAT" == "text" ]]; then
    echo -e "${BLUE}[3/3]${NC} Converting to plain text..."
    sed 's/^#\+\s*/\n/g; s/\*\*//g; s/\*//g; s/`//g' "$MARKER_OUTPUT" > "$OUTPUT"
elif [[ "$FORMAT" == "html" && "$MARKER_FMT" == "html" ]]; then
    echo -e "${BLUE}[3/3]${NC} Output is already HTML"
    cp "$MARKER_OUTPUT" "$OUTPUT"
else
    echo -e "${BLUE}[3/3]${NC} Converting to ${FORMAT} with Pandoc..."

    export _MARKER_OUT="$MARKER_OUTPUT"
    export _OUT_FMT="$FORMAT"
    export _OUT_FILE="$OUTPUT"

    PANDOC_ARGS=("-f" "markdown" "-o" "$OUTPUT")
    if [[ -n "$TITLE" ]]; then
        PANDOC_ARGS+=("--metadata" "title=$TITLE")
    fi
    if [[ -n "$AUTHOR" ]]; then
        PANDOC_ARGS+=("--metadata" "author=$AUTHOR")
    fi
    if [[ "$FORMAT" == "epub" ]]; then
        PANDOC_ARGS+=("--split-level=1" "--toc" "--toc-depth=2")
        EPUB_CSS="${TMPDIR}/epub-style.css"
        cat > "$EPUB_CSS" << 'CSS'
body { font-family: Georgia, serif; line-height: 1.6; }
h1 { margin-top: 2em; text-align: center; }
h2 { margin-top: 1.5em; }
p { text-indent: 1.5em; margin: 0.3em 0; }
CSS
        PANDOC_ARGS+=("--css=$EPUB_CSS")
    fi

    python3 -c "
import pypandoc, sys, os
pypandoc.ensure_pandoc_installed()
pypandoc.convert_file(os.environ['_MARKER_OUT'], os.environ['_OUT_FMT'],
    outputfile=os.environ['_OUT_FILE'], extra_args=sys.argv[1:])
" "${PANDOC_ARGS[@]}" 2>&1 || {
        pandoc "$MARKER_OUTPUT" "${PANDOC_ARGS[@]}" 2>&1
    }
fi

# Report
FILE_SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo -e "${GREEN}✓ Done!${NC} ${OUTPUT} (${FILE_SIZE})"
echo -e "  Format: ${FORMAT}"
if [[ -n "$TITLE" ]]; then
    echo -e "  Title: ${TITLE}"
fi
if [[ -n "$AUTHOR" ]]; then
    echo -e "  Author: ${AUTHOR}"
fi
if [[ -n "$DO_TRANSLATE" ]]; then
    echo -e "  Translated → ${TRANSLATE_TO}"
fi
