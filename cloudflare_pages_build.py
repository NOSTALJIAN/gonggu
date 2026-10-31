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

# This is applied ONLY to the Cloudflare copy. GitHub Pages keeps its own setup.
change_once(
    "serviceWorkerPath: 'gonggu/OneSignalSDKWorker.js'",
    "serviceWorkerPath: 'OneSignalSDKWorker.js'",
)
change_once(
    "serviceWorkerParam: { scope: '/gonggu/onesignal-push/' }",
    "serviceWorkerParam: { scope: '/' }",
)

# OneSignal subscriptions belong to the website origin. Use the NEW Cloudflare
# OneSignal app only in this generated copy; keep GitHub Pages subscribers intact.
change_once(
    "appId: '4ecfc195-43f7-4108-b6d4-abb11164a504'",
    "appId: '74494ff1-8318-40fd-ab2c-4bf9017a8991'",
)

# Accept existing legacy customer order links on the new domain. The ID/token
# validations directly below this code are preserved, and other sites rejected.
change_once(
    "if(page.origin!==location.origin||norm(page.pathname)!==norm(location.pathname))throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
    "const isCurrentSite=page.origin===location.origin&&norm(page.pathname)===norm(location.pathname);\n"
    " const isOldSite=page.origin==='https://nostaljian.github.io'&&norm(page.pathname)==='/gonggu/';\n"
    " if(!isCurrentSite&&!isOldSite)throw Error('미니예나 주문조회 링크만 사용할 수 있어요.');",
)

# Restore the manager-only push subscription control removed from the shared
# storefront. This applies only to the generated Cloudflare HTML.
change_once(
    '</div><div class="tabs admin-main-tabs"',
    '''<section class="pushbox pushbox-settings" aria-label="관리자 푸시 알림 설정">
       <div class="row between">
         <strong>관리자 푸시 알림</strong>
         <button type="button" class="btn sm" data-action="enable-admin-push">알림 허용</button>
       </div>
       <p id="mini-push-state" class="pushstate" role="status" aria-live="polite">알림 상태 확인 중…</p>
     </section>
     </div><div class="tabs admin-main-tabs''',
)
# The original CSS hides the entire push section, even if markup is present.
# Restore only the manager section. Do not show subscription UI to customers.
change_once(
    '</style>',
    '''/* Cloudflare-only manager push permission control */
    .admin-workspace-content .pushbox-settings{
      display:block!important;
      padding:10px 12px!important;
      margin:8px 0 13px!important;
    }
    .admin-workspace-content .pushbox-settings .row{gap:8px;align-items:center}
    .admin-workspace-content .pushbox-settings strong{font-size:12px;font-weight:650}
    .admin-workspace-content .pushbox-settings .btn{font-size:12px;padding:8px 12px;min-height:36px;white-space:nowrap}
    .admin-workspace-content .pushbox-settings #mini-push-state{font-size:11px;margin:4px 0 0;line-height:1.5}
    </style>''',
)

# Avoid presenting the legacy domain as the suggested example in the new site.
page = page.replace(
    'placeholder="https://nostaljian.github.io/gonggu/?page=track&id=...&token=..."',
    'placeholder="주문조회 링크를 붙여넣어 주세요"',
)
(OUTPUT / "index.html").write_text(page, encoding="utf-8")
print("MINIYENA Cloudflare Pages output prepared:", OUTPUT)
print("Note: OneSignal web push must also be configured for the new site origin.")
