# The map: how it scales

The browser holds no data and no layer list. It asks Supabase for slippy-map tiles (`z/x/y`) and Postgres decides what a tile contains at that zoom. Adding a data source, or a layer with hundreds of thousands of points, is a registry row and a tile branch, not a frontend change.

## Contract

| Call | Returns |
|---|---|
| `rpc/ui_config` | layers (code, label, group, kind, min zoom, default), signals (labels, wording ladders), evidence classes. Drives the toolbar, legend and tags. |
| `rpc/map_tile?p_layer&z&x&y` | GeoJSON `FeatureCollection` for one layer in one tile. `Cache-Control: max-age=30`. Typically 1–250 KB, 2–100 ms. |
| `rpc/area_summary?p_minx..p_maxy` | The latest numbers for the viewport: overflows, stretch condition counts per signal, rivers in view, flow extremes, bathing, parks and towns. Refuses views wider than 4.5°. |
| `rpc/stretch_dossier`, `stretch_geom` | One **stretch** (the regulator's waterbody, 5-47 km): its own readings, classes with the previous cycle, pressures, overflows, gauges, citizen surveys. Hover highlights the whole stretch and clicking a segment opens this, because the condition data belongs to the stretch, not to the OS link under the cursor. If the stretch has no monitoring, the nearest within 5 km is shown and labelled with its site name and distance. |
| `rpc/river_dossier`, `river_geom`, `search_rivers` | One river, its whole geometry (tidal reaches included), name search. |

The frontend requests only the tiles in view at the zoom it is at, queues them newest-first, drops requests for tiles already scrolled away, and keeps showing coarser tiles until finer ones arrive.

## What Postgres decides (all in `core.map_layer`, `core.map_zoom_rule`, `api.map_tile`)

- **Rivers.** Every OS watercourse link is in `core.river_link`. Thinning is by *river* (`river_class`, the size of the river at its mouth), so a major river appears whole, source to sea, while width follows the *link* (`size_class`, log2 of upstream channel length). Stream order was tried and rejected: it inflates in braided estuaries and ranks freshwater mainstems too low. Zoomed out you see about 30 rivers; about 90 at regional zoom; every stream at street level. Thresholds are rows in `core.map_zoom_rule`.
- **Dense point layers** declare `hot_only_below` (show only the urgent ones, such as overflows discharging now or gauges at flow extremes) or `cluster_below` (grid clusters with a count). Overflows: 24 dots nationally, 226 in a regional tile, all of them at street level.
- **Water and boundaries are drawn at true size** (towns, parks, lakes: width never inflated), unlike rivers, which are drawn wider than life so they stay legible. Both are thinned by area, not by importance.
- **Geometry** is simplified to the tile's resolution. Boundaries have pre-simplified low and mid columns. Fragmented lines are merged (a regional waterbody tile fell from 1.5 MB to 0.3 MB).
- **Caps** per layer (`max_features`); a tile reports `truncated` when it hit one.
- **Labels** (rivers, cities, parks, towns) are layers too, ranked and thinned the same way. Collision handling is in the browser, drawing is in the browser, nothing else is.

## Layers today

Base (no toggle, always on): countries, natural water (lakes, lochs, reservoirs and ponds as true-size shapes from OpenStreetMap, 23.7k of them, thinned by area as you zoom out), rivers (coloured by the selected signal), river names, city names. Overlays: national parks, towns (ONS built-up areas, fading out as you zoom in). Overlay-style shapes at true size: national parks, towns, natural water, beaches (3.6k OSM beach polygons, a toggle). Points: overflows (live), bathing waters (official class and last E. coli), river flow against each gauge's own record, bridges (26k named OSM bridges within 40 m of a real watercourse).

Click a segment for its stretch; double-click for the whole river. The URL carries the view: `?v=lon,lat,zoom&l=layer,layer#river-slug`. Share it and the other person sees the same thing.

## Flood, sewage and bridges

**Flood index (per gauge, `core.gauge_state`, rules in `core.flood_index_rule`).** Height is compared with the gauge's own stage scale from the EA: `(height - typical high) / (record high - typical high)`. Flow is compared with the median annual flood (QMED) from the National River Flow Archive. Bands: low, normal, elevated, high, severe; the overall band is the worse of the two. Where a gauge reports metres above Ordnance Datum, the code takes whichever reading falls inside the gauge's own record envelope, so a datum mix-up is dropped rather than shown. Height needs a stage scale (about 2,500 gauges); flow needs QMED (about 850). `refresh_live.py` pulls the latest readings and recomputes.

**Flood likelihood (`core.flood_forecast`).** The Flood Forecasting Centre's five-day risk per county and unitary authority (very low, low, medium, high), mapped onto ONS authority polygons (old counties such as Greater Manchester or Cumbria are unions). Active EA warnings and alerts are drawn as their own polygons. The FFC v1 endpoint still answers although v1 and v2 were announced as decommissioned after 30 June 2026; v3 needs a free API key. England and Wales only.

**Sewage (`core.sewage_works`, `core.overflow`).** Treated sewage leaves at works outfalls; untreated storm sewage at overflows. Works merge two records: the permit and, where one exists within 150 m, the EA effluent sampling point. A filled square means the effluent is monitored (operator self-monitoring, latest ammonia, BOD, suspended solids and phosphorus on the works record); hollow means no monitoring point was found. Overflows are circles: red = discharging now, filled = a live monitor is reporting, hollow = offline or none. Private and domestic septic discharges (about 30,000 permits) are deliberately not drawn.

**Bridges.** 26k named OSM bridges are points. Only the ones that are both at least 700 m long and mostly over water (outside the land outline, a major river, a tidal reach or a large water body) get outlines: 33 today, including the Queensferry Crossing, Prince of Wales, Forth Road, Tay Road, Humber, Severn, Mersey Gateway and Orwell bridges.

**Toolbar.** Click a layer to show or hide it. Parks, towns, water and beaches carry an `Aa` mark: double-click to show or hide their names. River and city names are always on. The state is in the URL (`l=` layers, `n=` layers with names on).

## One reading at a time

The toolbar selects one signal (chemical, ecology, sewage, farming, algae, flow) or none. Clicking the selected one deselects it. With one selected, rivers are coloured by it and the panel shows only that dataset. With none, rivers are one colour and the panel shows every dataset. `api.ui_config` supplies the signals, colours and words.

Flow is a signal like the others: `core.refresh_flow_signals()` compares each gauge's flow with its normal (QMED and percentile) and passes it to stretches and rivers with a gauge within 60 km along the same river (817 of 4,644 stretches). The words are stored in `core.signal_def.words` ("lower than normal", and so on).

Flow coverage has two methods, both stored in `core.signal` with `basis.method`. Measured: a gauge on the same-named river within 50 km (100 km on rivers over 150 km). Estimated (evidence class `modelled`): regional percentile transfer. Each nearby gauge's percentile for the time of year (`core.flow_normal`, built from NRFA and EA daily history) becomes a normal score; the scores of the nearest five gauges within 80 km are averaged, weighted by closeness and similar river size, and converted back. Leave-one-out test on 883 gauges: mean error 13.6 percentile points, correlation 0.77, 93% within one band, 51% exact band. Live gauges come from `refresh_flow.py` (EA Hydrology and SEPA); the weekly `flow_normal` job rebuilds the normals. Estuary and coastal water bodies (`load_tidal.py`, EA cycle 2 polygons, classifications to 2022) cover the tidal reaches.

Danger zones (`core.flood_zone`, layer `flood_zones`, drawn in red) are EA flood zones 2 and 3. `scripts/load/refresh_flood_zones.py` fetches them by bounding box only where a warning, alert or high/severe gauge exists. England only; Welsh zones are not loaded. A county outlook of medium or above does not yet trigger a fetch.

## Where the satellite work plugs in

Daily imagery analysis means two kinds of output, and neither needs the browser to change.

1. **Rasters** (true colour, chlorophyll, turbidity, flood extent): stored as cloud-optimised GeoTIFF in object storage, catalogued in a `core.scene` table (STAC item id, acquired_at, cloud %, product, bbox, asset URL, licence). Tiles served from object storage as PNG or PMTiles; the registry row says which product and date range.
2. **Vectors** (bloom polygons, erosion change at bends, flood outlines, with a value, a time and a confidence): a partitioned `core.geo_observation (product, observed_on, geom, value, confidence, run_id)` table with a GiST index per partition, registered as a layer. The tile function gets one branch that filters by product and `observed_on`; clustering and caps already exist. A time control becomes one more tile parameter.

Both carry `evidence_class` (satellite-derived is `modelled` until validated against sondes) and a licence, like every other source.

## Known limits

- Scotland has no waterbody polygons in this load: rivers show but are grey (no condition data).
- Tidal reaches, canals and lakes are not WFD-classified waterbodies, so they draw grey by design.
- Where OS gives one river different names along its length, the derivation bridges short reaches (Trent Falls, Sonning Reach) and a few Welsh/English pairs by alias. The upper Thames still stands apart from the lower Thames; the alias list in `derive_rivers.py` is the place to fix that, then run `scripts/load/rebuild_rivers.sh`.
- `area_summary` and tiles are recomputed per request. At national traffic, put a CDN in front (the cache header is already set) or materialise hot tiles.
