-- ETL schedule lives in the database. A runner outside the frontend reads it and executes due jobs.
create table if not exists ops.etl_job (
  name text primary key,
  command text not null,                -- run from scripts/load
  interval_minutes int not null check (interval_minutes > 0),
  enabled boolean not null default true,
  running_since timestamptz,
  last_started_at timestamptz,
  last_finished_at timestamptz,
  last_status text
);
create table if not exists ops.etl_run (
  id bigserial primary key,
  job text not null references ops.etl_job(name),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text,
  output text
);
alter table ops.etl_job enable row level security;
alter table ops.etl_run enable row level security;
insert into ops.etl_job (name, command, interval_minutes) values
  ('live', 'python3 refresh_live.py', 15)
on conflict (name) do nothing;
