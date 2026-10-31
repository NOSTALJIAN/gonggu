#!/usr/bin/env python3
"""Prepare MINIYENA as a separate Cloudflare Pages build without changing GitHub Pages.

Cloudflare Pages configuration:
  Repository: NOSTALJIAN/gonggu
  Production branch: master
  Build command: python3 cloudflare_pages_build.py
  Build output directory: cloudflare-dist
  Root directory: repository root (default)
"""
from pathlib import Path
import shutil

BASE = Path(__file__).resolve().parent
OUTPUT = BASE / "cloudflare-dist"
ASSETS = (
    "index.html",
    "manifest.webmanifest",
    "icon-192.png",
    "icon-512.png",
    "apple-touch-icon.png",
    "OneSignalSDKWorker.js",
)

if OUTPUT.exists():
    shutil.rmtree(OUTPUT)
OUTPUT.mkdir()
for name in ASSETS:
    source = BASE / name
    if not source.is_file():
        raise SystemExit(f"Required site asset not found: {name}")
    shutil.copy2(source, OUTPUT / name)

page = (OUTPUT / "index.html").read_text(encoding="utf-8")

def change_once(before, after):
    global page
    if page.count(before) != 1:
        raise SystemExit(f"Expected one exact occurrence of: {before[:100]!r}")
    page = page.replace(before, after, 1)

# OneSignal selects its app ID and worker path by hostname in index.html.
# No Cloudflare-specific replacement is needed here.

# Accept existing legacy customer order links on the new domain. The ID/token
# validations directly below this code are preserved, and other sites rejected.
change_once(
    "if(page.origin!==location.origin||norm(page.pathname)!==norm(location.pathname))throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
    "const isCurrentSite=page.origin===location.origin&&norm(page.pathname)===norm(location.pathname);\n"
    " const isOldSite=page.origin==='https://nostaljian.github.io'&&norm(page.pathname)==='/gonggu/';\n"
    " if(!isCurrentSite&&!isOldSite)throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
)

# Avoid presenting the legacy domain as the suggested example in the new site.
page = page.replace(
    'placeholder="https://nostaljian.github.io/gonggu/?page=track&id=...&token=..."',
    'placeholder="주문조회 링크를 붙여넣어 주세요"',
)
(OUTPUT / "index.html").write_text(page, encoding="utf-8")
print("MINIYENA Cloudflare Pages output prepared:", OUTPUT)
print("Note: OneSignal web push must also be configured for the new site origin.")
