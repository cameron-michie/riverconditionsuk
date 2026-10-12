"""SEPA KiWIS: stations, parameters, timeseries catalogue, latest values."""
from lib import *
S = "sepa"; K = "https://timeseries.sepa.org.uk/KiWIS/KiWIS?service=kisters&type=queryServices&datasource=0&format=json"
r = get(K + "&request=getStationList&returnfields=station_no,station_id,station_name,station_latitude,station_longitude,station_carteasting,station_cartnorthing,river_name,catchment_name,catchment_no,site_no,site_name,parametertype_name")
save(S, "stations.json", r.content, r.url, "SEPA OGL"); log(S, f"stations {len(r.json())-1}")
r = get(K + "&request=getParameterList"); save(S, "parameters.json", r.content, r.url, "SEPA OGL")
r = get(K + "&request=getTimeseriesList&returnfields=ts_id,ts_name,station_no,parametertype_name,stationparameter_name,ts_unitname,coverage&ts_name=15minute", timeout=300)
save(S, "timeseries_15min.json", r.content, r.url, "SEPA OGL"); ts = r.json(); log(S, f"15-min ts {len(ts)-1}")
ids = [row[0] for row in ts[1:]]
out = []
for i in range(0, len(ids), 200):
    rr = get(K + "&request=getTimeseriesValues&period=P1D&metadata=true&returnfields=Timestamp,Value,Quality%20Code&ts_id=" + ",".join(ids[i:i+200]), timeout=300)
    out += rr.json() if rr.status_code == 200 else []
save(S, "latest_values_P1D.json", out, "KiWIS getTimeseriesValues P1D", "SEPA OGL"); log(S, f"values for {len(out)} ts")
