# 미니예나 배송조회 변경 및 적용 방법

## 화면 변경

관리자 단일 주문·묶음배송과 구매자 견적 화면에서 송장번호를 누르면 롯데택배 공식 배송조회가 열립니다. 기존 주문 단계와 별도로 실제 API의 배송상태·조회시각·날짜/시간·위치·처리상태를 표시합니다. 서버가 제공하지 않은 이력은 만들지 않습니다. 누락된 값은 `—`, 이력이 없으면 공식 조회 안내를 표시합니다.

묶음 카드는 기존 `bundle_parent_id` 기준을 유지합니다. 일부 주문만 배송완료로 변경되거나 상태 필터에 한 주문만 걸려도 묶음 전체를 유지합니다. 관리자 화면에서는 한 묶음의 유일한 송장을 공유하고, 서로 다른 송장번호는 합치지 않습니다. 결제금액·배송비·주문상태는 배송정보 응답으로 변경할 수 없습니다.

## 현재까지 확인된 서버 정보

사용자가 확인한 Apps Script 함수:
- `lotteTrackDetailsV25_`: 실제 API 상태·상세이력 조회 성공
- `lotteSaveDetailsV25_`: Supabase 저장 시도, 저장 성공 여부 미확인
- `refreshLotteShippingDetailsV25`: 등록 송장 자동조회
- `lotteConfirmDelivery_`: 정상 작동 중인 자동 완료 처리

기존 저장 RPC는 `gq_lotte_save_tracking_v25`, 전달값에는 `p_tracking_number`, `p_status_code`, `p_status_label`, `p_event_time`, `p_events`, `p_tracking_url`이 포함됩니다. 이 함수의 정의·실제 저장 컬럼·이벤트 JSON 형태는 아직 확인되지 않았습니다. 프런트엔드에서는 비밀키나 Apps Script 관리자 엔드포인트를 사용하지 않습니다.

## 1. 현재 구조와 저장 성공 여부 확인 (읽기 전용)

Supabase SQL Editor에서 [01-inspect-shipping.sql](../sql/01-inspect-shipping.sql)을 실행합니다. 기존 저장 RPC 정의와 컬럼을 먼저 확인하세요. RPC가 쓰는 실제 테이블/컬럼을 확인한 뒤, 이미 조회한 송장 한 건의 이력이 저장되었는지 확인합니다. 개인정보·lookup_token·키 값은 공개하지 마세요.

이미 v25 저장 구조가 있다면 우선 그 구조를 재사용하는 것이 좋습니다. 아래 v26 SQL은 **기존 이력 저장·공개가 없을 때 사용하는 별도 대안**입니다. 현 구조의 정의를 확인하지 않고 기존 RPC를 덮어쓰지 마세요.

## 2. 선택적 저장·조회 SQL

[02-optional-shipping-v26.sql](../sql/02-optional-shipping-v26.sql)은 적용하지 않은 별도 마이그레이션입니다. 로컬 PostgreSQL 17의 테스트 스키마에서 실행·검증했습니다. 실제 Supabase 스키마에 대한 실행 검증은 하지 않았습니다.

확인 후 SQL Editor에서 파일 전체를 실행합니다. 하나의 트랜잭션이며 다음 전제와 다르면 실패하고 롤백합니다.

- `gq_quotes`에 기존 id·묶음부모·상태·수령방식·송장 컬럼이 존재
- `gq_read_quote`가 하나의 오버로드이고, 인자가 `p_quote_id`, `p_lookup_token` 순서의 uuid/text/varchar 두 개
- `gq_read_quote`가 SECURITY DEFINER이고 단일 JSON/JSONB 견적 객체를 반환하며 **함수 내부에서 lookup token을 검증**하고 `id`를 포함
- `gq_is_admin()`이 기존 JWT 기반 관리자 여부를 boolean으로 검증

`gq_read_quote`·`gq_is_admin`이 별도 실행역할, 다른 JSON 구조, 추가 인증 조건에 의존한다면 현 정의에 맞춰 검토 후 조정해야 합니다. SQL은 전제에 맞는 테스트 스키마를 검증한 것이며 알려지지 않은 인증 구현의 안전성을 대신 확인하지 않습니다.

새로 추가하는 객체:

| 객체 | 역할 및 접근 |
|---|---|
| `gq_shipment_details_v26` | 송장별 실제 조회결과 저장. RLS 활성화, 브라우저 직접 접근 불가 |
| `gq_lotte_store_details_v26` | service_role만 호출하는 저장 RPC |
| `gq_shipping_payload_v26` | 직접 호출을 막은 내부 묶음 송장 해석 함수 |
| `gq_read_shipping_v26` | 기존 `gq_read_quote`로 비밀 토큰 검증 후 배송정보만 반환 |
| `gq_read_admin_shipping_v26` | 기존 `gq_is_admin()` 검증 후 요청한 주문들의 배송정보 반환 |

기존 함수·트리거는 교체하지 않고 `gq_quotes`의 컬럼/값도 변경하지 않습니다. 기존 자동 배송완료 로직이 계속 원래 주문 상태를 관리합니다. 이미 같은 이름의 새 객체가 있으면 재실행도 실패하도록 했습니다. 기존 배포를 무심코 덮어쓰지 마세요.

새 조회 RPC는 묶음 부모/자식 관계를 서버에서 확인하고 취소 주문을 제외합니다. 하나의 롯데 송장인 경우에만 모든 주문이 그 송장과 저장 이력을 공유합니다. 다른 송장·운송사가 섞이면 공유 데이터를 반환하지 않습니다. 구매자에게 다른 주문의 토큰·개인정보·주문 전체를 노출하지 않습니다.

## 3. Apps Script 저장 연결

v26 대안을 선택할 때만 추가합니다. `lotteTrackDetailsV25_`의 **실제 조회 성공 결과**로 기존 `gq_lotte_save_tracking_v25`에 보내는 것과 같은 아래 여섯 필드를 `gq_lotte_store_details_v26`에도 보냅니다. 이미 사용하는 서버 측 Supabase 인증 설정을 재사용하고 키를 HTML/GitHub/로그에 복사하지 마세요.

```
POST <기존 Supabase URL>/rest/v1/rpc/gq_lotte_store_details_v26
서버 측 service_role 인증 및 Content-Type: application/json 사용

본문 필드:
p_tracking_number: 실제 조회한 송장번호 문자열
p_status_code: 실제 API 상태 코드 또는 null
p_status_label: 실제 API 상태 문구 또는 null
p_event_time: 실제 API 최근 이벤트 시각 또는 null
p_events: 실제 API 이벤트 배열 (JSON 문자열이 아니라 배열)
p_tracking_url: 실제 API 조회 URL 또는 null
```

새 저장 RPC는 service_role 전용입니다. 기존 v25가 publishable/anon 키와 별도 인증 인자를 사용한다면 동일 헤더만으로는 새 저장 RPC를 호출할 수 없습니다. 접근권한을 낮추지 말고, 서버의 안전한 설정에서 service_role 인증을 사용하거나 현재 v25 저장 구조를 재사용하는 어댑터를 선택하세요. service_role 키는 브라우저·문서·Git에 저장하지 않습니다.

기존 v25 RPC의 추가 매개변수는 새 RPC에 보내지 마세요. `p_events`는 문자열 `{time, location, status}` 형태와 Delivery Tracker의 `{time, location:{name}, status:{name}}` 형태를 화면에서 지원합니다. 다른 실제 이벤트 구조라면 실제 결과의 키 이름에 맞춰 어댑터를 조정해야 합니다. API 응답에 없는 값을 채우지 마세요.

추가 저장 호출은 별도 try/catch에서 HTTP 응답을 확인하고, 실패하더라도 **기존 `lotteConfirmDelivery_` 호출과 자동 완료 실행은 계속**되어야 합니다. 기존 저장 호출이나 자동 완료 호출을 새 저장 호출로 교체하지 마세요. 이미 사용 중인 v25 저장이 충분하다면 중복 저장 대신 그 결과를 새 조회 응답 계약으로 매핑하세요.

## 4. 실제 결과 확인

1. 기존 자동조회로 실제 송장 한 건을 다시 조회합니다.
2. SQL Editor에서 `select tracking_number,status_code,status_label,jsonb_array_length(events) as event_count,fetched_at from public.gq_shipment_details_v26;`로 저장을 확인합니다. 실제 송장번호가 포함되므로 결과는 공개하지 마세요.
3. 관리자와 구매자 비밀 링크에서 같은 송장·상태·실제 이력이 보이는지 확인합니다. 자식 주문에 송장이 비어 있어도 새 조회 RPC가 대표 송장을 공유합니다.
4. 묶음 일부가 먼저 완료돼도 하나의 카드인지, 가격·입금·배송비가 그대로인지 확인합니다.
5. 잘못된 비밀 토큰으로 배송정보를 읽지 못하는지 확인합니다. 기존 자동 배송완료도 원래 방식으로 확인합니다.

RPC가 아직 설치되지 않았거나 저장 이력이 없으면 기존 화면과 공식 링크를 계속 사용할 수 있습니다. 프런트엔드는 새 선택적 RPC 오류 때문에 기존 주문 읽기를 실패시키지 않으며 자동 완료 요청을 보내지 않습니다. 실제 서버 데이터 검증 전에는 내부 이력 연동 완료로 간주하지 않습니다.

## 개발 검증

- `node --test tests/shipping.cjs`
- 로컬 정적 서버를 실행한 상태에서 `node tests/shipping-browser.cjs` (Playwright·Chromium 필요, API 요청은 모두 테스트 응답으로 차단)
- `tests/shipping-db-fixture.sql` → `sql/02-optional-shipping-v26.sql` → `tests/shipping-db-assertions.sql`을 **빈 테스트 PostgreSQL DB에서만** 순서대로 실행합니다. fixture는 Supabase에서 실행하지 마세요.
- inline JavaScript 구문 검사, 브라우저의 실제 DOM·링크·배송이력 펼치기 검사, `git diff --check`

테스트 픽스처는 테스트 전용이며 앱의 실제 배송이력으로 제공하지 않습니다. GitHub 반영 대상은 `index.html`, `tests/`, `sql/`, 이 문서입니다. 실제 Supabase 변경이나 GitHub push는 수행하지 않았습니다.
