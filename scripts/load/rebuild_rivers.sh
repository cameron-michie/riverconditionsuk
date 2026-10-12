#!/bin/sh
# Re-derive rivers and everything that hangs off river ids. Run after any change to derive_rivers.py or the OS network.
set -e; cd "$(dirname "$0")"; DB=${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
python3 -W ignore derive_rivers.py
python3 -W ignore derive_size.py
psql $DB -q -c "update core.river_link l set river_class = r.mx from (select river_id, max(size_class) mx from core.river_link where river_id is not null group by river_id) r where r.river_id = l.river_id; update core.river_link set river_class = size_class where river_id is null;
                update core.river r set river_class = x.mx from (select river_id, max(size_class) mx from core.river_link where river_id is not null group by river_id) x where x.river_id = r.id;
                update core.river set label_pt = ST_PointOnSurface(geom) where geom is not null; analyze core.river; analyze core.river_link;"
python3 -W ignore load_tidal.py      # estuary and coastal water bodies; reassigns tidal links
psql $DB -q -f snap_sites.sql > /dev/null
psql $DB -q -c "select core.refresh_waterbody_river()" > /dev/null
psql $DB -q -f compute_signals.sql > /dev/null          # also refreshes core.waterbody_map_state
python3 -W ignore link_research.py
