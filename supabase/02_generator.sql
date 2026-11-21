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
