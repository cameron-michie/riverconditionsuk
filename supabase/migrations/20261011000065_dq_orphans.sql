-- observation.series_id has no foreign key by design (bulk loads); this view is the check the migration comment promised.
create or replace view ops.dq_orphan_observations as
select count(*) as orphans from core.observation o where not exists (select 1 from core.series s where s.id = o.series_id);
