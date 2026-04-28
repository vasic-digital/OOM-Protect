#!/usr/bin/env bash
# build-docs.sh
#
# Convert every markdown document in this toolkit to standalone HTML and PDF.
#
# Inputs:
#   ~/Downloads/Crash_Report.md
#   ~/Downloads/manuals/oom-hardening-manual.md
#   ~/Downloads/manuals/oom-runner-manual.md
#
# Outputs (placed beside each .md):
#   <name>.html   — standalone HTML, CSS embedded, viewable in any browser
#   <name>.pdf    — PDF rendered from the HTML via weasyprint (preferred) or
#                   chromium --headless --print-to-pdf (fallback)
#
# Tools used:
#   - pandoc       (markdown → HTML, with TOC, smart typography, syntax hl)
#   - weasyprint   (HTML → PDF, CSS-paged-media-aware) — preferred
#   - chromium     (HTML → PDF) — fallback if weasyprint fails
#
# Re-run any time. Idempotent. Safe.

set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "$0")" && pwd)"

# CSS may live in assets/ or reports/assets/ depending on directory layout.
if   [[ -f "$ROOT/assets/style.css" ]];          then CSS="$ROOT/assets/style.css"
elif [[ -f "$ROOT/reports/assets/style.css" ]];  then CSS="$ROOT/reports/assets/style.css"
else CSS="$ROOT/assets/style.css"   # let it fail with a clear message later
fi
readonly CSS

if [[ -t 1 ]]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; C=$'\033[0m'
else
    G=""; Y=""; R=""; D=""; C=""
fi
say()  { printf '%s[build-docs]%s %s\n' "$D" "$C" "$*"; }
ok()   { printf '%s[build-docs]%s %s\n' "$G" "$C" "$*"; }
warn() { printf '%s[build-docs]%s %s\n' "$Y" "$C" "$*" >&2; }
err()  { printf '%s[build-docs]%s %s\n' "$R" "$C" "$*" >&2; }
die()  { err "$*"; exit 1; }

# -------- locate tools --------------------------------------------------------

find_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    # Fallback: try ~/.local/bin
    if [[ -x "$HOME/.local/bin/$name" ]]; then
        printf '%s\n' "$HOME/.local/bin/$name"
        return 0
    fi
    return 1
}

PANDOC="$(find_tool pandoc || true)"
WEASYPRINT="$(find_tool weasyprint || true)"
CHROMIUM="$(find_tool chromium || find_tool chromium-browser || find_tool google-chrome || true)"

[[ -n "$PANDOC" ]] || die "pandoc not found. Install: sudo apt-get install pandoc"
[[ -f "$CSS" ]] || die "stylesheet missing: $CSS"

if [[ -z "$WEASYPRINT" ]] && [[ -z "$CHROMIUM" ]]; then
    die "Need either weasyprint or chromium for PDF conversion."
fi

say "pandoc:     $PANDOC ($($PANDOC --version | awk 'NR==1{print $2}'))"
say "weasyprint: ${WEASYPRINT:-none}"
say "chromium:   ${CHROMIUM:-none}"
say "stylesheet: $CSS"
echo

# -------- conversion functions ------------------------------------------------

md_to_html() {
    local md="$1" html="$2"
    say "  pandoc → $(basename "$html")"
    "$PANDOC" \
        --from=markdown+smart+pipe_tables+yaml_metadata_block+fenced_code_blocks+fenced_code_attributes \
        --to=html5 \
        --embed-resources --standalone \
        --toc --toc-depth=3 \
        --section-divs \
        --syntax-highlighting=tango \
        --metadata=lang:en \
        --css="$CSS" \
        --output="$html" \
        "$md"
}

html_to_pdf_weasyprint() {
    local html="$1" pdf="$2"
    say "  weasyprint → $(basename "$pdf")"
    "$WEASYPRINT" --quiet "$html" "$pdf" 2>/tmp/weasy-err.log || {
        warn "  weasyprint failed:"
        sed 's/^/    /' /tmp/weasy-err.log >&2 || true
        return 1
    }
}

html_to_pdf_chromium() {
    local html="$1" pdf="$2"
    say "  chromium --headless → $(basename "$pdf")"
    local tmpdir
    tmpdir="$(mktemp -d)"
    "$CHROMIUM" \
        --headless \
        --disable-gpu \
        --no-sandbox \
        --no-pdf-header-footer \
        --user-data-dir="$tmpdir" \
        --print-to-pdf="$pdf" \
        "file://$html" \
        >/dev/null 2>&1 || {
            rm -rf "$tmpdir"
            warn "  chromium failed"
            return 1
        }
    rm -rf "$tmpdir"
}

build_doc() {
    local md="$1"
    [[ -f "$md" ]] || { warn "skip (missing): $md"; return 0; }

    local base="${md%.md}"
    local html="${base}.html"
    local pdf="${base}.pdf"

    say "Building: $(basename "$md")"
    md_to_html "$md" "$html"

    if [[ -n "$WEASYPRINT" ]] && html_to_pdf_weasyprint "$html" "$pdf"; then
        :
    elif [[ -n "$CHROMIUM" ]] && html_to_pdf_chromium "$html" "$pdf"; then
        :
    else
        warn "  PDF generation failed for $md (HTML still produced)"
    fi

    if [[ -f "$html" ]] && [[ -f "$pdf" ]]; then
        local hsz psz
        hsz="$(du -h "$html" | awk '{print $1}')"
        psz="$(du -h "$pdf"  | awk '{print $1}')"
        ok "  $hsz HTML, $psz PDF"
    fi
    echo
}

# -------- main ----------------------------------------------------------------

# Build the doc list dynamically — pick whichever location each file lives in.
DOCS=()
for cand in \
    "$ROOT/README.md" \
    "$ROOT/Crash_Report.md" "$ROOT/reports/Crash_Report.md" \
    "$ROOT/manuals/oom-hardening-manual.md" \
    "$ROOT/manuals/oom-runner-manual.md"
do
    [[ -f "$cand" ]] && DOCS+=("$cand")
done

[[ "${1:-}" == "--list" ]] && { printf '%s\n' "${DOCS[@]}"; exit 0; }

ok "Building ${#DOCS[@]} document(s)"
echo

for md in "${DOCS[@]}"; do
    build_doc "$md"
done

ok "Done. Outputs:"
for md in "${DOCS[@]}"; do
    base="${md%.md}"
    [[ -f "${base}.html" ]] && echo "  ${base}.html"
    [[ -f "${base}.pdf"  ]] && echo "  ${base}.pdf"
done
