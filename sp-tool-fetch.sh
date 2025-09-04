#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- Config ----------
API_BASE="${API_BASE:-https://api.sp-tool.allocator.tech}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
POLL_MAX_INTERVAL="${POLL_MAX_INTERVAL:-15}"
POLL_TIMEOUT="${POLL_TIMEOUT:-900}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-900}"
WGET_ARGS=(--retry-connrefused --connect-timeout=10 --read-timeout=20 --tries=0 --continue)
ALLOW_COPY="${ALLOW_COPY:-0}"      # set 1 to allow a real copy if no reflink/clone is available
PREFER_IPFS_CAR="${PREFER_IPFS_CAR:-0}"  # set 1 to try ipfs-car first when unpacking

# ---------- Utils ----------
log()  { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage:
  $0 --install-deps [--os macos|debian|fedora|arch|windows] [--install-deps-only]
  $0 --client CLIENT_ID [--provider PROVIDER_ID] --dir DIR [--api-base URL] [--timeout S] [--sync-timeout S]
  $0 --unpack-only /path/to/file[.car] [--dir DIR]
  [--allow-copy]  # allow real copy if fast clone/reflink unsupported (uses disk space/time)

Notes:
  - macOS: uses Homebrew (non-sudo) if available. ipfs-car installs to user prefix if needed.
  - Linux: jq/curl/wget may need system install; we try user-level installs for ipfs-car and car.
  - Unpack safely clones then fixes padded/zero-length CARv1 without touching the original.
EOF
}

# ---------- OS detect ----------
# ------------- OS + installers -------------
USE_SUDO="auto"   # "auto" (Linux package managers may use sudo), "never"
OS_FAMILY="${OS_FAMILY:-}"

detect_os_family() {
  if [[ -n "$OS_FAMILY" ]]; then return 0; fi
  local u; u="$(uname -s 2>/dev/null || true)"
  case "$u" in
    Darwin) OS_FAMILY="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS_FAMILY="windows" ;;
    Linux)
      if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
          *debian*|*ubuntu*|debian|ubuntu) OS_FAMILY="debian" ;;
          *rhel*|*fedora*|*centos*|rhel|fedora|centos|rocky|alma) OS_FAMILY="fedora" ;;
          arch|*arch*) OS_FAMILY="arch" ;;
          *) OS_FAMILY="unknown" ;;
        esac
      else
        OS_FAMILY="unknown"
      fi
      ;;
    *) OS_FAMILY="unknown" ;;
  esac
}

run_pkg() {
  # Use sudo for system package managers on Linux when allowed; never for Homebrew.
  if [[ "$USE_SUDO" == "auto" ]]; then
    if [[ $EUID -eq 0 ]]; then
      "$@"
    elif command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      "$@"
    fi
  else
    "$@"
  fi
}


# ---------- Installers ----------
brew_install() { brew "$@" ; }   # never sudo

npm_global_install() {
  # try plain global; if EACCES on macOS, switch to user prefix ~/.npm-global
  set +e
  local out; out="$(npm i -g "$1" 2>&1)"; local rc=$?
  set -e
  if (( rc == 0 )); then return 0; fi
  if [[ "$OS_FAMILY" == "macos" ]] && grep -qiE 'EACCES|permission denied' <<<"$out"; then
    local prefix="${NPM_PREFIX:-$HOME/.npm-global}"
    log "npm global lacks perms; using user prefix: $prefix"
    mkdir -p "$prefix/bin"
    npm config set prefix "$prefix" >/dev/null
    export PATH="$prefix/bin:$PATH"
    npm i -g "$1"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return $rc
}

ensure_extractor_installed() {
  # Ensure 'car' or 'ipfs-car' exists; install in user space if possible.
  if have car || have ipfs-car; then return 0; fi

  if have go; then
    log "Installing 'car' via Go (user space)..."
    local go_bin; go_bin="$(go env GOBIN 2>/dev/null || true)"
    [[ -z "$go_bin" || "$go_bin" == "''" ]] && go_bin="$(go env GOPATH 2>/dev/null)/bin"
    [[ -z "$go_bin" ]] && go_bin="$HOME/go/bin"
    GOBIN="$go_bin" go install github.com/ipld/go-car/cmd/car@latest || true
    if [[ -x "$go_bin/car" ]]; then export PATH="$go_bin:$PATH"; return 0; fi
  fi

  if have npm; then
    log "Installing 'ipfs-car' via npm (user space)..."
    npm_global_install ipfs-car || return 1
    return 0
  fi

  return 1
}

# --- install the tolerant fork: github.com/kacperzuk-neti/go-car ---
ensure_kcar_installed() {
  # installs a separate CLI named 'car-pad' into ~/.local/bin (no sudo)
  if command -v car-pad >/dev/null 2>&1; then return 0; fi
  if ! command -v go >/dev/null 2>&1; then
    log "Go is not installed; cannot build car-pad. Install Go (brew/apt/dnf/pacman) then re-run."
    return 1
  fi

  local BIN="$HOME/.local/bin"
  mkdir -p "$BIN"
  local TMP; TMP="$(mktemp -d)"
  log "Building car-pad from fork (no sudo)..."
  git clone --depth 1 https://github.com/kacperzuk-neti/go-car "$TMP/go-car" || { rm -rf "$TMP"; return 1; }
  (
    cd "$TMP/go-car/cmd/car" && \
    go build -trimpath -ldflags "-s -w" -o "$BIN/car-pad" .
  ) || { rm -rf "$TMP"; return 1; }
  rm -rf "$TMP"
  chmod +x "$BIN/car-pad"
  export PATH="$BIN:$PATH"
  log "Installed car-pad -> $BIN/car-pad"
  return 0
}

install_deps() {
  detect_os_family
  local family="${1:-$OS_FAMILY}"
  log "Installing dependencies for: $family (sudo mode: $USE_SUDO)"

  case "$family" in
    macos)
      if ! have brew; then
        fail "Homebrew not found. Install from https://brew.sh (no sudo) and re-run --install-deps."
      fi
      # Never run brew with sudo
      brew_install update || true
      brew_install install jq wget go node || true
      ;;

    debian)
      # On Linux we allow sudo for system packages unless --no-sudo was passed
      run_pkg apt-get update -y
      run_pkg apt-get install -y curl jq wget nodejs npm golang-go || true
      ;;

    fedora)
      if command -v dnf >/dev/null 2>&1; then
        run_pkg dnf install -y curl jq wget nodejs npm golang || true
      else
        run_pkg yum install -y curl jq wget nodejs npm golang || true
      fi
      ;;

    arch)
      run_pkg pacman -Sy --noconfirm curl jq wget nodejs npm go || true
      ;;

    windows)
      log "Windows detected. Please install: curl, jq, Node.js (for ipfs-car) or Go (for car)."
      log "Example (winget): winget install -e --id JQLang.jq ; winget install OpenJS.NodeJS.LTS ; winget install GoLang.Go"
      ;;

    *)
      log "Unknown OS. Please ensure: curl, jq, and either Node.js (ipfs-car) or Go (car)."
      ;;
  esac

  # ensure at least one extractor exists; prefer the tolerant fork
  ensure_kcar_installed || true
  ensure_extractor_installed || fail "Could not install a CAR extractor (car or ipfs-car)."
  if ! (command -v car-pad >/dev/null || command -v car >/dev/null || command -v ipfs-car >/dev/null); then
    fail "No CAR extractor available. Install Go and re-run --install-deps to build car-pad."
  fi

  # Final checks
  have curl || fail "curl missing after install attempts."
  have jq   || fail "jq missing after install attempts."
  if ! (have car || have ipfs-car); then
    fail "No car/ipfs-car found after install attempts."
  fi
  have wget || log "Note: wget not installed; script will use curl for downloads."
}


# ---------- URL extraction ----------
extract_first_url_from_json() {
  local json="$1"
  local all; all="$(jq -r '.. | strings | select(test("^(https?)://"))' <<<"$json" 2>/dev/null || true)"
  local car; car="$(printf '%s\n' "$all" | grep -iE '\.car($|[?&]|[^A-Za-z0-9._-])' | head -n1 || true)"
  [[ -n "$car" ]] && { printf '%s' "$car"; return 0; }
  local any; any="$(printf '%s\n' "$all" | head -n1 || true)"
  [[ -n "$any" ]] && { printf '%s' "$any"; return 0; }
  return 1
}

# ---------- Download ----------
download_to_file() {
  local url="$1" out="$2"
  if have wget; then
    wget "${WGET_ARGS[@]}" -O "$out" "$url"
  else
    curl -L --connect-timeout 10 --max-time 0 -C - -o "$out" "$url"
  fi
}

# ---------- Safe clone (no data copy on APFS/Btrfs/XFS) ----------
safe_clone() {
  # $1 src, $2 dst
  local src="$1" dst="$2"
  # macOS APFS
  if cp -c "$src" "$dst" 2>/dev/null; then return 0; fi
  # Linux reflink (Btrfs/XFS)
  if cp --reflink=always "$src" "$dst" 2>/dev/null; then return 0; fi
  if [[ "$ALLOW_COPY" == "1" ]]; then
    log "Fast clone unsupported; doing real copy (this may be slow and use disk space)."
    cp "$src" "$dst"
    return 0
  fi
  fail "Fast clone unsupported on this filesystem. Re-run with ALLOW_COPY=1 to permit a real copy."
}

# ---------- Find zero-length section (CARv1 EOF marker) ----------
find_zero_len_offset() {
  # prints offset to stdout, returns 0 if found
  local car="$1"
  python3 - "$car" <<'PY'
import os, sys
p=sys.argv[1]
def rv(f):
    x=s=0
    while True:
        b=f.read(1)
        if not b: return None
        b=b[0]; x|=(b&0x7f)<<s
        if b<0x80: return x
        s+=7
with open(p,'rb') as f:
    h=rv(f)
    if h is None or h<=0: sys.exit(1)
    f.seek(h, os.SEEK_CUR)
    while True:
        pos=f.tell()
        n=rv(f)
        if n is None: sys.exit(2)
        if n==0:
            print(pos, end="")
            sys.exit(0)
        f.seek(n, os.SEEK_CUR)
PY
}

# ---------- Tolerant unpack (safe) ----------
unpack_car() {
  local carpath="$1"
  [[ -f "$carpath" ]] || {
    if [[ "$carpath" == *.car && -f "${carpath%.car}" ]]; then carpath="${carpath%.car}";
    elif [[ -f "${carpath}.car" ]]; then carpath="${carpath}.car";
    else fail "CAR file not found: $carpath"; fi
  }

  log "Unpacking CAR: $carpath"

  # 1) Prefer the tolerant forked CLI
  if command -v car-pad >/dev/null 2>&1; then
    if car-pad x -f "$carpath"; then return 0; fi
    log "car-pad failed; trying other extractors..."
  fi

  # 2) Try upstream go-car
  if command -v car >/dev/null 2>&1; then
    set +e
    local out; out="$(car x -f "$carpath" 2>&1)"; local rc=$?
    set -e
    if (( rc == 0 )); then return 0; fi

    # If it trips on zero-length/padding, fix safely (clone + truncate) then retry
    if grep -qiE 'ZeroLengthSectionAsEOF|zero length|null padding' <<<"$out"; then
      log "Detected zero-length section/padding. Fixing safely (clone + truncate)…"
      local offset; offset="$(find_zero_len_offset "$carpath" || true)"
      [[ -n "$offset" ]] || fail "Could not locate EOF marker in CAR; aborting."
      local fixed="${carpath}.fixed.car"
      safe_clone "$carpath" "$fixed"
      truncate -s "$offset" "$fixed"
      car x -f "$fixed" || fail "Extraction failed after fix (go-car)."
      return 0
    fi

    printf '%s\n' "$out" >&2
  fi

  # 3) Fallback to ipfs-car if present
  if command -v ipfs-car >/dev/null 2>&1; then
    if ipfs-car unpack "$carpath" --output .; then return 0; fi
    # Apply the same safe fix for zero-length, then retry
    log "ipfs-car failed; attempting safe truncate and retry…"
    local offset; offset="$(find_zero_len_offset "$carpath" || true)"
    [[ -n "$offset" ]] || fail "Could not locate EOF marker in CAR; aborting."
    local fixed="${carpath}.fixed.car"
    safe_clone "$carpath" "$fixed"
    truncate -s "$offset" "$fixed"
    ipfs-car unpack "$fixed" --output . || fail "Extraction failed after fix (ipfs-car)."
    return 0
  fi

  fail "No working extractor available (tried car-pad, car, ipfs-car)."
}

# ---------- Arg parse ----------
CLIENT=""; PROVIDER=""; DIR_NAME=""
DO_INSTALL_DEPS="false"; INSTALL_ONLY="false"; UNPACK_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client)           CLIENT="${2:-}"; shift 2;;
    --provider)         PROVIDER="${2:-}"; shift 2;;
    --dir)              DIR_NAME="${2:-}"; shift 2;;
    --api-base)         API_BASE="${2:-}"; shift 2;;
    --timeout)          POLL_TIMEOUT="${2:-}"; shift 2;;
    --sync-timeout)     SYNC_TIMEOUT="${2:-}"; shift 2;;
    --os)               OS_FAMILY="${2:-}"; shift 2;;
    --install-deps)     DO_INSTALL_DEPS="true"; shift;;
    --install-deps-only)INSTALL_ONLY="true"; shift;;
    --unpack-only)      UNPACK_ONLY="${2:-}"; shift 2;;
    --allow-copy)       ALLOW_COPY="1"; shift;;
    -h|--help)          usage; exit 0;;
    *) fail "Unknown argument: $1";;
  esac
done

# ---------- Optional: install deps ----------
if [[ "$DO_INSTALL_DEPS" == "true" ]]; then
  install_deps "${OS_FAMILY:-}"
  log "Dependency setup complete."
  [[ "$INSTALL_ONLY" == "true" ]] && exit 0
fi

# ---------- Unpack-only mode ----------
if [[ -n "$UNPACK_ONLY" ]]; then
  if [[ -n "${DIR_NAME:-}" ]]; then mkdir -p "$DIR_NAME"; cd "$DIR_NAME"; fi
  # quick sanity (for users who skipped --install-deps)
  have curl || fail "curl missing. Please install it."
  have jq   || fail "jq missing. Please install it."
  ensure_extractor_installed || fail "No car/ipfs-car. Run --install-deps first."
  unpack_car "$UNPACK_ONLY"
  log "Success. CAR unpacked in: $(pwd)"
  exit 0
fi

# ---------- End-to-end flow ----------
[[ -n "$CLIENT" ]]  || { usage; fail "Missing --client (or use --unpack-only)"; }
[[ -n "$DIR_NAME" ]] || { usage; fail "Missing --dir (or use --unpack-only)"; }
have curl || fail "curl missing. Please install it."
have jq   || fail "jq missing. Please install it."
ensure_extractor_installed || fail "No car/ipfs-car. Run --install-deps first."

mkdir -p "$DIR_NAME"
cd "$DIR_NAME"

# Build POST payload
if [[ -n "${PROVIDER:-}" ]]; then
  POST_PAYLOAD=$(jq -n --arg client "$CLIENT" --arg provider "$PROVIDER" '{client:$client, provider:$provider}')
else
  POST_PAYLOAD=$(jq -n --arg client "$CLIENT" '{client:$client}')
fi

# Create job (async)
log "Creating job for client=$CLIENT${PROVIDER:+, provider=$PROVIDER} ..."
RESP="$(curl -sS -X POST "$API_BASE/job" -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$POST_PAYLOAD" -w $'\n%{http_code}')"
HTTP_CODE="${RESP##*$'\n'}"; JOB_BODY="${RESP%$'\n'*}"
log "POST /job -> HTTP $HTTP_CODE"

JOB_ID="$(
  jq -r '
    .jobID // .jobId // .id //
    .data.jobID // .data.jobId // .data.id //
    .job.id // .job.jobID // .job.jobId //
    .result.jobID // .result.jobId // .result.id // empty
  ' <<<"$JOB_BODY" 2>/dev/null || true
)"
[[ -z "$JOB_ID" || "$JOB_ID" == "null" ]] && [[ "$JOB_BODY" =~ ^[A-Za-z0-9._:-]+$ ]] && JOB_ID="$JOB_BODY" || true

URL_FIRST=""
if [[ -n "$JOB_ID" && "$JOB_ID" != "null" && "$HTTP_CODE" =~ ^2 ]]; then
  log "Job created: $JOB_ID"
  log "Polling job status until done (timeout ${POLL_TIMEOUT}s)..."
  START_TIME=$(date +%s); INTERVAL="$POLL_INTERVAL"
  while :; do
    JOB_JSON="$(curl -sS -H 'Accept: application/json' "$API_BASE/jobs/$JOB_ID")" || fail "GET /jobs/$JOB_ID failed"
    STATUS="$(jq -r '.status // .data.status // .job.status // empty' <<<"$JOB_JSON")"
    if [[ "$STATUS" == "done" ]]; then
      if URL_FIRST="$(extract_first_url_from_json "$JOB_JSON")"; then
        log "Job done."; break
      else
        log "Job done but URL not found yet; retrying..."
      fi
    elif [[ "$STATUS" == "error" || "$STATUS" == "failed" || "$STATUS" == "cancelled" ]]; then
      log "Response: $JOB_JSON"; fail "Job ended with status: $STATUS"
    fi
    NOW=$(date +%s); ELAPSED=$(( NOW - START_TIME ))
    (( ELAPSED < POLL_TIMEOUT )) || { log "Response: $JOB_JSON"; fail "Timed out after ${POLL_TIMEOUT}s"; }
    sleep "$INTERVAL"; (( INTERVAL < POLL_MAX_INTERVAL )) && INTERVAL=$(( INTERVAL + 1 ))
  done
else
  log "Could not extract job ID (or non-2xx). Response body follows:"; printf '%s\n' "$JOB_BODY" >&2
  log "Falling back to sync endpoint: GET $API_BASE/url/client/$CLIENT (poll up to ${SYNC_TIMEOUT}s)..."
  START_TIME=$(date +%s); INTERVAL="$POLL_INTERVAL"
  while :; do
    SYNC_RESP="$(curl -sS -H 'Accept: application/json' "$API_BASE/url/client/$CLIENT" -w $'\n%{http_code}')"
    SYNC_CODE="${SYNC_RESP##*$'\n'}"; SYNC_JSON="${SYNC_RESP%$'\n'*}"
    if [[ ! "$SYNC_CODE" =~ ^2 ]]; then log "Sync GET -> HTTP $SYNC_CODE (continuing)"; fi
    if URL_FIRST="$(extract_first_url_from_json "$SYNC_JSON")"; then
      log "URL ready from sync endpoint."; break
    fi
    NOW=$(date +%s); ELAPSED=$(( NOW - START_TIME ))
    (( ELAPSED < SYNC_TIMEOUT )) || { log "Sync response (last): $SYNC_JSON"; fail "Timed out after ${SYNC_TIMEOUT}s waiting for a URL"; }
    sleep "$INTERVAL"; (( INTERVAL < POLL_MAX_INTERVAL )) && INTERVAL=$(( INTERVAL + 1 ))
  done
fi

[[ "$URL_FIRST" =~ ^https?:// ]] || fail "Extracted value is not a valid URL: $URL_FIRST"
FILE_NAME="$(basename "${URL_FIRST%%[\?#]*}")"
[[ -n "$FILE_NAME" ]] || fail "Could not derive filename from URL"

log "Downloading: $FILE_NAME"
download_to_file "$URL_FIRST" "$FILE_NAME" || fail "Download failed"

unpack_car "$FILE_NAME"
log "Success. File downloaded and unpacked in: $(pwd)"
