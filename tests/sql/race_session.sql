-- Start two independent psql sessions after race_setup.sql.
-- Different request_id values: exactly one success and one PT409.
-- Same request_id value: both succeed, one duplicate=true; only one stock deduction.
-- Example psql options: -v request_id=race-a -v hold_seconds=0.5
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-0000-0000-000000000005';
SELECT public.kenz_create_sale(
  '20000000-0000-0000-0000-000000000001', 0, :'request_id', 'last-piece',
  1, 0, 'Customer', '', '', '', 'تم التوصيل', 'مدفوع'
);
SELECT pg_sleep(:hold_seconds);
COMMIT;
