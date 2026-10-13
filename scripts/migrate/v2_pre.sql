-- v2 upgrade, step 1 of 3: move the old schemas aside so the baseline can create ref, ops and api afresh.
-- core keeps its name: the satellite-monitoring tables live there and stay put.
do $$ begin
  if to_regclass('geo.site') is not null then raise exception 'already upgraded (geo.site exists)'; end if;
  if to_regclass('core.site') is null then raise exception 'nothing to upgrade (core.site missing)'; end if;
end $$;
alter schema ref rename to legacy_ref;
alter schema ops rename to legacy_ops;
alter schema api rename to legacy_api;
