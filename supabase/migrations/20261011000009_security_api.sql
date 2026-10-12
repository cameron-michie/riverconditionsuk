-- Security model: public READ only, through the api schema. Everything else is service-role.
-- RLS is enabled on every table so a future grant mistake cannot expose private data.

do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname in ('ingest','ref','core','research','ops') loop
    execute format('alter table %I.%I enable row level security', t.schemaname, t.tablename);
  end loop;
end $$;

-- public-read policies only where the data is itself public
do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname in ('ref','core') loop
    execute format('create policy public_read on %I.%I for select to anon, authenticated using (true)', t.schemaname, t.tablename);
  end loop;
end $$;
create policy public_read on research.work             for select to anon, authenticated using (true);
create policy public_read on research.work_place       for select to anon, authenticated using (status = 'accepted');
create policy public_read on research.gloss            for select to anon, authenticated using (status = 'approved');
create policy public_read on research.evidence_rule    for select to anon, authenticated using (true);
create policy public_read on research.work_evidence_tag for select to anon, authenticated using (status = 'approved');
create policy public_read on ingest.source             for select to anon, authenticated using (true);
create policy public_read on ingest.licence            for select to anon, authenticated using (true);

-- Lock down: api is the exposed surface. The api views run as owner (security_invoker off) and read private tables.
revoke all on all tables in schema ingest, ref, core, research, ops from anon, authenticated;
revoke usage on schema ingest, ref, core, research, ops from anon, authenticated;
grant usage on schema api to anon, authenticated;
alter default privileges in schema api grant select on tables to anon, authenticated;
alter default privileges in schema api grant execute on functions to anon, authenticated;
