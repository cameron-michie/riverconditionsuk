-- Rulebook seed. Idempotent. Everything here is data an agent may later propose to extend.

insert into ingest.licence (slug, name, url, allows_redistribution, allows_commercial, requires_attribution, attribution_text, notes) values
 ('ogl3',       'Open Government Licence v3.0', 'https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/', true, true, true, 'Contains public sector information licensed under the Open Government Licence v3.0.', 'EA, NRW, SEPA, Defra, Natural England, OS Open Rivers'),
 ('ukceh-ogl',  'UKCEH (OGL for NRFA)', 'https://nrfa.ceh.ac.uk/terms-and-conditions', true, true, true, 'Contains data from the National River Flow Archive, UK Centre for Ecology & Hydrology.', null),
 ('cc0',        'CC0 1.0', 'https://creativecommons.org/publicdomain/zero/1.0/', true, true, false, null, 'OpenAlex metadata; individual works carry their own licences'),
 ('rt-castco',  'Rivers Trust / CaSTCo open layers (item-level licence)', 'https://theriverstrust.org/', null, null, true, 'Data: The Rivers Trust / CaSTCo.', 'Per-item licences vary and several wrap OGL government data. CONFIRM before any redistribution or paid tier.'),
 ('company-open','Water company open data (Stream / NSOH terms)', 'https://stream-water-data.com/', null, null, true, 'Water company storm overflow data via the National Storm Overflow Hub.', 'Published for public use; onward-sale terms unconfirmed.'),
 ('unknown',    'Not yet determined', null, null, null, true, null, 'Needs a direct conversation (e.g. Stirling, WyeViz, W&UF)')
on conflict (slug) do nothing;

insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, status_note) values
 ('ea_flood_monitoring','EA Flood Monitoring API (stations, measures, readings, warnings)','Environment Agency','ENG','rest_api','https://environment.data.gov.uk/flood-monitoring',(select id from ingest.licence where slug='ogl3'),'official_monitoring','PT15M','PT30M','active','Daily national 15-min archive CSV ~60MB; /id/stations has 5.5k stations, 7.4k measures'),
 ('ea_hydrology','EA Hydrology API','Environment Agency','ENG','rest_api','https://environment.data.gov.uk/hydrology',(select id from ingest.licence where slug='ogl3'),'official_monitoring','P1D','P1D','active','9.5k stations; readings carry quality/completeness/valid/invalid/missing. WAF 403s bursts: needs a rate limiter (<=1 req/s).'),
 ('nrfa','National River Flow Archive','UKCEH','GB','rest_api','https://nrfaapps.ceh.ac.uk/nrfa/ws',(select id from ingest.licence where slug='ukceh-ogl'),'official_monitoring','P1D','P30D','active','1,604 stations incl. catchment descriptors + land cover fractions; links EA/NRW/SEPA via measuring-authority-station-id'),
 ('ea_wq_archive','EA Water Quality Archive (new API, Feb 2026)','Environment Agency','ENG','rest_api','https://environment.data.gov.uk/water-quality',(select id from ingest.licence where slug='ogl3'),'official_monitoring','P1D','P2D','active','Old WIMS API retired Dec 2025. 66k points, 8,081 determinands, 72M obs. CSV 2500/page; JSON-LD capped 250. 12.7% of results are censored (<x).'),
 ('ea_bathing','EA Bathing Water Quality','Environment Agency','ENG','rest_api','https://environment.data.gov.uk/doc/bathing-water',(select id from ingest.licence where slug='ogl3'),'regulator_assessment','P1D','P1D','active','464 sites; designated sites only, seasonal. _view=full unsupported; use default view.'),
 ('ea_edm_annual','EA Event Duration Monitoring annual returns (ArcGIS, all years)','Environment Agency','ENG','arcgis_feature_service','https://services1.arcgis.com/JZM7qJpmv7vJ0Hzx/arcgis/rest/services/edm_annual_returns_all_years_public/FeatureServer/0',(select id from ingest.licence where slug='ogl3'),'company_reported','P1Y','P3M','active','72k rows, every column a string, "#N/A" sentinels; carries wfd_waterbody_id'),
 ('rt_edm_annual_ew','Rivers Trust EDM annual returns, England & Wales','The Rivers Trust','GB','arcgis_feature_service','https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services',(select id from ingest.licence where slug='rt-castco'),'company_reported','P1Y','P3M','active','Adds Welsh companies (Dwr Cymru, Hafren Dyfrdwy)'),
 ('nsoh_england','National Storm Overflow Hub company feeds (Stream schema)','Water UK / 9 English water companies','ENG','arcgis_feature_service','https://portal-streamwaterdata.hub.arcgis.com',(select id from ingest.licence where slug='company-open'),'company_reported','PT5M','PT1H','active','All 9 English companies collected (Anglian, Northumbrian, Severn Trent, South West, Southern, Thames, United Utilities, Wessex, Yorkshire); shared schema. Status 1/0/-1.'),
 ('nsoh_scotland','Scottish Water overflow feeds','Scottish Water / SEPA','SCT','arcgis_feature_service','https://services-eu1.arcgis.com/jj6fR2HO7enbrICO',(select id from ingest.licence where slug='company-open'),'company_reported','PT1H','PT1H','active','Entirely different schema (OVERFLOW_STATUS_ID...). Needs its own adapter.'),
 ('welsh_water_edm_live','Dwr Cymru / Hafren Dyfrdwy live overflow map','Dwr Cymru Welsh Water','WLS','scrape',null,(select id from ingest.licence where slug='unknown'),'company_reported','PT1H',null,'gap','Public map exists; no open feature service found. Annual EDM available via Rivers Trust layer.'),
 ('ea_cde_classification','EA Catchment Data Explorer: WFD classification (cycles 1-3, 2009-2022)','Environment Agency','ENG','bulk_csv','https://environment.data.gov.uk/catchment-planning/England/classifications.csv',(select id from ingest.licence where slug='ogl3'),'regulator_assessment','P3Y',null,'active','533MB, 1.39M rows, tall: waterbody x year x element x cycle'),
 ('ea_cde_rnag','EA CDE: Reasons for Not Achieving Good','Environment Agency','ENG','bulk_csv','https://environment.data.gov.uk/catchment-planning/England/rnags.csv',(select id from ingest.licence where slug='ogl3'),'regulator_assessment','P3Y',null,'active','Official sector/activity attribution per waterbody (agriculture, water industry, urban ...)'),
 ('castco_wfd_c4','WFD Cycle 4 (2025) classification on river waterbodies, via CaSTCo','The Rivers Trust (EA data)','ENG','arcgis_feature_service','https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services',(select id from ingest.licence where slug='rt-castco'),'regulator_assessment','P3Y',null,'active','Latest classification on lines and catchment polygons, simplified geometry'),
 ('castco_separate','SEPARATE source apportionment (P, N, sediment) per waterbody','The Rivers Trust / CaSTCo','ENG','arcgis_feature_service','https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services',(select id from ingest.licence where slug='rt-castco'),'modelled','P1Y',null,'active','MODELLED. Must always display as modelled apportionment, not measurement.'),
 ('castco_big_river_watch','Big River Watch survey responses','The Rivers Trust','GB','arcgis_feature_service','https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services/The_Big_River_Watch_view/FeatureServer',(select id from ingest.licence where slug='rt-castco'),'citizen_science','P6M',null,'active','20k surveys, carries wfdWaterbody'),
 ('castco_riverfly','Riverfly Partnership (ARMI) surveys','Riverfly Partnership / CaSTCo','GB','arcgis_feature_service','https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services/Riverfly1/FeatureServer',(select id from ingest.licence where slug='rt-castco'),'citizen_science','P1D',null,'active','83k surveys + urban/extended variants'),
 ('castco_pressures','CaSTCo pressure layers (consented discharges, pollution incidents, obstacles, WQ summary stats)','The Rivers Trust (EA data)','ENG','arcgis_feature_service','https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services',(select id from ingest.licence where slug='rt-castco'),'regulator_assessment','P1Y',null,'active',null),
 ('os_open_rivers','OS Open Rivers (WatercourseLink / HydroNode)','Ordnance Survey','GB','bulk_file','https://api.os.uk/downloads/v1/products/OpenRivers',(select id from ingest.licence where slug='ogl3'),'official_monitoring','P6M',null,'active','193k links, 198k nodes; names are not unique rivers (600 links called River Avon)'),
 ('sepa_kiwis','SEPA KiWIS time series','SEPA','SCT','rest_api','https://timeseries.sepa.org.uk/KiWIS/KiWIS',(select id from ingest.licence where slug='ogl3'),'official_monitoring','PT15M','PT30M','active','1,176 stations, 736 15-min series; getStationList 500s on station_elevation / gauge_datum'),
 ('nrw_river_levels','NRW River Levels API','Natural Resources Wales','WLS','rest_api','https://api-portal.naturalresources.wales',(select id from ingest.licence where slug='ogl3'),'official_monitoring','PT15M',null,'blocked','Azure APIM developer portal: needs a free subscription key. ACTION: register and add key. Wye is half Welsh.'),
 ('nrw_wye_sondes','NRW Wye SAC sonde data (15-min chemistry)','Natural Resources Wales','WLS','arcgis_feature_service','https://smnr-nrw.hub.arcgis.com/apps/98b26568c38f48c797ddc9a198dea7d0/explore',(select id from ingest.licence where slug='ogl3'),'official_monitoring','PT15M',null,'blocked','Only exposed through an ArcGIS Experience dashboard; backing feature service is permission-restricted. ACTION: email opendata@naturalresourceswales.gov.uk.'),
 ('nrw_datamap_wfs','DataMapWales GeoServer (WFD, stations, SAC phosphorus, bathing)','Natural Resources Wales','WLS','wfs','https://datamap.gov.wales/geoserver/ows',(select id from ingest.licence where slug='ogl3'),'regulator_assessment','P1Y',null,'active','Welsh waterbodies, catchments, main rivers, WQ archive stations (no results), phosphorus compliance'),
 ('openalex','OpenAlex works','OurResearch','GB','rest_api','https://api.openalex.org/works',(select id from ingest.licence where slug='cc0'),'published_research','P1D',null,'active','No key needed. Per-work OA status and licence retained.'),
 ('ne_nutrient_neutrality','Natural England nutrient neutrality catchments','Natural England','ENG','arcgis_feature_service','https://services.arcgis.com/JJzESW51TqeY9uat/arcgis/rest/services/Nutrient_Neutrality_Catchments_England/FeatureServer',(select id from ingest.licence where slug='ogl3'),'regulator_assessment','P1Y',null,'active',null),
 ('rpa_parcel_points','RPA parcel points (2.6M)','Rural Payments Agency','ENG','ogc_features','https://environment.data.gov.uk/spatialdata/rpa-parcel-points-england/ogc/features/v1',(select id from ingest.licence where slug='ogl3'),'inferred_risk','P6M',null,'gap','Points carry only parcel_reference + county: NO crop or land-use. Not useful alone; need CROME or field boundaries.'),
 ('ea_intensive_farming','EA permitted intensive livestock units','Environment Agency','ENG','manual',null,(select id from ingest.licence where slug='unknown'),'regulator_assessment',null,null,'gap','No open dataset found. FOI / EIR request needed (permit register).'),
 ('defra_june_survey','Defra June Survey livestock','Defra','ENG','bulk_csv','https://data.gov.uk/dataset/june_survey_of_agriculture_and_horticulture_england',(select id from ingest.licence where slug='ogl3'),'official_monitoring','P1Y',null,'gap','County level only; finest geography last published for 2021'),
 ('sentinel2_stac','Sentinel-2 scene catalogue (STAC)','ESA / Copernicus','GB','stac',null,(select id from ingest.licence where slug='unknown'),'official_monitoring','P5D',null,'planned','Phase 4. True-colour before/after first; quantified bloom detection undecided (Stirling).'),
 ('stirling_chlorophyll','Stirling UK Lakes Observatory chlorophyll-a','University of Stirling','GB','manual',null,(select id from ingest.licence where slug='unknown'),'modelled','P7D',null,'planned','Licence for public display unknown: needs a direct conversation.'),
 ('wyeviz','WyeViz / Friends of the River Wye','Friends of the River Wye','ENG','manual',null,(select id from ingest.licence where slug='unknown'),'citizen_science','P7D',null,'gap','Tableau dashboard, no bulk API. Needs direct request.'),
 ('wuf_reports','Wye & Usk Foundation reports and data','Wye & Usk Foundation','WLS','pdf',null,(select id from ingest.licence where slug='unknown'),'published_research',null,null,'gap','PDF reports; CSV possibly on request.')
on conflict (slug) do nothing;

insert into ref.organisation (slug, name, kind, country, aliases) values
 ('anglian_water','Anglian Water','water_company','ENG','{"Anglian Water Services","AWS","Anglian Water Services Ltd"}'),
 ('northumbrian_water','Northumbrian Water','water_company','ENG','{"Northumbrian Water Ltd","NWL","NWG"}'),
 ('severn_trent','Severn Trent Water','water_company','ENG','{"STW","SVT","Severn Trent"}'),
 ('south_west_water','South West Water','water_company','ENG','{"SWW","SBB","South West Water Ltd"}'),
 ('southern_water','Southern Water','water_company','ENG','{"SWS","Southern Water Services"}'),
 ('thames_water','Thames Water','water_company','ENG','{"TWL","Thames Water Utilities","Thames Water Utilities Limited"}'),
 ('united_utilities','United Utilities','water_company','ENG','{"UUP","UU","United Utilities Water"}'),
 ('wessex_water','Wessex Water','water_company','ENG','{"WXW","WSX","Wessex Water Services"}'),
 ('yorkshire_water','Yorkshire Water','water_company','ENG','{"YWS","Yorkshire Water Services"}'),
 ('dwr_cymru','Dwr Cymru Welsh Water','water_company','WLS','{"DCWW","Welsh Water","Dwr Cymru"}'),
 ('hafren_dyfrdwy','Hafren Dyfrdwy','water_company','WLS','{"HD","Dee Valley Water"}'),
 ('scottish_water','Scottish Water','water_company','SCT','{"SW"}'),
 ('environment_agency','Environment Agency','regulator','ENG','{"EA"}'),
 ('natural_resources_wales','Natural Resources Wales','regulator','WLS','{"NRW","Cyfoeth Naturiol Cymru"}'),
 ('sepa','Scottish Environment Protection Agency','regulator','SCT','{"SEPA"}'),
 ('rivers_trust','The Rivers Trust','charity','GB','{"Rivers Trust"}'),
 ('wye_usk_foundation','Wye and Usk Foundation','charity','WLS','{"W&UF","WUF"}')
on conflict (slug) do nothing;

-- canonical unit per dimension (is_canonical) + every conversion we have met
insert into ref.unit (id, label, dimension, is_canonical, factor, "offset", aliases) values
 ('mg_l','milligram per litre','concentration_mass',true,1,0,'{"MILLIGRAM PER LITRE","mg/l","mg/L","mg l-1","MG/L"}'),
 ('ug_l','microgram per litre','concentration_mass',false,0.001,0,'{"MICROGRAM PER LITRE","ug/l","µg/l","ug/L"}'),
 ('ng_l','nanogram per litre','concentration_mass',false,0.000001,0,'{"NANOGRAM PER LITRE","ng/l"}'),
 ('m3_s','cubic metre per second','flow',true,1,0,'{"m3/s","m3s","m³/s","cumecs","CUBIC METRE PER SECOND"}'),
 ('l_s','litre per second','flow',false,0.001,0,'{"l/s","L/s","LITRE PER SECOND"}'),
 ('m','metre','length',true,1,0,'{"m","mASD","mAOD","mALD","metre","meter","METRE"}'),
 ('cm','centimetre','length',false,0.01,0,'{"cm"}'),
 ('mm','millimetre of rain','depth_rain',true,1,0,'{"mm","millimeter","MILLIMETRE"}'),
 ('celsius','degrees Celsius','temperature',true,1,0,'{"CELSIUS","degC","°C","deg C","C"}'),
 ('kelvin','kelvin','temperature',false,1,-273.15,'{"K","KELVIN"}'),
 ('pct','percent','ratio',true,1,0,'{"PERCENTAGE","%","percent","% saturation","PERCENT"}'),
 ('us_cm','microsiemens per centimetre','conductivity',true,1,0,'{"MICROSIEMENS PER CENTIMETRE","uS/cm","µS/cm","us/cm"}'),
 ('ms_cm','millisiemens per centimetre','conductivity',false,1000,0,'{"mS/cm","MILLISIEMENS PER CENTIMETRE"}'),
 ('ph','pH units','ph',true,1,0,'{"PH UNITS","pH","pH units"}'),
 ('ntu','nephelometric turbidity unit','turbidity',true,1,0,'{"NTU","FNU","FTU","NEPHELOMETRIC TURBIDITY UNIT","FORMAZIN NEPHELOMETRIC UNIT"}'),
 ('per_100ml','count per 100 ml','count_per_100ml',true,1,0,'{"COUNT PER 100 ML","CFU/100ml","MPN/100ml","no/100ml","cfu/100ml","NUMBER PER 100 ML"}'),
 ('score','score / index','dimensionless',true,1,0,'{}')
on conflict (id) do nothing;

insert into ref.parameter (code, name, domain, canonical_unit, signal_code, higher_is) values
 ('water_level','River water level','hydrology','m',null,'neutral'),
 ('river_flow','River flow','hydrology','m3_s',null,'neutral'),
 ('rainfall','Rainfall','meteorology','mm',null,'neutral'),
 ('groundwater_level','Groundwater level','hydrology','m',null,'neutral'),
 ('water_temperature','Water temperature','physical','celsius','chemical','worse'),
 ('ph','pH','chemistry','ph','chemical','neutral'),
 ('dissolved_oxygen_conc','Dissolved oxygen (concentration)','chemistry','mg_l','chemical','better'),
 ('dissolved_oxygen_sat','Dissolved oxygen (% saturation)','chemistry','pct','chemical','better'),
 ('bod5','Biochemical oxygen demand (5 day)','chemistry','mg_l','chemical','worse'),
 ('conductivity','Electrical conductivity (25 C)','physical','us_cm','chemical','neutral'),
 ('turbidity','Turbidity','physical','ntu','algal_visual','worse'),
 ('suspended_solids','Suspended solids','physical','mg_l','chemical','worse'),
 ('ammonia_total_n','Ammoniacal nitrogen (total, as N)','chemistry','mg_l','chemical','worse'),
 ('ammonia_unionised_n','Ammonia, un-ionised (as N)','chemistry','mg_l','chemical','worse'),
 ('nitrate_n','Nitrate (as N)','chemistry','mg_l','chemical','worse'),
 ('nitrite_n','Nitrite (as N)','chemistry','mg_l','chemical','worse'),
 ('nitrogen_total_oxidised','Total oxidised nitrogen (as N)','chemistry','mg_l','chemical','worse'),
 ('phosphorus_reactive','Orthophosphate, reactive (as P)','chemistry','mg_l','chemical','worse'),
 ('phosphorus_total','Phosphorus, total (as P)','chemistry','mg_l','chemical','worse'),
 ('chlorophyll_a','Chlorophyll a','biology','ug_l','algal_visual','worse'),
 ('ecoli','Escherichia coli','bacteria','per_100ml','chemical','worse'),
 ('enterococci','Intestinal enterococci','bacteria','per_100ml','chemical','worse')
on conflict (code) do nothing;

-- EA WQ archive: the priority determinands mapped by hand; the loader adds the remaining ~8,000 as 'unmapped' so nothing is lost
insert into ref.parameter_alias (source_id, native_code, native_label, native_unit, parameter_id, unit_id, fraction, method, matrix, status, confidence, decided_by)
select (select id from ingest.source where slug='ea_wq_archive'), v.code, v.label, v.unit, (select id from ref.parameter where code=v.p), v.u, v.frac, v.meth, 'river_water', 'mapped', 1, 'human:seed'
from (values
 ('0180','Orthophosphate, reactive as P','MILLIGRAM PER LITRE','phosphorus_reactive','mg_l','reactive','laboratory'),
 ('0348','Phosphorus, Total as P','MILLIGRAM PER LITRE','phosphorus_total','mg_l','total','laboratory'),
 ('0117','Nitrate as N','MILLIGRAM PER LITRE','nitrate_n','mg_l','dissolved','laboratory'),
 ('0118','Nitrite as N','MILLIGRAM PER LITRE','nitrite_n','mg_l','dissolved','laboratory'),
 ('0116','Nitrogen, Total Oxidised as N','MILLIGRAM PER LITRE','nitrogen_total_oxidised','mg_l','total','laboratory'),
 ('0111','Ammoniacal Nitrogen as N','MILLIGRAM PER LITRE','ammonia_total_n','mg_l','total','laboratory'),
 ('0119','Ammonia un-ionised as N','MILLIGRAM PER LITRE','ammonia_unionised_n','mg_l','unionised','calculated'),
 ('9901','Oxygen, Dissolved, % Saturation','PERCENTAGE','dissolved_oxygen_sat','pct','saturation','in_situ'),
 ('9924','Oxygen, Dissolved as O2','MILLIGRAM PER LITRE','dissolved_oxygen_conc','mg_l',null,'in_situ'),
 ('0082','Oxygen, Dissolved : (Laboratory) as O2','MILLIGRAM PER LITRE','dissolved_oxygen_conc','mg_l',null,'laboratory'),
 ('0085','BOD : 5 Day ATU','MILLIGRAM PER LITRE','bod5','mg_l',null,'laboratory'),
 ('0061','pH','PH UNITS','ph','ph',null,'in_situ'),
 ('0076','Temperature of Water','CELSIUS','water_temperature','celsius',null,'in_situ'),
 ('0077','Conductivity at 25 C','MICROSIEMENS PER CENTIMETRE','conductivity','us_cm',null,'in_situ'),
 ('0068','Turbidity','NTU','turbidity','ntu',null,'in_situ'),
 ('0135','Solids, Suspended at 105 C','MILLIGRAM PER LITRE','suspended_solids','mg_l',null,'laboratory'),
 ('0729','Chlorophyll a','MICROGRAM PER LITRE','chlorophyll_a','ug_l',null,'laboratory')
) as v(code,label,unit,p,u,frac,meth)
on conflict (source_id, native_code) do nothing;

-- Categorical crosswalks
insert into ref.value_map (domain, source_id, native, canonical, rank, note) values
 ('wfd_status',null,'High','high',1,null),('wfd_status',null,'Good','good',2,null),('wfd_status',null,'Moderate','moderate',3,null),
 ('wfd_status',null,'Poor','poor',4,null),('wfd_status',null,'Bad','bad',5,null),
 ('wfd_status',null,'Pass','pass',null,'chemical status is binary'),('wfd_status',null,'Fail','fail',null,'chemical status is binary'),
 ('wfd_status',null,'Supports Good','supports_good',null,'hydrology/mitigation elements'),('wfd_status',null,'Does Not Support Good','does_not_support_good',null,null),
 ('wfd_status',null,'Not High','not_high',null,null),('wfd_status',null,'Moderate or less','moderate_or_worse',null,null),
 ('wfd_status',null,'Does not require assessment','not_assessed',null,null),('wfd_status',null,'No Information','not_assessed',null,null),
 ('overflow_status',null,'1','discharging',null,'Stream/NSOH: overflow currently discharging'),
 ('overflow_status',null,'0','not_discharging',null,null),
 ('overflow_status',null,'-1','offline',null,'EDM monitor offline: unknown, NOT zero'),
 ('obs_quality',null,'Good','good',null,null),('obs_quality',null,'Estimated','estimated',null,null),('obs_quality',null,'Suspect','suspect',null,null),
 ('obs_quality',null,'Unchecked','unchecked',null,null),('obs_quality',null,'Missing','missing',null,null),
 ('bathing_class',null,'Excellent','excellent',1,null),('bathing_class',null,'Good','good',2,null),('bathing_class',null,'Sufficient','sufficient',3,null),('bathing_class',null,'Poor','poor',4,null)
on conflict do nothing;

insert into ref.pressure_sector (code, label, native_names) values
 ('agriculture','Agriculture and rural land management','{"Agriculture and rural land management"}'),
 ('water_industry','Water industry','{"Water Industry"}'),
 ('urban_transport','Urban and transport','{"Urban and transport"}'),
 ('industry','Industry','{"Industry"}'),
 ('government','Local and central government','{"Local and Central Government"}'),
 ('domestic','Domestic general public','{"Domestic General Public"}'),
 ('mining','Mining and quarrying','{"Mining and quarrying"}'),
 ('recreation','Recreation','{"Recreation"}'),
 ('navigation','Navigation','{"Navigation"}'),
 ('natural','Natural causes','{"Natural"}'),
 ('other','Other','{"Other"}'),
 ('no_sector','No sector responsible','{"No sector responsible"}'),
 ('under_investigation','Sector under investigation','{"Sector under investigation"}')
on conflict (code) do nothing;

insert into ref.classification_element (code, label, level, signal_code, native_names) values
 ('overall','Overall water body','overall',null,'{"Overall Water Body"}'),
 ('ecological','Ecological status/potential','ecological','ecological','{"Ecological"}'),
 ('chemical','Chemical status','chemical','chemical','{"Chemical"}'),
 ('biological','Biological quality elements','biological','ecological','{"Biological quality elements"}'),
 ('physchem','Physico-chemical quality elements','physico_chemical','chemical','{"Physico-chemical quality elements"}'),
 ('fish','Fish','biological','ecological','{"Fish"}'),
 ('invertebrates','Invertebrates','biological','ecological','{"Invertebrates"}'),
 ('macrophytes_phytobenthos','Macrophytes and phytobenthos','biological','ecological','{"Macrophytes and Phytobenthos Combined","Macrophytes","Phytobenthos"}'),
 ('phosphate','Phosphate','physico_chemical','chemical','{"Phosphate"}'),
 ('ammonia','Ammonia','physico_chemical','chemical','{"Ammonia (Phys-Chem)","Ammonia (Annex 8)","Un-ionised ammonia"}'),
 ('dissolved_oxygen','Dissolved oxygen','physico_chemical','chemical','{"Dissolved oxygen"}'),
 ('ph','pH','physico_chemical','chemical','{"pH"}'),
 ('temperature','Temperature','physico_chemical','chemical','{"Temperature"}'),
 ('hydrological_regime','Hydrological regime','hydromorphology',null,'{"Hydrological Regime"}'),
 ('morphology','Morphology','hydromorphology','ecological','{"Morphology"}'),
 ('hydromorph_supporting','Hydromorphological supporting elements','hydromorphology',null,'{"Hydromorphological Supporting Elements"}'),
 ('specific_pollutants','Specific pollutants','specific_pollutant','chemical','{"Specific pollutants"}'),
 ('priority_substances','Priority substances','priority_substance','chemical','{"Priority substances"}'),
 ('priority_hazardous','Priority hazardous substances','priority_substance','chemical','{"Priority hazardous substances"}'),
 ('other_pollutants','Other pollutants','other','chemical','{"Other Pollutants"}')
on conflict (code) do nothing;

insert into core.signal_def (code, label, description) values
 ('chemical','Chemical','WFD physico-chemical + chemical status and the latest official nutrient/oxygen readings.'),
 ('sewage_pressure','Sewage pressure','Storm overflow activity, consented discharges and modelled sewage load upstream and in the waterbody.'),
 ('agricultural_pressure','Agricultural pressure','Modelled agricultural share of nutrient load, official reasons-for-failure, nutrient neutrality status. Inferred landscape risk, never field attribution.'),
 ('ecological','Ecological','WFD ecological and biological classes, Riverfly scores, obstacles.'),
 ('algal_visual','Algal / visual','Citizen reports of colour, algae and turbidity; satellite true-colour when available.')
on conflict (code) do nothing;

insert into research.evidence_rule (code, label, rule_text, rank) values
 ('single_pilot_study','Single or pilot study','One study, one site/period, or flagged pilot/preliminary by its authors.',1),
 ('multiple_independent_studies','Multiple independent studies','Two or more studies by independent groups reaching a broadly similar finding on this river or comparable ones.',2),
 ('official_monitoring_consensus','Official monitoring consensus','Regulator monitoring or an official assessment (WFD, Defra/EA/NRW report) supports the finding.',3)
on conflict (code) do nothing;

-- added while profiling flood-monitoring units (Ml/d, mBDAT)
insert into ref.unit (id, label, dimension, is_canonical, factor, "offset", aliases) values
 ('ml_d','megalitre per day','flow',false,0.011574074,0,'{"Ml/d","MEGALITRE PER DAY"}') on conflict (id) do nothing;
update ref.unit set aliases = aliases || '{mBDAT}' where id='m' and not ('mBDAT' = any(aliases));
