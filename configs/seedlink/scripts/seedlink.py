import os, re, time, sys, requests, argparse, io, bencodepy
from urllib.parse import quote

# ============================================================
# ARGUMENT / ENVIRONMENT HANDLING
# ============================================================

parser = argparse.ArgumentParser()
parser.add_argument("--title")
parser.add_argument("--dir")
parser.add_argument("--cat")
args, _ = parser.parse_known_args()

def detect_sab_job():
    """Detect SABnzbd hook arguments if run as a post-processing script."""
    if len(sys.argv) >= 7:
        finaldir = sys.argv[1]
        nzbname = sys.argv[2]
        jobname = sys.argv[3]
        category = sys.argv[4]
        group = sys.argv[5]
        status = sys.argv[6]
        print(f"📦 SAB Hook detected: job={jobname}, status={status}, cat={category}")

        if not category and group:
            if "movies" in group.lower():
                category = "movies"
            elif "tv" in group.lower():
                category = "tv"
            else:
                category = group

        return jobname, finaldir, category
    return None, None, None


# ============================================================
# ENVIRONMENT VARIABLES / DEFAULTS
# ============================================================

QBIT_HOST = os.getenv("QBIT_HOST", "http://qbit-proxy:8082")
QBIT_USER = os.getenv("QBIT_USER", "admin")
QBIT_PASS = os.getenv("QBIT_PASS", "adminadmin")

TL_UID = os.getenv("TORRENTLEECH_UID")
TL_PASS = os.getenv("TORRENTLEECH_PASS")
PROWLARR_API_KEY = os.getenv("PROWLARR_API_KEY")
PROWLARR_URL = os.getenv("PROWLARR_URL", "http://172.20.0.3:9696")
MILKIE_COOKIE = os.getenv("MILKIE_COOKIE")

MAX_PEERS = int(os.getenv("MAX_PEERS", 10))
STOP_RATIO = float(os.getenv("STOP_RATIO", 2.0))

SAB_TITLE = os.getenv("SAB_TITLE") or args.title or ""
SAB_COMPLETE_DIR = os.getenv("SAB_COMPLETE_DIR") or args.dir or "/downloads/complete"
SAB_CATEGORY = os.getenv("SAB_CATEGORY") or args.cat or ""


# ============================================================
# qBittorrent API Helper
# ============================================================

QBIT = requests.Session()
auth = QBIT.post(f"{QBIT_HOST}/api/v2/auth/login", data={
    "username": QBIT_USER,
    "password": QBIT_PASS
})
if auth.status_code != 200 or "Ok" not in auth.text:
    print(f"❌ qBittorrent login failed: {auth.text}")
else:
    print("✅ Connected to qBittorrent API")


# ============================================================
# Torrent Verification Helper
# ============================================================

def verify_local_files_match(torrent_bytes, base_path):
    """Check if all torrent files exist and match sizes locally."""
    try:
        torrent = bencodepy.decode(torrent_bytes)
        info = torrent[b'info']
        files = []
        if b'files' in info:  # Multi-file torrent
            for f in info[b'files']:
                path = os.path.join(base_path, *[x.decode() for x in f[b'path']])
                length = f[b'length']
                files.append((path, length))
        else:  # Single file torrent
            path = os.path.join(base_path, info[b'name'].decode())
            files.append((path, info[b'length']))

        missing = []
        for path, length in files:
            if not os.path.exists(path) or os.path.getsize(path) != length:
                missing.append(path)

        if missing:
            print(f"⚠️ Skipping — {len(missing)} file(s) missing or mismatched.")
            for m in missing[:3]:
                print(f"   → {m}")
            return False
        print("✅ All local files verified. Safe to seed.")
        return True
    except Exception as e:
        print(f"⚠️ Torrent verification failed: {e}")
        return False


# ============================================================
# TorrentLeech Search
# ============================================================

def find_on_torrentleech(title):
    if not TL_UID or not TL_PASS:
        print("⚠️ TorrentLeech credentials missing, skipping TL search.")
        return None
    headers = {"cookie": f"tluid={TL_UID}; tlpass={TL_PASS}"}
    url = f"https://www.torrentleech.org/torrents/browse/index/query/{quote(title)}"
    r = requests.get(url, headers=headers)
    if r.status_code != 200:
        print(f"⚠️ TL search failed ({r.status_code})")
        return None
    match = re.search(r'/download/(\d+)/[^"]+\.torrent', r.text)
    if match:
        torrent_id = match.group(1)
        turl = f"https://www.torrentleech.org/download/{torrent_id}/file.torrent"
        tdata = requests.get(turl, headers=headers).content
        print(f"🎯 Found TorrentLeech match for '{title}'")
        return tdata
    print("🚫 No TorrentLeech match found.")
    return None


# ============================================================
# Prowlarr Fallback
# ============================================================

def find_on_prowlarr(title):
    if not PROWLARR_API_KEY:
        print("⚠️ No Prowlarr API key; skipping fallback.")
        return None
    api_url = f"{PROWLARR_URL}/api/v1/search"
    params = {"query": title, "apiKey": PROWLARR_API_KEY}
    try:
        r = requests.get(api_url, params=params, timeout=10)
        results = r.json()
        if not results:
            print("🚫 No Prowlarr results found.")
            return None
        for item in results:
            if item.get("downloadUrl"):
                print(f"🎯 Found Prowlarr match: {item['title']}")
                tfile = requests.get(item["downloadUrl"]).content
                return tfile
    except Exception as e:
        print(f"⚠️ Prowlarr fallback failed: {e}")
    return None


# ============================================================
# Add Torrent to qBittorrent
# ============================================================

def add_torrent_to_qb(torrent_bytes, path):
    files = {'torrents': ('file.torrent', torrent_bytes)}
    data = {'savepath': path, 'skip_checking': 'false', 'autoTMM': 'false'}
    resp = QBIT.post(f"{QBIT_HOST}/api/v2/torrents/add", files=files, data=data)
    if resp.status_code != 200:
        print(f"❌ Failed to add torrent: {resp.text}")
        return False
    print(f"📥 Added torrent to qBittorrent: {path}")
    return True


# ============================================================
# Set Torrent Limits
# ============================================================

def set_torrent_limits(title):
    torrents = QBIT.get(f"{QBIT_HOST}/api/v2/torrents/info").json()
    for t in torrents:
        if title.lower() in t["name"].lower():
            hash_ = t["hash"]
            QBIT.post(f"{QBIT_HOST}/api/v2/torrents/setShareLimits", data={
                "hashes": hash_,
                "ratioLimit": STOP_RATIO,
                "seedingTimeLimit": 0
            })
            QBIT.post(f"{QBIT_HOST}/api/v2/torrents/setUploadLimit",
                      data={"hashes": hash_, "limit": MAX_PEERS * 1024})
            print(f"⚖️ Set limits: ratio {STOP_RATIO}, peers {MAX_PEERS}")
            return True
    return False


# ============================================================
# MAIN
# ============================================================

def main():
    title, path, category = (None, None, None)

    # Only detect SAB job if no CLI title provided
    if not args.title:
        title, path, category = detect_sab_job()
    else:
        print("🧰 CLI mode detected (skipping SAB hook auto-detect).")


    if not title:
        print("🧰 CLI mode detected (ignoring SAB hook detection).")
        title = SAB_TITLE
        path = SAB_COMPLETE_DIR
        category = SAB_CATEGORY
        if not title:
            print("⚠️ No SAB_TITLE or CLI args provided. Run manually or via SAB.")
            return

    # Skip known non-video types
    skip_exts = (".epub", ".pdf", ".txt", ".mobi", ".doc", ".docx")
    if any(title.lower().endswith(ext) for ext in skip_exts):
        print(f"⏭️ Skipping non-video content: {title}")
        return

    print(f"🎬 Category: {category or 'unknown'}")
    print(f"🔍 Searching for: {title}")

    torrent_data = (
        find_on_torrentleech(title)
        or find_on_prowlarr(title)
    )

    if not torrent_data:
        print("❌ No torrent found for seeding.")
        return

    if verify_local_files_match(torrent_data, path):
        if add_torrent_to_qb(torrent_data, path):
            time.sleep(3)
            set_torrent_limits(title)
            print(f"🚀 Seeding started for '{title}'")
    else:
        print(f"⏭️ Skipped '{title}' (local files not identical).")


# ============================================================
# ENTRYPOINT
# ============================================================

if __name__ == "__main__":
    main()
