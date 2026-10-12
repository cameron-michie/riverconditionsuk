-- Name labels can be switched on and off per kind. The list is data, served through ui_config.
create table core.map_label_toggle (code text primary key, label text not null, default_on boolean not null default true, sort smallint not null);
alter table core.map_label_toggle enable row level security;
create policy public_read on core.map_label_toggle for select to anon, authenticated using (true);
insert into core.map_label_toggle values ('rivers', 'rivers', true, 1), ('cities', 'cities', true, 2), ('towns', 'towns', true, 3), ('parks', 'parks', true, 4), ('water', 'water', true, 5);

create or replace function api.ui_config() returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object(
    'layers',   (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'group', grp, 'kind', geom_kind, 'min_zoom', min_zoom, 'cluster_below', cluster_below, 'hot_only_below', hot_only_below, 'on', default_on) order by sort) from core.map_layer),
    'labels',   (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'on', default_on) order by sort) from core.map_label_toggle),
    'signals',  (select jsonb_agg(jsonb_build_object('code', code, 'label', short_label, 'words', words, 'pressure', is_pressure, 'about', description) order by sort) from core.signal_def),
    'evidence', (select jsonb_object_agg(code, jsonb_build_object('label', label, 'about', description)) from ref.evidence_class_def));
$$;
