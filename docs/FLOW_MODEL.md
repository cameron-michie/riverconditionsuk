# Flow model: rain-driven, now and five days ahead

Output: `live.waterbody_now.flow_days` (every river waterbody: now and each day ahead, latest issue only). Evidence class `modelled`. Job: `flow_forecast`, every 5 minutes.

## Method
State is the normal score `z` of the flow's seasonal percentile (`geo.gauge_model.normal`, the same scale as the map's flow bands). One model day is 09:00–09:00 UTC (the EA convention).

    z[d] = b0 + b1·z[d-1] + b2·r[d] + b3·r[d-1] + b4·r[d-2] + b5·mean(r[d-3..d-7]),   r = sqrt(catchment rain, mm)

- **Per gauge fit** (`scripts/etl/flow_model_fit.py --save`): ordinary least squares on daily flow (NRFA) and CEH-GEAR catchment rainfall (NRFA `cdr`), 2015 to Sept 2025, 1,239 gauges. Median in-sample R² 0.91.
- **Ungauged waterbody:** starting state and parameters come from the same nearby gauges that `live.refresh_flow_signals()` already picks (weights 1/(km+10)²). Starting from the neighbours' state *now* beat spinning up from days earlier.
- **Rain:** Met Office radar up to now, ECMWF IFS after (`live.rain`), averaged over the waterbody's catchment and everything upstream of it (`scripts/etl/wb_graph.py`; the graph's upstream area matches the NRFA catchment area, median ratio 1.05).
- Days without full rain cover are not forecast, so the horizon grows each time a new ECMWF run lands.

## Skill (held-out year Oct 2024–Sep 2025, mean absolute error in z units, lower is better)
| lead | persistence | rain model, own gauge | ungauged: neighbours' state held | ungauged: this model |
|---|---|---|---|---|
| 1 day | 0.24 | 0.19 | 0.47 | 0.42 |
| 3 days | 0.45 | 0.28 | 0.62 | 0.45 |
| 5 days | 0.57 | 0.32 | 0.73 | 0.47 |

Caveats: these use observed catchment rain, so real forecasts (ECMWF rain) will do worse than the table. The ungauged starting-state error (about 0.4 z, roughly 12 percentile points) dominates at short range and is unchanged from the previous estimate. Reproduce with `flow_model_fit.py` and `flow_model_transfer_eval.py`.

## Flow in m³/s
Every river waterbody also gets a flow in m³/s (`q` in `live.waterbody_now.flow_days`): the neighbouring gauges' seasonal flow at the same percentile, per km² of their catchment (geometric mean, same weights as the state), times the waterbody's upstream area from the drainage graph. Where a gauge sits on the stretch its own flow and area are used.

Tested leave-one-gauge-out over 29,662 gauge-days on 1,200 gauges (`scripts/etl/flow_scale_eval.py`; the percentile is the estimated one, the area the graph's):

| setup | median error | within 1.5x | within 2x |
|---|---|---|---|
| true NRFA area, true percentile (scaling error alone) | x1.29 | 67% | 84% |
| true area, estimated percentile | x1.41 | 56% | 75% |
| **graph area, estimated percentile (what the map uses)** | **x1.76** | **40%** | **57%** |

So for an ungauged river expect the right order of magnitude and often better, not a measurement; the panel says "typically within a factor of 2". Most of the loss is the upstream area (a gauge sits partway along its waterbody); a better area, for example from a DEM, is the next improvement. NRW's APIs give river level and rainfall only, so Welsh flow comes through the NRFA gauges and this model.
