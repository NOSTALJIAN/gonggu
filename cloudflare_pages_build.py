#!/usr/bin/env python3
"""Build MINIYENA's public storefront and its separate Cloudflare admin page.

Cloudflare Pages: python3 cloudflare_pages_build.py
GitHub Pages:     python3 cloudflare_pages_build.py --github
Both publish the same public storefront; only Cloudflare publishes /admin/.
"""
from pathlib import Path
import json
import shutil
import sys

BASE = Path(__file__).resolve().parent
OUTPUT = BASE / "cloudflare-dist"
IS_GITHUB = "--github" in sys.argv
ASSETS = (
    "index.html",
    "manifest.webmanifest",
    "icon-192.png",
    "icon-512.png",
    "apple-touch-icon.png",
    "OneSignalSDKWorker.js",
    "sw.js",
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


def change_once(before: str, after: str) -> None:
    global page
    if page.count(before) != 1:
        raise SystemExit(f"Expected one exact occurrence of: {before[:100]!r}")
    page = page.replace(before, after, 1)


if not IS_GITHUB:
    # The public order screen and the admin page share the same buyer URL rules.
    # A Cloudflare customer can also paste a link from the legacy GitHub site.
    change_once(
        "if(page.origin!==location.origin||norm(page.pathname)!==norm(STOREFRONT_PATH))throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
        "const isCurrentSite=page.origin===location.origin&&norm(page.pathname)===norm(STOREFRONT_PATH);\n"
        " const isOldSite=page.origin==='https://nostaljian.github.io'&&norm(page.pathname)==='/gonggu/';\n"
        " if(!isCurrentSite&&!isOldSite)throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
    )
    page = page.replace(
        'placeholder="https://nostaljian.github.io/gonggu/?page=track&id=...&token=..."',
        'placeholder="주문조회 링크를 붙여넣어 주세요"',
    )

(OUTPUT / "index.html").write_text(page, encoding="utf-8")

if not IS_GITHUB:
    # Real standalone HTML at /admin/, not an iframe or a customer-page query.
    # Set the base so all relative images and icons resolve from the site root.
    admin = page.replace("<head>\n", '<head>\n<base href="../">\n', 1)
    admin = admin.replace(
        '<meta name="apple-mobile-web-app-title" content="미니예나">',
        '<meta name="apple-mobile-web-app-title" content="미니예나 관리자">',
        1,
    )
    admin = admin.replace(
        '<meta name="application-name" content="MINIYENA">',
        '<meta name="application-name" content="MINIYENA ADMIN">',
        1,
    )
    manifest_tag = '<link rel="manifest" href="./manifest.webmanifest?v=exact-original-mini-logo-inverted-20261022">'
    if admin.count(manifest_tag) != 1:
        raise SystemExit("Cannot locate the storefront manifest reference.")
    admin = admin.replace(
        manifest_tag,
        '<link rel="manifest" href="admin/manifest.webmanifest?v=separate-admin-20261104">',
        1,
    )
    admin_folder = OUTPUT / "admin"
    admin_folder.mkdir()
    (admin_folder / "index.html").write_text(admin, encoding="utf-8")
    admin_manifest = {
        "id": "/admin/",
        "name": "MINIYENA | 관리자",
        "short_name": "미니예나 관리자",
        "description": "미니예나 관리자 전용 상품·주문·정산 화면",
        "start_url": "/admin/",
        "scope": "/admin/",
        "display": "standalone",
        "background_color": "#ffffff",
        "theme_color": "#ffffff",
        "lang": "ko",
        "icons": [
            {"src": "../icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable"},
            {"src": "../icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
        ],
    }
    (admin_folder / "manifest.webmanifest").write_text(
        json.dumps(admin_manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

print("MINIYENA build:", "GitHub storefront" if IS_GITHUB else "Cloudflare storefront + /admin/", OUTPUT)
