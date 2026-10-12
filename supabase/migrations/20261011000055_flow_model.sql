-- Parameters of the rain-driven flow model, one row per gauge (fitted by scripts/etl/flow_model_fit.py --save).
--   z[d] = beta0 + beta1*z[d-1] + beta2*r[d] + beta3*r[d-1] + beta4*r[d-2] + beta5*mean(r[d-3..d-7]),  z = normal score of seasonal flow percentile, r = sqrt(catchment rain mm)
create table if not exists core.flow_model_param (
  site_id   bigint primary key references core.site(id) on delete cascade,
  beta      double precision[] not null check (cardinality(beta) = 6),
  sd        double precision not null,       -- one-day residual standard deviation, in z units
  n         int not null,
  r2        double precision,
  trained_through date not null,
  fitted_at timestamptz not null default now()
);
alter table core.flow_model_param enable row level security;
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('flow_forecast', '../../.venv/bin/python -W ignore ../etl/flow_forecast.py', 60, null, 900, 240)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
