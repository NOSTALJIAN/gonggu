# 미니예나 (MINIYENA)

남대문·수입 아동복 공동구매 쇼핑몰과 관리자 화면입니다.

## 운영 주소

- 기존 쇼핑몰: https://nostaljian.github.io/gonggu/
- 새 쇼핑몰: https://miniyena.pages.dev/
- 새 관리자: https://miniyena.pages.dev/admin/

## 배포

`master`에 변경사항이 반영되면 GitHub Actions의 `Deploy MINIYENA` 워크플로가 실행됩니다.

1. `cloudflare_pages_build.py`로 쇼핑몰과 관리자 페이지를 생성합니다.
2. 저장소 Actions secrets에 `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`가 있으면 기존 Cloudflare Pages `miniyena` 프로젝트의 프로덕션 브랜치로 자동 배포합니다.
3. 기존 GitHub Pages 쇼핑몰도 함께 배포합니다.

Cloudflare에 비밀키를 직접 코드에 입력하지 마세요. 권한이 정상 연결되었는지는 GitHub Actions의 `Publish Cloudflare Pages production` 단계에서 확인할 수 있습니다.

모든 수정은 기존 프로젝트를 업데이트하며, 별도의 새 Cloudflare Pages 프로젝트를 만들지 않습니다.
