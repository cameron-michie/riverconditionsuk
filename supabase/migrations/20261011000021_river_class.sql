-- Thinning is by RIVER (its size at the mouth), width is by LINK (local size). Major rivers therefore appear whole, source to sea.
alter table core.river_link add column river_class smallint;
update core.river_link l set river_class = r.mx from (select river_id, max(size_class) mx from core.river_link where river_id is not null group by river_id) r where r.river_id = l.river_id;
update core.river_link set river_class = size_class where river_class is null;
drop index if exists core.river_link_s11, core.river_link_s10, core.river_link_s9, core.river_link_s8, core.river_link_s7, core.river_link_s6, core.river_link_s4, core.river_link_s2;
create index river_link_c11 on core.river_link using gist (geom) where river_class >= 11;
create index river_link_c10 on core.river_link using gist (geom) where river_class >= 10;
create index river_link_c9  on core.river_link using gist (geom) where river_class >= 9;
create index river_link_c8  on core.river_link using gist (geom) where river_class >= 8;
create index river_link_c7  on core.river_link using gist (geom) where river_class >= 7;
create index river_link_c6  on core.river_link using gist (geom) where river_class >= 6;
create index river_link_c4  on core.river_link using gist (geom) where river_class >= 4;
create index river_link_c2  on core.river_link using gist (geom) where river_class >= 2;
analyze core.river_link;
