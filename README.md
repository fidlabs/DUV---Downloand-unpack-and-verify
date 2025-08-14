# DUV---Downloand-unpack-and-verify
# Description

A single, no-sudo CLI to:
- Create a job against `api.sp-tool.allocator.tech`, poll until ready, fetch the **first** CAR URL, download, and unpack it.
- Or **unpack an already-downloaded** CAR file safely (keeps your original intact).
- Optionally install required tooling **without sudo** (macOS: with Homebrew; user‑space installs for `ipfs-car` via npm and `car` via Go).

> The script never runs Homebrew with `sudo` and will not use `sudo` at all. It favors **user-space** installs.

---

## Features

- **End-to-end flow:** POST job → poll `jobs/{id}` → fallback to synchronous endpoint → download first URL → unpack.
- **Unpack‑only mode:** Works on files saved **with or without** `.car` extension.
- **Resilient CAR unpack:** Handles CARv1 **zero-length section/padding** by making a **copy-on-write clone** and truncating at the exact EOF marker, then unpacking the **clone**.
- **Dependency bootstrap (no sudo):** Installs `ipfs-car` (npm global with user prefix if needed) or `car` (`go install`) into `~/go/bin` or `~/.npm-global/bin`.
- **macOS ready:** Uses APFS `cp -c` for instant cloning (no data copy). On Linux, tries `cp --reflink=always` (XFS/Btrfs); otherwise requires `ALLOW_COPY=1`.
- **Only the first file** is downloaded/unpacked by design.

---

## Requirements

- **Shell:** bash (macOS default is fine), `curl`, `jq`.
- **Extractors:** one of `ipfs-car` (recommended) or `car` (from `go-car`). The script can install either in user space.
- **Python 3:** used for fast CAR structure probing (no data scan). macOS usually has it; if not: `brew install python`.
- **Optional:** `wget` (script falls back to `curl` if not present).

> On Linux without sudo, you must already have `curl` and `jq` installed, or install them via your package manager. The script can still install `ipfs-car`/`car` in user space.

---

## Quick start

```bash
# 1) Make the script executable
chmod +x sp-tool-fetch.sh

# 2) (Optional) Install deps in user space (no sudo)
./sp-tool-fetch.sh --install-deps --os macos   # macOS (requires Homebrew to be present)
# Linux (no sudo): the script can install ipfs-car/car for your user; ensure curl & jq exist

# 3) End-to-end run: fetch and unpack FIRST URL into a work dir
./sp-tool-fetch.sh --client CLIENT_ID --dir DIRECTORY_TO_UNPACK
# optionally narrow to one provider
./sp-tool-fetch.sh --client CLIENT_ID --provider PROVIDER_ID --dir DIRECTORY_TO_UNPACK

# 4) Unpack a previously downloaded file (original stays intact)
./sp-tool-fetch.sh --unpack-only ./DIRECTORY_TO_UNPACK/FILE[.car]
```

---

## Modes

### A) Dependency installation (no sudo)
```bash
./sp-tool-fetch.sh --install-deps [--os macos|debian|fedora|arch|windows] [--install-deps-only]
```
- **macOS:** uses Homebrew without sudo (must already be installed). Installs `jq`, `wget`, `go`, `node`.
- **Linux:** package installs without sudo are not possible; the script still attempts user-space installs for `ipfs-car` and/or `car`.
- **Windows:** prints manual install hints.

### B) End-to-end (job → download → unpack)
```bash
./sp-tool-fetch.sh --client CLIENT_ID [--provider PROVIDER_ID] --dir DIR [--api-base URL]                    [--timeout SECONDS] [--sync-timeout SECONDS]
```

### C) Unpack an existing file (safe)
```bash
./sp-tool-fetch.sh --unpack-only /path/to/file[.car] [--dir DIR]
```
- The script creates an **instant clone** on APFS/Btrfs/XFS and truncates the clone at the CAR EOF marker. Your original is never modified.
- On filesystems without clone/reflink support, set `ALLOW_COPY=1` to allow a regular copy.

---

## Arguments

- `--client CLIENT_ID` *(required for end-to-end)*  
- `--provider PROVIDER_ID` *(optional)*  
- `--dir DIR` *(required for end-to-end; optional for unpack-only)*  
- `--api-base URL` (default: `https://api.sp-tool.allocator.tech`)  
- `--timeout SECONDS` (poll timeout for async job; default `900`)  
- `--sync-timeout SECONDS` (poll timeout for sync endpoint; default `900`)  
- `--install-deps` (attempt user-space installs)  
- `--install-deps-only` (install and exit)  
- `--unpack-only PATH` (skip network; only unpack this file)  
- `--os macos|debian|fedora|arch|windows` (hint for dependency phase)  
- `--allow-copy` (allow real copy if clone/reflink unsupported; uses disk space/time)

---

## Environment variables

- `API_BASE` – override API base.  
- `POLL_INTERVAL` – initial poll interval seconds (default `2`).  
- `POLL_MAX_INTERVAL` – cap for backoff (default `15`).  
- `POLL_TIMEOUT` – async job poll limit seconds (default `900`).  
- `SYNC_TIMEOUT` – sync endpoint poll limit seconds (default `900`).  
- `PREFER_IPFS_CAR=1` – prefer `ipfs-car unpack` over `car x`. Recommended for padded CARs.  
- `ALLOW_COPY=1` – permit a regular copy when cloning is unsupported.  
- `OS_FAMILY` – preset OS for installer (`macos|debian|fedora|arch|windows`).

To make the npm user prefix permanent (so `ipfs-car` stays on PATH):
```bash
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

---

## How unpack safety works

- The script **never modifies your original file**. It:
  1. **Probes** the CAR structure to find the **first zero-length section** (the EOF marker) using varints (fast; does not scan gigabytes).
  2. Makes a **copy-on-write clone** (`cp -c` on APFS; `cp --reflink=always` on Btrfs/XFS).  
     If unsupported and `ALLOW_COPY=1` is set, it performs a real copy.
  3. **Truncates the clone** at the marker.  
  4. Unpacks from the **clone** using `car` or `ipfs-car`.

This resolves “null padding not allowed” / “Invalid CAR section (zero length)” errors without redownloading.

---

## Troubleshooting

- **`HTTP 405` on POST /job**  
  The script falls back to the synchronous endpoint and polls until a URL is available.

- **Sync endpoint returns “Success” or no URL**  
  The script polls until it extracts the first `http(s)` URL from the JSON.

- **File saved without `.car` extension**  
  `--unpack-only` accepts files with or without `.car`. It will try both forms automatically.

- **`Invalid CAR section (zero length)` or `null padding not allowed`**  
  Use `--unpack-only` (or the end-to-end flow) with `PREFER_IPFS_CAR=1`.  
  If both extractors complain, the script clones and truncates the file at the EOF marker, then retries.

- **“Fast clone unsupported”**  
  Set `ALLOW_COPY=1` to allow a real copy (uses disk space/time).  
  Example: `ALLOW_COPY=1 ./sp-tool-fetch.sh --unpack-only ./file`

- **`command not found: ipfs-car` / `car`**  
  Run `./sp-tool-fetch.sh --install-deps --os macos` (or your OS).  
  Or install manually: `npm i -g ipfs-car` (user prefix) / `go install github.com/ipld/go-car/cmd/car@latest`.

- **`jq` or `curl` missing**  
  macOS: `brew install jq curl`.  
  Linux: install via your package manager (may require sudo).

---

## Examples

```bash
# Install deps, then run
./sp-tool-fetch.sh --install-deps --os macos
./sp-tool-fetch.sh --client f0CLIENT --dir 410_3

# With provider narrowed
./sp-tool-fetch.sh --client f0CLIENT --provider f0PROVIDER --dir 410_3

# Unpack an existing file (prefer ipfs-car)
PREFER_IPFS_CAR=1 ./sp-tool-fetch.sh --unpack-only ./410_3/mydownloadedfile

# If your filesystem lacks clone/reflink:
ALLOW_COPY=1 ./sp-tool-fetch.sh --unpack-only ./410_3/FILE
```

---

## Notes

- The script downloads only the **first** URL if multiple URLs are returned.
- It prints HTTP codes and raw responses on failures for quick debugging.
- Works best on macOS APFS and Linux filesystems with reflink support.

---

## License

MIT
