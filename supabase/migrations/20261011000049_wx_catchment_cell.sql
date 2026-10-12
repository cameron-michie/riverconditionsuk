-- Which radar cells (1 km OSGB grid, ix east / iy south from the upper-left corner of the composite) fall in each waterbody catchment.
-- Built once by scripts/etl/build_catchment_cells.py. Catchments smaller than a cell get the cell holding their centroid.
create table if not exists wx.catchment_cell (
  waterbody_id bigint not null references core.waterbody(id),
  ix smallint not null,
  iy smallint not null,
  primary key (waterbody_id, ix, iy)
);
create index if not exists catchment_cell_waterbody on wx.catchment_cell (waterbody_id);
alter table wx.catchment_cell enable row level security;
revoke all on wx.catchment_cell from anon, authenticated;
