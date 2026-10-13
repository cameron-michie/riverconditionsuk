# Access to request

Nothing here blocks what already runs. Each row unlocks data that is not yet in the app.

| # | What | Who and how | Unlocks | Effort |
|---|---|---|---|---|
| 1 | **Wye & Usk Foundation: permission and ecology data** | Email below. The weekly chemistry already loads from their public Epicollect projects, but the projects state no licence. | Written permission and attribution wording for the Epicollect data; electrofishing, Riverfly/macroinvertebrates, temperature loggers, habitat and phosphate studies | One email |
| 2 | **NRW API key** (now only for the rest) | River levels and rainfall are already flowing from NRW's open telemetry API, no key needed. A key (`api-portal.naturalresources.wales`, free) is still needed for *Flood Risk Forecast* and *Live Flood Warnings*. | Five-day flood risk for Wales, Welsh warnings | 10 minutes |
| 3 | **Flood Forecasting Centre v3 key** | Ask the FFC (Met Office / EA) for a free API key. The v1 endpoint we use still works (a statement issued today), but the v3 endpoint needs a key and v1 has been announced for retirement. | Keeps the five-day flood outlook running | One email |
| 4 | **NRW Wye SAC sondes** | Ask NRW's evidence and data team. The sonde dashboard is permissioned. | Continuous chemistry (the best Wye signal), once the Wye data is in | One email |
| 5 | **Supabase Storage credentials** | Hosted project `cam-rivers`: Dashboard, Storage, S3 connection, create an access key. Or use the service-role key through the CLI. | Pushing the cold archive and weather frames to the hosted project | 5 minutes |
| 6 | **Cardiff Wye-Usk Observatory contact** | The data and facilities page lists key contacts (it blocks automated fetches; open it in a browser). | Cardiff's own processed Wye/Usk datasets, which could replace the volunteer feed for QA'd values | One email |
| 7 | **Met Office DataHub account** (optional) | `datahub.metoffice.gov.uk`, free tier. Not needed: radar comes from the open AWS bucket and the forecast from ECMWF open data. | A fallback for rain and pressure images | Skip unless a feed breaks |
| 8 | **SEPA** (optional) | No key needed for what we use. Keys exist for large bulk pulls. | Historic Scottish backfill | Skip |

Already open, no request needed: EA flood-monitoring, EA hydrology, EA water quality archive, EA bathing waters, Met Office radar (AWS, CC BY-SA), ECMWF open data, NRFA, SEPA KiWIS, the water companies' Stream feeds, Welsh Water's live overflow layer, Rivers Trust ArcGIS layers, Epicollect5 public projects (5 requests per minute).

## Draft: Wye & Usk Foundation

> Subject: Using the Wye and Usk citizen-science data in a free river-conditions map
>
> Hello,
>
> I'm building a free, non-commercial map of UK river conditions (rivers, sewage overflows, flood and weather data in one place). It already shows the weekly volunteer readings from the public Epicollect5 projects *Wye Alliance Citizen Science* and *Usk CaSTCo Citizen Science* (phosphate, nitrate, ammonia, conductivity, turbidity, temperature), as 'citizen science' data with the sampling site and date on every reading.
>
> Two questions:
>
> 1. Are you happy for that data to be used this way? If so, how would you like it credited, and is there a licence you would like attached (I have assumed none is stated, so I show it as 'licence unconfirmed' until I hear from you)?
> 2. Could you share any of your other ecological data, in whatever form is easiest: electrofishing and fish-population surveys, Riverfly and macroinvertebrate results, habitat and restoration surveys, temperature logger records, and the phosphate studies? I would show it alongside the chemistry with the same credit.
>
> I can send a link to the live map so you can see how it is presented. I'm happy to adjust anything you're uncomfortable with.
>
> Thank you,
> Cameron

## Draft: Natural Resources Wales (sondes)

> Subject: Data request: Wye SAC continuous water quality sondes
>
> Hello, I'm building a free, non-commercial UK river-conditions map that already uses NRW's open River Levels data. Could NRW share the Wye SAC continuous water quality sonde data (dissolved oxygen, temperature, pH, conductivity, turbidity, ammonia where measured), or tell me how to be given access to the dashboard feed? I would credit NRW and show readings with their timestamps and site.

## Notes
- Epicollect5 exports allow 5 requests a minute; the loader uses a 24-second gap and fetches only entries uploaded since the last run.
- About 6,600 volunteer visits (of 36,000) could not be placed because their site never recorded coordinates. Asking the Foundation for the site list with coordinates fixes this in one step.
