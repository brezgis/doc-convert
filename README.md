# doc-convert

A CLI tool for converting documents (especially scanned PDFs) to markdown, EPUB, HTML, DOCX, or plain text — using GPU-powered neural OCR. Optional auto-translate to any language.

Everything runs locally. Nothing leaves your machine.

## What it does

1. **OCR** — Extracts text from PDFs (including scanned/image-only) using [Marker](https://github.com/VikParuchuri/marker) with [Surya](https://github.com/VikParuchuri/surya) neural OCR on GPU
2. **Translate** *(optional)* — Auto-detects source language and translates to your target language using [Argos Translate](https://github.com/argosopentech/argos-translate) (local neural MT)
3. **Convert** — Outputs to your desired format via [Pandoc](https://pandoc.org/) with auto-detected metadata (title, author), table of contents, and proper styling

## Quick start

```bash
# PDF → Markdown (default)
doc-convert paper.pdf

# Scanned book → EPUB with OCR
doc-convert book.pdf -f epub --ocr

# Russian PDF → English markdown
doc-convert russian-paper.pdf --translate

# Auto-detect language → English EPUB
doc-convert article.pdf -f epub --translate

# Force OCR + LLM-enhanced accuracy
doc-convert old-scan.pdf -f epub --ocr --llm
```

## Installation

### Prerequisites

- **Python 3.10+**
- **NVIDIA GPU** with CUDA (for Marker/Surya OCR). CPU-only is possible but very slow.
- **Pandoc** (`apt install pandoc` or `brew install pandoc`)

### Setup

```bash
# Create a virtualenv for marker-pdf
python3 -m venv ~/marker-env
source ~/marker-env/bin/activate

# Install dependencies
pip install marker-pdf pypandoc PyMuPDF

# Optional: translation support
pip install argos-translate langdetect

# Install the script
chmod +x doc-convert.sh
cp doc-convert.sh ~/.local/bin/doc-convert
```

By default, the script looks for the marker venv at `~/marker-env`. Override with:

```bash
export DOC_CONVERT_VENV=/path/to/your/marker-env
```

## Options

| Flag | Description |
|------|-------------|
| `-f, --format FORMAT` | Output format: `md`, `epub`, `html`, `txt`, `docx` (default: `md`) |
| `--translate` | Auto-detect language and translate to English |
| `--translate-to LANG` | Set target language (ISO 639-1 code, e.g. `ru`, `es`, `fr`) |
| `-o, --output PATH` | Output file path (default: auto-named next to input) |
| `--ocr` | Force OCR on all pages (for scanned/image PDFs) |
| `--llm` | Use LLM for higher OCR accuracy (slower) |
| `--title TITLE` | Set document title (auto-detected from PDF metadata if not set) |
| `--author AUTHOR` | Set author name (auto-detected if not set) |
| `--config` | Show/edit persistent settings |
| `-h, --help` | Show help |

## Configuration

Persistent settings live at `~/.config/doc-convert/settings.conf`:

```bash
# Default target language for --translate
DEFAULT_TRANSLATE_TO="en"

# Default output format
DEFAULT_FORMAT="md"
```

Run `doc-convert --config` to create or view the config file.

## How it works

**Marker** is the heavy lifter — it uses Surya's neural OCR models to extract text from PDFs, handling scanned documents, complex layouts, tables, and equations. It runs on GPU (CUDA) for speed.

**Pandoc** handles format conversion. For EPUBs, doc-convert auto-detects title and author from PDF metadata (or first-page text), generates a table of contents, and applies clean typography.

**Argos Translate** provides local neural machine translation between 30+ language pairs. No API keys, no cloud services.

### Large scanned PDFs

For books over ~100 pages, Marker may run out of VRAM. The workaround is chunked processing:

```bash
# Split into chunks (requires pdftk or qpdf)
qpdf --split-pages=25 big-book.pdf chunk_%d.pdf

# Convert each chunk
for f in chunk_*.pdf; do
    doc-convert "$f" --ocr
done

# Merge the markdown
cat chunk_*.md > full-book.md

# Convert merged output to EPUB
doc-convert full-book.md -f epub --title "Book Title" --author "Author Name"
```

## Supported formats

| Input | Output |
|-------|--------|
| PDF (native text) | Markdown |
| PDF (scanned/image) | EPUB |
| PPTX, DOCX | HTML |
| Any Marker-supported format | Plain text |
| | DOCX |

## Dependencies

| Package | Purpose | Required? |
|---------|---------|-----------|
| [marker-pdf](https://github.com/VikParuchuri/marker) | OCR + text extraction | Yes |
| [pypandoc](https://github.com/JessicaTegworthy/pypandoc) | Format conversion | Yes |
| [PyMuPDF](https://pymupdf.readthedocs.io/) | PDF metadata extraction | Yes |
| [argos-translate](https://github.com/argosopentech/argos-translate) | Local neural translation | Only for `--translate` |
| [langdetect](https://github.com/Mimino666/langdetect) | Language detection | Only for `--translate` |

## License

MIT
