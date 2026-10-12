-- Plausibility rules as data. Values outside the range are FLAGGED (quality='suspect'), never deleted or clipped:
-- the raw value stays visible and the rule that flagged it is one row in ref.parameter.
alter table ref.parameter add column plausible_min double precision, add column plausible_max double precision;

update ref.parameter p set plausible_min = v.mn, plausible_max = v.mx from (values
  ('ph', 3.0, 11.5), ('water_temperature', -1.0, 32.0), ('dissolved_oxygen_sat', 0.0, 250.0), ('dissolved_oxygen_conc', 0.0, 25.0),
  ('phosphorus_reactive', 0.0, 20.0), ('phosphorus_total', 0.0, 30.0), ('nitrate_n', 0.0, 100.0), ('ammonia_total_n', 0.0, 50.0),
  ('conductivity', 0.0, 60000.0), ('bod5', 0.0, 500.0), ('suspended_solids', 0.0, 20000.0), ('rainfall', 0.0, 200.0)
) as v(code, mn, mx) where p.code = v.code;
-- flow and level are deliberately unbounded: tidal gauges legitimately read negative flow, and datums differ per site.

-- series whose upstream parameter/unit disagree (e.g. a 'level' measure reporting celsius) are retired, not guessed at
create function ops.retire_inconsistent_series() returns bigint language sql as $$
  with r as (
    update core.series s set status = 'retired', attrs = s.attrs || jsonb_build_object('retired_reason', 'parameter/unit mismatch upstream')
    from ref.parameter p, ref.unit u
    where p.id = s.parameter_id and u.id = s.unit_id and s.status <> 'retired'
      and u.dimension <> (select u2.dimension from ref.unit u2 where u2.id = p.canonical_unit)
    returning 1) select count(*) from r;
$$;

create function ops.flag_implausible(p_since timestamptz default '-infinity') returns bigint language sql as $$
  with f as (
    update core.observation o set quality = 'suspect'
    from core.series s join ref.parameter p on p.id = s.parameter_id
    where s.id = o.series_id and o.observed_at >= p_since and o.quality in ('unchecked','good','provisional') and o.value is not null
      and ((p.plausible_min is not null and o.value < p.plausible_min) or (p.plausible_max is not null and o.value > p.plausible_max))
    returning 1) select count(*) from f;
$$;

create view ops.dq_summary as
select 'observations flagged suspect' as check_name, count(*)::bigint as n from core.observation where quality = 'suspect'
union all select 'series retired (unit mismatch)', count(*) from core.series where status = 'retired'
union all select 'unmapped determinands (catalogue)', count(*) from ref.parameter_alias where status = 'unmapped'
union all select 'sites snapped >200 m from network', count(*) from core.site where snap_distance_m > 200 and river_link_id is not null
union all select 'open site-merge reviews', count(*) from core.site_match where decision = 'needs_review'
union all select 'pending agent proposals', count(*) from ops.proposal where status = 'pending';
