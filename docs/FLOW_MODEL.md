# Flow model: rain-driven, now and five days ahead

Output: `core.waterbody_flow` (every river waterbody) and `core.forecast` (gauges, m³/s with a p10–p90 band). Evidence class `modelled`. Job: `flow_forecast`, hourly.

## Method
State is the normal score `z` of the flow's seasonal percentile (`core.flow_normal`, the same scale as the map's flow bands). One model day is 09:00–09:00 UTC (the EA convention).

    z[d] = b0 + b1·z[d-1] + b2·r[d] + b3·r[d-1] + b4·r[d-2] + b5·mean(r[d-3..d-7]),   r = sqrt(catchment rain, mm)

- **Per gauge fit** (`scripts/etl/flow_model_fit.py --save`): ordinary least squares on daily flow (NRFA) and CEH-GEAR catchment rainfall (NRFA `cdr`), 2015 to Sept 2025, 1,239 gauges. Median in-sample R² 0.91.
- **Ungauged waterbody:** starting state and parameters come from the same nearby gauges that `core.refresh_flow_signals()` already picks (weights 1/(km+10)²). Starting from the neighbours' state *now* beat spinning up from days earlier.
- **Rain:** Met Office radar up to now, ECMWF IFS after (`wx.catchment_rain`), averaged over the waterbody's catchment and everything upstream of it (`scripts/etl/wb_graph.py`; the graph's upstream area matches the NRFA catchment area, median ratio 1.05).
- Days without full rain cover are not forecast, so the horizon grows each time a new ECMWF run lands.

## Skill (held-out year Oct 2024–Sep 2025, mean absolute error in z units, lower is better)
| lead | persistence | rain model, own gauge | ungauged: neighbours' state held | ungauged: this model |
|---|---|---|---|---|
| 1 day | 0.24 | 0.19 | 0.47 | 0.42 |
| 3 days | 0.45 | 0.28 | 0.62 | 0.45 |
| 5 days | 0.57 | 0.32 | 0.73 | 0.47 |

Caveats: these use observed catchment rain, so real forecasts (ECMWF rain) will do worse than the table. The ungauged starting-state error (about 0.4 z, roughly 12 percentile points) dominates at short range and is unchanged from the previous estimate. Reproduce with `flow_model_fit.py` and `flow_model_transfer_eval.py`.
