-- 비례의 전설 · Supabase 한 번에 설치 (01~03을 합친 파일)
-- SQL Editor에 전체를 붙여 넣고 Run 하세요. 여러 번 실행해도 안전합니다.

-- =====================================================================
-- 비례의 전설 · 1단계: 표와 권한
-- Supabase 대시보드 > SQL Editor에 붙여 넣고 Run 하세요.
-- (setup.sql 하나로 1~3단계를 한 번에 실행해도 됩니다.)
-- =====================================================================

-- 방
create table if not exists public.rooms (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[0-9]{4}$'),
  status        text not null default 'waiting' check (status in ('waiting','playing','ended')),
  level         int  not null check (level between 1 and 4),
  duration_sec  int  not null check (duration_sec in (180, 300, 420)),
  bonus_on      boolean not null default true,
  blind_on      boolean not null default true,   -- 마지막 30초 자동 블라인드
  blind_manual  boolean not null default false,  -- 선생님이 버튼으로 켠 블라인드
  golden_until  timestamptz,
  started_at    timestamptz,
  ends_at       timestamptz,
  created_at    timestamptz not null default now()
);

-- 학생 (별명·동물만 받는다)
create table if not exists public.players (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  nickname   text not null check (char_length(nickname) between 1 and 10),
  animal     text not null,
  score      int  not null default 0,
  correct    int  not null default 0,
  bonus      int  not null default 0,
  solved     int  not null default 0,
  joined_at  timestamptz not null default clock_timestamp(),
  unique (room_id, nickname)
);
create index if not exists players_room_idx on public.players(room_id);

-- 선생님 비밀 코드
create table if not exists public.room_secrets (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  secret  text not null
);

-- 학생 토큰과 지금 문제
create table if not exists public.player_secrets (
  player_id     uuid primary key references public.players(id) on delete cascade,
  room_id       uuid not null references public.rooms(id) on delete cascade,
  token         text not null unique,
  current_no    int,
  choice_order  int[],
  solved_nos    int[] not null default '{}',
  last_type     text,
  locked_until  timestamptz
);

-- 게임 시작 때 만든 문제
create table if not exists public.room_problems (
  room_id    uuid not null references public.rooms(id) on delete cascade,
  no         int  not null,
  level      int  not null,
  type_code  text not null,
  question   text not null,
  choices    text[] not null,
  answer     int  not null,          -- choices 안의 정답 위치(0부터)
  hint       text,
  explain    text,
  visual     jsonb,
  primary key (room_id, no)
);

-- 답안 기록
create table if not exists public.answers (
  id          bigint generated always as identity primary key,
  room_id     uuid not null references public.rooms(id) on delete cascade,
  player_id   uuid not null references public.players(id) on delete cascade,
  problem_no  int  not null,
  type_code   text not null,
  chosen      int  not null,
  is_correct  boolean not null,
  points      int  not null,
  bonus       int  not null,
  created_at  timestamptz not null default now()
);
create index if not exists answers_room_idx on public.answers(room_id);

-- 문장제 소재(사람 이름)
create table if not exists public.story_materials (
  id    serial primary key,
  kind  text not null,
  value text not null
);
insert into public.story_materials(kind, value)
select 'name', v from unnest(array['하윤','시후','은채','재민','서영','도연','하람','승우','민준','지우','서준','예린']) v
where not exists (select 1 from public.story_materials where kind = 'name');

-- ---------------------------------------------------------------------
-- 권한: 브라우저(anon)는 rooms·players 읽기만. 나머지는 함수로만.
-- ---------------------------------------------------------------------
alter table public.rooms           enable row level security;
alter table public.players         enable row level security;
alter table public.room_secrets    enable row level security;
alter table public.player_secrets  enable row level security;
alter table public.room_problems   enable row level security;
alter table public.answers         enable row level security;
alter table public.story_materials enable row level security;

drop policy if exists "rooms read"   on public.rooms;
drop policy if exists "players read" on public.players;
create policy "rooms read"   on public.rooms   for select to anon, authenticated using (true);
create policy "players read" on public.players for select to anon, authenticated using (true);
-- 추가·수정·삭제 정책은 일부러 만들지 않는다.

revoke all on public.rooms, public.players from anon, authenticated;
grant select on public.rooms, public.players to anon, authenticated;
revoke all on public.room_secrets, public.player_secrets, public.room_problems,
              public.answers, public.story_materials from anon, authenticated;

-- 실시간 알림은 rooms와 players에만
alter table public.rooms   replica identity full;
alter table public.players replica identity full;
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.rooms;
    exception when duplicate_object then null;
    end;
    begin
      alter publication supabase_realtime add table public.players;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- =====================================================================
-- 비례의 전설 · 2단계: 문제 자동 생성기 (PRD 6-7, 6-8)
-- 유형 28개(A1~D6). 게임을 시작할 때마다 숫자·소재·보기를 새로 만든다.
-- 문제 글 표기: 분수 {2/3}, 대분수 {1 1/2}, 빈칸 □, ㉠ ㉡, 줄바꿈 \n
-- =====================================================================

do $$ begin
  create type public.gen_problem as (
    question text, choices text[], answer int, hint text, explain text, visual jsonb
  );
exception when duplicate_object then null;
end $$;

-- ---------- 작은 도구 ----------
create or replace function public._ri(lo int, hi int) returns int
language sql volatile as $$ select lo + floor(random() * (hi - lo + 1))::int $$;

create or replace function public._gcd(a int, b int) returns int
language plpgsql immutable as $$
declare t int;
begin
  a := abs(a); b := abs(b);
  while b <> 0 loop t := b; b := a % b; a := t; end loop;
  return a;
end $$;

create or replace function public._lcm(a int, b int) returns int
language sql immutable as $$ select a / public._gcd(a, b) * b $$;

-- 공약수가 1뿐이고 서로 다른 두 수
create or replace function public._cop(lo int, hi int) returns int[]
language plpgsql volatile as $$
declare a int; b int;
begin
  loop
    a := public._ri(lo, hi); b := public._ri(lo, hi);
    exit when a <> b and public._gcd(a, b) = 1;
  end loop;
  return array[a, b];
end $$;

create or replace function public._pick(arr text[]) returns text
language sql volatile as $$ select arr[1 + floor(random() * array_length(arr, 1))::int] $$;

create or replace function public._n(x numeric) returns text
language sql immutable as $$ select trim_scale(x)::text $$;

create or replace function public._r(a numeric, b numeric) returns text
language sql immutable as $$ select public._n(a) || ' : ' || public._n(b) $$;

create or replace function public._f(n int, d int) returns text
language sql immutable as $$ select '{' || n || '/' || d || '}' $$;

create or replace function public._pos(x int) returns text
language sql immutable as $$ select case when x > 0 then x::text end $$;

create or replace function public._two_names() returns text[]
language sql volatile as $$
  select array_agg(value) from (
    select value from public.story_materials where kind = 'name' order by random() limit 2
  ) s
$$;

-- 4지선다 만들기: 오답 후보에서 정답·중복·빈값을 빼고 3개를 고른다
create or replace function public._mk(q text, correct text, wrongs text[], hint text, expl text, vis jsonb default null)
returns public.gen_problem language plpgsql immutable as $$
declare ch text[] := array[correct]; w text;
begin
  foreach w in array wrongs loop
    exit when array_length(ch, 1) >= 4;
    if w is not null and w <> '' and w <> all(ch) then ch := ch || w; end if;
  end loop;
  if array_length(ch, 1) < 4 then return null; end if;
  return row(q, ch, 0, hint, expl, vis)::public.gen_problem;
end $$;

-- O/X 만들기
create or replace function public._ox(q text, truth boolean, hint text, expl text, vis jsonb default null)
returns public.gen_problem language sql immutable as $$
  select row(q, array['O','X'], case when truth then 0 else 1 end, hint, expl, vis)::public.gen_problem
$$;

create or replace function public._prop_vis(t1 text, t2 text, t3 text, t4 text) returns jsonb
language sql immutable as $$ select jsonb_build_object('kind','prop','terms',jsonb_build_array(t1,t2,t3,t4)) $$;

create or replace function public._bar_vis(a int, b int, la text, lb text, total text) returns jsonb
language sql immutable as $$ select jsonb_build_object('kind','bar','a',a,'b',b,'la',la,'lb',lb,'total',total) $$;

-- =====================================================================
-- 묶음 A — 기초
-- =====================================================================
create or replace function public._g_a1() returns public.gen_problem language plpgsql volatile as $$
declare a int := public._ri(2, 20); b int;
begin
  loop b := public._ri(2, 20); exit when b <> a; end loop;
  if random() < 0.5 then
    return public._mk(format('%s : %s에서 전항은 무엇일까요?', a, b), a::text,
      array[b::text, (a + b)::text, public._pos(abs(a - b)), (a * b)::text],
      '기호 : 앞에 있는 수가 전항이에요.',
      format('앞에 있는 수가 전항, 뒤에 있는 수가 후항이에요. (전항 %s, 후항 %s)', a, b));
  end if;
  return public._mk(format('%s : %s에서 후항은 무엇일까요?', a, b), b::text,
    array[a::text, (a + b)::text, public._pos(abs(a - b)), (a * b)::text],
    '기호 : 뒤에 있는 수가 후항이에요.',
    format('앞에 있는 수가 전항, 뒤에 있는 수가 후항이에요. (전항 %s, 후항 %s)', a, b));
end $$;

create or replace function public._g_a2() returns public.gen_problem language plpgsql volatile as $$
declare p int[] := public._cop(2, 12); a int := p[1]; b int := p[2]; k int := public._ri(2, 6);
        c int := a * k; d int := b * k; e text; v jsonb;
begin
  e := format('%s : %s = %s : %s', a, b, c, d);
  v := public._prop_vis(a::text, b::text, c::text, d::text);
  if random() < 0.5 then
    return public._mk(e || E'\n외항을 모두 고르면?', format('%s, %s', a, d),
      array[format('%s, %s', b, c), format('%s, %s', a, b), format('%s, %s', c, d), format('%s, %s', a, c)],
      '비례식에서 바깥쪽 두 수가 외항이에요.',
      format('%s에서 외항은 바깥쪽 %s, %s이고 내항은 안쪽 %s, %s입니다.', e, a, d, b, c), v);
  end if;
  return public._mk(e || E'\n내항을 모두 고르면?', format('%s, %s', b, c),
    array[format('%s, %s', a, d), format('%s, %s', a, b), format('%s, %s', c, d), format('%s, %s', b, d)],
    '비례식에서 안쪽 두 수가 내항이에요.',
    format('%s에서 외항은 바깥쪽 %s, %s이고 내항은 안쪽 %s, %s입니다.', e, a, d, b, c), v);
end $$;

create or replace function public._g_a3() returns public.gen_problem language plpgsql volatile as $$
declare
  fixed text[] := array[
    'O|비의 전항과 후항에 0이 아닌 같은 수를 곱해도 비율은 같아요.',
    'X|비의 전항과 후항에 0을 곱해도 비율은 같아요.',
    'O|비의 전항과 후항을 0이 아닌 같은 수로 나누어도 비율은 같아요.',
    'X|비의 전항과 후항에 같은 수를 더해도 비율은 같아요.',
    'X|비의 전항에만 어떤 수를 곱해도 비율은 같아요.',
    'X|비의 전항과 후항에서 같은 수를 빼도 비율은 같아요.'];
  s text; p int[]; a int; b int; k int; truth boolean;
begin
  if random() < 0.45 then
    s := public._pick(fixed);
    return public._ox(substr(s, 3), left(s, 1) = 'O',
      '전항과 후항에 0이 아닌 같은 수를 곱하거나 나누어야 비율이 같아요.',
      '비의 전항과 후항에 0이 아닌 같은 수를 곱하거나 나누어도 비율은 같습니다. 더하거나 빼면 비율이 달라집니다.');
  end if;
  p := public._cop(1, 9); a := p[1]; b := p[2]; k := public._ri(2, 9); truth := random() < 0.5;
  if random() < 0.5 then
    return public._ox(
      format(E'%s : %s의 두 항에 모두 ×%s → %s\n두 비의 비율은 같아요.', a, b, k,
             case when truth then public._r(a * k, b * k) else public._r(a * k, b * k + k) end),
      truth, '전항과 후항에 똑같이 곱했는지 확인해 보세요.',
      format('%s의 두 항에 모두 ×%s 하면 %s입니다.', public._r(a, b), k, public._r(a * k, b * k)));
  end if;
  return public._ox(
    format(E'%s의 두 항을 모두 ÷%s → %s\n두 비의 비율은 같아요.', public._r(a * k, b * k), k,
           case when truth then public._r(a, b) else public._r(a, b + 1) end),
    truth, '전항과 후항을 똑같이 나누었는지 확인해 보세요.',
    format('%s의 두 항을 모두 ÷%s 하면 %s입니다.', public._r(a * k, b * k), k, public._r(a, b)));
end $$;

create or replace function public._g_a4() returns public.gen_problem language plpgsql volatile as $$
declare a int := public._ri(1, 9); b int; k int := public._ri(2, 9);
begin
  loop b := public._ri(1, 9); exit when b <> a; end loop;
  return public._mk(format('%s의 전항과 후항에 각각 %s배를 한 비는?', public._r(a, b), k),
    public._r(a * k, b * k),
    array[public._r(a * k, b), public._r(a + k, b + k), public._r(a, b * k), public._r(b * k, a * k)],
    '전항과 후항에 똑같이 곱해야 해요.',
    format('%s × %s = %s, %s × %s = %s이므로 %s입니다.', a, k, a * k, b, k, b * k, public._r(a * k, b * k)));
end $$;

create or replace function public._g_a5() returns public.gen_problem language plpgsql volatile as $$
declare p int[] := public._cop(2, 9); a int := p[1]; b int := p[2]; k int := public._ri(2, 6);
begin
  return public._mk(format('%s의 비율과 같은 비를 고르세요.', public._r(a, b)),
    public._r(a * k, b * k),
    array[public._r(a + k, b + k), public._r(b * k, a * k), public._r(a * k, b + k), public._r(a * k, b * (k + 1))],
    '전항과 후항에 0이 아닌 같은 수를 곱한 비를 찾아보세요.',
    format('%s의 두 항에 모두 ×%s 하면 %s입니다.', public._r(a, b), k, public._r(a * k, b * k)));
end $$;

create or replace function public._g_a6() returns public.gen_problem language plpgsql volatile as $$
declare p int[] := public._cop(1, 9); a int := p[1]; b int := p[2]; k int := public._ri(2, 6);
        truth boolean := random() < 0.5; c int; d int;
begin
  if truth then c := a * k; d := b * k;
  elsif random() < 0.5 then c := a + k; d := b + k;
  else c := b * k; d := a * k;
  end if;
  return public._ox(format(E'%s : %s = %s : %s\n옳은 비례식이면 O, 아니면 X', a, b, c, d), truth,
    '외항의 곱과 내항의 곱이 같은지 확인해 보세요.',
    format('외항의 곱 %s × %s = %s, 내항의 곱 %s × %s = %s이므로 %s', a, d, a * d, b, c, b * c,
           case when truth then '옳은 비례식입니다.' else '옳은 비례식이 아닙니다.' end),
    public._prop_vis(a::text, b::text, c::text, d::text));
end $$;

create or replace function public._g_a7() returns public.gen_problem language plpgsql volatile as $$
declare
  fixed text[] := array[
    'O|비례식에서 외항의 곱과 내항의 곱은 같아요.',
    'X|비례식에서 외항의 합과 내항의 합은 항상 같아요.',
    'O|비율이 같은 두 비를 기호 =를 사용하여 나타낸 식을 비례식이라고 해요.',
    'X|비율이 다른 두 비도 기호 =로 이어 쓰면 비례식이에요.',
    'X|비례식에서 외항의 곱은 내항의 곱의 2배예요.'];
  s text; p int[]; a int; b int; k int; e text; truth boolean; outer_q boolean;
begin
  if random() < 0.45 then
    s := public._pick(fixed);
    return public._ox(substr(s, 3), left(s, 1) = 'O',
      '비례식에서 외항의 곱과 내항의 곱은 같아요.',
      '비율이 같은 두 비를 =로 나타낸 식이 비례식이고, 비례식에서 외항의 곱과 내항의 곱은 같습니다.');
  end if;
  p := public._cop(1, 9); a := p[1]; b := p[2]; k := public._ri(2, 6);
  e := format('%s : %s = %s : %s', a, b, a * k, b * k);
  truth := random() < 0.5; outer_q := random() < 0.5;
  return public._ox(
    format(E'%s에서\n%s → %s', e, case when outer_q then '외항' else '내항' end,
      case when outer_q = truth then format('%s, %s', a, b * k) else format('%s, %s', b, a * k) end),
    truth, '바깥쪽 두 수가 외항, 안쪽 두 수가 내항이에요.',
    format('%s에서 외항은 %s, %s이고 내항은 %s, %s입니다.', e, a, b * k, b, a * k),
    public._prop_vis(a::text, b::text, (a * k)::text, (b * k)::text));
end $$;

create or replace function public._g_a8() returns public.gen_problem language plpgsql volatile as $$
declare r int := public._ri(1, 6); p int[] := public._cop(2, 9); a int := p[1]; b int := p[2]; k int := public._ri(2, 5);
begin
  case r
  when 1 then return public._mk('전체를 주어진 비로 나누는 것을 무엇이라고 할까요?', '비례배분',
      array['비례식', '비율', '외항'], '전체를 비에 맞게 나누어 주는 것이에요.', '전체를 주어진 비로 나누는 것을 비례배분이라고 합니다.');
  when 2 then return public._mk('비율이 같은 두 비를 기호 =를 사용하여 나타낸 식을 무엇이라고 할까요?', '비례식',
      array['비례배분', '비율', '전항'], '=로 두 비를 이은 식이에요.', '비율이 같은 두 비를 기호 =를 사용하여 나타낸 식을 비례식이라고 합니다.');
  when 3 then return public._mk(format('비 %s에서 앞에 있는 수를 무엇이라고 할까요?', public._r(a, b)), '전항',
      array['후항', '외항', '내항'], '기호 : 앞에 있는 수예요.', '비에서 기호 : 앞에 있는 수를 전항, 뒤에 있는 수를 후항이라고 합니다.');
  when 4 then return public._mk(format('비 %s에서 뒤에 있는 수를 무엇이라고 할까요?', public._r(a, b)), '후항',
      array['전항', '외항', '내항'], '기호 : 뒤에 있는 수예요.', '비에서 기호 : 앞에 있는 수를 전항, 뒤에 있는 수를 후항이라고 합니다.');
  when 5 then return public._mk(format(E'비례식 %s : %s = %s : %s에서\n바깥쪽에 있는 %s, %s를 무엇이라고 할까요?', a, b, a * k, b * k, a, b * k), '외항',
      array['내항', '전항', '후항'], '바깥쪽에 있는 두 수예요.', '비례식에서 바깥쪽에 있는 두 수를 외항, 안쪽에 있는 두 수를 내항이라고 합니다.',
      public._prop_vis(a::text, b::text, (a * k)::text, (b * k)::text));
  else return public._mk(format(E'비례식 %s : %s = %s : %s에서\n안쪽에 있는 %s, %s를 무엇이라고 할까요?', a, b, a * k, b * k, b, a * k), '내항',
      array['외항', '전항', '후항'], '안쪽에 있는 두 수예요.', '비례식에서 바깥쪽에 있는 두 수를 외항, 안쪽에 있는 두 수를 내항이라고 합니다.',
      public._prop_vis(a::text, b::text, (a * k)::text, (b * k)::text));
  end case;
end $$;

-- =====================================================================
-- 묶음 B — 유형 연습
-- =====================================================================
create or replace function public._g_b1() returns public.gen_problem language plpgsql volatile as $$
declare p int[] := public._cop(2, 9); a int := p[1]; b int := p[2]; k int := public._ri(2, 9);
        c int := a * k; d int := b * k;
begin
  if random() < 0.5 then
    return public._mk(format(E'%s : %s = %s : □\n□에 알맞은 수는?', a, b, c), d::text,
      array[public._pos(b + c - a), (d + b)::text, public._pos(d - b), (c + b)::text, (d + k)::text],
      '전항이 몇 배가 되었는지 보세요.',
      format('%s × %s = %s이므로 후항도 %s × %s = %s입니다.', a, k, c, b, k, d),
      public._prop_vis(a::text, b::text, c::text, '□'));
  end if;
  return public._mk(format(E'%s : %s = □ : %s\n□에 알맞은 수는?', a, b, d), c::text,
    array[public._pos(a + d - b), (c + a)::text, public._pos(c - a), (d + a)::text, (c + k)::text],
    '후항이 몇 배가 되었는지 보세요.',
    format('%s × %s = %s이므로 전항도 %s × %s = %s입니다.', b, k, d, a, k, c),
    public._prop_vis(a::text, b::text, '□', d::text));
end $$;

create or replace function public._g_b2() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; a int; b int; g int; dv int; part text;
begin
  loop
    p := public._cop(1, 9); a := p[1]; b := p[2]; g := public._ri(2, 12);
    exit when a * g <= 100 and b * g <= 100;
  end loop;
  select x into dv from generate_series(2, g - 1) x where g % x = 0 order by random() limit 1;
  part := case when dv is not null then public._r(a * g / dv, b * g / dv) else public._r(2 * a, 2 * b) end;
  return public._mk(format(E'%s\n간단한 자연수의 비로 나타내면?', public._r(a * g, b * g)), public._r(a, b),
    array[part, public._r(b, a), public._r(a + 1, b), public._r(a, b + 1)],
    '두 항을 최대공약수로 나누어 보세요.',
    format('두 항을 최대공약수(%s)로 나누면 %s입니다.', g, public._r(a, b)));
end $$;

create or replace function public._g_b3() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; a int; b int; m int;
begin
  loop
    p := public._cop(1, 9); a := p[1]; b := p[2]; m := public._ri(2, 9);
    exit when a * m <= 99 and b * m <= 99 and ((a * m) % 10 <> 0 or (b * m) % 10 <> 0);
  end loop;
  return public._mk(format(E'%s\n간단한 자연수의 비로 나타내면?', public._r(a * m / 10.0, b * m / 10.0)), public._r(a, b),
    array[public._r(a * m, b * m), public._r(b, a), public._r(a + 1, b), public._r(a * 10, b)],
    '두 항에 10을 곱한 뒤 다시 간단히 해 보세요.',
    format('두 항에 10을 곱하면 %s, 최대공약수(%s)로 나누면 %s입니다.', public._r(a * m, b * m), m, public._r(a, b)));
end $$;

-- 진분수 하나 (분모 lo~hi)
create or replace function public._pf(lo int, hi int) returns int[]
language plpgsql volatile as $$
declare q int; n int;
begin
  loop q := public._ri(lo, hi); n := public._ri(1, q - 1); exit when public._gcd(n, q) = 1; end loop;
  return array[n, q];
end $$;

create or replace function public._g_b4() returns public.gen_problem language plpgsql volatile as $$
declare f1 int[]; f2 int[]; n int; d int; g int; r1 int; r2 int; l int;
begin
  loop
    f1 := public._pf(2, 10); f2 := public._pf(2, 10);
    n := f1[1] * f2[2]; d := f2[1] * f1[2]; g := public._gcd(n, d); r1 := n / g; r2 := d / g;
    exit when r1 <= 20 and r2 <= 20 and r1 <> r2;
  end loop;
  l := public._lcm(f1[2], f2[2]);
  return public._mk(format(E'%s : %s\n간단한 자연수의 비로 나타내면?', public._f(f1[1], f1[2]), public._f(f2[1], f2[2])),
    public._r(r1, r2),
    array[public._r(f1[1], f2[1]), public._r(r2, r1), public._r(f1[1] * l / f1[2], f2[1] * l / f2[2]),
          public._r(r1 + 1, r2), public._r(f1[2], f2[2])],
    '두 항에 분모의 최소공배수를 곱해 보세요.',
    case when f1[1] * l / f1[2] = r1 then format('두 항에 분모의 최소공배수(%s)를 곱하면 %s입니다.', l, public._r(r1, r2))
         else format('두 항에 분모의 최소공배수(%s)를 곱하면 %s, 간단히 하면 %s입니다.', l,
           public._r(f1[1] * l / f1[2], f2[1] * l / f2[2]), public._r(r1, r2)) end);
end $$;

create or replace function public._g_b5() returns public.gen_problem language plpgsql volatile as $$
declare p int[] := public._cop(1, 9); a int := p[1]; b int := p[2]; k int := public._ri(2, 9);
        t int[]; pos int := public._ri(1, 4); v int; s text[]; add_err int; prod int;
begin
  t := array[a, b, a * k, b * k];
  v := t[pos];
  s := array[t[1]::text, t[2]::text, t[3]::text, t[4]::text];
  s[pos] := '□';
  add_err := case pos when 1 then t[3] - (t[4] - t[2]) when 2 then t[4] - (t[3] - t[1])
                      when 3 then t[1] + (t[4] - t[2]) else t[2] + (t[3] - t[1]) end;
  prod := a * b * k;
  return public._mk(format(E'%s : %s = %s : %s\n□에 알맞은 수는?', s[1], s[2], s[3], s[4]), v::text,
    array[public._pos(add_err), (v + k)::text, public._pos(v * k), public._pos(abs(v - k)), (v + 1)::text, (v * 2)::text],
    '외항의 곱 = 내항의 곱을 이용해 보세요.',
    format('외항의 곱(%s × %s)과 내항의 곱(%s × %s)이 같아야 하므로 □ = %s입니다.', s[1], s[4], s[2], s[3], v),
    public._prop_vis(s[1], s[2], s[3], s[4]));
end $$;

create or replace function public._g_b6() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; a int; b int; m int; n int; front boolean := random() < 0.5; ans int; oth int; w text[];
begin
  loop
    p := public._cop(1, 9); a := p[1]; b := p[2]; m := public._ri(2, 25); n := (a + b) * m;
    exit when n <= 200;
  end loop;
  if front then ans := a * m; oth := b * m; else ans := b * m; oth := a * m; end if;
  w := array[
    case when front and (n * a) % b = 0 then (n * a / b)::text when not front and (n * b) % a = 0 then (n * b / a)::text end,
    oth::text, case when n % 2 = 0 then (n / 2)::text end, (ans + m)::text, public._pos(ans - m)];
  return public._mk(format(E'비례배분: 전체 %s, 비 %s\n%s 몫은 얼마일까요?', n, public._r(a, b), case when front then '앞쪽' else '뒤쪽' end),
    ans::text, w,
    '전체 × (내 몫의 비 ÷ 비의 합)으로 구해요.',
    format('%s × %s = %s입니다.', n, public._f(case when front then a else b end, a + b), ans),
    public._bar_vis(a, b, '앞쪽', '뒤쪽', n::text));
end $$;

-- =====================================================================
-- 묶음 C — 응용 심화
-- =====================================================================
create or replace function public._g_c1() returns public.gen_problem language plpgsql volatile as $$
declare q int; pn int; dd int; n int; d int; g int; r1 int; r2 int; fs text; ds text; fd text; first_frac boolean := random() < 0.5;
begin
  loop
    q := (array[2, 4, 5, 10])[public._ri(1, 4)];
    loop pn := public._ri(1, q - 1); exit when public._gcd(pn, q) = 1; end loop;
    dd := public._ri(1, 19);
    continue when dd % 10 = 0;
    if first_frac then n := pn * 10; d := dd * q; else n := dd * q; d := pn * 10; end if;
    g := public._gcd(n, d); r1 := n / g; r2 := d / g;
    exit when r1 <= 20 and r2 <= 20 and r1 <> r2;
  end loop;
  fs := public._f(pn, q); ds := public._n(dd / 10.0); fd := public._n(pn::numeric / q);
  return public._mk(
    format(E'%s\n간단한 자연수의 비로 나타내면?', case when first_frac then fs || ' : ' || ds else ds || ' : ' || fs end),
    public._r(r1, r2),
    array[public._r(n, d), public._r(r2, r1),
          case when first_frac then public._r(pn, dd) else public._r(dd, pn) end, public._r(r1 + 1, r2)],
    '분수를 소수로, 또는 소수를 분수로 바꾸어 형태를 맞춰 보세요.',
    format('%s = %s 이므로 %s, 간단히 하면 %s입니다.', fs, fd,
           case when first_frac then fd || ' : ' || ds else ds || ' : ' || fd end, public._r(r1, r2)));
end $$;

create or replace function public._g_c2() returns public.gen_problem language plpgsql volatile as $$
declare w int; f1 int[]; f2 int[]; num int; n int; d int; g int; r1 int; r2 int; wn int; wd int; wg int; mixed text;
begin
  loop
    w := public._ri(1, 3); f1 := public._pf(2, 6); f2 := public._pf(2, 10);
    num := w * f1[2] + f1[1];
    n := num * f2[2]; d := f2[1] * f1[2]; g := public._gcd(n, d); r1 := n / g; r2 := d / g;
    exit when r1 <= 20 and r2 <= 20 and r1 <> r2;
  end loop;
  wn := f1[1] * f2[2]; wd := f2[1] * f1[2]; wg := public._gcd(wn, wd);
  mixed := '{' || w || ' ' || f1[1] || '/' || f1[2] || '}';
  return public._mk(format(E'%s : %s\n간단한 자연수의 비로 나타내면?', mixed, public._f(f2[1], f2[2])),
    public._r(r1, r2),
    array[public._r(wn / wg, wd / wg), public._r(r2, r1), public._r(n, d), public._r(r1 + 1, r2)],
    '대분수를 가분수로 바꾼 뒤 계산해 보세요.',
    format('%s = %s로 바꾸어 계산하면 %s입니다.', mixed, public._f(num, f1[2]), public._r(r1, r2)));
end $$;

create or replace function public._g_c3() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; a int; b int; k int; k2 int; r1 text; r2 text; r3 text; r4 text; lst text[]; dec boolean := random() < 0.6; ex text;
begin
  loop
    p := public._cop(2, 9); a := p[1]; b := p[2]; k := public._ri(2, 9);
    exit when not dec or ((a * k) % 10 <> 0 or (b * k) % 10 <> 0);
  end loop;
  k2 := public._ri(1, 5);
  r1 := public._r(a, b);
  if dec then
    r2 := public._r(a * k / 10.0, b * k / 10.0);
    ex := format('%s의 두 항에 10을 곱하고 간단히 하면 %s이므로 비율이 같습니다.', r2, r1);
  else
    r2 := public._r(a * k, b * k);
    ex := format('%s를 간단히 하면 %s이므로 비율이 같습니다.', r2, r1);
  end if;
  r3 := public._f(1, a) || ' : ' || public._f(1, b);
  r4 := public._r(a + k2, b + k2);
  select array_agg(x order by random()) into lst from unnest(array[r1, r2, r3, r4]) x;
  return public._mk(format(E'%s,  %s,  %s,  %s\n비율이 같은 두 비로 세운 비례식은?', lst[1], lst[2], lst[3], lst[4]),
    r1 || ' = ' || r2,
    array[r1 || ' = ' || r3, r1 || ' = ' || r4, r3 || ' = ' || r2, r2 || ' = ' || r4],
    '각 비를 간단한 자연수의 비로 바꾸어 비교해 보세요.', ex);
end $$;

create or replace function public._g_c4() returns public.gen_problem language plpgsql volatile as $$
declare f1 int[]; f2 int[]; n int; d int; g int; r1 int; r2 int; s int := public._ri(1, 3); back boolean := random() < 0.6; ans int; given int;
begin
  loop
    f1 := public._pf(2, 10); f2 := public._pf(2, 10);
    n := f1[1] * f2[2]; d := f2[1] * f1[2]; g := public._gcd(n, d); r1 := n / g; r2 := d / g;
    exit when r1 <= 12 and r2 <= 12 and r1 <> r2;
  end loop;
  if back then ans := r2 * s; given := r1 * s; else ans := r1 * s; given := r2 * s; end if;
  return public._mk(
    case when back then format(E'%s : %s = %s : □\n□에 알맞은 수는?', public._f(f1[1], f1[2]), public._f(f2[1], f2[2]), given)
         else format(E'%s : %s = □ : %s\n□에 알맞은 수는?', public._f(f1[1], f1[2]), public._f(f2[1], f2[2]), given) end,
    ans::text,
    array[given::text, ((case when back then r2 else r1 end + 1) * s)::text, (ans + s)::text,
          (case when back then f2[1] else f1[1] end)::text, (ans * 2)::text],
    '앞의 비를 먼저 간단한 자연수의 비로 나타내 보세요.',
    format('%s : %s → 간단한 자연수의 비 %s, 따라서 □ = %s입니다.', public._f(f1[1], f1[2]), public._f(f2[1], f2[2]), public._r(r1, r2), ans));
end $$;

-- 비례식 활용 문장제 (C5: 개수, C6: 회전·속력)
create or replace function public._g_story(p_kind text) returns public.gen_problem language plpgsql volatile as $$
declare
  tpl text; unit text; ma int; mb int; idx int; p int[]; a0 int; b0 int; s int; t int;
  qa int; qb int; qc int; ans int; step int; timed boolean := false;
begin
  if p_kind = 'c5' then
    idx := public._ri(1, 4);
    tpl := (array[
      '병뚜껑 %1$s개를 담는 데 상자 %2$s개가 필요해요. 병뚜껑 %3$s개를 담으려면 상자는 몇 개가 필요할까요?',
      '친환경 신발 %2$s켤레를 만드는 데 페트병 %1$s개가 필요해요. 페트병 %3$s개로는 신발을 몇 켤레 만들 수 있을까요?',
      '헌 크레파스 %1$s g으로 새 크레파스 %2$s개를 만들어요. 헌 크레파스 %3$s g으로는 새 크레파스를 몇 개 만들 수 있을까요?',
      '책을 %1$s분 동안 %2$s쪽 읽었어요. 같은 빠르기로 %3$s분 동안 읽으면 몇 쪽을 읽을까요?'])[idx];
    unit := (array['개', '켤레', '개', '쪽'])[idx];
    ma := (array[10, 1, 10, 1])[idx]; mb := 1; timed := idx = 4;
  else
    idx := public._ri(1, 3);
    tpl := (array[
      '빨간 톱니바퀴가 %1$s바퀴 돌 때 파란 톱니바퀴는 %2$s바퀴 돌아요. 빨간 톱니바퀴가 %3$s바퀴 돌면 파란 톱니바퀴는 몇 바퀴 돌까요?',
      '일정한 빠르기로 달리는 고속 열차가 %1$s분 동안 %2$s km를 가요. 같은 빠르기로 %3$s분 동안 가면 몇 km를 갈까요?',
      '자전거를 타고 %1$s분 동안 %2$s km를 갔어요. 같은 빠르기로 %3$s분 동안 가면 몇 km를 갈까요?'])[idx];
    unit := (array['바퀴', ' km', ' km'])[idx];
    ma := (array[1, 5, 5])[idx]; mb := (array[1, 10, 1])[idx]; timed := idx > 1;
  end if;
  loop
    p := public._cop(1, 9); a0 := p[1]; b0 := p[2]; s := public._ri(1, 4); t := public._ri(2, 12);
    qa := a0 * s * ma; qb := b0 * s * mb; qc := a0 * t * ma; ans := b0 * t * mb;
    exit when t <> s and qc <= 1000 and ans <= 1000 and qa <> qb
          and (not timed or (qa <= 120 and qc <= 120));
  end loop;
  step := b0 * mb;
  return public._mk(format(tpl, qa, qb, qc), ans || unit,
    array[case when qb + qc - qa > 0 and qb + qc - qa <> ans then (qb + qc - qa) || unit end,
          (ans + step) || unit, case when ans - step > 0 then (ans - step) || unit end,
          (ans + 2 * step) || unit, (ans * 2) || unit],
    '구하는 값을 □로 놓고 비례식을 세워 보세요.',
    format('%s : %s = %s : □로 비례식을 세우면 %s × □ = %s × %s, □ = %s입니다.', qa, qb, qc, qa, qb, qc, ans));
end $$;

create or replace function public._g_c5() returns public.gen_problem language sql volatile as $$ select public._g_story('c5') $$;
create or replace function public._g_c6() returns public.gen_problem language sql volatile as $$ select public._g_story('c6') $$;

create or replace function public._g_c7() returns public.gen_problem language plpgsql volatile as $$
declare idx int := public._ri(1, 5); nm text[] := public._two_names(); p int[]; a int; b int; m int; n int;
        unit text; tpl text; la text; lb text; front boolean := random() < 0.5; ans int; oth int; who text; mstep int;
begin
  case idx
  when 1 then tpl := '우유 %1$s mL를 %2$s, %3$s 두 사람이 %4$s의 비로 나누어 마셔요. %5$s의 몫은 몇 mL일까요?'; unit := ' mL'; la := nm[1]; lb := nm[2]; mstep := 10;
  when 2 then tpl := '색종이 %1$s장을 %2$s, %3$s 두 사람이 %4$s의 비로 나누어 가져요. %5$s의 색종이는 몇 장일까요?'; unit := '장'; la := nm[1]; lb := nm[2]; mstep := 1;
  when 3 then tpl := '지갑 %1$s개를 %2$s와 %3$s에 %4$s의 비로 나누어 기부해요. %5$s에 기부하는 지갑은 몇 개일까요?'; unit := '개'; la := '행복 센터'; lb := '나눔 센터'; mstep := 1;
  when 4 then tpl := '점토 %1$s g을 %2$s과 %3$s에 %4$s의 비로 나누어 써요. %5$s에 쓰는 점토는 몇 g일까요?'; unit := ' g'; la := '컵'; lb := '컵 받침'; mstep := 10;
  else tpl := '종이띠 %1$s cm를 %2$s, %3$s 두 사람이 %4$s의 비로 나누어 가져요. %5$s의 종이띠는 몇 cm일까요?'; unit := ' cm'; la := nm[1]; lb := nm[2]; mstep := 10;
  end case;
  loop
    p := public._cop(1, 9); a := p[1]; b := p[2]; m := public._ri(2, 20) * mstep; n := (a + b) * m;
    exit when n <= 1000;
  end loop;
  if front then ans := a * m; oth := b * m; who := la; else ans := b * m; oth := a * m; who := lb; end if;
  return public._mk(format(tpl, n, la, lb, public._r(a, b), who), ans || unit,
    array[oth || unit,
          case when front and (n * a) % b = 0 then (n * a / b) || unit when not front and (n * b) % a = 0 then (n * b / a) || unit end,
          case when n % 2 = 0 then (n / 2) || unit end, (ans + m) || unit, case when ans - m > 0 then (ans - m) || unit end],
    '전체 × (내 몫의 비 ÷ 비의 합)으로 구해요.',
    format('%s × %s = %s%s입니다.', n, public._f(case when front then a else b end, a + b), ans, unit),
    public._bar_vis(a, b, la, lb, n || unit));
end $$;

create or replace function public._g_c8() returns public.gen_problem language plpgsql volatile as $$
declare s int := (array[20, 25, 30, 40, 50, 60, 80, 100, 120, 150, 200])[public._ri(1, 11)];
        m1 int := public._ri(2, 10); m2 int; r1 int; ans int;
begin
  loop m2 := public._ri(3, 20); exit when m2 <> m1 and s * m2 <= 3000; end loop;
  r1 := s * m1; ans := s * m2;
  return public._mk(format('실제 거리 %s m를 지도에 %s cm로 그렸어요. 지도에서 %s cm인 거리는 실제로 몇 m일까요?', r1, m1, m2),
    ans || ' m',
    array[(r1 * m2) || ' m', (ans + s) || ' m', case when ans - s > 0 then (ans - s) || ' m' end,
          (r1 + m2 - m1) || ' m', (ans * 2) || ' m'],
    '지도의 1 cm가 실제로 몇 m인지 먼저 구해 보세요.',
    format('지도에서 1 cm가 실제 %s m이므로 %s cm는 %s × %s = %s m입니다.', s, m2, s, m2, ans));
end $$;

-- =====================================================================
-- 묶음 D — 고난도
-- =====================================================================
create or replace function public._g_d1() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; k1 int; k2 int; a int; x int; b int; y int; pr int; ask_x boolean := random() < 0.5; ans int; oth int;
begin
  loop
    p := public._cop(1, 6); k1 := public._ri(2, 6); k2 := public._ri(2, 6);
    exit when k1 <> k2;
  end loop;
  a := p[1] * k1; x := p[2] * k1; b := p[1] * k2; y := p[2] * k2; pr := a * y;
  if ask_x then ans := x; oth := y; else ans := y; oth := x; end if;
  return public._mk(format(E'%s : ㉠ = %s : ㉡\n외항의 곱이 %s일 때 %s에 알맞은 수는?', a, b, pr, case when ask_x then '㉠' else '㉡' end),
    ans::text,
    array[oth::text, (ans + k1)::text, public._pos(abs(ans - p[2])), (ans * 2)::text, (ans + 1)::text],
    '외항의 곱과 내항의 곱은 같아요.',
    format('외항의 곱 = 내항의 곱 = %s. %s × ㉡ = %s이므로 ㉡ = %s, ㉠ × %s = %s이므로 ㉠ = %s입니다.', pr, a, pr, y, b, pr, x),
    public._prop_vis(a::text, '㉠', b::text, '㉡'));
end $$;

create or replace function public._g_d2() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; a int; b int; m int; per int; ask_w boolean := random() < 0.5; ans int; oth int; sm int;
begin
  loop
    p := public._cop(1, 9); a := p[1]; b := p[2]; m := public._ri(2, 20); per := 2 * (a + b) * m;
    exit when per <= 400;
  end loop;
  sm := (a + b) * m;
  if ask_w then ans := a * m; oth := b * m; else ans := b * m; oth := a * m; end if;
  return public._mk(format('둘레가 %s cm이고 가로와 세로의 비가 %s인 직사각형이 있어요. %s는 몇 cm일까요?', per, public._r(a, b),
                           case when ask_w then '가로' else '세로' end),
    ans || ' cm',
    array[(ans * 2) || ' cm', oth || ' cm', sm || ' cm', (ans + m) || ' cm'],
    '가로와 세로의 합은 둘레의 절반이에요.',
    format('가로와 세로의 합은 %s ÷ 2 = %s cm, %s × %s = %s cm입니다.', per, sm, sm, public._f(case when ask_w then a else b end, a + b), ans));
end $$;

create or replace function public._g_d3() returns public.gen_problem language plpgsql volatile as $$
declare pairs text[] := array['토마토|양파|토마토와 양파', '당근|양파|당근과 양파', '딸기|바나나|딸기와 바나나', '밥|채소|밥과 채소'];
        pr text[]; n1 int; n2 int; p int[]; a int; b int; u int; m1 int; m2 int; ans int;
begin
  pr := string_to_array(public._pick(pairs), '|');
  loop
    n1 := (array[2, 3, 4])[public._ri(1, 3)]; n2 := (array[2, 3, 4, 6])[public._ri(1, 4)];
    p := public._cop(1, 5); a := p[1]; b := p[2]; u := public._ri(1, 10) * 10;
    m1 := (a + b) * u * n1; m2 := (a + b) * u * n2;
    exit when n1 <> n2 and m1 <= 1000 and m2 <= 1000;
  end loop;
  ans := a * u * n2;
  return public._mk(format('%s인분 조리법에 %s를 %s의 비로 섞은 것 %s g이 들어가요. %s인분을 만들 때 필요한 %s의 양은 몇 g일까요?',
                           n1, pr[3], public._r(a, b), m1, n2, pr[1]),
    ans || ' g',
    array[(a * u * n1) || ' g', m2 || ' g', (b * u * n2) || ' g', (ans + a * u) || ' g'],
    '먼저 바꾼 인분에 필요한 섞은 양을 구해 보세요.',
    format('%s인분일 때 섞은 것은 %s ÷ %s × %s = %s g이고, %s의 양은 %s × %s = %s g입니다.', n2, m1, n1, n2, m2, pr[1], m2, public._f(a, a + b), ans));
end $$;

create or replace function public._g_d4() returns public.gen_problem language plpgsql volatile as $$
declare idx int := public._ri(1, 3); p int[] := public._cop(1, 9); a int := p[1]; b int := p[2]; m int := public._ri(2, 15);
        part int := a * m; tot int := (a + b) * m; tpl text; unit text; la text; lb text;
begin
  case idx
  when 1 then tpl := '구슬을 형과 동생이 %1$s의 비로 나누었더니 형이 %2$s개를 가졌어요. 구슬은 모두 몇 개일까요?'; unit := '개'; la := '형'; lb := '동생';
  when 2 then tpl := '사탕을 언니와 동생이 %1$s의 비로 나누었더니 언니가 %2$s개를 가졌어요. 사탕은 모두 몇 개일까요?'; unit := '개'; la := '언니'; lb := '동생';
  else tpl := '카드를 1모둠과 2모둠이 %1$s의 비로 나누었더니 1모둠이 %2$s장을 가졌어요. 카드는 모두 몇 장일까요?'; unit := '장'; la := '1모둠'; lb := '2모둠';
  end case;
  return public._mk(format(tpl, public._r(a, b), part), tot || unit,
    array[(b * m) || unit, (tot + m) || unit, (part * 2) || unit, case when (part * (a + b)) % b = 0 and part * (a + b) / b <> tot then (part * (a + b) / b) || unit end,
          (tot - m) || unit],
    '한 칸이 얼마인지 먼저 구해 보세요.',
    format('비 %s에서 %s의 %s칸이 %s%s이므로 한 칸은 %s%s, 전체 %s칸은 %s%s입니다.', public._r(a, b), la, a, part, unit, m, unit, a + b, tot, unit),
    public._bar_vis(a, b, la, lb, '?'));
end $$;

create or replace function public._g_d5() returns public.gen_problem language plpgsql volatile as $$
declare p int[]; a int; b int; m int; n int; ans int;
begin
  loop
    p := public._cop(1, 9); a := p[1]; b := p[2]; m := public._ri(2, 25); n := (a + b) * m;
    exit when n <= 300;
  end loop;
  ans := abs(a - b) * m;
  return public._mk(format(E'비례배분: 전체 %s, 비 %s\n나눈 두 수의 차는 얼마일까요?', n, public._r(a, b)),
    ans::text,
    array[(a * m)::text, (b * m)::text, m::text, (ans + m)::text, public._pos(ans - m)],
    '먼저 두 몫을 각각 구해 보세요.',
    format('%s × %s = %s, %s × %s = %s이므로 차는 %s입니다.', n, public._f(a, a + b), a * m, n, public._f(b, a + b), b * m, ans),
    public._bar_vis(a, b, '앞쪽', '뒤쪽', n::text));
end $$;

create or replace function public._g_d6() returns public.gen_problem language plpgsql volatile as $$
declare p int[] := public._cop(1, 9); a int := p[1]; b int := p[2]; m int := public._ri(2, 12); s int := (a + b) * m;
        ask_b boolean := random() < 0.5; ans int; oth int;
begin
  if ask_b then ans := b * m; oth := a * m; else ans := a * m; oth := b * m; end if;
  return public._mk(format(E'%s = ㉠ : ㉡이고 ㉠ + ㉡ = %s일 때\n%s에 알맞은 수는?', public._r(a, b), s, case when ask_b then '㉡' else '㉠' end),
    ans::text,
    array[oth::text, case when s % 2 = 0 then (s / 2)::text end, (ans + m)::text, public._pos(ans - m), (ans * 2)::text],
    '㉠ : ㉡은 앞의 비와 같아요. 합을 비례배분해 보세요.',
    format('㉠ : ㉡ = %s이므로 %s = %s × %s = %s입니다.', public._r(a, b), case when ask_b then '㉡' else '㉠' end, s,
           public._f(case when ask_b then b else a end, a + b), ans),
    public._prop_vis(a::text, b::text, '㉠', '㉡'));
end $$;

-- =====================================================================
-- 생성 관리
-- =====================================================================
create or replace function public._valid_problem(r public.gen_problem) returns boolean
language sql immutable as $$
  select r.question is not null
     and array_length(r.choices, 1) in (2, 4)
     and (select count(distinct c) from unnest(r.choices) c) = array_length(r.choices, 1)
     and r.answer between 0 and array_length(r.choices, 1) - 1
     and char_length(r.question) <= 220
$$;

create or replace function public._gen_valid(p_type text) returns public.gen_problem
language plpgsql volatile as $$
declare r public.gen_problem; i int;
begin
  for i in 1..30 loop
    execute format('select * from public.%I()', '_g_' || lower(p_type)) into r;
    if public._valid_problem(r) then return r; end if;
  end loop;
  return row('2 : 3의 비율과 같은 비를 고르세요.', array['4 : 6', '4 : 5', '3 : 2', '2 : 6'], 0,
             '전항과 후항에 0이 아닌 같은 수를 곱한 비를 찾아보세요.', '2 : 3의 두 항에 ×2를 하면 4 : 6입니다.', null)::public.gen_problem;
end $$;

-- 단계별 출제 비율 (PRD 6-2)
create or replace function public._pick_type(p_level int) returns text
language plpgsql volatile as $$
declare r float := random(); bundle text;
begin
  bundle := case p_level
    when 1 then 'A'
    when 2 then case when r < 0.2 then 'A' else 'B' end
    when 3 then case when r < 0.3 then 'B' else 'C' end
    else        case when r < 0.3 then 'C' else 'D' end
  end;
  return case bundle
    when 'A' then public._pick(array['A1','A2','A3','A4','A5','A6','A7','A8'])
    when 'B' then public._pick(array['B1','B2','B3','B4','B5','B6'])
    when 'C' then public._pick(array['C1','C2','C3','C4','C5','C6','C7','C8'])
    else          public._pick(array['D1','D2','D3','D4','D5','D6'])
  end;
end $$;

create or replace function public._generate_problems(p_room uuid, p_level int, p_count int) returns int
language plpgsql volatile as $$
declare start_no int; i int; t text; r public.gen_problem; tries int;
begin
  select coalesce(max(no), 0) into start_no from public.room_problems where room_id = p_room;
  for i in 1..p_count loop
    tries := 0;
    loop
      t := public._pick_type(p_level);
      r := public._gen_valid(t);
      tries := tries + 1;
      exit when tries >= 6 or not exists (
        select 1 from public.room_problems where room_id = p_room and question = r.question);
    end loop;
    insert into public.room_problems(room_id, no, level, type_code, question, choices, answer, hint, explain, visual)
    values (p_room, start_no + i, p_level, t, r.question, r.choices, r.answer, r.hint, r.explain, r.visual);
  end loop;
  return p_count;
end $$;

-- =====================================================================
-- 비례의 전설 · 3단계: 선생님·학생 함수 (PRD 8절)
-- 브라우저는 이 함수들로만 데이터를 바꾼다.
-- 선생님 함수는 비밀 코드, 학생 함수는 토큰이 맞을 때만 동작한다.
-- =====================================================================

create or replace function public._new_secret() returns text
language sql volatile as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

-- 선생님 확인: 맞으면 방 행을 잠그고 돌려준다
create or replace function public._teacher(p_room uuid, p_secret text) returns public.rooms
language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms;
begin
  if p_secret is null or not exists (
       select 1 from public.room_secrets where room_id = p_room and secret = p_secret) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  select * into rm from public.rooms where id = p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  return rm;
end $$;

-- 학생 확인: 토큰으로 학생 비밀 행을 잠그고 돌려준다
create or replace function public._player(p_token text) returns public.player_secrets
language plpgsql volatile security definer set search_path = public as $$
declare ps public.player_secrets;
begin
  select * into ps from public.player_secrets where token = p_token for update;
  if not found then raise exception 'BAD_TOKEN'; end if;
  return ps;
end $$;

-- 학생에게 보낼 문제 (정답은 빼고, 학생마다 섞은 보기 순서로)
create or replace function public._question_json(p_room uuid, p_no int, p_order int[]) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'no', pr.no, 'type', pr.type_code, 'question', pr.question, 'visual', pr.visual,
    'choices', (select json_agg(pr.choices[o + 1] order by i) from unnest(p_order) with ordinality u(o, i)))
  from public.room_problems pr where pr.room_id = p_room and pr.no = p_no
$$;

-- 다음 문제 고르기: 푼 문제 제외, 같은 유형 연속 피하기, 모자라면 20문제 더 만들기
create or replace function public._assign_next(p_player uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare ps public.player_secrets; rm public.rooms; pr public.room_problems; ord int[];
begin
  select * into ps from public.player_secrets where player_id = p_player for update;
  select * into rm from public.rooms where id = ps.room_id;
  select * into pr from public.room_problems
   where room_id = ps.room_id and not (no = any(ps.solved_nos)) and type_code is distinct from ps.last_type
   order by random() limit 1;
  if not found then
    select * into pr from public.room_problems
     where room_id = ps.room_id and not (no = any(ps.solved_nos))
     order by random() limit 1;
  end if;
  if not found then
    perform 1 from public.rooms where id = ps.room_id for update;
    if not exists (select 1 from public.room_problems
                    where room_id = ps.room_id and not (no = any(ps.solved_nos))) then
      perform public._generate_problems(ps.room_id, rm.level, 20);
    end if;
    select * into pr from public.room_problems
     where room_id = ps.room_id and not (no = any(ps.solved_nos))
     order by (type_code is not distinct from ps.last_type), random() limit 1;
  end if;
  select array_agg(g order by random()) into ord from generate_series(0, array_length(pr.choices, 1) - 1) g;
  update public.player_secrets set current_no = pr.no, choice_order = ord, last_type = pr.type_code
   where player_id = p_player;
  return public._question_json(ps.room_id, pr.no, ord);
end $$;

-- ---------------------------------------------------------------------
-- 모두
-- ---------------------------------------------------------------------
create or replace function public.server_time() returns timestamptz
language sql stable as $$ select clock_timestamp() $$;

-- ---------------------------------------------------------------------
-- 선생님
-- ---------------------------------------------------------------------
create or replace function public.create_room(p_level int, p_duration int, p_bonus boolean, p_blind boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare v_code text; v_id uuid; v_secret text := public._new_secret(); i int := 0;
begin
  if p_level not between 1 and 4 then raise exception 'BAD_LEVEL'; end if;
  if p_duration not in (180, 300, 420) then raise exception 'BAD_DURATION'; end if;
  -- pg_cron이 없어도 오래된 방은 지운다(만든 지 24시간)
  delete from public.rooms where created_at < now() - interval '24 hours';
  loop
    v_code := lpad(public._ri(1000, 9999)::text, 4, '0');
    exit when not exists (select 1 from public.rooms where code = v_code);
    i := i + 1;
    if i > 200 then raise exception 'NO_CODE_LEFT'; end if;
  end loop;
  insert into public.rooms(code, level, duration_sec, bonus_on, blind_on)
  values (v_code, p_level, p_duration, coalesce(p_bonus, true), coalesce(p_blind, true))
  returning id into v_id;
  insert into public.room_secrets(room_id, secret) values (v_id, v_secret);
  return json_build_object('room_id', v_id, 'code', v_code, 'secret', v_secret);
end $$;

create or replace function public.start_game(p_room uuid, p_secret text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms := public._teacher(p_room, p_secret); v_ends timestamptz;
begin
  if rm.status <> 'waiting' then raise exception 'ALREADY_STARTED'; end if;
  if not exists (select 1 from public.players where room_id = p_room) then raise exception 'NO_PLAYERS'; end if;
  delete from public.room_problems where room_id = p_room;
  perform public._generate_problems(p_room, rm.level, case when rm.level = 1 then 60 else 40 end);
  update public.player_secrets set current_no = null, choice_order = null, solved_nos = '{}', last_type = null, locked_until = null
   where room_id = p_room;
  v_ends := now() + make_interval(secs => rm.duration_sec);
  update public.rooms set status = 'playing', started_at = now(), ends_at = v_ends where id = p_room;
  return json_build_object('ends_at', v_ends);
end $$;

create or replace function public.end_game(p_room uuid, p_secret text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms := public._teacher(p_room, p_secret);
begin
  if rm.status = 'ended' then return json_build_object('status', 'ended'); end if;
  update public.rooms set status = 'ended', ends_at = least(coalesce(ends_at, now()), now()), blind_manual = false
   where id = p_room;
  return json_build_object('status', 'ended');
end $$;

create or replace function public.set_golden(p_room uuid, p_secret text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms := public._teacher(p_room, p_secret); v_until timestamptz;
begin
  if rm.status <> 'playing' or now() >= rm.ends_at then raise exception 'NOT_PLAYING'; end if;
  v_until := least(now() + interval '20 seconds', rm.ends_at);
  update public.rooms set golden_until = v_until where id = p_room;
  return json_build_object('golden_until', v_until);
end $$;

create or replace function public.set_blind(p_room uuid, p_secret text, p_on boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms := public._teacher(p_room, p_secret);
begin
  update public.rooms set blind_manual = coalesce(p_on, false) where id = p_room;
  return json_build_object('blind_manual', coalesce(p_on, false));
end $$;

-- 통계: 학생 별명 없이 문제별로만
create or replace function public.get_stats(p_room uuid, p_secret text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms := public._teacher(p_room, p_secret); v_total int; v_correct int; v_boxes int; v_weak json; v_hard json;
begin
  select count(*), count(*) filter (where is_correct), count(*) filter (where bonus > 0)
    into v_total, v_correct, v_boxes from public.answers where room_id = p_room;
  select json_build_object('type', type_code, 'rate', round(100.0 * sum(is_correct::int) / count(*)))
    into v_weak
    from public.answers where room_id = p_room
   group by type_code having count(*) >= 3
   order by sum(is_correct::int)::float / count(*), count(*) desc limit 1;
  if rm.status = 'ended' then
    select json_agg(h) into v_hard from (
      select pr.no, pr.type_code as type, pr.question, pr.choices[pr.answer + 1] as answer_text,
             pr.explain, pr.visual, count(*) as attempts,
             round(100.0 * sum(a.is_correct::int) / count(*)) as rate
        from public.answers a join public.room_problems pr on pr.room_id = a.room_id and pr.no = a.problem_no
       where a.room_id = p_room
       group by pr.no, pr.type_code, pr.question, pr.choices, pr.answer, pr.explain, pr.visual
       order by sum(a.is_correct::int)::float / count(*), count(*) desc
       limit 3) h;
  end if;
  return json_build_object(
    'total', v_total,
    'correct_rate', case when v_total > 0 then round(100.0 * v_correct / v_total) end,
    'boxes', v_boxes, 'weak', v_weak, 'hardest', coalesce(v_hard, '[]'::json));
end $$;

create or replace function public.delete_room(p_room uuid, p_secret text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms := public._teacher(p_room, p_secret);
begin
  delete from public.rooms where id = p_room;   -- 학생, 답안, 문제, 비밀 코드가 함께 지워진다
  return json_build_object('deleted', true);
end $$;

-- ---------------------------------------------------------------------
-- 학생
-- ---------------------------------------------------------------------
create or replace function public.join_room(p_code text, p_nickname text, p_animal text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare rm public.rooms; v_nick text := btrim(coalesce(p_nickname, '')); v_pid uuid; v_token text := public._new_secret();
begin
  select * into rm from public.rooms where code = btrim(coalesce(p_code, ''));
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if rm.status = 'ended' then raise exception 'ROOM_ENDED'; end if;
  if char_length(v_nick) < 1 or char_length(v_nick) > 10 then raise exception 'BAD_NICKNAME'; end if;
  if v_nick ~ '[0-9]{4}' then raise exception 'NICKNAME_DIGITS'; end if;
  if p_animal not in ('rabbit','cat','bear','fox','penguin','squirrel','frog','owl') then raise exception 'BAD_ANIMAL'; end if;
  if exists (select 1 from public.players where room_id = rm.id and nickname = v_nick) then
    raise exception 'NICKNAME_TAKEN';
  end if;
  if (select count(*) from public.players where room_id = rm.id) >= 40 then raise exception 'ROOM_FULL'; end if;
  insert into public.players(room_id, nickname, animal) values (rm.id, v_nick, p_animal) returning id into v_pid;
  insert into public.player_secrets(player_id, room_id, token) values (v_pid, rm.id, v_token);
  return json_build_object('player_id', v_pid, 'room_id', rm.id, 'token', v_token);
end $$;

create or replace function public.next_question(p_token text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare ps public.player_secrets := public._player(p_token); rm public.rooms;
begin
  select * into rm from public.rooms where id = ps.room_id;
  if rm.status = 'waiting' then return json_build_object('status', 'waiting'); end if;
  if rm.status = 'ended' or now() >= rm.ends_at then return json_build_object('status', 'ended'); end if;
  if ps.current_no is not null then
    return json_build_object('status', 'playing', 'question', public._question_json(ps.room_id, ps.current_no, ps.choice_order));
  end if;
  return json_build_object('status', 'playing', 'question', public._assign_next(ps.player_id));
end $$;

create or replace function public.submit_answer(p_token text, p_no int, p_choice int)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  ps public.player_secrets := public._player(p_token); rm public.rooms; pr public.room_problems; pl public.players;
  v_orig int; v_ok boolean; v_pts int := 0; v_bonus int := 0; v_hi int; v_eq int; v_n int; v_mid numeric; v_prob numeric;
  v_score int; v_next json;
begin
  select * into rm from public.rooms where id = ps.room_id;
  if rm.status <> 'playing' or now() >= rm.ends_at then return json_build_object('status', 'ended'); end if;
  if ps.current_no is null or p_no is distinct from ps.current_no then
    return json_build_object('status', 'playing', 'error', 'STALE',
      'question', case when ps.current_no is null then public._assign_next(ps.player_id)
                       else public._question_json(ps.room_id, ps.current_no, ps.choice_order) end);
  end if;
  if ps.locked_until is not null and ps.locked_until > now() then
    return json_build_object('status', 'playing', 'error', 'LOCKED',
      'wait_ms', ceil(extract(epoch from ps.locked_until - now()) * 1000));
  end if;
  if p_choice is null or p_choice < 0 or p_choice >= array_length(ps.choice_order, 1) then raise exception 'BAD_CHOICE'; end if;

  select * into pr from public.room_problems where room_id = ps.room_id and no = ps.current_no;
  v_orig := ps.choice_order[p_choice + 1];
  v_ok := (v_orig = pr.answer);

  select * into pl from public.players where id = ps.player_id for update;
  if v_ok then
    v_pts := case when rm.golden_until is not null and now() < rm.golden_until then 2 else 1 end;
    if rm.bonus_on then
      -- 지금 순위(동점은 가운데 순위)로 상자 확률을 정한다
      select count(*) filter (where score > pl.score), count(*) filter (where score = pl.score), count(*)
        into v_hi, v_eq, v_n from public.players where room_id = ps.room_id;
      v_mid := v_hi + (v_eq + 1) / 2.0;
      v_prob := case when v_mid <= v_n / 3.0 then 0.10 when v_mid <= 2 * v_n / 3.0 then 0.20 else 0.30 end;
      if random() < v_prob then v_bonus := public._ri(1, 3); end if;
    end if;
  end if;

  update public.players
     set score = score + v_pts + v_bonus, correct = correct + v_ok::int, bonus = bonus + v_bonus, solved = solved + 1
   where id = ps.player_id returning score into v_score;
  insert into public.answers(room_id, player_id, problem_no, type_code, chosen, is_correct, points, bonus)
  values (ps.room_id, ps.player_id, pr.no, pr.type_code, v_orig, v_ok, v_pts, v_bonus);
  update public.player_secrets
     set solved_nos = solved_nos || pr.no, current_no = null, choice_order = null,
         locked_until = case when v_ok then null else now() + interval '1 second' end
   where player_id = ps.player_id;

  v_next := public._assign_next(ps.player_id);
  return json_build_object(
    'status', 'playing', 'correct', v_ok,
    'correct_choice', array_position(ps.choice_order, pr.answer) - 1,
    'points', v_pts, 'bonus', v_bonus, 'score', v_score,
    'hint', case when v_ok then null else pr.hint end,
    'next', v_next);
end $$;

-- ---------------------------------------------------------------------
-- 실행 권한: 공개 함수만 브라우저에 열고, _로 시작하는 내부 함수는 막는다
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like '\_%' or p.proname in ('create_room','start_game','end_game','set_golden','set_blind',
            'get_stats','delete_room','join_room','next_question','submit_answer','server_time'))
  loop
    execute format('revoke all on function %s from public', f.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', f.sig);
      if f.proname not like '\_%' then
        execute format('grant execute on function %s to anon, authenticated', f.sig);
      end if;
    end if;
  end loop;
end $$;
