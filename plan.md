River Conditions UK — Build Plan
10 Oct 2026 · @Cam
The concept and an honest verdict
The idea is a public-facing picture of UK river health: for any river, a single place that fuses live conditions (flow, level, temperature), water chemistry, satellite-detected algae and discolouration, sewage discharges, agricultural pressure, ecological status and the local rules of use — and that holds both water companies and farmers to account using official data, crowdsourced readings, and the latest research. It reacts to events (a storm, a heatwave bloom) and it translates science trapped in PDFs into plain English.
The verdict: the concept is sound and the gap is real, but the other agent's framing undersells the hard part and oversells the easy part. Its framing — a “river weather forecast” focused on swim-safety — is the most buildable slice, but it is also the slice closest to what already exists (Surfers Against Sewage, the EA's own tools). The genuinely novel, genuinely valuable, genuinely hard parts are the three the other agent treats as secondary: fusing many siloed sources into one honest health picture, bringing agriculture into the accountability frame, and synthesising research automatically as it is published. Those are what make this a fellowship-grade project rather than another conditions map, and they are where the engineering and the AI actually live.
One correction worth carrying forward: “the data is already there, just not in one place” is true for the structured APIs (flow, bathing water) and false for most of what makes this distinctive. Research outputs, citizen-science readings, agricultural pressure, and academic findings are not sitting behind clean APIs — they are in PDFs, bespoke dashboards, and formats that differ per source. The project is hard precisely because the valuable data is not already in one place or one shape. That difficulty is the moat.
What makes this different
Every existing tool owns one variable and one audience. Surfers Against Sewage owns sewage alerts for swimmers. The EA's Check For Flooding owns hydrology. The Rivers Trust owns policy-facing catchment reports. WyeViz owns one river for campaigners. None of them does the synthesis, and three specific moves set this project apart.
First, interpretation over data. The scarce thing is not readings — it is a layer that weaves hydrology, chemistry, satellite observation, sewage and agriculture into one legible read per river, honest about uncertainty. The value is the fusion and the plain-English translation, not any single feed.
Second, agriculture in the frame — as inferred risk, not attribution. Sewage gets the headlines, but agricultural runoff (nitrates, phosphates, slurry) is arguably the larger driver of poor river health, and almost nothing public addresses it, because the pollution is diffuse and field-level “what was sprayed here” data does not exist publicly. The honest build is a risk-proximity model, not an accusation: open field boundaries, regional fertiliser averages, livestock-density proxies at parish or ward level, and proximity of intensive agriculture to the watercourse, combined into an explicitly inferred risk (“this stretch passes through X hectares of farmland, Y% intensive livestock in the surrounding parish, regional phosphate loading around Z kg/ha”). It presents the landscape and lets the reader draw the inference — genuinely new ground for a public tool, and defensible precisely because it never names a culprit field.
Third, research synthesis. Universities, Rivers Trusts, catchment partnerships and the EA constantly publish findings about specific rivers, and all of it is locked in PDFs the public never reads. A pipeline that ingests those outputs, works out which river each concerns, and surfaces the finding in plain English — cited, with its evidence strength shown — is the standout AI-native component. It is also the thing that would make a scientist look at this and say it is genuinely useful, not just pretty.
Together these turn “a river map” into “the public's window onto the health of their river and the science about it.” The swim-safety feature the other agent leads with is worth building, but as one view among several — not the headline, because the headline has to be the part nobody else has done.
How the system runs itself
The design principle is a pipeline that wakes on a schedule, pulls from every source it can reach, and leaves a clean, queryable picture of river health behind it — no manual step in the loop. The hard engineering is in stages 2 and 3: an ingestion layer with one adapter per source (API pulls where an API exists, scrapers and PDF extraction where it does not, scene fetches for satellite), feeding a normalisation layer that does the thing nothing else does — maps every heterogeneous record to a specific river and catchment, aligns units and schemas, and tags every value with its provenance. That feeds one store (Postgres with PostGIS, per-stretch and time-series), over which a synthesis layer produces the plain-English state, the research findings, and the safety reads the public views render. Each stage fails independently: a source going dark degrades one layer, not the whole system.
Data sources, and the honest difficulty of each
The sources split sharply by how hard they are to ingest. The structured APIs are a weekend each; the valuable, differentiating sources (research, agriculture, crowd data, satellite) are where the real work and the real moat sit. The table sorts roughly from easiest to hardest.
Source
Feeds
Access
Honest difficulty
EA flood-monitoring API
river level, flow, rainfall, warnings
Open REST, no key
Easy — ~2,400 gauges, national, real-time
EA Hydrology API
historic level/flow/rainfall series
Open REST, no key
Easy — well-documented
NRW River Levels API
Welsh river levels, rainfall
Open (OGL)
Easy — critical: the Wye is cross-border
NRW Wye SAC sonde data
temp, DO, pH, turbidity, chlorophyll, ammonium — every 15 min
Open (data.gov.uk)
Easy — six Wye sondes; the strongest real-time chemistry signal
National River Flow Archive (NRFA)
definitive long-term flow records
Open (CEH)
Easy — use for trend context
EA Water Quality Archive (WIMS)
nitrate, phosphate, DO, pH, ammonia
Open API / bulk CSV
Moderate — ~91 EA points on the Wye; intermittent sampling
NRW Open Water Quality Archive
NRW chemistry samples
Open (DataMapWales)
Moderate — ~83 Wye points; some fields redacted
Bathing Water Quality API
E. coli, enterococci, classification
Open REST, no key
Easy — designated sites only, seasonal
EDM storm-overflow data
sewage discharge frequency/duration
Open download (annual) + emerging live feeds
Moderate — annual lag; Welsh Water (Dŵr Cymru) live varies
Big River Watch
public observations (colour, pollution, wildlife)
Bulk CSV via Data Explorer
Easy — biannual snapshots; simple adapter
Riverfly Partnership (ARMI)
macroinvertebrate / water-quality scores
Open download (Cartographer) + CaBA feature service
Easy — daily feed, nationwide
CaSTCo Data Hub
aggregated citizen science, Riverfly, silt/flow
Open geoportal
Moderate — emerging national aggregator; treat as a primary trust source
RPA Field Boundaries
~2.6M agricultural parcels
Open (OGL), WFS
Moderate — England only; geometric backbone for ag-risk
MAGIC
land classification, nutrient-pollution plan boundaries
Open layers
Moderate — nutrient-plan boundaries directly relevant to phosphate
UKCEH Land Cover Maps
25m land-cover raster
Open (UKCEH)
Moderate — catchment land-use percentages
Defra June Survey
livestock counts (cattle, sheep, pigs, poultry)
Open (data.gov.uk)
Moderate — county level only, never parish
BSFP fertiliser practice
fertiliser / manure application rates
Official stats, by region
Moderate — regional averages only
Sentinel-2 (Copernicus)
true-colour, chlorophyll, turbidity bands
Open, free
Hard — use for true-colour before/after; quantified detection is CV-hard
Stirling UK Lakes Observatory
weekly chlorophyll-a, ~936 waterbodies, 20m
Request / licence
Unknown — contact for public-display licensing; else backend-only
WyeViz / Friends of the River Wye
citizen phosphate & water-quality, weekly
Tableau dashboard; no bulk API
Needs direct request — they may welcome proper surfacing of their data
W&UF
electrofishing, habitat, phosphate studies
PDF reports; CSV possibly on request
Needs direct request — CaSTCo participation suggests openness
Cardiff Wye-Usk Observatory
long-term catchment data from the 1980s
Collaborator access
Email for collaboration
Two honest cautions remain. The chemistry worry is resolved — the Wye has ~91 EA plus ~83 NRW sampling points and six 15-minute sondes, so the chemical sub-signal is viable; commit to it. And the cross-border point matters more than first assumed: the Wye runs through England and Wales, so NRW feeds are not optional — they are half the river.
Two honest cautions. The University of Stirling already runs a near-real-time algal-bloom monitoring service over hundreds of UK waterbodies, so the satellite layer is not virgin ground — check whether to build it or cite it. And the EA APIs, though excellent, have real gaps: water-quality sampling points are sparse and intermittent, so “chemistry here, now” is often an interpolation, not a reading — the honest presentation has to show that, not paper over it.
The research-synthesis engine
This is the component that makes the project distinctive, and the one that best shows an AI-native skillset. The problem it solves: universities, Rivers Trusts, catchment partnerships and the EA constantly publish findings about specific rivers, and almost all of it is locked in PDFs and journal pages the public never reads. The role here is librarian and translator, not author: the app surfaces, links and glosses the science — it never asserts a finding in its own authoritative voice. That single choice removes the project's biggest risks (misrepresenting a researcher, and “the AI made it up”) while keeping the genuinely AI-native work.
The pipeline, stage by stage:
1. Ingest from a curated source list. A watched set of trusted sources — named university groups, the EA, Rivers Trusts, catchment partnerships, relevant journals and preprints. Curated, not open-web, because quality and scope both collapse otherwise. New outputs are pulled on a schedule.
2. Geolocate each output to a waterway. The key AI move: a model reads each report and works out which river or catchment it concerns. This mapping from free text to place is the hard, valuable step and is impractical without an LLM — it is what lets a study surface on the right river's page.
3. Judge relevance and write a plain-English gloss. For each output: a one-line gloss that helps a member of the public decide whether to click (“this study looks at phosphate in the Wye from poultry farming”) — a signpost, not a claim the app is making.
4. Present the source, not a synthesised verdict. Each item on the river page shows the title, the author and date, the abstract (where licensing allows) or a short quote, the plain-English gloss, and a link out to the original. The app does not combine findings into its own assertion like “phosphate is rising”; it shows the reader the studies and lets them read the science.
Three rules keep it honest, which matters enormously when putting science in front of the public:
• Always cite, always link, never assert. Every item links to its source and the authority stays with the researcher. The app surfaces and signposts; it never becomes the thing making the claim. This is the defence against “the AI made it up.”
• Prefer open-access, respect abstract licensing. Open-access papers, preprints, and .gov/.ac.uk reports can be shown in full; some paywalled journals restrict reproducing even the abstract, so those get a short quote or the gloss plus the link. Licence is tracked per source, like every other feed.
• Signpost relevance and recency, not a verdict. Show what each study is about and when it was published, and let the reader weigh it. The app orders and translates the literature; it does not rule on it.
This engine is the strongest argument for the whole project in a fellowship setting: it is unambiguously AI-native (the geolocation and glossing could not be done at scale before LLMs), it serves the public directly, and it turns the thing everyone complains about — research trapped in PDFs — into a living, browsable public library, without the app ever overstepping into claims it has no authority to make.
How it presents to the public
The design choice that sets this apart: organise around the river, not the administrative unit. Every existing tool is built around constituency, water company or beach, because that is how blame is assigned. Organising around the river and its stretches matches how nature works and how a curious person actually thinks — “what about my river?” — and it differentiates the app before anything is drawn.
Three nested levels the whole app moves between: a national map (rivers coloured by a composite signal, with event overlays for blooms, high flow and recent discharges); a river or catchment page (the heart of the app — a scrollable dossier); and a stretch or spot view (conditions now, what is upstream, is it safe to be in).
For river health itself, the key presentation rule is honest separation, not a single blended score. Show a small set of named sub-signals side by side — chemical, sewage pressure, agricultural pressure, ecological, and algal/visual — each as its own indicator, so a river that is chemically acceptable but ecologically collapsing reads as exactly that. Encode state in form (a chip, a stripe, a direction arrow), not just colour, so the dimension in trouble is visible at a glance and the page works for colour-blind and skimming readers. Always pair “now” with “trend”: current state beside the multi-year trajectory is what turns a reading into an argument and lets the app say “getting worse in this specific way” with evidence.
The accountability view is a first-class part of the river page: a plain apportioning of the pressures present in a catchment — water-company discharges upstream, agricultural land use, urban runoff — framed as “pressures present here,” not forensic blame, but finally putting farming in the same frame as water companies.
The river dossier reads top to bottom as one object: headline state (the named sub-signals, now and trend) → map of this stretch with live overlays → conditions and safety (carefully caveated) → pressures on this river (the accountability view) → what the science says (the living research feed) → the data behind this (provenance, official vs crowd, links out). One object, every dimension, honest about certainty throughout.
Reactive event mode is the mass-audience hook. When a storm hits or a heatwave triggers a bloom, the home page shifts: before/after satellite imagery of river colour, animated level spikes from the gauges, and a plain-language overlay (“this is what 48 hours of runoff after heavy rain looks like”). This is what makes the app something people open during the news, not a reference they visit once.
Build phases
The plan is a v0 proving ground on one river, then nationwide as the immediate next priority — not a distant phase. The Wye proves the hard parts (the pipeline, the fusion, the research engine) on ground where the data is richest and the personal connection is strongest; going national is then a data-onboarding exercise, not a rebuild, because the architecture is per-source adapters feeding one schema. Build the slice narrow to prove it, then widen fast. Given the richness of the Wye and Usk Foundation's data, one catchment (the Wye) is the obvious v1 — the other agent is right about that.
Phase 0 — the spine (the unglamorous, load-bearing part). Stand up the ingestion-and-normalisation pipeline and the Postgres + PostGIS store for the Wye only: EA flow/level, bathing-water, WIMS chemistry, and EDM sewage, each with a source adapter and provenance tagging. A clean, unified, queryable river-health schema is itself a real artifact and the thing nobody has built publicly. This phase is mostly your Postgres/geospatial learning plan made concrete.
Phase 1 — the river page for the Wye. The dossier for a handful of stretches: separated health sub-signals, now-and-trend, the map with overlays, and conditions. Plain-language synthesis from the fused signals is the first visible AI payoff. Shippable, demonstrable, honest.
Phase 2 — the research-synthesis engine, Wye-scoped. Point the engine at a curated set of Wye sources (the Foundation, Cardiff and other local university work, the EA). This is the standout piece; scoping it to one river keeps it tractable while proving the mechanism. This is the component to build with the most care, because it is the one that makes the whole project distinctive.
Phase 3 — agriculture and accountability. Add the catchment-pressure modelling (land use, livestock density) and the accountability view putting farming beside water companies. This is the Wye's defining issue (poultry-driven phosphate), so it lands with real force here.
Phase 4 — the satellite layer. Sentinel-2 algal/colour detection for the Wye. Technically the most ambitious piece; worth doing because it is the standout in a live demo — but decide first whether to build it or cite Stirling's existing service.
Phase 5 — nationwide (immediate priority). go nationwide, as the immediate priority once v0 works — not a distant phase. Onboard rivers in waves (the Usk next, then the Severn, Teme, Thames and outward), reusing the same pipeline and adding each river's local research sources. Because the hard parts are already built and the EA feeds are national, the main work is onboarding data and sources, not new engineering — which is the whole reason for proving it narrow first.
The honest sequencing note: Phase 0 is the one people skip and the one everything rests on. A tempting demo (a map, a safety light) built before the spine is a prototype that cannot grow. Build the spine first even though it is the least visible.
Risks to hold throughout
• Safety liability. Telling the public “safe to swim” is a genuine duty-of-care problem. Frame everything as “current conditions and official classifications” with clear caveats, never as a guarantee. This needs careful handling, not bravado.
• Don’t rebuild the sewage map. If it reads as another sewage map it dies against the incumbents. Lead with fusion, agriculture and research; sewage is one input.
• Scope creep. The five sub-signals plus the research engine cannot all ship at once. One catchment, spine first, research engine as the centrepiece.
• Credibility of mixed data. Official, crowd and modelled values must always be visibly distinguished. Mixing them invisibly would wreck the trust the whole project depends on.
Technical stack
Built entirely on Supabase, deliberately: it is Postgres (which the project wants anyway for PostGIS geospatial and time-series), it bundles the database, auth and auto-generated APIs, and building a real public app end-to-end on it is itself a strong story for the fellowship and for your Supabase work. It stays a free, open-access tool unless running costs force a change; the fallback revenue model is selling database access to academics and researchers — which is clean for your own synthesis and openly-licensed sources, but not for data licensed in from others, so licence and provenance are tracked per source.
• Database: Supabase Postgres with PostGIS — river and catchment geometry, per-stretch readings, time-series. Confirm spatial-index performance on real (heavy) polygons early.
• ETL / processing: Supabase workers (hosted Dockerfiles), one adapter per source, each on its own schedule. Split light adapters (API pulls) from heavy jobs (satellite imagery, bulk PDF ingestion) — the heavy jobs likely need bigger or batch compute, not a lightweight worker. The pipeline's “runs itself” property depends on real scheduled execution.
• Frontend: minimal and usable — river pages, a dashboard, and the map. Everything except the map is genuinely simple reads from Supabase; the map is the one hard piece (vector tiles, zoom-based loading, MapLibre as the open option), so budget effort there and keep the rest light.
• Auth: none in v1. The tool is purely public read, so there is no per-user state to store and no login to build. Auth arrives only with the first per-user feature.
Ingestion priority order
The spine should onboard feeds in this order — open and high-value first, so the app shows something real early:
1. EA flood / hydrology API — open, national, immediate.
2. NRW river levels + Wye SAC sonde data — open, cross-border, the strongest real-time chemistry signal.
3. EA Water Quality Archive (WIMS), filtered to Wye points — bulk download.
4. Big River Watch bulk CSV — simple biannual adapter.
5. Riverfly (Cartographer / CaBA feature service) — monthly or daily.
6. RPA Field Boundaries + MAGIC nutrient-plan boundaries — quarterly static layers.
7. Stirling chlorophyll — weekly, only if licensing allows.
Everything else — W&UF reports, university PDFs, the whole research-synthesis feed — sits in the research engine, not the live pipeline. That split (structured feeds in the spine, unstructured research in the agent-driven engine) is the backbone of the architecture.
On the horizon (out of scope for v1)
The feature worth building toward is public submission — letting people contribute their own readings (phosphate kits, observations, photos) into the datasets. It is deliberately out of scope now, because it brings auth, moderation, spam and data-quality handling, and the provenance question in its sharpest form (citizen readings must never be shown as equal to official monitoring). But it is the natural next chapter: the same “broadcast layer” that surfaces others' data eventually lets the public help build it.
Agents as the core of the stack
The distinctive technical bet is that the system is run by a fleet of AI agents, not a set of fixed scripts. The difference is real, not cosmetic: a script is told “fetch this URL, extract these fields”; an agent is given an outcome to own (“keep the Wye's research feed current and correct”), a set of tools, and the latitude to decide how — which sources to check, whether a new item is worth adding, when it is unsure and should defer to a human. This is the Kagi News model applied to river health: agents continuously read a changing world and keep a synthesised picture current, with no human in the daily loop. Building it this way is what makes AI agents central to the stack rather than incidental, and it is the single most compelling thing about the project for an AI-native audience.
The work splits into a few agent roles, each owning an outcome rather than a step:
• Source-scout agents own discovery. Each watches a slice of the world (a set of university groups, the EA's publications, Rivers Trust outputs, preprint feeds) and decides what is new and relevant to a river the system tracks. Their job is not “scrape page X” but “know what has been published about these rivers and bring back what matters.”
• Extraction-and-geolocation agents own the hard mapping: read each incoming document and work out which river or catchment it concerns, what it is about, and write the plain-English gloss. This is the step that is impractical without an LLM and the reason the whole feed is possible.
• Ingestion agents own the structured feeds. Even API pulls benefit from an agent that notices when a feed's schema drifts, a station goes offline, or a value looks wrong, and adapts or raises a flag — rather than a brittle script that silently breaks.
• Curator / editor agent owns the feed's quality as a whole: deduplicates, orders by relevance and recency, catches an item that looks miscategorised, and decides what rises to the top of a river's page. This is the “editor” in the Kagi-News sense.
• Verification / critic agent owns trust: a separate agent that checks the others' output before it goes live — is this study really about this river, does the gloss misrepresent it, is the licence respected, is an official reading being conflated with a citizen one. Keeping this separate from the agent that produced the work is what makes the quality bar credible. Two hard boundaries are enforced here, not left to a model's discretion: evidence strength is assigned from a human-written rule-based taxonomy (single pilot study / multiple independent studies / official monitoring consensus) — the LLM only tags an input against those rules, it never weighs scientific consensus itself; and the app never emits a swim / don't-swim verdict — the gate keeps the public output a compiled conditions panel (flow, last sonde temperature and DO, last official phosphate reading, any recent EDM nearby, nearest bathing-water classification) with a fixed caveat, leaving the judgement to the reader.
Two principles hold the fleet together. First, an orchestration layer schedules and coordinates them — agents wake on cadence (hourly, daily, weekly by role), run their loop, and hand off to the next; a run that fails or is uncertain escalates rather than corrupts the store. Second, a human-in-the-loop seam: agents propose, and anything low-confidence or high-stakes waits for a quick human yes/no rather than publishing itself. Early on that seam sits wide (you review most additions); as the critic agent earns trust, it narrows. This is how you get autonomy without surrendering correctness — and it is itself a serious, demonstrable piece of AI engineering.
Concretely on your stack, each agent is a Supabase worker (a hosted Dockerfile) running an agent loop against an LLM with a defined toolset (fetch, read-PDF, query-the-store, write-a-proposal, flag-for-review). The orchestration is the scheduling layer plus a “proposals” table the agents write to and the critic and human read from. The store is the shared memory the whole fleet reads and writes. Nothing here needs infrastructure you do not already have — it is the same workers-and-Postgres stack, organised as agents owning outcomes instead of scripts running steps.
The shape to hold onto: agents fan out across a changing world and propose; a critic agent and a human gate stand between those proposals and the live store, so autonomy never comes at the cost of correctness. The gate is wide at first and narrows as the critic earns trust.
What is still not understood
Desk research has resolved most of the original unknowns — chemistry density, the agricultural approach, the satellite decision, the incumbent relationship, the safety line and the success metric are now settled and recorded in place above. What remains below is the genuinely open set: the questions desk research cannot close, grouped by the kind of risk they carry. The plan is no longer a hopeful guess about data availability; the hard part is now honest engineering.
Data and feasibility
• How good is the geolocation step, really? This is the one unknown desk research cannot resolve and the linchpin of the research engine. The concrete test: run the LLM extraction over 20–30 curated Wye-focused PDFs and hand-verify. Above ~85% accuracy, commit to the automated feed; below it, descope to manual curation with an AI-assisted draft. Run this benchmark before building the engine.
• How robust is the agricultural risk-proximity model? The approach is settled (inferred landscape risk from field boundaries, regional fertiliser averages, livestock-density proxies and proximity — never field-level attribution). What is open: which exact datasets, their resolution, the parish/ward level the proxies work at, and whether the inferred risk is robust and clearly-enough caveated to publish without misleading.
• How far to go on satellite? Settled: raw Sentinel-2/Landsat imagery is free and public, so v1 does the simple, striking version — true-colour before/after for event mode — cheaply. Open: whether to build quantified bloom/chlorophyll detection (serious CV work, Stirling's specialism) or license/partner with Stirling for it. That decision can wait until the spine and research engine are built.
• Chemistry density — resolved. The Wye has ~91 EA plus ~83 NRW sampling points and six 15-minute SAC sondes, so the chemical sub-signal is viable. Commit to it. (Kept here only to record that the earlier worry is closed.)
• Can Stirling's processed algae data be licensed for public redistribution? Their service is org-facing and City-Region-Deal-funded; whether they will license the processed layer, for free or at all, and whether terms allow showing it to the public, is unknown and needs a direct conversation.
Scientific and ethical integrity
• How is evidence strength actually judged? Deciding “single study vs consensus” is itself a scientific judgment. Whether an LLM can do this reliably, or whether it needs a human-curated layer, is unresolved — and getting it wrong means misleading the public.
• Where exactly is the line on safety advice? “Conditions, not guarantees” is the principle, but the precise wording, caveats, and what the app refuses to say need real thought, possibly legal input, given the duty of care around swimming.
• How are researchers’ findings represented without distortion? Summarising someone’s work in one public line risks misrepresenting it. Whether to seek researcher sign-off, or how to let them flag misreadings, is open.
Scope, sustainability and positioning
• Who runs it after it is built — reframed. For a fellowship portfolio piece, proven automation matters more than eternal upkeep. Build scheduled adapters with self-healing alerts (source-down notifications) and frame it as a demonstration of durable architecture, not a promise of a permanent public service. The question only reopens if it graduates into a real ongoing service.
• Relationship to the incumbents — settled as a complementary index. SAS owns sewage alerts, the Rivers Trust owns policy reports, WyeViz owns the Wye campaign dashboard; this is the synthesis layer above them (“we surface and cite their data; we do not compete with their advocacy”). The open part is purely operational: securing data-sharing from Friends of the River Wye and W&UF by direct request.
• Is “Downing Street / a government project” the right home for something that holds farmers and water companies to account? There is a real question about whether an accountability tool sits comfortably inside government, or whether that creates conflicts. Worth thinking through before framing it as a fellowship project specifically.
• v1 success metric — pinned. “A member of the public can open the Wye page during a news event and, in under 60 seconds, understand why the river looks the way it does, with every claim linked to a source.” Testable, visual, and honest — build toward exactly that.
• Do Supabase workers give real scheduled execution, and where do the heavy jobs run? The pipeline's “runs itself” property needs cron-like scheduling, and satellite/PDF processing may exceed a lightweight worker's limits — confirm both before committing the ingestion design. (Your home turf, so you'll know the current state.)
• What exactly can be re-sold? The academic-access revenue fallback is clean for your own synthesis and OGL-licensed government data, but data licensed in from Stirling or scraped from a trust may forbid onward sale. Per-source licence tracking keeps this clean — but the boundary needs to be explicit before any paid tier.
