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
