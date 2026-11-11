# 1. 클라이언트를 신뢰하지 않는 설계

## 문제

Supabase 앱은 브라우저가 DB에 직접 붙는다. 누구든 개발자 도구를 열면 공개 키로 테이블과 RPC를 마음대로 호출할 수 있다. 코인이 걸린 게임이라면 "화면에서 버튼을 숨겼다"는 아무 의미가 없다.

## 결정

**쓰기는 전부 서버 함수가 한다.**
- 게임 판정은 `public.play_game(p_game, p_bet, p_choice)` 하나로 처리한다 ([games 마이그레이션](../../supabase/migrations/20261111000300_games.sql)). 이 함수는 `SECURITY DEFINER`로 실행되고, 다음 순서를 한 트랜잭션 안에서 끝낸다.
  1. 입력을 검증한다.
  2. 잔액을 확인하고 판돈을 차감한다.
  3. 서버에서 난수를 뽑는다.
  4. 배당을 계산한다.
  5. 게임 기록(`game_rounds`)과 원장(`ledger`)을 남긴다.
- 클라이언트는 결과를 받아 애니메이션으로 보여 주기만 한다.

**RLS는 SELECT 정책만 둔다.**
- `profiles`, `ledger`, `game_rounds`, `inventories` 같은 테이블에는 읽기 정책만 있다. INSERT·UPDATE·DELETE 정책이 하나도 없으므로 직접 쓰는 요청은 모두 막힌다.
- `profiles`는 컬럼 단위 `GRANT SELECT(...)`로 다른 사람에게 보여도 되는 컬럼만 연다.

**관리자와 내부 함수는 노출하지 않는다.**
- 내부 함수는 `app` 스키마에 두고 `REVOKE ALL ... FROM PUBLIC`으로 막는다.
- 공개 관리자 RPC는 함수 안에서 관리자 여부를 확인하고, 아니면 `NOT_ADMIN`을 던진다.

**규칙 값의 정본은 서버다.**
- 배당표와 확률은 `app.*` 상수 함수에 있다. 화면은 `get_rules()`로 같은 값을 받아 그린다 ([rules 마이그레이션](../../supabase/migrations/20261111001100_rules.sql)).
- 클라이언트에 같은 숫자를 따로 적어 두지 않으므로, 서버와 화면의 배당이 어긋날 일이 없다.

## 실제로 뚫렸던 경로

운영 중에 `highlow_continue(p_choice)`에 `null`을 넣으면 무조건 이기는 버그가 있었다.
- 원인은 입력 검사를 `if p_choice not in (...)`으로만 한 것이다. SQL에서 `null not in (...)`의 결과는 `null`이라 검사를 그냥 통과한다. 그 뒤 승패 변수도 `null`이 되어 `if not v_win`이 거짓으로 처리됐다.
- 그 결과 브라우저 콘솔에서 RPC를 세 번 호출하면 판돈의 512배를 받을 수 있었다.
- 수정: `null`이면 `INVALID_CHOICE`로 거부하고, 승패를 `coalesce(..., false)`로 감쌌다.

"서버가 판정한다"는 원칙만으로는 충분하지 않았다. 서버 함수의 입력 검증도 클라이언트를 의심하는 쪽으로 써야 한다.

## 결과

[`supabase/tests/03_security.sql`](../../supabase/tests/03_security.sql)이 다음을 회귀 테스트로 고정한다.
- 로그인한 사용자가 `profiles.coins`, `plays_used`를 직접 UPDATE하거나 `ledger`에 직접 INSERT하면 값이 바뀌지 않거나 거부된다.
- `highlow_continue(null)`은 `INVALID_CHOICE`를 던진다. 운영 중 실제로 뚫렸던 경로다.
- 키노의 중복 번호와 판돈 0은 거부된다.
- 일반 사용자가 관리자 함수를 부르면 `NOT_ADMIN`, 로그인하지 않으면 `AUTH_REQUIRED`가 나온다.

CI는 PR마다 `supabase test db`로 이 테스트를 돌린다.

## 한계와 다음에 한다면

- 로직이 DB 함수에 있으면 원자성과 우회 차단은 확실하다. 대신 디버깅과 단위 테스트가 어렵다. pgTAP으로 일부를 보완했지만, 게임이 더 늘어나면 판정 로직을 순수 함수로 떼어 내 시뮬레이션 테스트를 늘리는 쪽을 택하겠다.
- 정책을 테이블마다 손으로 쓰기 때문에 하나를 빠뜨릴 수 있다. 다음에는 "모든 public 테이블에 쓰기 정책이 없다"를 검사하는 메타 테스트를 추가하겠다.
