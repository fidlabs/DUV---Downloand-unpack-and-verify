#!/usr/bin/env bash
# CID-to-download: Find download URL for a Filecoin piece CID and optionally fetch it.
#
# Flow:
#   1. Lookup piece CID → (provider, client) via filecoin.tools (no IPNI)
#   2. Get provider HTTP endpoints via Lotus StateMinerInfo + cid.contact/providers
#   3. Build direct piece URL: {endpoint}/piece/{piece_cid}
#   4. Output URL for wget/curl, or optionally invoke sp-tool-fetch.sh
#
set -Eeuo pipefail

# ---------- Config ----------
FILECOIN_TOOLS_API="${FILECOIN_TOOLS_API:-https://api.filecoin.tools/api}"
LOTUS_RPC="${LOTUS_RPC:-https://api.node.glif.io/rpc/v1}"
CID_CONTACT_BASE="${CID_CONTACT_BASE:-https://cid.contact}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_piece_endpoints.sh
source "$SCRIPT_DIR/lib_piece_endpoints.sh"

# ---------- Utils ----------
log()  { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage:
  $0 PIECE_CID [options]

  Look up a Filecoin piece CID and find/download its content.

Options:
  --url-only          Only print the first working URL (for wget/curl)
  --all-urls          Print all candidate URLs
  --download DIR      Download the piece into DIR (uses wget/curl)
  --use-sp-tool       Use sp-tool-fetch.sh when client+provider are known (needs --download)
  --client ID         Override client address (e.g. f01234) for --use-sp-tool
  --provider ID       Override provider address (e.g. f05678) - skip CID lookup
  --no-filecoin-tools Skip filecoin.tools lookup (use storacha/cid.contact only)
  -h, --help          Show this help

Lookup order (no IPNI): filecoin.tools API → storacha CLI → cid.contact/cid (if --no-filecoin-tools not set)

Examples:
  $0 baga6ea4seaqoswuzhosh2egrvdhfczfgxcah3maweujwf2c63b2ffpsp4aktwma --url-only
  $0 baga6ea4seaqoswuzhosh2egrvdhfczfgxcah3maweujwf2c63b2ffpsp4aktwma --download ./output
  $0 baga6ea4seaqoswuzhosh2egrvdhfczfgxcah3maweujwf2c63b2ffpsp4aktwma --use-sp-tool --download ./output
EOF
}

# ---------- Lookup: Piece CID → Provider (and Client) ----------

# Try filecoin.tools API (no IPNI)
# API: GET /api/search?filter=<piece_cid> returns {data: [{providerId, clientId, ...}]}
lookup_via_filecoin_tools() {
  local cid="$1"
  local json
  json="$(curl -sS --connect-timeout 15 --max-time 30 \
    "${FILECOIN_TOOLS_API}/search?filter=${cid}" 2>/dev/null)" || return 1
  [[ -z "$json" || "$json" == "{}" ]] && return 1
  # Parse: .data[0].providerId, .data[0].clientId
  local provider client
  provider="$(jq -r '.data[0].providerId // .data[0].provider_id // empty' <<<"$json" 2>/dev/null)"
  client="$(jq -r '.data[0].clientId // .data[0].client_id // empty' <<<"$json" 2>/dev/null)"
  [[ -z "$provider" || "$provider" == "null" ]] && return 1
  # Ensure f0 prefix (API returns numeric IDs like "3099101")
  [[ "$provider" =~ ^[0-9]+$ ]] && provider="f0${provider}"
  [[ -n "$client" && "$client" =~ ^[0-9]+$ ]] && client="f0${client}"
  printf '%s\t%s\n' "$provider" "${client:-}"
  return 0
}

# Try storacha CLI: storacha can filecoin info <piece-cid>
lookup_via_storacha() {
  local cid="$1"
  have storacha || return 1
  local out
  out="$(storacha can filecoin info "$cid" 2>/dev/null)" || return 1
  # Output format: "Provider: 1392893" -> f01392893
  local provider
  provider="$(echo "$out" | grep -iE '^\s*Provider:\s*[0-9]+' | head -1 | sed -n 's/.*Provider:\s*\([0-9]*\).*/\1/p')"
  [[ -z "$provider" ]] && return 1
  printf 'f0%s\t\n' "$provider"
  return 0
}

# Fallback: cid.contact/cid/{cid} (indexer - user prefers to avoid, but last resort)
lookup_via_cid_contact() {
  local cid="$1"
  [[ "${USE_CID_CONTACT_LOOKUP:-1}" == "0" ]] && return 1
  local json
  json="$(curl -sS --connect-timeout 10 --max-time 20 \
    "${CID_CONTACT_BASE}/cid/${cid}" 2>/dev/null)" || return 1
  [[ -z "$json" ]] && return 1
  # Parse provider metadata - structure varies
  local provider
  provider="$(jq -r '.MultihashResults[0].ProviderResults[0].Provider.ID // .Providers[0].ID // empty' <<<"$json" 2>/dev/null)"
  [[ -z "$provider" || "$provider" == "null" ]] && return 1
  printf '%s\t\n' "$provider"
  return 0
}

# ---------- Main ----------
main() {
  have curl || fail "curl required"
  have jq || fail "jq required"

  local PIECE_CID=""
  local URL_ONLY=false
  local ALL_URLS=false
  local DOWNLOAD_DIR=""
  local USE_SP_TOOL=false
  local NO_FILECOIN_TOOLS=false
  local OVERRIDE_CLIENT=""
  local OVERRIDE_PROVIDER=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url-only)       URL_ONLY=true; shift ;;
      --all-urls)       ALL_URLS=true; shift ;;
      --download)       DOWNLOAD_DIR="${2:-}"; shift 2 ;;
      --use-sp-tool)    USE_SP_TOOL=true; shift ;;
      --client)         OVERRIDE_CLIENT="${2:-}"; shift 2 ;;
      --provider)       OVERRIDE_PROVIDER="${2:-}"; shift 2 ;;
      --no-filecoin-tools) NO_FILECOIN_TOOLS=true; shift ;;
      -h|--help)        usage; exit 0 ;;
      -*)               fail "Unknown option: $1" ;;
      *)
        if [[ -z "$PIECE_CID" ]]; then
          PIECE_CID="$1"
        else
          fail "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -z "$PIECE_CID" ]] && { usage; fail "Missing PIECE_CID"; }

  local provider client
  provider="" client=""

  # If provider override: skip CID lookup
  if [[ -n "$OVERRIDE_PROVIDER" ]]; then
    provider="$OVERRIDE_PROVIDER"
    client="${OVERRIDE_CLIENT:-}"
    log "Using provided provider=$provider client=${client:-<none>}"
  fi

  # Step 1: Lookup piece CID → provider (and client) unless overridden
  if [[ -z "$provider" ]]; then
    log "Looking up piece CID: $PIECE_CID"
  fi

  if [[ -z "$provider" && "$NO_FILECOIN_TOOLS" != "true" ]]; then
    local lookup_result
    if lookup_result="$(lookup_via_filecoin_tools "$PIECE_CID" 2>/dev/null)"; then
      provider="$(echo "$lookup_result" | cut -f1)"
      client="$(echo "$lookup_result" | cut -f2)"
      log "Found via filecoin.tools: provider=$provider client=${client:-<none>}"
    fi
  fi

  if [[ -z "$provider" ]] && lookup_result="$(lookup_via_storacha "$PIECE_CID" 2>/dev/null)"; then
    provider="$(echo "$lookup_result" | cut -f1)"
    client="$(echo "$lookup_result" | cut -f2)"
    log "Found via storacha: provider=$provider client=${client:-<none>}"
  fi

  if [[ -z "$provider" ]] && lookup_result="$(lookup_via_cid_contact "$PIECE_CID" 2>/dev/null)"; then
    provider="$(echo "$lookup_result" | cut -f1)"
    client="$(echo "$lookup_result" | cut -f2)"
    log "Found via cid.contact: provider=$provider"
  fi

  # Apply overrides
  [[ -n "$OVERRIDE_CLIENT" ]] && client="$OVERRIDE_CLIENT"

  [[ -z "$provider" ]] && fail "Could not find provider for piece CID. Try: storacha can filecoin info $PIECE_CID. Or pass --provider f0XXX if known."

  # Step 2: Get provider HTTP endpoints
  log "Getting HTTP endpoints for provider $provider"
  local miner_info peer_id
  miner_info="$(get_miner_info "$provider")" || fail "Failed to get miner info for $provider"
  peer_id="$(jq -r '.result.PeerId // empty' <<<"$miner_info")"
  [[ -z "$peer_id" ]] && fail "No peer ID for provider $provider"

  local endpoints
  endpoints=()
  # Try cid.contact first (has explicit HTTP multiaddrs)
  while IFS= read -r ep; do [[ -n "$ep" ]] && endpoints+=("$ep"); done < <(get_provider_http_endpoints_from_cid_contact "$peer_id")
  # Fallback: Lotus Multiaddrs (ip4+tcp; retrieval often on same port)
  if [[ ${#endpoints[@]} -eq 0 ]]; then
    log "cid.contact has no data for this provider; trying Lotus Multiaddrs"
    while IFS= read -r ep; do [[ -n "$ep" ]] && endpoints+=("$ep"); done < <(get_provider_http_endpoints_from_lotus "$miner_info")
  fi

  [[ ${#endpoints[@]} -eq 0 ]] && fail "No HTTP endpoints found for provider $provider (peer $peer_id). Try: --use-sp-tool --client $client --download DIR"

  # Step 3: Build piece URLs
  local urls=()
  for ep in "${endpoints[@]}"; do
    urls+=("${ep%/}/piece/${PIECE_CID}")
  done

  log "Built ${#urls[@]} candidate URL(s)"

  # Step 4: Use sp-tool path if requested and we have client
  if [[ "$USE_SP_TOOL" == "true" && -n "$client" && -n "$DOWNLOAD_DIR" ]]; then
    if [[ -f "$SCRIPT_DIR/sp-tool-fetch.sh" ]]; then
      log "Invoking sp-tool-fetch.sh --client $client --provider $provider --dir $DOWNLOAD_DIR"
      exec "$SCRIPT_DIR/sp-tool-fetch.sh" --client "$client" --provider "$provider" --dir "$DOWNLOAD_DIR"
    else
      fail "sp-tool-fetch.sh not found at $SCRIPT_DIR/sp-tool-fetch.sh"
    fi
  elif [[ "$USE_SP_TOOL" == "true" && -z "$client" ]]; then
    log "Note: --use-sp-tool requires client; filecoin.tools did not return client. Using direct piece URL."
  fi

  # Step 5: Output or download
  if [[ "$URL_ONLY" == "true" ]]; then
    [[ "$ALL_URLS" == "true" ]] && printf '%s\n' "${urls[@]}"
    [[ "$ALL_URLS" != "true" ]] && echo "${urls[0]}"
    exit 0
  fi

  if [[ -n "$DOWNLOAD_DIR" ]]; then
    mkdir -p "$DOWNLOAD_DIR"
    local outfile="$DOWNLOAD_DIR/$(basename "${PIECE_CID}").car"
    local url ok=false
    for url in "${urls[@]}"; do
      log "Trying: $url"
      rm -f "$outfile"
      if have wget; then
        if wget --retry-connrefused --connect-timeout=10 --read-timeout=30 -O "$outfile" "$url"; then
          if [[ -s "$outfile" ]]; then ok=true; break; fi
        fi
      else
        if curl -fSL --connect-timeout 10 -o "$outfile" "$url"; then
          if [[ -s "$outfile" ]]; then ok=true; break; fi
        fi
      fi
      log "This URL failed or returned an empty file; trying next candidate if any…"
    done
    [[ "$ok" == true ]] || fail "Download failed for all ${#urls[@]} candidate URL(s) for this provider"
    log "Downloaded. Unpack with: $SCRIPT_DIR/sp-tool-fetch.sh --unpack-only $outfile --dir $DOWNLOAD_DIR"
    exit 0
  fi

  # Default: print first URL
  echo "${urls[0]}"
}

main "$@"
