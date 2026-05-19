#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP_PATH="${1:-$ROOT/dump.html}"
OUT_DIR="${SYNOLOGY_CHAT_REFERENCE_DIR:-$ROOT/reference/synology-chat/cache}"

if [[ ! -f "$DUMP_PATH" ]]; then
  echo "Missing dump file: $DUMP_PATH" >&2
  exit 1
fi

BASE_URL="${SYNOLOGY_CHAT_BASE_URL:-}"
if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(
    perl -0ne 'if (m{https?://[^/"'"'"'<>[:space:]]+}i) { print $&; exit }' "$DUMP_PATH"
  )"
fi

if [[ -z "$BASE_URL" ]]; then
  echo "Could not infer server URL from dump. Set SYNOLOGY_CHAT_BASE_URL=https://host:port." >&2
  exit 1
fi

mkdir -p "$OUT_DIR/files"
: > "$OUT_DIR/manifest.tsv"
: > "$OUT_DIR/errors.log"

resolve_url() {
  local href="$1"
  href="${href//&amp;/&}"

  case "$href" in
    http://*|https://*) printf '%s\n' "$href" ;;
    //*) printf 'https:%s\n' "$href" ;;
    /*) printf '%s%s\n' "$BASE_URL" "$href" ;;
    ./*) printf '%s/%s\n' "$BASE_URL" "${href#./}" ;;
    *) printf '%s/%s\n' "$BASE_URL" "$href" ;;
  esac
}

local_path_for_url() {
  local url="$1"
  local path
  path="$(printf '%s\n' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/?##; s/[?#].*$//; s#^/+##')"
  path="${path#./}"
  if [[ -z "$path" || "$path" == */ ]]; then
    path="${path}index"
  fi
  printf '%s/files/%s\n' "$OUT_DIR" "$path"
}

fetch_one() {
  local url="$1"
  local dest
  dest="$(local_path_for_url "$url")"

  mkdir -p "$(dirname "$dest")"
  if curl -k -L --fail --silent --show-error --max-time 30 "$url" -o "$dest"; then
    printf '%s\t%s\n' "$url" "${dest#$ROOT/}" >> "$OUT_DIR/manifest.tsv"
  else
    printf '%s\n' "$url" >> "$OUT_DIR/errors.log"
    rm -f "$dest"
  fi
}

tmp_urls="$(mktemp)"
tmp_asset_urls="$(mktemp)"
trap 'rm -f "$tmp_urls" "$tmp_asset_urls"' EXIT

perl -0ne '
  while (/<(?:link|script)\b[^>]*(?:href|src)="([^"]+)"/g) {
    my $url = $1;
    $url =~ s/&amp;/&/g;
    next unless $url =~ /\.(?:css|js)(?:[?#]|$)/i;
    print "$url\n";
  }
' "$DUMP_PATH" | sort -u > "$tmp_urls"

while IFS= read -r href; do
  [[ -z "$href" ]] && continue
  fetch_one "$(resolve_url "$href")"
done < "$tmp_urls"

while IFS=$'\t' read -r source local_file; do
  [[ "$local_file" == *.css ]] || continue
  css_path="$ROOT/$local_file"
  css_base="$(dirname "$source")"

  perl -0ne '
    while (/url\((?:"([^"]+)"|'\''([^'\'']+)'\''|([^)]*?))\)/g) {
      my $url = defined $1 ? $1 : defined $2 ? $2 : $3;
      $url =~ s/^\s+|\s+$//g;
      next if $url =~ /^(?:data:|#|about:)/i;
      next unless $url =~ m{images/(?:common|icon)/}i;
      print "$url\n";
    }
  ' "$css_path" | sort -u | while IFS= read -r asset; do
    [[ -z "$asset" ]] && continue
    case "$asset" in
      http://*|https://*|//*) resolved="$(resolve_url "$asset")" ;;
      /*) resolved="$(resolve_url "$asset")" ;;
      *) resolved="$css_base/$asset" ;;
    esac
    printf '%s\n' "$resolved"
  done >> "$tmp_asset_urls"
done < "$OUT_DIR/manifest.tsv"

sort -u "$tmp_asset_urls" | while IFS= read -r asset_url; do
  [[ -z "$asset_url" ]] && continue
  fetch_one "$asset_url"
done

echo "Cached $(wc -l < "$OUT_DIR/manifest.tsv" | tr -d ' ') assets in ${OUT_DIR#$ROOT/}"
if [[ -s "$OUT_DIR/errors.log" ]]; then
  echo "Some assets failed to download. See ${OUT_DIR#$ROOT/}/errors.log" >&2
fi
