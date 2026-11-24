-- 게임 프로필 생성을 opt-in 으로 바꾼다.
-- 이 프로젝트의 Auth 는 다른 앱(status-window, 별도 스키마)과 함께 쓴다. 그 앱의 가입자가
-- 게임 유저(명단·순위)로 나타나거나, 아이디 충돌로 가입이 막히지 않도록 한다.
--   · 게스트(익명) 로그인         → 지금처럼 항상 프로필 생성
--   · 그 밖의 계정               → user_metadata.paddock = true 일 때만 프로필 생성
-- 관리자 발급은 '게임 유저로 등록'을 골라야(p_paddock = true) 표시가 붙는다. 기본은 해제.

CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'app'
    AS $$
declare
  v_name   text := coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1));
  v_hidden boolean := (v_name = app.hidden_name());
begin
  if not coalesce(new.is_anonymous, false)
     and coalesce(new.raw_user_meta_data->>'paddock', '') <> 'true' then
    return new;
  end if;

  insert into public.profiles
    (id, username, coins, plays_used, last_reset, hl_card, hp, hp_at, meals_at, hidden)
  values (
    new.id,
    v_name,
    app.initial_coins(),
    0,
    app.today_kst(),
    app.hl_draw(),
    app.hp_max(),
    now(),
    now(),
    v_hidden
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- 계정 발급: p_paddock 인자를 더한다(기본 false).
DROP FUNCTION public.panel_add_player(p_name text);
DROP FUNCTION public.admin_create_player(p_username text, p_password text);

CREATE FUNCTION public.admin_create_player(p_username text, p_password text, p_paddock boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions', 'app'
    AS $$
declare
  v_username text := lower(btrim(coalesce(p_username, '')));
  v_email    text;
  v_id       uuid := gen_random_uuid();
begin
  if not app.username_valid(v_username) then raise exception 'INVALID_NAME'; end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'INVALID_PASSWORD'; end if;

  v_email := public.username_to_email(v_username);
  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'NAME_TAKEN';
  end if;

  -- 주의: 아래 토큰 컬럼들을 반드시 빈 문자열('')로 채워야 한다.
  -- 인증 서버(GoTrue)는 이 컬럼들을 NULL 을 허용하지 않는 문자열로 읽기 때문에,
  -- NULL 로 두면 로그인할 때 "Database error querying schema" 500 이 발생한다.
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous,
    confirmation_token, recovery_token,
    email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id,
    'authenticated', 'authenticated',
    v_email, extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('username', v_username, 'paddock', coalesce(p_paddock, false)),
    false, false,
    '', '',
    '', '', '',
    '', '', ''
  );

  -- 비밀번호 로그인이 동작하려면 identities 행이 함께 있어야 한다.
  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), v_id, v_id::text,
    jsonb_build_object('sub', v_id::text, 'email', v_email),
    'email', now(), now(), now()
  );

  return v_username;
end;
$$;

-- 관리자 화면의 플레이어 추가. 초기 비밀번호는 응답으로 한 번만 보여 준다.
CREATE FUNCTION public.panel_add_player(p_name text, p_paddock boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'app'
    AS $$
declare
  v_name text := lower(btrim(coalesce(p_name, '')));
  v_pw   text;
begin
  perform app.require_admin();
  if not app.username_valid(v_name) then raise exception 'INVALID_NAME'; end if;
  if exists (select 1 from public.profiles where username = v_name) then
    raise exception 'NAME_TAKEN';
  end if;

  v_pw := app.gen_password();
  perform public.admin_create_player(v_name, v_pw, p_paddock);

  return jsonb_build_object('name', v_name, 'password', v_pw, 'paddock', coalesce(p_paddock, false));
end;
$$;

REVOKE ALL ON FUNCTION public.admin_create_player(p_username text, p_password text, p_paddock boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_create_player(p_username text, p_password text, p_paddock boolean) TO service_role;

REVOKE ALL ON FUNCTION public.panel_add_player(p_name text, p_paddock boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.panel_add_player(p_name text, p_paddock boolean) TO anon;
GRANT ALL ON FUNCTION public.panel_add_player(p_name text, p_paddock boolean) TO authenticated;
GRANT ALL ON FUNCTION public.panel_add_player(p_name text, p_paddock boolean) TO service_role;

-- 이미 게임 프로필이 있는 일반 계정(admin, demo01~03 등)에 등록 표시를 붙인다. 데이터·화면은 그대로다.
update auth.users u
   set raw_user_meta_data = coalesce(u.raw_user_meta_data, '{}'::jsonb) || '{"paddock": true}'::jsonb
 where not coalesce(u.is_anonymous, false)
   and exists (select 1 from public.profiles p where p.id = u.id);
