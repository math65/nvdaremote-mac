#!/bin/bash
# Renders a Markdown release-notes file to HTML with pandoc and
# release-notes-template.html (light and dark mode), for Sparkle's update dialog.
#
# Usage: scripts/render-release-notes.sh <input.md> <output.html> [lang]
#
# [lang] goes into <html lang="…"> so VoiceOver reads the notes with the right
# voice. Defaults to "en".
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "Usage: $0 <input.md> <output.html> [lang]" >&2
	exit 2
fi

SRC="$1"
DST="$2"
LANG_CODE="${3:-en}"
TEMPLATE="$(cd "$(dirname "$0")" && pwd)/release-notes-template.html"

command -v pandoc >/dev/null || { echo "pandoc not found. Install it with: brew install pandoc" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "Source file not found: $SRC" >&2; exit 1; }

pandoc \
	--from=gfm \
	--to=html5 \
	--standalone \
	--template="$TEMPLATE" \
	--metadata title="$(basename "${DST%.html}")" \
	--metadata lang="$LANG_CODE" \
	--output "$DST" \
	"$SRC"

echo "Rendered $SRC -> $DST"
