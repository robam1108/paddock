-- 게임 프로필은 opt-in: 게스트이거나 user_metadata.paddock = true 일 때만 만든다.
begin;
select plan(5);

-- Auth 를 함께 쓰는 다른 앱의 이메일 가입(표시 없음) → 프로필 없음
insert into auth.users (id, aud, role, email, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000a1', 'authenticated', 'authenticated',
        'demo01@other-app.test', '{}'::jsonb, now(), now());
select ok(not exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'),
          '표시 없는 가입은 게임 프로필을 만들지 않는다(아이디가 겹쳐도 가입은 성공)');

-- 표시가 있으면 프로필 생성
insert into auth.users (id, aud, role, email, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000a2', 'authenticated', 'authenticated',
        'optin01@x.test', '{"username":"optin01","paddock":true}'::jsonb, now(), now());
select ok(exists (select 1 from public.profiles where username = 'optin01'),
          'paddock = true 이면 게임 프로필을 만든다');

-- 관리자 발급: 기본은 프로필 없음, 선택하면 생성
select public.admin_create_player('optout02', 'pw-123456');
select ok(not exists (select 1 from public.profiles where username = 'optout02'),
          '관리자 발급 기본값(해제)은 프로필을 만들지 않는다');
select public.admin_create_player('optin03', 'pw-123456', true);
select ok(exists (select 1 from public.profiles where username = 'optin03'),
          '관리자 발급에서 등록을 고르면 프로필을 만든다');

-- 시드 계정은 등록 표시를 갖는다
select ok((select raw_user_meta_data->>'paddock' from auth.users u
            join public.profiles p on p.id = u.id where p.username = 'demo01') = 'true',
          '시드 계정 demo01 에 등록 표시가 있다');

select * from finish();
rollback;
