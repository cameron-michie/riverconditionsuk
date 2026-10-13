-- Scheduling inside Postgres. ops.etl_job stays the registry (name, interval, command); pg_cron fires ops.dispatch_job(name) on the job's schedule, which POSTs to the
-- Supabase Compute container (URL and token in Vault: 'etl_url', 'etl_token'). The container runs the job's command and writes the result back to ops.etl_run / ops.etl_job.
-- ops.sync_cron() rebuilds every cron schedule from ops.etl_job; call it after changing a job. Hosted only (needs pg_net and pg_cron); harmless where they are absent.
alter table ops.etl_run add column if not exists request_id bigint;

create or replace function ops.dispatch_job(p_name text) returns bigint language plpgsql security definer set search_path = ops, public, extensions, vault, pg_temp as $$
declare j ops.etl_job%rowtype; rid bigint; base text; tok text; req bigint;
begin
  select * into j from ops.etl_job where name = p_name and enabled;
  if not found then return null; end if;
  if j.running_since is not null and j.running_since > now() - make_interval(secs => greatest(j.timeout_s, 600) + 600) then return null; end if;   -- still running
  select decrypted_secret into base from vault.decrypted_secrets where name = 'etl_url';
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'etl_token';
  update ops.etl_job set running_since = now(), last_started_at = now() where name = p_name;
  insert into ops.etl_run (job) values (p_name) returning id into rid;
  select net.http_post(url := base || '/run', headers := jsonb_build_object('Content-Type', 'application/json', 'X-ETL-Token', tok),
                       body := jsonb_build_object('job', p_name, 'run_id', rid), timeout_milliseconds := 20000) into req;
  update ops.etl_run set request_id = req where id = rid;
  return rid;
end $$;

-- A run whose request was refused or never answered would otherwise look "running" until the timeout: fail it now so the next tick can retry.
create or replace function ops.check_dispatches() returns int language plpgsql security definer set search_path = ops, public, net, pg_temp as $$
declare n int;
begin
  with bad as (
    select r.id, r.job, coalesce(h.status_code::text, 'no response') || ' ' || left(coalesce(h.content, h.error_msg, ''), 200) as why
    from ops.etl_run r left join net._http_response h on h.id = r.request_id
    where r.finished_at is null and r.request_id is not null and r.started_at > now() - interval '1 day'
      and ((h.id is not null and (h.status_code is null or h.status_code not between 200 and 299)) or (h.id is null and r.started_at < now() - interval '3 minutes'))),
  u as (update ops.etl_run r set finished_at = now(), status = 'failed', output = 'dispatch failed: ' || bad.why from bad where r.id = bad.id returning r.job)
  update ops.etl_job j set running_since = null, last_finished_at = now(), last_status = 'failed' where j.name in (select job from u);
  get diagnostics n = row_count;
  -- a run whose container was replaced mid-job (a redeploy) never reports back: close it once it has outlived its timeout
  with dead as (
    update ops.etl_run r set finished_at = now(), status = 'timeout', output = coalesce(output, '') || 'no result recorded: container restarted or job outlived its timeout'
    from ops.etl_job j where j.name = r.job and r.request_id is not null and r.finished_at is null and r.started_at < now() - make_interval(secs => j.timeout_s + 300) returning r.job)   -- only runs this dispatcher started
  update ops.etl_job j set running_since = null, last_finished_at = now(), last_status = 'timeout' where j.name in (select job from dead);
  return n;
end $$;

-- interval -> cron expression, with a per-job minute offset so jobs do not all start on the same second
create or replace function ops.cron_expr(p_name text, p_minutes int) returns text language sql immutable as $$
  select case
    when p_minutes < 60 then (select string_agg(m::text, ',' order by m) from generate_series(abs(hashtext(p_name)) % p_minutes, 59, p_minutes) m) || ' * * * *'
    when p_minutes < 1440 and p_minutes % 60 = 0 then (abs(hashtext(p_name)) % 60)::text || ' */' || (p_minutes / 60) || ' * * *'
    when p_minutes = 1440 then (abs(hashtext(p_name)) % 60)::text || ' ' || (2 + abs(hashtext(p_name)) % 3)::text || ' * * *'
    when p_minutes = 10080 then (abs(hashtext(p_name)) % 60)::text || ' 3 * * 0'
    else (abs(hashtext(p_name)) % 60)::text || ' 4 1 * *' end
$$;

create or replace function ops.sync_cron() returns table (jobname text, schedule text) language plpgsql security definer set search_path = ops, public, cron, pg_temp as $$
declare j record;
begin
  for j in select name, interval_minutes from ops.etl_job where enabled loop
    perform cron.schedule('etl:' || j.name, ops.cron_expr(j.name, j.interval_minutes), format('select ops.dispatch_job(%L)', j.name));
  end loop;
  perform cron.schedule('etl:_check', '*/2 * * * *', 'select ops.check_dispatches()');
  perform cron.schedule('etl:_partitions', '5 1 * * *', 'select ops.roll_forecast_partitions()');
  perform cron.unschedule(c.jobname) from cron.job c where c.jobname like 'etl:%' and c.jobname not in ('etl:_check', 'etl:_partitions') and substring(c.jobname from 5) not in (select name from ops.etl_job where enabled);
  return query select c.jobname::text, c.schedule::text from cron.job c where c.jobname like 'etl:%' order by 1;
end $$;
