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
