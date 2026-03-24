# Shared: Lotus StateMinerInfo + cid.contact + Lotus multiaddr → HTTP base URLs for an SP.
# Sourced by cid-to-download.sh and cid-all-sp-piece-urls.sh (set LOTUS_RPC / CID_CONTACT_BASE before or rely on defaults).

LOTUS_RPC="${LOTUS_RPC:-https://api.node.glif.io/rpc/v1}"
CID_CONTACT_BASE="${CID_CONTACT_BASE:-https://cid.contact}"

get_miner_info() {
  local provider="$1"
  [[ "$provider" =~ ^f0[0-9]+$ ]] || provider="f0${provider#f0}"
  curl -sS -X POST "$LOTUS_RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Filecoin.StateMinerInfo\",\"params\":[\"${provider}\",null]}" 2>/dev/null
}

get_provider_http_endpoints_from_cid_contact() {
  local peer_id="$1"
  local json
  json="$(curl -sS --connect-timeout 10 --max-time 20 \
    "${CID_CONTACT_BASE}/providers/${peer_id}" 2>/dev/null)" || return 1
  [[ -z "$json" || "${#json}" -lt 10 ]] && return 1
  jq -r '
    .. | .Addrs? // empty | if type == "array" then .[] else empty end
  ' <<<"$json" 2>/dev/null | while read -r addr; do
    [[ -z "$addr" ]] && continue
    if [[ "$addr" =~ ^/ip4/([^/]+)/tcp/([0-9]+)/http ]]; then echo "http://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^/ip4/([^/]+)/tcp/([0-9]+)/https ]]; then echo "https://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^/dns4/([^/]+)/tcp/([0-9]+)/http ]]; then echo "http://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^/dns4/([^/]+)/tcp/([0-9]+)/https ]]; then echo "https://${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    fi
  done | sort -u
}

get_provider_http_endpoints_from_lotus() {
  local miner_info="$1"
  local multiaddrs_b64
  multiaddrs_b64="$(jq -r '.result.Multiaddrs[]? // empty' <<<"$miner_info" 2>/dev/null)"
  [[ -z "$multiaddrs_b64" ]] && return 1
  while read -r b64; do
    [[ -z "$b64" ]] && continue
    python3 - "$b64" 2>/dev/null <<'PY' || true
import base64, struct, sys
try:
    data = base64.b64decode(sys.argv[1])
    i = 0
    ip, port = None, None
    while i < len(data):
        val, shift = 0, 0
        while i < len(data):
            b = data[i]; i += 1
            val |= (b & 0x7f) << shift
            if b < 0x80: break
            shift += 7
        if val == 4 and i + 4 <= len(data):
            ip = ".".join(str(b) for b in data[i:i+4])
            i += 4
        elif val == 6 and i + 2 <= len(data):
            port = struct.unpack(">H", data[i:i+2])[0]
            i += 2
        elif val in (480, 0x1e0): pass
        elif val == 443: pass
    if ip and port:
        print(f"http://{ip}:{port}")
except Exception: pass
PY
  done <<<"$multiaddrs_b64" | sort -u
}
