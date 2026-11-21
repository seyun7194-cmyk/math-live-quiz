-- =====================================================================
-- 비례의 전설 · 4단계(선택): 오래된 방 자동 삭제
-- 먼저 Supabase 대시보드 > Database > Extensions에서 pg_cron을 켠 뒤 실행하세요.
-- 매시간 17분에 만든 지 24시간이 지난 방(학생·답안·문제 포함)을 지웁니다.
-- pg_cron을 켜지 않아도 새 방을 만들 때마다 24시간 지난 방은 지워집니다.
-- =====================================================================
create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'proportion-legend-cleanup';
select cron.schedule(
  'proportion-legend-cleanup',
  '17 * * * *',
  $$delete from public.rooms where created_at < now() - interval '24 hours'$$
);
