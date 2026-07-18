#!/bin/bash
# doc-convert -- Convert documents with local GPU OCR + optional translation
#
# Wraps Marker (neural OCR), Argos Translate (local MT), and Pandoc.
# Everything runs locally. Nothing leaves the machine.
#
# Copyright (c) 2026 Anna Brezgis — MIT License

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve real script directory (follows symlinks, e.g. ~/.local/bin/doc-convert -> ...)
# ---------------------------------------------------------------------------
resolve_script_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(resolve_script_dir)"

# ---------------------------------------------------------------------------
# TTY-aware color (respects NO_COLOR convention)
# ---------------------------------------------------------------------------
setup_colors() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
    fi
}
setup_colors

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
info()  { printf '%b\n' "${BLUE}${1}${NC}"; }
ok()    { printf '%b\n' "${GREEN}${1}${NC}"; }
warn()  { printf '%b\n' "${YELLOW}${1}${NC}" >&2; }
err()   { printf '%b\n' "${RED}${1}${NC}" >&2; }
die()   { err "$1"; exit "${2:-1}"; }
step()  { printf '%b\n' "${BLUE}[${1}]${NC} ${2}"; }
detail(){ printf '%b\n' "  ${DIM}${1}${NC}"; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CONFIG_DIR="${HOME}/.config/doc-convert"
CONFIG_FILE="${CONFIG_DIR}/settings.conf"
DEFAULT_TRANSLATE_TO="en"
DEFAULT_FORMAT="md"

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}
load_config

# ---------------------------------------------------------------------------
# Venv resolution
#
# Priority:
#   1. $DOC_CONVERT_VENV  (documented env var)
#   2. $MARKER_VENV        (legacy compat)
#   3. ~/marker-env        (documented default)
#   4. $SCRIPT_DIR/marker-env  (co-located)
#   5. marker_single already on PATH / venv already active
#   6. Error with actionable instructions
# ---------------------------------------------------------------------------
RESOLVED_VENV=""

resolve_venv() {
    # 1. Explicit env var (primary, matches README)
    if [[ -n "${DOC_CONVERT_VENV:-}" ]] && [[ -d "${DOC_CONVERT_VENV}/bin" ]]; then
        RESOLVED_VENV="$DOC_CONVERT_VENV"
        return 0
    fi
    # 2. Legacy env var
    if [[ -n "${MARKER_VENV:-}" ]] && [[ -d "${MARKER_VENV}/bin" ]]; then
        RESOLVED_VENV="$MARKER_VENV"
        return 0
    fi
    # 3. ~/marker-env (documented default)
    if [[ -d "${HOME}/marker-env/bin" ]]; then
        RESOLVED_VENV="${HOME}/marker-env"
        return 0
    fi
    # 4. Co-located with the script
    if [[ -d "${SCRIPT_DIR}/marker-env/bin" ]]; then
        RESOLVED_VENV="${SCRIPT_DIR}/marker-env"
        return 0
    fi
    # 5. Already available (active venv or on PATH)
    if command -v marker_single &>/dev/null; then
        RESOLVED_VENV=""  # empty = no activation needed
        return 0
    fi
    # 6. Nothing found
    return 1
}

activate_venv() {
    if ! resolve_venv; then
        err "Could not find a Marker virtualenv."
        echo ""
        echo "To set one up:"
        echo "  python3 -m venv ~/marker-env"
        echo "  source ~/marker-env/bin/activate"
        echo "  pip install marker-pdf pypandoc PyMuPDF"
        echo ""
        echo "Or point to an existing venv:"
        echo "  export DOC_CONVERT_VENV=/path/to/your/marker-env"
        exit 1
    fi
    if [[ -n "$RESOLVED_VENV" ]]; then
        # shellcheck source=/dev/null
        source "${RESOLVED_VENV}/bin/activate"
    fi
    # Ensure ~/.local/bin is on PATH (for pypandoc's bundled pandoc, pip tools)
    export PATH="$HOME/.local/bin:$PATH"
}

# ---------------------------------------------------------------------------
# Pandoc capability detection
# ---------------------------------------------------------------------------
PANDOC_SPLIT_FLAG=""

detect_pandoc_split_flag() {
    local pandoc_help
    if ! command -v pandoc &>/dev/null; then
        return 1
    fi
    pandoc_help="$(pandoc --help 2>&1)" || true
    if echo "$pandoc_help" | grep -q -- '--split-level'; then
        PANDOC_SPLIT_FLAG="--split-level=1"
    elif echo "$pandoc_help" | grep -q -- '--epub-chapter-level'; then
        PANDOC_SPLIT_FLAG="--epub-chapter-level=1"
    else
        PANDOC_SPLIT_FLAG=""
    fi
}

# ---------------------------------------------------------------------------
# doctor subcommand
# ---------------------------------------------------------------------------
cmd_doctor() {
    local ok_count=0
    local warn_count=0
    local fail_count=0

    printf '%b\n' "${BOLD}doc-convert doctor${NC}"
    echo "Checking your environment..."
    echo ""

    # Python
    if command -v python3 &>/dev/null; then
        local pyver
        pyver="$(python3 --version 2>&1)"
        ok "  [ok]  python3 ($pyver)"
        ok_count=$((ok_count + 1))
    else
        err "  [!!]  python3 not found"
        echo "        Install Python 3.10+ from your package manager."
        fail_count=$((fail_count + 1))
    fi

    # Venv + marker_single
    if resolve_venv; then
        if [[ -n "$RESOLVED_VENV" ]]; then
            ok "  [ok]  Marker venv found at $RESOLVED_VENV"
            # Check marker_single inside venv
            if [[ -x "${RESOLVED_VENV}/bin/marker_single" ]]; then
                ok "  [ok]  marker_single available"
                ok_count=$((ok_count + 1))
            else
                warn "  [!!]  marker_single not found in venv"
                echo "        Run: source ${RESOLVED_VENV}/bin/activate && pip install marker-pdf"
                fail_count=$((fail_count + 1))
            fi
        else
            ok "  [ok]  marker_single already on PATH ($(command -v marker_single))"
            ok_count=$((ok_count + 1))
        fi
        ok_count=$((ok_count + 1))
    else
        err "  [!!]  No Marker venv found"
        echo "        Create one:  python3 -m venv ~/marker-env"
        echo "        Then:        source ~/marker-env/bin/activate && pip install marker-pdf pypandoc PyMuPDF"
        echo "        Or set:      export DOC_CONVERT_VENV=/path/to/your/venv"
        fail_count=$((fail_count + 1))
    fi

    # Pandoc
    if command -v pandoc &>/dev/null; then
        local pdver
        pdver="$(pandoc --version 2>&1 | head -1)"
        detect_pandoc_split_flag
        if [[ -n "$PANDOC_SPLIT_FLAG" ]]; then
            ok "  [ok]  $pdver (epub split: $PANDOC_SPLIT_FLAG)"
        else
            warn "  [~~]  $pdver (no epub chapter-split flag found; epub output may not split chapters)"
            warn_count=$((warn_count + 1))
        fi
        ok_count=$((ok_count + 1))
    else
        err "  [!!]  pandoc not found"
        echo "        Install: apt install pandoc  OR  brew install pandoc"
        fail_count=$((fail_count + 1))
    fi

    # PyMuPDF (fitz) -- optional metadata extraction
    if python3 -c "import fitz" 2>/dev/null; then
        ok "  [ok]  PyMuPDF (fitz) available"
        ok_count=$((ok_count + 1))
    else
        warn "  [~~]  PyMuPDF not found (metadata auto-detect won't work)"
        echo "        Install: pip install PyMuPDF"
        warn_count=$((warn_count + 1))
    fi

    # pypandoc
    if python3 -c "import pypandoc" 2>/dev/null; then
        ok "  [ok]  pypandoc available"
        ok_count=$((ok_count + 1))
    else
        warn "  [~~]  pypandoc not found (Pandoc fallback will be used)"
        echo "        Install: pip install pypandoc"
        warn_count=$((warn_count + 1))
    fi

    # Argos Translate (optional)
    if python3 -c "import argostranslate" 2>/dev/null; then
        ok "  [ok]  argos-translate available"
        ok_count=$((ok_count + 1))
    else
        detail "  [--]  argos-translate not installed (only needed for --translate)"
        echo "        Install: pip install argostranslate"
    fi

    # langdetect (optional)
    if python3 -c "import langdetect" 2>/dev/null; then
        ok "  [ok]  langdetect available"
        ok_count=$((ok_count + 1))
    else
        detail "  [--]  langdetect not installed (only needed for --translate)"
        echo "        Install: pip install langdetect"
    fi

    # GPU check (informational)
    echo ""
    if command -v nvidia-smi &>/dev/null; then
        local gpu_name
        gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" || gpu_name="(query failed)"
        ok "  [ok]  GPU: $gpu_name"
        ok_count=$((ok_count + 1))
    else
        detail "  [--]  No NVIDIA GPU detected (Marker will use CPU -- slow but functional)"
    fi

    # Summary
    echo ""
    if ((fail_count > 0)); then
        err "$fail_count critical issue(s) found. Fix these before converting."
    elif ((warn_count > 0)); then
        warn "Ready with $warn_count optional warning(s)."
    else
        ok "All good. Ready to convert."
    fi
    return "$fail_count"
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    printf '%b\n' "${BOLD}doc-convert${NC} -- local GPU-powered document conversion"
    echo ""
    printf '%b\n' "Usage: ${GREEN}doc-convert${NC} <input-file> [options]"
    printf '%b\n' "       ${GREEN}doc-convert${NC} doctor"
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
    echo "  --config                 Show/edit persistent settings"
    echo "  -h, --help               Show this help"
    echo ""
    echo "Subcommands:"
    echo "  doctor, --check          Check environment and dependencies"
    echo ""
    echo "Examples:"
    echo "  doc-convert paper.pdf                         # PDF -> Markdown"
    echo "  doc-convert book.pdf -f epub --ocr            # Scanned book -> EPUB"
    echo "  doc-convert russian-paper.pdf --translate      # Russian PDF -> English markdown"
    echo "  doc-convert article.pdf -f epub --translate    # Auto-detect -> English EPUB"
    echo ""
    echo "Settings: ${CONFIG_FILE}"
}

# ---------------------------------------------------------------------------
# Config display
# ---------------------------------------------------------------------------
show_config() {
    printf '%b\n' "${BOLD}doc-convert settings${NC}"
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        printf '%b\n' "Config file: ${GREEN}${CONFIG_FILE}${NC}"
        echo ""
        cat "$CONFIG_FILE"
    else
        echo "No config file yet. Creating with defaults..."
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" << 'CONF'
# doc-convert settings

# Default target language for --translate (ISO 639-1 code)
# Common: en, ru, es, fr, de, zh, ja, ko
DEFAULT_TRANSLATE_TO="en"

# Default output format (md, epub, html, txt, docx)
DEFAULT_FORMAT="md"
CONF
        printf '%b\n' "${GREEN}Created:${NC} ${CONFIG_FILE}"
        echo ""
        cat "$CONFIG_FILE"
    fi
    echo ""
    echo "Edit with: nano ${CONFIG_FILE}"
}

# ---------------------------------------------------------------------------
# Metadata extraction (Python heredoc)
# ---------------------------------------------------------------------------
extract_metadata() {
    local input_file="$1"
    python3 - "$input_file" << 'PYEOF' 2>/dev/null || true
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
                        if 3 < len(line) < 200:
                            title = line
                            break
                if not author and len(lines) > 1:
                    for line in lines[1:5]:
                        if line.lower().startswith("by "):
                            author = line[3:].strip()
                            break
                        elif 3 < len(line) < 80 and not any(c.isdigit() for c in line):
                            author = line
                            break
                if title:
                    break

    # Filename fallback for title
    if not title:
        import os
        fname = os.path.splitext(os.path.basename(sys.argv[1]))[0]
        title = fname.replace('_', ' ').replace('-', ' ')

    print(f"TITLE={title}")
    print(f"AUTHOR={author}")
except Exception:
    print("TITLE=")
    print("AUTHOR=")
PYEOF
}

# ---------------------------------------------------------------------------
# Translation (Python heredoc) -- block-by-block, code-block aware
# ---------------------------------------------------------------------------
translate_file() {
    local input_file="$1"
    local target_lang="$2"

    python3 - "$input_file" "$target_lang" << 'PYEOF'
import sys
import re

input_file = sys.argv[1]
target_lang = sys.argv[2]

with open(input_file, 'r', encoding='utf-8') as f:
    text = f.read()

# --- Language detection ---
src_lang = None
try:
    from langdetect import detect, DetectorFactory
    DetectorFactory.seed = 0  # deterministic detection
    # Extract a sample of plain text (strip markdown syntax for better detection)
    sample = re.sub(r'[#*`\[\]()!|]', '', text[:5000])
    src_lang = detect(sample)
    print(f"  Detected language: {src_lang}", flush=True)
except ImportError:
    print("  Error: langdetect not installed.", file=sys.stderr)
    print("  Install it:  pip install langdetect", file=sys.stderr)
    print("  Without langdetect, automatic language detection is not possible.", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"  Warning: language detection failed ({e}), cannot auto-detect source language.", file=sys.stderr)
    sys.exit(1)

if src_lang == target_lang:
    print(f"  Document is already in {target_lang}, skipping translation.", flush=True)
    sys.exit(0)

# --- Load Argos Translate ---
try:
    import argostranslate.package
    import argostranslate.translate
except ImportError:
    print("  Error: argos-translate not installed.", file=sys.stderr)
    print("  Install it:  pip install argostranslate", file=sys.stderr)
    sys.exit(1)

# --- Ensure language pack is available ---
installed = argostranslate.package.get_installed_packages()
have_pack = any(p.from_code == src_lang and p.to_code == target_lang for p in installed)

if not have_pack:
    print(f"  Installing {src_lang}->{target_lang} language pack...", flush=True)
    argostranslate.package.update_package_index()
    available = argostranslate.package.get_available_packages()
    pkg = next((p for p in available if p.from_code == src_lang and p.to_code == target_lang), None)
    if not pkg:
        print(f"  Error: No translation package available for {src_lang}->{target_lang}", file=sys.stderr)
        sys.exit(1)
    argostranslate.package.install_from_path(pkg.download())

print(f"  Translating {src_lang}->{target_lang} block by block...", flush=True)

# --- Block-by-block translation ---
# Split on blank lines, skip fenced code blocks.
lines = text.split('\n')
blocks = []       # list of (text, should_translate)
current = []
in_code_fence = False

for line in lines:
    stripped = line.strip()

    # Detect fenced code block boundaries
    if stripped.startswith('```'):
        if in_code_fence:
            # End of code block
            current.append(line)
            blocks.append(('\n'.join(current), False))
            current = []
            in_code_fence = False
        else:
            # Start of code block -- flush current block first
            if current:
                blocks.append(('\n'.join(current), True))
                current = []
            current.append(line)
            in_code_fence = True
        continue

    if in_code_fence:
        current.append(line)
        continue

    # Outside code: blank line = block boundary
    if stripped == '':
        if current:
            blocks.append(('\n'.join(current), True))
            current = []
        blocks.append(('', False))  # preserve blank line
    else:
        current.append(line)

# Flush remaining
if current:
    blocks.append(('\n'.join(current), not in_code_fence))

# Translate each translatable block
translated_parts = []
total = sum(1 for _, t in blocks if t)
done = 0
for content, should_translate in blocks:
    if not should_translate or not content.strip():
        translated_parts.append(content)
    else:
        translated_parts.append(
            argostranslate.translate.translate(content, src_lang, target_lang)
        )
        done += 1
        if total > 1 and done % 10 == 0:
            print(f"  ... {done}/{total} blocks", flush=True)

result = '\n'.join(translated_parts)
with open(input_file, 'w', encoding='utf-8') as f:
    f.write(result)

print(f"  Done ({src_lang}->{target_lang}, {total} blocks translated)", flush=True)
PYEOF
}

# ---------------------------------------------------------------------------
# Image asset handling
#
# Marker emits markdown + extracted images into a temp dir. For md/html/txt
# the temp dir is deleted on exit, orphaning the image references. This
# function copies images next to the output and rewrites references in the
# output file so they resolve.
# ---------------------------------------------------------------------------
preserve_images() {
    local marker_dir="$1"    # directory containing Marker output
    local output_file="$2"   # final output path
    local format="$3"        # output format

    # For epub/docx, Pandoc embeds images from --resource-path. Nothing to do.
    if [[ "$format" == "epub" || "$format" == "docx" ]]; then
        return 0
    fi

    # Find image files Marker may have produced
    local -a images
    mapfile -t images < <(find "$marker_dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.svg' -o -iname '*.webp' \) 2>/dev/null)

    if [[ ${#images[@]} -eq 0 ]]; then
        return 0
    fi

    local output_dir output_base assets_dir
    output_dir="$(dirname "$output_file")"
    output_base="$(basename "$output_file" ".${format}")"
    assets_dir="${output_dir}/${output_base}_images"

    mkdir -p "$assets_dir"

    local img_name
    for img in "${images[@]}"; do
        img_name="$(basename "$img")"
        cp "$img" "${assets_dir}/${img_name}"
    done

    # Rewrite image references in the output file
    # Marker typically uses relative paths from the markdown file's directory.
    # We need to replace those with paths relative to the output.
    if [[ -f "$output_file" ]]; then
        local marker_output_dir
        marker_output_dir="$(dirname "$(find "$marker_dir" -type f \( -name '*.md' -o -name '*.html' \) | head -1)")"

        # Replace any reference to images from the temp dir structure
        # with the new assets dir location.
        local rel_assets="${output_base}_images"
        local tmpfile="${output_file}.img_rewrite"
        # Handle both relative and absolute references to the images
        while IFS= read -r line; do
            for img in "${images[@]}"; do
                img_name="$(basename "$img")"
                # Replace any path ending in this filename with the new relative path
                # Handles: ./images/foo.png, images/foo.png, /tmp/.../foo.png, just foo.png
                line="${line//"$img_name"/"${rel_assets}/${img_name}"}"
            done
            printf '%s\n' "$line"
        done < "$output_file" > "$tmpfile"
        mv "$tmpfile" "$output_file"

        detail "Copied ${#images[@]} image(s) to ${assets_dir}/"
    fi
}

# ---------------------------------------------------------------------------
# Run Marker with robust exit-status capture
# ---------------------------------------------------------------------------
run_marker() {
    local -a marker_args=("$@")
    local marker_exit

    # Run marker_single, capture its real exit status.
    # We use a temp file for status because pipelines hide it.
    local status_file
    status_file="$(mktemp)"

    {
        marker_single "${marker_args[@]}" 2>&1
        echo "$?" > "$status_file"
    } | while IFS= read -r line; do
        # Skip blank lines for cleaner output
        [[ -z "$line" ]] && continue
        detail "marker: $line"
    done

    marker_exit="$(cat "$status_file")"
    rm -f "$status_file"

    if [[ "$marker_exit" -ne 0 ]]; then
        err "Marker exited with status $marker_exit"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
INPUT=""
FORMAT="$DEFAULT_FORMAT"
DO_TRANSLATE=""
TRANSLATE_TO="$DEFAULT_TRANSLATE_TO"
OUTPUT=""
FORCE_OCR=""
USE_LLM=""
TITLE=""
AUTHOR=""

# Handle subcommands before flag parsing
if [[ "${1:-}" == "doctor" || "${1:-}" == "--check" ]]; then
    cmd_doctor
    exit $?
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--format)
            [[ -z "${2:-}" ]] && die "Error: --format requires an argument"
            FORMAT="$2"; shift 2 ;;
        --translate)
            DO_TRANSLATE="yes"; shift ;;
        --translate-to)
            [[ -z "${2:-}" ]] && die "Error: --translate-to requires an argument"
            TRANSLATE_TO="$2"; DO_TRANSLATE="yes"; shift 2 ;;
        -o|--output)
            [[ -z "${2:-}" ]] && die "Error: --output requires an argument"
            OUTPUT="$2"; shift 2 ;;
        --ocr)     FORCE_OCR="yes"; shift ;;
        --llm)     USE_LLM="yes"; shift ;;
        --title)
            [[ -z "${2:-}" ]] && die "Error: --title requires an argument"
            TITLE="$2"; shift 2 ;;
        --author)
            [[ -z "${2:-}" ]] && die "Error: --author requires an argument"
            AUTHOR="$2"; shift 2 ;;
        --config)  show_config; exit 0 ;;
        --check)   cmd_doctor; exit $? ;;
        -h|--help) usage; exit 0 ;;
        -*)        die "Unknown option: $1. Run doc-convert --help for usage." ;;
        *)         INPUT="$1"; shift ;;
    esac
done

if [[ -z "$INPUT" ]]; then
    err "Error: No input file specified."
    usage
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    die "Error: File not found: $INPUT"
fi

# ---------------------------------------------------------------------------
# Derive output filename
# ---------------------------------------------------------------------------
BASENAME="$(basename "$INPUT")"
BASENAME_NOEXT="${BASENAME%.*}"
INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"

case "$FORMAT" in
    md|markdown) EXT="md";   MARKER_FMT="markdown" ;;
    epub)        EXT="epub"; MARKER_FMT="markdown" ;;
    html)        EXT="html"; MARKER_FMT="markdown" ;;
    txt|text)    EXT="txt";  MARKER_FMT="markdown" ;;
    docx)        EXT="docx"; MARKER_FMT="markdown" ;;
    *) die "Unknown format: $FORMAT. Supported: md, epub, html, txt, docx" ;;
esac

# Note: html output uses markdown from Marker, then Pandoc converts to HTML.
# This gives better results than Marker's native HTML output because Pandoc
# produces clean, structured HTML with proper metadata.

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="${INPUT_DIR}/${BASENAME_NOEXT}.${EXT}"
fi

# ---------------------------------------------------------------------------
# Activate venv (only needed for actual conversion, not doctor/help)
# ---------------------------------------------------------------------------
activate_venv

# ---------------------------------------------------------------------------
# Detect Pandoc epub capabilities
# ---------------------------------------------------------------------------
detect_pandoc_split_flag

# ---------------------------------------------------------------------------
# Step 0: Auto-detect metadata from PDF
# ---------------------------------------------------------------------------
if [[ -z "$TITLE" || -z "$AUTHOR" ]]; then
    step "0/3" "Detecting metadata..."
    METADATA="$(extract_metadata "$INPUT")"

    if [[ -z "$TITLE" ]]; then
        TITLE=$(echo "$METADATA" | grep "^TITLE=" | cut -d= -f2-)
    fi
    if [[ -z "$AUTHOR" ]]; then
        AUTHOR=$(echo "$METADATA" | grep "^AUTHOR=" | cut -d= -f2-)
    fi

    [[ -n "$TITLE" ]]  && detail "Title:  $TITLE"
    [[ -n "$AUTHOR" ]] && detail "Author: $AUTHOR"
fi

# ---------------------------------------------------------------------------
# Step 1: OCR with Marker
# ---------------------------------------------------------------------------
step "1/3" "Extracting text with Marker..."
WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$WORK_DIR'" EXIT

MARKER_ARGS=("$INPUT" "--output_dir" "$WORK_DIR" "--output_format" "$MARKER_FMT")
[[ -n "$FORCE_OCR" ]] && MARKER_ARGS+=("--force_ocr")
[[ -n "$USE_LLM" ]]   && MARKER_ARGS+=("--use_llm")

if ! run_marker "${MARKER_ARGS[@]}"; then
    die "Marker failed. Check that marker-pdf is installed and the input file is valid."
fi

# Find marker output
MARKER_OUTPUT=$(find "$WORK_DIR" -type f \( -name "*.md" -o -name "*.html" \) | head -1)

if [[ -z "$MARKER_OUTPUT" || ! -f "$MARKER_OUTPUT" ]]; then
    err "Error: Marker produced no output."
    echo "Contents of temp dir:"
    find "$WORK_DIR" -type f
    exit 1
fi

MARKER_OUTPUT_DIR="$(dirname "$MARKER_OUTPUT")"
MARKER_BYTES="$(wc -c < "$MARKER_OUTPUT" | tr -d ' ')"
ok "  Extracted ${MARKER_BYTES} bytes of text"

# ---------------------------------------------------------------------------
# Step 2: Translate (optional)
# ---------------------------------------------------------------------------
if [[ -n "$DO_TRANSLATE" ]]; then
    step "2/3" "Translating -> ${TRANSLATE_TO}..."
    if ! translate_file "$MARKER_OUTPUT" "$TRANSLATE_TO"; then
        die "Translation failed. Check that argos-translate and langdetect are installed."
    fi
else
    step "2/3" "No translation requested, skipping."
fi

# ---------------------------------------------------------------------------
# Step 3: Convert to final format
# ---------------------------------------------------------------------------
if [[ "$FORMAT" == "md" || "$FORMAT" == "markdown" ]]; then
    step "3/3" "Writing markdown output..."
    cp "$MARKER_OUTPUT" "$OUTPUT"
    preserve_images "$MARKER_OUTPUT_DIR" "$OUTPUT" "md"

elif [[ "$FORMAT" == "txt" || "$FORMAT" == "text" ]]; then
    step "3/3" "Converting to plain text..."
    # Use Pandoc for proper markdown->text conversion if available
    if command -v pandoc &>/dev/null; then
        pandoc "$MARKER_OUTPUT" -t plain -o "$OUTPUT" --wrap=auto 2>&1 || {
            # Fallback to sed-based stripping
            sed 's/^#\+[[:space:]]*/\n/g; s/\*\*//g; s/\*//g; s/`//g' "$MARKER_OUTPUT" > "$OUTPUT"
        }
    else
        sed 's/^#\+[[:space:]]*/\n/g; s/\*\*//g; s/\*//g; s/`//g' "$MARKER_OUTPUT" > "$OUTPUT"
    fi
    preserve_images "$MARKER_OUTPUT_DIR" "$OUTPUT" "txt"

elif [[ "$FORMAT" == "html" ]]; then
    step "3/3" "Converting to HTML with Pandoc..."
    local_pandoc_args=("-f" "markdown" "-t" "html" "-s" "-o" "$OUTPUT")
    [[ -n "$TITLE" ]]  && local_pandoc_args+=("--metadata" "title=${TITLE}")
    [[ -n "$AUTHOR" ]] && local_pandoc_args+=("--metadata" "author=${AUTHOR}")
    local_pandoc_args+=("--resource-path=${MARKER_OUTPUT_DIR}")

    pandoc "$MARKER_OUTPUT" "${local_pandoc_args[@]}" 2>&1
    preserve_images "$MARKER_OUTPUT_DIR" "$OUTPUT" "html"

else
    step "3/3" "Converting to ${FORMAT} with Pandoc..."

    PANDOC_ARGS=("-f" "markdown" "-o" "$OUTPUT")
    [[ -n "$TITLE" ]]  && PANDOC_ARGS+=("--metadata" "title=${TITLE}")
    [[ -n "$AUTHOR" ]] && PANDOC_ARGS+=("--metadata" "author=${AUTHOR}")

    # Resource path so Pandoc can find Marker's extracted images for embedding
    PANDOC_ARGS+=("--resource-path=${MARKER_OUTPUT_DIR}")

    if [[ "$FORMAT" == "epub" ]]; then
        [[ -n "$PANDOC_SPLIT_FLAG" ]] && PANDOC_ARGS+=("$PANDOC_SPLIT_FLAG")
        PANDOC_ARGS+=("--toc" "--toc-depth=2")
        EPUB_CSS="${WORK_DIR}/epub-style.css"
        cat > "$EPUB_CSS" << 'CSS'
body { font-family: Georgia, serif; line-height: 1.6; }
h1 { margin-top: 2em; text-align: center; }
h2 { margin-top: 1.5em; }
p { text-indent: 1.5em; margin: 0.3em 0; }
CSS
        PANDOC_ARGS+=("--css=${EPUB_CSS}")
    fi

    # Try pypandoc first (handles bundled pandoc), fall back to system pandoc
    _MARKER_OUT="$MARKER_OUTPUT" \
    _OUT_FMT="$FORMAT" \
    _OUT_FILE="$OUTPUT" \
    python3 -c "
import pypandoc, sys, os
pypandoc.convert_file(
    os.environ['_MARKER_OUT'],
    os.environ['_OUT_FMT'],
    outputfile=os.environ['_OUT_FILE'],
    extra_args=sys.argv[1:]
)
" "${PANDOC_ARGS[@]}" 2>&1 || {
        detail "pypandoc unavailable, using system pandoc..."
        pandoc "$MARKER_OUTPUT" "${PANDOC_ARGS[@]}" 2>&1
    }
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ ! -f "$OUTPUT" ]]; then
    die "Conversion completed but output file was not created: $OUTPUT"
fi

FILE_SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
ok "Done! ${OUTPUT} (${FILE_SIZE})"
[[ -n "$TITLE" ]]       && detail "Title: ${TITLE}"
[[ -n "$AUTHOR" ]]      && detail "Author: ${AUTHOR}"
[[ -n "$DO_TRANSLATE" ]] && detail "Translated -> ${TRANSLATE_TO}"
