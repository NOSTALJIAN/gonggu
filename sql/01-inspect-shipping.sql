-- Read only. Run this before deciding whether the optional v26 migration is needed.
select column_name, data_type from information_schema.columns
where table_schema='public' and table_name='gq_quotes' order by ordinal_position;
select p.oid::regprocedure as signature, pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
('gq_read_quote','gq_is_admin','gq_lotte_save_tracking_v25','gq_set_bundle_stage_v24');
select policyname, roles, cmd, qual, with_check from pg_policies
where schemaname='public' and tablename='gq_quotes';
