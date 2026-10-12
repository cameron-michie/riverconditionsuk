-- Map support: dominant river per waterbody (what a click opens) and a compact state feed for colouring.
create table core.waterbody_river (
  waterbody_id bigint primary key references core.waterbody(id),
  river_id     bigint not null references core.river(id),
  link_len_m   double precision not null
);
create index on core.waterbody_river (river_id);
alter table core.waterbody_river enable row level security;
create policy public_read on core.waterbody_river for select to anon, authenticated using (true);

create function core.refresh_waterbody_river() returns void language sql as $$
  truncate core.waterbody_river;
  insert into core.waterbody_river (waterbody_id, river_id, link_len_m)
  select distinct on (waterbody_id) waterbody_id, river_id, len from (
    select waterbody_id, river_id, sum(length_m) len from core.river_link where waterbody_id is not null and river_id is not null group by 1, 2) q
  order by waterbody_id, len desc;
$$;
select core.refresh_waterbody_river();

-- s = { signal: [rank 1..4, trend code -1 worse | 0 stable/unknown | 1 better] }
create view api.waterbody_map as
select w.id, w.name, w.country, r.slug as river_slug, r.name as river_name,
       coalesce((select jsonb_object_agg(s.signal_code, jsonb_build_array(s.state_rank, case s.trend when 'improving' then 1 when 'worsening' then -1 else 0 end))
                 from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = w.id), '{}') as s
from core.waterbody w left join core.waterbody_river wr on wr.waterbody_id = w.id left join core.river r on r.id = wr.river_id
where w.line_geom is not null;
grant select on api.waterbody_map to anon, authenticated;
