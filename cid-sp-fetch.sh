#!/usr/bin/env bash
# Look up a piece CID on filecoin.tools, pick a random deal, then download that piece from the chosen SP.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_BASE="${FILECOIN_TOOLS_API:-https://api.filecoin.tools/api}"

usage() {
  cat <<EOF
Usage: $0 [options] PIECE_CID [OUTPUT_DIR]

  1. GET ${API_BASE}/search?page=1&limit=10&filter=PIECE_CID
  2. Randomly choose one entry from .data[]
  3. Build retrieval URL: http(s)://<SP-endpoint>/piece/<PIECE_CID> (Lotus + cid.contact, same as cid-to-download.sh)
  4. Download the .car into OUTPUT_DIR (default: ./output)

Options:
  --sp-tool       Skip direct piece URL; only run sp-tool-fetch.sh (allocator API)
  --sp-fallback   If direct /piece/ download fails, run sp-tool-fetch.sh (see note below)
  -h, --help      Show this help

Note: sp-tool-fetch returns a URL for the client, not necessarily THIS piece CID.
      Prefer re-running this script (another random SP) or fixing direct retrieval.
      Direct download now tries every HTTP endpoint for the chosen SP before failing.

Environment:
  FILECOIN_TOOLS_API  Override API base (default: https://api.filecoin.tools/api)

After a direct download, unpack with:
  ./sp-tool-fetch.sh --unpack-only OUTPUT_DIR/<piece_cid>.car --dir OUTPUT_DIR
EOF
}

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

USE_SP_TOOL_ONLY=false
SP_TOOL_FALLBACK=false
PIECE_CID=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sp-tool) USE_SP_TOOL_ONLY=true; shift ;;
    --sp-fallback) SP_TOOL_FALLBACK=true; shift ;;
    -*)
      fail "Unknown option: $1 (try --help)"
      ;;
    *)
      if [[ -z "$PIECE_CID" ]]; then
        PIECE_CID="$1"
      elif [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$1"
      else
        fail "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$PIECE_CID" ]] || { usage; exit 1; }
OUTPUT_DIR="${OUTPUT_DIR:-./output}"

command -v curl >/dev/null 2>&1 || fail "curl required"
command -v jq >/dev/null 2>&1 || fail "jq required"
[[ -f "$SCRIPT_DIR/sp-tool-fetch.sh" ]] || fail "sp-tool-fetch.sh not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_DIR/cid-to-download.sh" ]] || fail "cid-to-download.sh not found in $SCRIPT_DIR (needed for piece URL + download)"

log "Searching filecoin.tools for: $PIECE_CID"
JSON="$(
  curl -sS --connect-timeout 20 --max-time 60 -G "${API_BASE}/search" \
    --data-urlencode "page=1" \
    --data-urlencode "limit=10" \
    --data-urlencode "filter=${PIECE_CID}" \
    -H 'accept: */*'
)" || fail "curl failed"

COUNT="$(jq '.data | length' <<<"$JSON")"
[[ "$COUNT" =~ ^[0-9]+$ ]] || fail "Invalid JSON from API"
(( COUNT > 0 )) || fail "No deals returned for this CID (empty .data)"

IDX=$((RANDOM % COUNT))
log "Picked deal $((IDX + 1)) of $COUNT (random index $IDX)"

PROVIDER="$(jq -r --argjson i "$IDX" '.data[$i].providerId // empty' <<<"$JSON")"
CLIENT="$(jq -r --argjson i "$IDX" '.data[$i].clientId // empty' <<<"$JSON")"
[[ -n "$PROVIDER" && "$PROVIDER" != "null" ]] || fail "Missing providerId in chosen deal"
[[ -n "$CLIENT" && "$CLIENT" != "null" ]] || fail "Missing clientId in chosen deal"

[[ "$PROVIDER" =~ ^f0[0-9]+$ ]] || PROVIDER="f0${PROVIDER#f0}"
[[ "$CLIENT" =~ ^f0[0-9]+$ ]] || CLIENT="f0${CLIENT#f0}"

log "Using provider=$PROVIDER client=$CLIENT dir=$OUTPUT_DIR"

if [[ "$USE_SP_TOOL_ONLY" == "true" ]]; then
  exec bash "$SCRIPT_DIR/sp-tool-fetch.sh" --client "$CLIENT" --provider "$PROVIDER" --dir "$OUTPUT_DIR"
fi

# Direct piece URL includes PIECE_CID: {base}/piece/{PIECE_CID}
log "Resolving SP HTTP endpoint and downloading piece (cid-to-download.sh --provider … --download …)"
if bash "$SCRIPT_DIR/cid-to-download.sh" "$PIECE_CID" --provider "$PROVIDER" --client "$CLIENT" --download "$OUTPUT_DIR"; then
  exit 0
fi
if [[ "$SP_TOOL_FALLBACK" == "true" ]]; then
  log "Direct piece download failed; --sp-fallback: invoking sp-tool-fetch.sh (piece CID may differ from requested)"
  exec bash "$SCRIPT_DIR/sp-tool-fetch.sh" --client "$CLIENT" --provider "$PROVIDER" --dir "$OUTPUT_DIR"
fi
log "Direct download failed for all endpoints on this SP. Re-run to pick another random deal, or use --sp-fallback (allocator may fetch a different piece)."
exit 1
