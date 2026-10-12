-- One river layer: every OS watercourse link, thinned by stream order as you zoom out, coloured by its waterbody's condition.

-- per-waterbody display state, flat and compact. s = rank digit per signal in core.signal_def.sort order (0 none), t = trend char per signal (0 / + / -)
create table core.waterbody_map_state (
  waterbody_id bigint primary key references core.waterbody(id),
  name         text,
  river_slug   text,
  s            text not null,
  t            text not null
);
alter table core.waterbody_map_state enable row level security;
create policy public_read on core.waterbody_map_state for select to anon, authenticated using (true);

create function core.refresh_waterbody_map_state() returns void language sql as $$
  truncate core.waterbody_map_state;
  insert into core.waterbody_map_state (waterbody_id, name, river_slug, s, t)
  select w.id, w.name, r.slug,
         (select string_agg(coalesce(sg.state_rank::text, '0'), '' order by d.sort) from core.signal_def d left join core.signal sg on sg.entity_kind = 'waterbody' and sg.entity_id = w.id and sg.signal_code = d.code),
         (select string_agg(case sg.trend when 'improving' then '+' when 'worsening' then '-' else '0' end, '' order by d.sort) from core.signal_def d left join core.signal sg on sg.entity_kind = 'waterbody' and sg.entity_id = w.id and sg.signal_code = d.code)
  from core.waterbody w left join core.waterbody_river wr on wr.waterbody_id = w.id left join core.river r on r.id = wr.river_id;
$$;
select core.refresh_waterbody_map_state();

-- river labels, from the database
alter table core.river add column label_pt geometry(Point,4326);
update core.river set label_pt = ST_PointOnSurface(geom) where geom is not null;
create index on core.river using gist (label_pt) where label_pt is not null;
create index river_link_g7 on core.river_link using gist (geom) where strahler >= 7;

-- the separate waterbody layer is retired: its geometry duplicated the network and cost 10x the bytes
delete from core.map_layer where code = 'waterbodies';
update core.map_layer set label = 'rivers', note = 'OS watercourses. Minimum stream order rises as you zoom out; width follows stream order; colour follows the selected signal.' where code = 'network';
insert into core.map_layer (code, label, grp, geom_kind, min_zoom, default_on, sort, max_features, note) values
  ('river_labels', 'names', 'base', 'point', 3, true, 3, 400, 'river names; longer rivers first, shorter as you zoom in');
