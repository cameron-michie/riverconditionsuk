-- ───────────── Research library (librarian, not author) ─────────────
create table research.work (
  id              bigint generated always as identity primary key,
  openalex_id     text unique,
  doi             text,
  title           text not null,
  pub_year        smallint,
  pub_date        date,
  work_type       text,
  language        text,
  venue           text,
  authors         jsonb not null default '[]',
  abstract        text,                                  -- stored only when abstract_rights allows display
  abstract_rights text not null default 'none' check (abstract_rights in ('full','quote_only','none')),
  oa_status       text,                                  -- gold|green|hybrid|bronze|closed
  licence         text,                                  -- cc-by ... per work, never assumed
  landing_url     text,
  pdf_url         text,
  cited_by        integer,
  topics          text[] not null default '{}',
  found_by        text[] not null default '{}',          -- which scout queries surfaced it
  source_id       bigint references ingest.source(id),
  fetched_at      timestamptz not null default now()
);
create index on research.work (doi);
create index on research.work (pub_year desc);
create index on research.work (source_id);
create index on research.work using gin (topics);
create index on research.work using gin (to_tsvector('english', title || ' ' || coalesce(abstract,'')));

-- Geolocation: which river/waterbody/catchment is this about?  Proposed by agents, accepted by critic/human.
create table research.work_place (
  id          bigint generated always as identity primary key,
  work_id     bigint not null references research.work(id),
  place_kind  text not null check (place_kind in ('river','waterbody','catchment','site','region')),
  place_id    bigint not null,
  place_text  text,                                      -- phrase in the document that justified the link
  confidence  real not null check (confidence between 0 and 1),
  method      text not null check (method in ('rule','llm','manual','openalex_geo')),
  evidence_span text,
  status      text not null default 'proposed' check (status in ('proposed','accepted','rejected')),
  run_id      bigint,
  decided_by  text,
  decided_at  timestamptz,
  unique (work_id, place_kind, place_id)
);
create index on research.work_place (place_kind, place_id) where status = 'accepted';
create index on research.work_place (work_id);

create table research.gloss (
  id            bigint generated always as identity primary key,
  work_id       bigint not null references research.work(id),
  text          text not null,                          -- one-line signpost, never a claim
  model         text,
  prompt_version text,
  status        text not null default 'proposed' check (status in ('proposed','approved','rejected')),
  reviewed_by   text,
  created_at    timestamptz not null default now()
);
create index on research.gloss (work_id);

-- Rule-based evidence taxonomy: humans write the rules; the model only tags inputs against them.
create table research.evidence_rule (
  code        text primary key,                         -- single_pilot_study | multiple_independent_studies | official_monitoring_consensus
  label       text not null,
  rule_text   text not null,
  rank        smallint not null
);
create table research.work_evidence_tag (
  work_id     bigint not null references research.work(id),
  rule_code   text not null references research.evidence_rule(code),
  tagged_by   text not null,
  confidence  real,
  status      text not null default 'proposed' check (status in ('proposed','approved','rejected')),
  primary key (work_id, rule_code)
);
create index on research.work_evidence_tag (rule_code);

create table research.work_embedding (
  work_id    bigint not null references research.work(id),
  model      text not null,
  embedding  vector(1024) not null,
  primary key (work_id, model)
);

-- ───────────── Ops: agents propose, critics and humans dispose ─────────────
create table ops.agent_run (
  id          bigint generated always as identity primary key,
  role        text not null check (role in ('source_scout','extractor','ingestor','curator','critic','other')),
  model       text,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running' check (status in ('running','ok','escalated','failed')),
  input_tokens bigint,
  output_tokens bigint,
  cost_usd    numeric(10,4),
  notes       text
);
create index on ops.agent_run (role, started_at desc);

create table ops.proposal (
  id            bigint generated always as identity primary key,
  agent_run_id  bigint references ops.agent_run(id),
  kind          text not null check (kind in ('work_place','gloss','evidence_tag','site_merge','parameter_mapping','river_alias','new_source_item','schema_drift','dq_alert')),
  target        jsonb not null,                           -- {table:'research.work_place', pk:{...}} or payload to insert
  payload       jsonb not null,
  confidence    real,
  stakes        text not null default 'normal' check (stakes in ('normal','high')),
  critic_verdict jsonb,
  status        text not null default 'pending' check (status in ('pending','auto_approved','approved','rejected','applied','superseded')),
  reviewed_by   text,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index on ops.proposal (status, kind) where status = 'pending';
create index on ops.proposal (agent_run_id);

-- Source health: each stage fails independently; this view says which source has gone quiet.
create view ops.source_health as
select s.id as source_id, s.slug, s.status, s.cadence,
       r.started_at as last_run_at, r.status as last_run_status, r.rows_written as last_rows_written,
       now() - r.started_at as since_last_run
from ingest.source s
left join lateral (
  select * from ingest.run where source_id = s.id order by started_at desc limit 1
) r on true;

-- ───────────── Health sub-signals (never blended into one score) ─────────────
create table core.signal_def (
  code   text primary key,                                 -- chemical | sewage_pressure | agricultural_pressure | ecological | algal_visual
  label  text not null,
  description text not null
);

create table core.signal (
  entity_kind    text not null check (entity_kind in ('waterbody','river','site')),
  entity_id      bigint not null,
  signal_code    text not null references core.signal_def(code),
  state          text not null check (state in ('good','moderate','poor','bad','unknown')),
  state_rank     smallint,
  trend          text not null default 'unknown' check (trend in ('improving','stable','worsening','unknown')),
  basis          jsonb not null,                           -- the inputs: which classifications / readings / counts produced this, with ids
  evidence_class core.evidence_class not null,
  as_of          timestamptz not null,
  computed_at    timestamptz not null default now(),
  primary key (entity_kind, entity_id, signal_code)
);
create index on core.signal (signal_code, state_rank);
