-- Licences and sources for the weather feeds. Radar is CC BY-SA, so the map must credit the Met Office.
insert into ingest.licence (slug, name, url, allows_redistribution, allows_commercial, requires_attribution, attribution_text, notes) values
  ('cc-by-sa-4', 'CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/', true, true, true, 'Contains Met Office data © Crown copyright', 'Share-alike: derived images must carry the same licence'),
  ('cc-by-4', 'CC BY 4.0', 'https://creativecommons.org/licenses/by/4.0/', true, true, true, 'Contains ECMWF open data', null)
on conflict (slug) do nothing;
insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, notes) values
  ('metoffice_radar', 'Met Office UK radar composite, surface rain rate (1 km)', 'Met Office', 'GBR', 'bulk_file', 'https://met-office-radar-obs-data.s3.eu-west-2.amazonaws.com/radar/', (select id from ingest.licence where slug = 'cc-by-sa-4'), 'official_monitoring', 'PT15M', 'PT25M', 'active', 'HDF5 ODIM, OSGB grid, public S3 bucket, 2-year rolling archive'),
  ('ecmwf_ifs', 'ECMWF IFS open data, 0.25 degree', 'ECMWF', 'EUR', 'bulk_file', 'https://data.ecmwf.int/forecasts/', (select id from ingest.licence where slug = 'cc-by-4'), 'modelled', 'PT12H', 'PT8H', 'active', 'Total precipitation and mean sea level pressure, 00z and 12z runs to 144 h')
on conflict (slug) do nothing;
