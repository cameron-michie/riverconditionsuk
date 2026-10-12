-- Cold archive: how long each kind of series stays in Postgres. Rows older than hot_days are written to Parquet (Storage bucket 'archive'), verified, then deleted.
create table if not exists ops.retention_rule (
  dataset  text primary key,
  hot_days int not null check (hot_days >= 1),
  note     text
);
insert into ops.retention_rule (dataset, hot_days, note) values
  ('observation:fast',   8,   'series with interval under a day (15-minute gauges, rain): the 7-day sparkline plus a day'),
  ('observation:daily',  8,   'daily means and totals; seasonal normals are rebuilt weekly from the archive'),
  ('observation:sparse', 400, 'lab and survey samples: bathing, chemistry and ecology views read the last year'),
  ('wx:catchment_rain',  9,   'radar catchment rain; the flow model needs the last week')
on conflict (dataset) do nothing;
alter table ops.retention_rule enable row level security;
-- several files can cover one period (late-arriving rows), so uniqueness is by path
alter table ops.archive_object drop constraint if exists archive_object_dataset_period_start_period_end_key;
create unique index if not exists archive_object_path on ops.archive_object (bucket, path);
-- monthly observation partitions through 2035 (they stopped at 2028-12)
do $$
declare d date := date '2029-01-01';
begin
  while d < date '2036-01-01' loop
    if to_regclass(format('core.observation_%s', to_char(d, 'YYYY_MM'))) is null then
      execute format('create table core.observation_%s partition of core.observation for values from (%L) to (%L)', to_char(d, 'YYYY_MM'), d, d + interval '1 month');
    end if;
    d := (d + interval '1 month')::date;
  end loop;
end $$;
