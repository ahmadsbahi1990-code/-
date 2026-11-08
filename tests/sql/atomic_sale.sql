-- Local PostgreSQL integration tests. Load tests/fixtures/live_schema.sql and the
-- migration first. All synthetic data and test helpers are rolled back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA kenz_test;
GRANT USAGE ON SCHEMA kenz_test TO authenticated, anon;
CREATE FUNCTION kenz_test.assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', label; END IF;
END;
$$;
CREATE FUNCTION kenz_test.throws(statement text, expected_code text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expected_code THEN RETURN; END IF;
    RAISE EXCEPTION 'Expected SQLSTATE %, got %: %', expected_code, SQLSTATE, SQLERRM;
  END;
  RAISE EXCEPTION 'Expected SQLSTATE %, statement succeeded: %', expected_code, statement;
END;
$$;
CREATE FUNCTION kenz_test.sale(overrides jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.kenz_create_sale(
    (r->>'expected_store_id')::uuid, (r->>'expected_revision')::bigint,
    r->>'request_id', r->>'item_id', (r->>'quantity')::integer,
    (r->>'delivery_fee')::numeric, r->>'customer', r->>'phone', r->>'address',
    r->>'notes', r->>'status', r->>'payment'
  ) FROM (SELECT '{
    "expected_store_id":"10000000-0000-0000-0000-000000000001","expected_revision":0,
    "request_id":"sale-first","item_id":"item-first","quantity":2,"delivery_fee":0,
    "customer":"  وسام دمشق  ","phone":"","address":"","notes":"",
    "status":"تم التوصيل","payment":"مدفوع"
  }'::jsonb || overrides AS r) q
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA kenz_test TO authenticated, anon;

INSERT INTO auth.users(id, email) VALUES
  ('00000000-0000-0000-0000-000000000001', 'owner-one@example.invalid'),
  ('00000000-0000-0000-0000-000000000002', 'staff@example.invalid'),
  ('00000000-0000-0000-0000-000000000003', 'owner-two@example.invalid'),
  ('00000000-0000-0000-0000-000000000004', 'unassigned@example.invalid');
INSERT INTO public.kenz_stores(id, owner_id) VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003');
INSERT INTO public.kenz_store_members(user_id, store_id, role) VALUES
  ('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'owner'),
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'staff'),
  ('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'owner');
INSERT INTO public.kenz_inventory_state(store_id, payload) VALUES
  ('10000000-0000-0000-0000-000000000001', '{
    "version":1,"sentinel":{"preserve":true},"items":[
      {"id":"item-first","model":"K16 شتوي","color":"أحمر","size":"M","price":2200.5,"quantity":5.0,"photo":"data:image/jpeg;base64,QUJD","custom":"keep"},
      {"id":"item-other","model":"K13","color":"أزرق","size":"L","price":100,"quantity":2,"photo":""}
    ],"orders":[
      {"id":"legacy-order","number":9.0,"itemId":"item-first","model":"Old model snapshot","color":"أحمر","size":"M","price":2000,"quantity":1,"photo":"","deliveryFee":0,"customer":"Legacy","phone":"","address":"","notes":"","status":"جديد","payment":"غير مدفوع","date":"2026-11-01T00:00:00.000Z"}
    ]
  }'),
  ('10000000-0000-0000-0000-000000000002', '{"version":1,"items":[],"orders":[]}');
CREATE TEMP TABLE initial_state AS SELECT * FROM public.kenz_inventory_state;
CREATE TEMP TABLE receipts(label text PRIMARY KEY, result jsonb);
GRANT SELECT ON initial_state TO authenticated;
GRANT ALL ON receipts TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
INSERT INTO receipts VALUES ('first', kenz_test.sale());
DO $$
DECLARE r jsonb := (SELECT result FROM receipts WHERE label = 'first'); current_state public.kenz_inventory_state%ROWTYPE;
BEGIN
  SELECT * INTO STRICT current_state FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001';
  PERFORM kenz_test.assert(r->>'role' = 'owner' AND (r->>'revision')::bigint = 1 AND r->'duplicate' = 'false', 'owner sale receipt');
  PERFORM kenz_test.assert(r->>'store_id' = current_state.store_id::text AND NOT r ? 'payload', 'small receipt, no full state');
  PERFORM kenz_test.assert((r->>'new_quantity')::integer = 3 AND current_state.payload#>>'{items,0,quantity}' = '3', 'deduct quantity exactly once');
  PERFORM kenz_test.assert(r#>>'{order,id}' = 'sale-first' AND (r#>>'{order,number}')::bigint = 10, 'stable id and next order number');
  PERFORM kenz_test.assert(r#>>'{order,model}' = 'K16 شتوي' AND (r#>>'{order,price}')::numeric = 2200.5
    AND r#>>'{order,photo}' = 'data:image/jpeg;base64,QUJD', 'snapshot derives from stored item');
  PERFORM kenz_test.assert(r#>>'{order,customer}' = 'وسام دمشق' AND r#>>'{order,phone}' = ''
    AND r#>>'{order,address}' = '' AND r#>>'{order,notes}' = '', 'trimmed customer and blank optional values');
  PERFORM kenz_test.assert((r#>>'{order,date}')::timestamptz > now() - interval '1 minute', 'server timestamp');
  PERFORM kenz_test.assert(current_state.payload#>'{orders,0}' = (SELECT payload#>'{orders,0}' FROM initial_state WHERE store_id = current_state.store_id)
    AND current_state.payload#>'{items,1}' = (SELECT payload#>'{items,1}' FROM initial_state WHERE store_id = current_state.store_id)
    AND current_state.payload->'sentinel' = '{"preserve":true}', 'preserve prior orders, other items and metadata');
  PERFORM kenz_test.assert(current_state.updated_by = auth.uid() AND current_state.revision = 1, 'attribution and revision');
END;
$$;
INSERT INTO receipts VALUES ('retry', kenz_test.sale());
SELECT kenz_test.assert(result->'duplicate' = 'true' AND result->>'revision' = '1' AND result->>'new_quantity' = '3', 'same-id retry succeeds before stale revision comparison') FROM receipts WHERE label = 'retry';

-- All invalid calls must preserve the entire row, including revision and timestamp.
DO $$
DECLARE before_row jsonb; after_row jsonb; invalid jsonb;
BEGIN
  SELECT to_jsonb(s) INTO before_row FROM public.kenz_inventory_state s WHERE s.store_id = '10000000-0000-0000-0000-000000000001';
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"quantity":1}')$q$, 'PT409');
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"request_id":"new-stale"}')$q$, 'PT409');
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"request_id":"legacy-order","expected_revision":1}')$q$, 'PT409');
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"request_id":"over-stock","expected_revision":1,"quantity":6}')$q$, 'PT409');
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"request_id":"missing-item","expected_revision":1,"item_id":"absent"}')$q$, 'PT404');
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"expected_store_id":"10000000-0000-0000-0000-000000000002"}')$q$, 'PT409');
  FOR invalid IN SELECT value FROM jsonb_array_elements('[
    {"quantity":0},{"quantity":-1},{"quantity":1000001},{"quantity":null},
    {"delivery_fee":-1},{"delivery_fee":1000000001},{"delivery_fee":1.001},{"delivery_fee":null},
    {"customer":" "},{"customer":null},{"status":"ملغي"},{"status":"invalid"},{"payment":"invalid"},
    {"expected_revision":-1},{"expected_revision":null},{"request_id":""},{"item_id":""}
  ]') LOOP
    PERFORM kenz_test.throws(format('SELECT kenz_test.sale(%L::jsonb)', invalid), '22023');
  END LOOP;
  PERFORM kenz_test.throws(format('SELECT kenz_test.sale(%L::jsonb)', jsonb_build_object('customer', repeat('x', 101))), '22023');
  PERFORM kenz_test.throws(format('SELECT kenz_test.sale(%L::jsonb)', jsonb_build_object('phone', repeat('x', 41))), '22023');
  PERFORM kenz_test.throws(format('SELECT kenz_test.sale(%L::jsonb)', jsonb_build_object('notes', repeat('x', 501))), '22023');
  SELECT to_jsonb(s) INTO after_row FROM public.kenz_inventory_state s WHERE s.store_id = '10000000-0000-0000-0000-000000000001';
  PERFORM kenz_test.assert(before_row = after_row, 'all rejected sales are atomic and leave row untouched');
END;
$$;

-- Simulate the existing full-state cancellation path: status changes and stock restores.
SELECT public.kenz_save_state('10000000-0000-0000-0000-000000000001', 1,
  jsonb_set(jsonb_set(payload, '{orders,1,status}', '"ملغي"'), '{items,0,quantity}', '5')) IS NOT NULL AS legacy_save_works
FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001';
INSERT INTO receipts VALUES ('retry-cancelled', kenz_test.sale());
SELECT kenz_test.assert(result->'duplicate' = 'true' AND result->>'revision' = '2'
  AND result->>'new_quantity' = '5' AND result#>>'{order,status}' = 'ملغي', 'retry after cancellation returns current receipt without reselling')
FROM receipts WHERE label = 'retry-cancelled';

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
INSERT INTO receipts VALUES ('staff', kenz_test.sale('{"request_id":"sale-staff","expected_revision":2,"quantity":1,"delivery_fee":10.25,"phone":null,"address":null,"notes":null}'));
SELECT kenz_test.assert(result->>'role' = 'staff' AND result->>'revision' = '3' AND result->>'new_quantity' = '4'
  AND result#>>'{order,phone}' = '' AND result#>>'{order,deliveryFee}' = '10.25', 'staff sale and null optional canonicalization')
FROM receipts WHERE label = 'staff';
SELECT kenz_test.throws($q$UPDATE public.kenz_inventory_state SET revision = revision + 1$q$, '42501');
SELECT kenz_test.throws($q$SELECT public.kenz_inventory_valid_payload('{}')$q$, '42501');
SELECT kenz_test.throws($q$SELECT public.kenz_membership_required(false)$q$, '42501');
SELECT kenz_test.throws($q$SELECT public.kenz_save_state('10000000-0000-0000-0000-000000000001', 2, payload)
  FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001'$q$, 'PT409');

RESET ROLE;
SELECT kenz_test.assert(updated_by = '00000000-0000-0000-0000-000000000002', 'staff attribution') FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001';
DELETE FROM public.kenz_store_members WHERE user_id = '00000000-0000-0000-0000-000000000002';
SET LOCAL ROLE authenticated;
SELECT kenz_test.throws($q$SELECT kenz_test.sale('{"request_id":"removed-staff","expected_revision":3}')$q$, 'PT403');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
SELECT kenz_test.throws($q$SELECT kenz_test.sale()$q$, 'PT403');
SELECT kenz_test.assert((SELECT count(*) = 0 FROM public.kenz_inventory_state), 'unassigned RLS denies state');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
SELECT kenz_test.throws($q$SELECT kenz_test.sale()$q$, 'PT409');
SELECT kenz_test.assert((SELECT count(*) = 0 FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001'), 'cross-store RLS denies state');
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT kenz_test.throws($q$SELECT kenz_test.sale()$q$, '42501');
SET LOCAL ROLE anon;
SELECT kenz_test.throws($q$SELECT kenz_test.sale()$q$, '42501');
RESET ROLE;

-- Similar to the user's 35-item, 20-order state: about 7.6 MB of inline photos.
WITH photo AS (SELECT 'data:image/jpeg;base64,' || repeat('A', 138000) AS value),
items AS (SELECT jsonb_agg(jsonb_build_object('id', 'large-item-' || n, 'model', 'K' || n,
  'color', 'red', 'size', 'M', 'price', 2200, 'quantity', 5, 'photo', photo.value || lpad(n::text, 4, '0')) ORDER BY n) AS value
  FROM generate_series(1,35) n CROSS JOIN photo),
orders AS (SELECT jsonb_agg(jsonb_build_object('id', 'large-order-' || n, 'number', n,
  'itemId', 'large-item-1', 'model', 'K1', 'color', 'red', 'size', 'M', 'price', 2200,
  'quantity', 1, 'photo', photo.value || '0001', 'deliveryFee', 0, 'customer', 'Customer', 'phone', '',
  'address', '', 'notes', '', 'date', '2026-11-01T00:00:00.000Z', 'status', 'تم التوصيل', 'payment', 'مدفوع') ORDER BY n) AS value
  FROM generate_series(1,20) n CROSS JOIN photo)
UPDATE public.kenz_inventory_state SET revision = 62,
  payload = jsonb_build_object('version', 1, 'items', items.value, 'orders', orders.value)
FROM items CROSS JOIN orders WHERE store_id = '10000000-0000-0000-0000-000000000001';
SELECT kenz_test.assert(octet_length(payload::text) BETWEEN 7500000 AND 8000000
  AND public.kenz_inventory_valid_payload(payload), 'large multi-order fixture validates')
FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
INSERT INTO receipts VALUES ('large', kenz_test.sale('{"expected_revision":62,"request_id":"large-new","item_id":"large-item-1","quantity":1}'));
SELECT kenz_test.assert(octet_length(result::text) < 150000 AND result->>'revision' = '63'
  AND result->>'new_quantity' = '4' AND result#>>'{order,number}' = '21', 'large inventory sale returns only one photo and receipt')
FROM receipts WHERE label = 'large';
SELECT 'Large state bytes / receipt bytes' AS metric,
  (SELECT octet_length(payload::text) FROM public.kenz_inventory_state WHERE store_id = '10000000-0000-0000-0000-000000000001') AS state_bytes,
  octet_length(result::text) AS receipt_bytes FROM receipts WHERE label = 'large';
RESET ROLE;

-- Exactly below the existing 10 MB limit: the next photo snapshot must fail cleanly.
UPDATE public.kenz_inventory_state SET payload = payload || jsonb_build_object('test_padding', '')
WHERE store_id = '10000000-0000-0000-0000-000000000001';
UPDATE public.kenz_inventory_state SET payload = jsonb_set(payload, '{test_padding}',
  to_jsonb(repeat('p', 10485760 - octet_length(payload::text) - 10)))
WHERE store_id = '10000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
DO $$
DECLARE before_row jsonb;
BEGIN
  SELECT to_jsonb(s) INTO before_row FROM public.kenz_inventory_state s WHERE s.store_id = '10000000-0000-0000-0000-000000000001';
  PERFORM kenz_test.throws($q$SELECT kenz_test.sale('{"expected_revision":63,"request_id":"too-large","item_id":"large-item-1","quantity":1}')$q$, '22023');
  PERFORM kenz_test.assert(before_row = (SELECT to_jsonb(s) FROM public.kenz_inventory_state s WHERE s.store_id = '10000000-0000-0000-0000-000000000001'), '10 MB check rolls back stock/order/revision together');
END;
$$;
RESET ROLE;
SELECT 'atomic_sale.sql: all assertions passed' AS result;
ROLLBACK;
