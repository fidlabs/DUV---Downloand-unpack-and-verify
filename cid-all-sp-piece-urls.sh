#!/usr/bin/env bash
# List every retrieval URL for a piece CID across all SPs returned by filecoin.tools (paginated search).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_BASE="${FILECOIN_TOOLS_API:-https://api.filecoin.tools/api}"
SEARCH_PAGE_LIMIT="${SEARCH_PAGE_LIMIT:-100}"

# shellcheck source=lib_piece_endpoints.sh
source "$SCRIPT_DIR/lib_piece_endpoints.sh"

usage() {
  cat <<EOF
Usage: $0 [options] PIECE_CID

  Paginates GET ${API_BASE}/search?filter=PIECE_CID&limit=SEARCH_PAGE_LIMIT&page=…,
  collects unique providerIds, then for each SP resolves HTTP bases (cid.contact + Lotus)
  and builds piece URLs: {base}/piece/{PIECE_CID}.

  Prints JSON to stdout:
    { "data": [ { "providerId": "f0…", "pieceUrls": [ { "providerEndpoint", "pieceUrl" }, … ] }, … ] }

Options:
  -c, --compact   Single-line JSON (jq -c)
  -h, --help      Show this help

Environment:
  FILECOIN_TOOLS_API   API base (default https://api.filecoin.tools/api)
  SEARCH_PAGE_LIMIT    Page size for search (default 100)
  LOTUS_RPC, CID_CONTACT_BASE  Same as cid-to-download.sh
EOF
}

err() { printf "%s\n" "$*" >&2; }

COMPACT=false
PIECE_CID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -c|--compact) COMPACT=true; shift ;;
    -*)
      err "Unknown option: $1"; usage; exit 1 ;;
    *)
      [[ -z "$PIECE_CID" ]] || { err "Unexpected argument: $1"; exit 1; }
      PIECE_CID="$1"
      shift
      ;;
  esac
done

[[ -n "$PIECE_CID" ]] || { usage; exit 1; }

command -v curl >/dev/null 2>&1 || { err "curl required"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq required"; exit 1; }

# Collect unique f0-prefixed provider IDs from all search pages
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

page=1
while true; do
  json="$(
    curl -sS --connect-timeout 20 --max-time 90 -G "${API_BASE}/search" \
      --data-urlencode "page=$page" \
      --data-urlencode "limit=$SEARCH_PAGE_LIMIT" \
      --data-urlencode "filter=${PIECE_CID}" \
      -H 'accept: */*'
  )" || exit 1

  n="$(jq '.data | length' <<<"$json")"
  [[ "$n" =~ ^[0-9]+$ ]] || { err "Invalid search response"; exit 1; }
  [[ "$n" -eq 0 ]] && break

  jq -r '.data[].providerId' <<<"$json" >>"$tmp"

  [[ "$n" -lt "$SEARCH_PAGE_LIMIT" ]] && break
  page=$((page + 1))
done

providers=()
while read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^f0[0-9]+$ ]] || line="f0${line#f0}"
  providers+=("$line")
done < <(sort -u "$tmp")

if [[ ${#providers[@]} -eq 0 ]]; then
  if [[ "$COMPACT" == true ]]; then
    echo '{"data":[]}'
  else
    jq -n '{data:[]}'
  fi
  exit 0
fi

# One JSON object per provider (compact line) → slurp into { data: [...] }
entries_tmp="$(mktemp)"
trap 'rm -f "$tmp" "$entries_tmp"' EXIT

for provider in "${providers[@]}"; do
  miner_info="$(get_miner_info "$provider")"
  peer_id="$(jq -r '.result.PeerId // empty' <<<"$miner_info")"

  endpoints=()
  if [[ -n "$peer_id" ]]; then
    while IFS= read -r ep; do [[ -n "$ep" ]] && endpoints+=("$ep"); done < <(get_provider_http_endpoints_from_cid_contact "$peer_id")
  fi
  if [[ ${#endpoints[@]} -eq 0 ]]; then
    while IFS= read -r ep; do [[ -n "$ep" ]] && endpoints+=("$ep"); done < <(get_provider_http_endpoints_from_lotus "$miner_info")
  fi

  if [[ ${#endpoints[@]} -eq 0 ]]; then
    jq -cn --arg pid "$provider" --arg cid "$PIECE_CID" \
      '{providerId: $pid, pieceUrls: []}' >>"$entries_tmp"
  else
    # Pass endpoints as JSON array (--argjson); avoid --args (breaks on some jq: URLs parsed as filter).
    eps_json="$(printf '%s\n' "${endpoints[@]}" | jq -R . | jq -s -c .)"
    jq -cn --arg pid "$provider" --arg cid "$PIECE_CID" --argjson eps "$eps_json" \
      '$eps
        | map(. as $raw | ($raw | rtrimstr("/")) as $base
        | {providerEndpoint: $base, pieceUrl: ($base + "/piece/" + $cid)})
        | {providerId: $pid, pieceUrls: .}' >>"$entries_tmp"
  fi
done

# Read NDJSON from file via stdin so the path is never mistaken for a filter (portable across jq builds).
if [[ "$COMPACT" == true ]]; then
  jq -s -c '{data: .}' <"$entries_tmp"
else
  jq -s '{data: .}' <"$entries_tmp"
fi
