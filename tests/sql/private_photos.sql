-- Load live_schema, storage_schema, atomic_sale and private_photos migrations.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA photo_test;
GRANT USAGE ON SCHEMA photo_test TO authenticated,anon;
CREATE FUNCTION photo_test.assert(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %',label; END IF; END; $$;
CREATE FUNCTION photo_test.throws(statement text,expected_code text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE=expected_code THEN RETURN; END IF;
    RAISE EXCEPTION 'Expected SQLSTATE %, got %: %',expected_code,SQLSTATE,SQLERRM;
  END;
  RAISE EXCEPTION 'Expected SQLSTATE %, statement succeeded: %',expected_code,statement;
END; $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA photo_test TO authenticated,anon;

INSERT INTO auth.users VALUES
 ('00000000-0000-0000-0000-000000000001','owner-one@example.invalid'),
 ('00000000-0000-0000-0000-000000000002','staff@example.invalid'),
 ('00000000-0000-0000-0000-000000000003','owner-two@example.invalid'),
 ('00000000-0000-0000-0000-000000000004','unassigned@example.invalid');
INSERT INTO public.kenz_stores(id,owner_id) VALUES
 ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001'),
 ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003');
INSERT INTO public.kenz_store_members(user_id,store_id,role) VALUES
 ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','owner'),
 ('00000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','staff'),
 ('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002','owner');
INSERT INTO public.kenz_inventory_state(store_id,revision,payload) VALUES
 ('10000000-0000-0000-0000-000000000001',62,'{
  "version":1,"sentinel":{"must":"stay"},"items":[
   {"id":"item-one","model":"K16","color":"red","size":"M","price":2200,"quantity":5,"photo":"data:image/jpeg;base64,QUJD","custom":"untouched"},
   {"id":"item-two","model":"K17","color":"blue","size":"L","price":100,"quantity":2,"photo":"data:image/jpeg;base64,QUJD"},
   {"id":"item-three","model":"K18","color":"green","size":"S","price":50,"quantity":0}
  ],"orders":[
   {"id":"order-old","number":20,"itemId":"item-one","model":"Old snapshot","color":"red","size":"M","price":2000,"quantity":1,"photo":"data:image/png;base64,REVG","deliveryFee":2,"customer":"Old customer","phone":"","address":"","notes":"","status":"تم التوصيل","payment":"مدفوع","date":"2026-11-01T00:00:00.000Z","_sale_request":{"preserve":"original"}},
   {"id":"order-shared","number":21,"itemId":"item-one","model":"K16","color":"red","size":"M","price":2200,"quantity":1,"photo":"data:image/jpeg;base64,QUJD","deliveryFee":0,"customer":"Shared photo","phone":"","address":"","notes":"","status":"جديد","payment":"غير مدفوع","date":"2026-11-02T00:00:00.000Z"}
  ]}'),
 ('10000000-0000-0000-0000-000000000002',0,'{"version":1,"items":[],"orders":[]}');
CREATE TEMP TABLE original_state AS SELECT * FROM public.kenz_inventory_state;
CREATE TEMP TABLE refs AS SELECT
 public.kenz_photo_reference('10000000-0000-0000-0000-000000000001','data:image/jpeg;base64,QUJD') AS current_photo,
 public.kenz_photo_reference('10000000-0000-0000-0000-000000000001','data:image/png;base64,REVG') AS historical_photo,
 public.kenz_photo_reference('10000000-0000-0000-0000-000000000002','data:image/jpeg;base64,QUJD') AS foreign_photo;
CREATE TEMP TABLE receipts(label text PRIMARY KEY,result jsonb);
GRANT SELECT ON original_state,refs TO authenticated,anon;
GRANT ALL ON receipts TO authenticated;
SELECT photo_test.assert(NOT public AND file_size_limit=1048576 AND cardinality(allowed_mime_types)=3,'bucket private and bounded')
 FROM storage.buckets WHERE id='kenz-model-photos';
SELECT photo_test.assert(public.kenz_photo_store_id('malformed') IS NULL
 AND public.kenz_photo_store_id('not-a-uuid/'||repeat('a',64)||'.jpg') IS NULL
 AND public.kenz_photo_store_id(current_photo)='10000000-0000-0000-0000-000000000001','safe path parser') FROM refs;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
SELECT photo_test.assert(public.kenz_get_state()=public.kenz_get_state_v2(),'v1 read compatibility');
SELECT photo_test.throws($q$SELECT public.kenz_save_state('10000000-0000-0000-0000-000000000001',62,'{"version":2,"items":[],"orders":[]}')$q$,'PT426');
SELECT photo_test.throws($q$SELECT public.kenz_save_state_v2('10000000-0000-0000-0000-000000000001',62,'{"version":2,"items":[],"orders":[]}')$q$,'PT409');
SELECT photo_test.throws($q$SELECT public.kenz_migrate_photos('10000000-0000-0000-0000-000000000002',62)$q$,'PT409');
SELECT photo_test.throws($q$SELECT public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',61)$q$,'PT409');
SELECT photo_test.throws($q$SELECT public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',62)$q$,'22023');
SELECT photo_test.assert((SELECT to_jsonb(s)=to_jsonb(o) FROM public.kenz_inventory_state s JOIN original_state o USING(store_id)
 WHERE s.store_id='10000000-0000-0000-0000-000000000001'),'missing upload leaves entire original row exact');
SELECT photo_test.throws($q$INSERT INTO storage.objects(bucket_id,name) SELECT 'kenz-model-photos',foreign_photo FROM refs$q$,'42501');
SELECT photo_test.throws($q$INSERT INTO storage.objects(bucket_id,name) VALUES('kenz-model-photos','malformed')$q$,'42501');
INSERT INTO storage.objects(bucket_id,name) SELECT 'kenz-model-photos',current_photo FROM refs;
SELECT photo_test.throws($q$SELECT public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',62)$q$,'22023');
RESET ROLE;
SELECT photo_test.assert((SELECT count(*)=0 FROM public.kenz_photo_migration_backups),'partial upload does not create archive');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
SELECT photo_test.throws($q$SELECT public.kenz_save_state('10000000-0000-0000-0000-000000000001',62,'{"version":2,"items":[],"orders":[]}')$q$,'PT426');
INSERT INTO storage.objects(bucket_id,name) SELECT 'kenz-model-photos',historical_photo FROM refs;
SELECT photo_test.assert((SELECT count(*)=2 FROM storage.objects WHERE bucket_id='kenz-model-photos'),'staff shares photos');
SELECT photo_test.throws($q$SELECT public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',62)$q$,'PT403');
SELECT photo_test.throws($q$SELECT public.kenz_get_photo_migration_backup('10000000-0000-0000-0000-000000000001')$q$,'PT403');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
INSERT INTO receipts VALUES('migration',public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',62));
SELECT photo_test.assert(result->>'revision'='63' AND result#>>'{payload,version}'='2' AND result->'duplicate'='false'
 AND result#>>'{migration,unique_images}'='2' AND result#>>'{migration,photo_references}'='4','migration count and revision') FROM receipts WHERE label='migration';
SELECT photo_test.assert(result#>>'{payload,items,0,photo}'=r.current_photo
 AND result#>>'{payload,items,1,photo}'=r.current_photo
 AND result#>>'{payload,orders,0,photo}'=r.historical_photo
 AND result#>>'{payload,orders,1,photo}'=r.current_photo
 AND NOT (result#>'{payload,items,2}')?'photo','dedupe, historical snapshot and missing photo preserved') FROM receipts CROSS JOIN refs r WHERE label='migration';
SELECT photo_test.assert(result->'payload'=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(o.payload,
 '{version}','2'),'{items,0,photo}',to_jsonb(r.current_photo)),
 '{items,1,photo}',to_jsonb(r.current_photo)),
 '{orders,0,photo}',to_jsonb(r.historical_photo)),
 '{orders,1,photo}',to_jsonb(r.current_photo)),
 'every other field, array order and unknown key remains byte-equivalent as JSONB')
 FROM receipts CROSS JOIN refs r CROSS JOIN original_state o
 WHERE label='migration' AND o.store_id='10000000-0000-0000-0000-000000000001';
SELECT photo_test.assert((public.kenz_get_photo_migration_backup('10000000-0000-0000-0000-000000000001')->'payload')=
 (SELECT payload FROM original_state WHERE store_id='10000000-0000-0000-0000-000000000001'),'owner archive exact original');
SELECT photo_test.throws($q$SELECT public.kenz_get_state()$q$,'PT426');
INSERT INTO receipts VALUES('migration-replay',public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',62));
SELECT photo_test.assert(result->>'revision'='63' AND result->'duplicate'='true','migration replay idempotent even with original revision') FROM receipts WHERE label='migration-replay';
SELECT photo_test.throws($q$SELECT public.kenz_save_state('10000000-0000-0000-0000-000000000001',63,payload) FROM original_state WHERE store_id='10000000-0000-0000-0000-000000000001'$q$,'PT426');
SELECT photo_test.throws($q$SELECT public.kenz_save_state_v2('10000000-0000-0000-0000-000000000001',63,payload) FROM original_state WHERE store_id='10000000-0000-0000-0000-000000000001'$q$,'22023');
SELECT photo_test.throws($q$SELECT public.kenz_save_state_v2('10000000-0000-0000-0000-000000000001',63,jsonb_set(payload,'{items,0,photo}',to_jsonb(r.foreign_photo))) FROM public.kenz_inventory_state s CROSS JOIN refs r WHERE s.store_id='10000000-0000-0000-0000-000000000001'$q$,'22023');
SELECT photo_test.throws($q$SELECT public.kenz_save_state_v2('10000000-0000-0000-0000-000000000001',63,jsonb_set(payload,'{items,0,photo}',to_jsonb('10000000-0000-0000-0000-000000000001/'||repeat('a',64)||'.jpg'))) FROM public.kenz_inventory_state WHERE store_id='10000000-0000-0000-0000-000000000001'$q$,'22023');
SELECT photo_test.throws($q$SELECT public.kenz_save_state_v2('10000000-0000-0000-0000-000000000001',62,payload) FROM public.kenz_inventory_state WHERE store_id='10000000-0000-0000-0000-000000000001'$q$,'PT409');
INSERT INTO receipts SELECT 'edit',public.kenz_save_state_v2(s.store_id,63,jsonb_set(s.payload,'{items,0,photo}',to_jsonb(r.historical_photo)))
 FROM public.kenz_inventory_state s CROSS JOIN refs r WHERE s.store_id='10000000-0000-0000-0000-000000000001';
SELECT photo_test.assert(result->>'revision'='64' AND result#>>'{payload,orders,1,photo}'=r.current_photo,
 'editing item photo does not rewrite older orders') FROM receipts CROSS JOIN refs r WHERE label='edit';
INSERT INTO receipts VALUES('sale',public.kenz_create_sale('10000000-0000-0000-0000-000000000001',64,'sale-v2','item-one',1,0,'Customer','','','','جديد','مدفوع'));
SELECT photo_test.assert(result->>'revision'='65' AND result->>'new_quantity'='4'
 AND result#>>'{order,photo}'=r.historical_photo AND octet_length(result::text)<2000,'v2 atomic sale carries reference only') FROM receipts CROSS JOIN refs r WHERE label='sale';
SELECT photo_test.assert(public.kenz_create_sale('10000000-0000-0000-0000-000000000001',64,'sale-v2','item-one',1,0,'Customer','','','','جديد','مدفوع')->'duplicate'='true','v2 sale replay does not deduct twice');
WITH changed AS(UPDATE storage.objects SET name='overwritten.jpg' WHERE bucket_id='kenz-model-photos' RETURNING *)
 SELECT photo_test.assert((SELECT count(*)=0 FROM changed),'immutable object names even with broad pre-existing policy');
WITH changed AS(UPDATE storage.objects SET metadata='{"changed":true}' WHERE bucket_id='kenz-model-photos' RETURNING *)
 SELECT photo_test.assert((SELECT count(*)=0 FROM changed),'immutable object metadata');
WITH changed AS(DELETE FROM storage.objects WHERE bucket_id='kenz-model-photos' RETURNING *)
 SELECT photo_test.assert((SELECT count(*)=0 FROM changed),'historical photos cannot be deleted by members');
SELECT photo_test.throws($q$UPDATE storage.objects SET bucket_id='kenz-model-photos',name=(SELECT current_photo FROM refs)
 WHERE bucket_id='unrelated-public'$q$,'42501');
WITH changed AS(UPDATE storage.buckets SET public=true WHERE id='kenz-model-photos' RETURNING *)
 SELECT photo_test.assert((SELECT count(*)=0 FROM changed),'members cannot make private bucket public');
WITH changed AS(DELETE FROM storage.buckets WHERE id='kenz-model-photos' RETURNING *)
 SELECT photo_test.assert((SELECT count(*)=0 FROM changed),'members cannot delete private bucket');
SELECT photo_test.throws($q$SELECT * FROM public.kenz_photo_migration_backups$q$,'42501');
SELECT photo_test.throws($q$SELECT public.kenz_photo_reference('10000000-0000-0000-0000-000000000001','data:image/jpeg;base64,QUJD')$q$,'42501');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
SELECT photo_test.assert((SELECT count(*)=0 FROM storage.objects WHERE bucket_id='kenz-model-photos'),'other store cannot read photographs');
SELECT photo_test.throws($q$INSERT INTO storage.objects(bucket_id,name) SELECT 'kenz-model-photos',current_photo FROM refs$q$,'42501');
SELECT photo_test.throws($q$SELECT public.kenz_get_photo_migration_backup('10000000-0000-0000-0000-000000000001')$q$,'PT409');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',true);
SELECT photo_test.assert((SELECT count(*)=0 FROM storage.objects WHERE bucket_id='kenz-model-photos'),'unassigned cannot read photographs');
SELECT photo_test.throws($q$SELECT public.kenz_get_state_v2()$q$,'PT403');
RESET ROLE;
DELETE FROM public.kenz_store_members WHERE user_id='00000000-0000-0000-0000-000000000002';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
SELECT photo_test.assert((SELECT count(*)=0 FROM storage.objects WHERE bucket_id='kenz-model-photos'),'removed staff loses photo access');
SELECT photo_test.throws($q$INSERT INTO storage.objects(bucket_id,name) SELECT 'kenz-model-photos',current_photo FROM refs$q$,'42501');
SELECT photo_test.throws($q$SELECT public.kenz_get_state_v2()$q$,'PT403');
SELECT set_config('request.jwt.claim.sub','',true);
SET LOCAL ROLE anon;
SELECT photo_test.assert((SELECT count(*)=0 FROM storage.objects WHERE bucket_id='kenz-model-photos'),'anonymous read denied despite broad policy');
SELECT photo_test.assert((SELECT count(*)=1 FROM storage.objects WHERE bucket_id='unrelated-public'),'other bucket policy unchanged for anonymous readers');
SELECT photo_test.throws($q$INSERT INTO storage.objects(bucket_id,name) SELECT 'kenz-model-photos',current_photo FROM refs$q$,'42501');
SELECT photo_test.throws($q$SELECT public.kenz_get_state_v2()$q$,'42501');
SELECT photo_test.throws($q$SELECT public.kenz_migrate_photos('10000000-0000-0000-0000-000000000001',62)$q$,'42501');
RESET ROLE;
SELECT photo_test.assert((SELECT count(*)=1 FROM public.kenz_photo_migration_backups),'one exact archive despite replay');
SELECT photo_test.assert((SELECT payload#>>'{version}'='2' AND revision=65 FROM public.kenz_inventory_state
 WHERE store_id='10000000-0000-0000-0000-000000000001'),'failed operations do not mutate inventory');
SELECT photo_test.assert(NOT public.kenz_inventory_valid_payload('{"version":2,"items":[],"orders":[]}'::jsonb||jsonb_build_object('padding',repeat('x',10485760))),
 'v2 metadata retains 10 MiB bound');

-- Representative production size: 35 items and 20 historical orders, ~7.6 MB.
-- These synthetic base64 bytes test hashing/JSONB migration, not image decoding.
WITH photo AS(SELECT 'data:image/jpeg;base64,'||repeat('A',138000) AS value),
 items AS(SELECT jsonb_agg(jsonb_build_object('id','large-item-'||n,'model','K'||n,
  'color','red','size','M','price',2200,'quantity',5,'photo',photo.value||lpad(n::text,4,'0')) ORDER BY n) AS value
  FROM generate_series(1,35)n CROSS JOIN photo),
 orders AS(SELECT jsonb_agg(jsonb_build_object('id','large-order-'||n,'number',n,
  'itemId','large-item-1','model','K1','color','red','size','M','price',2200,'quantity',1,
  'photo',photo.value||'0001','deliveryFee',0,'customer','Customer','phone','','address','','notes','',
  'date','2026-11-01T00:00:00.000Z','status','تم التوصيل','payment','مدفوع') ORDER BY n) AS value
  FROM generate_series(1,20)n CROSS JOIN photo)
UPDATE public.kenz_inventory_state SET revision=62,payload=jsonb_build_object('version',1,'items',items.value,'orders',orders.value)
 FROM items CROSS JOIN orders WHERE store_id='10000000-0000-0000-0000-000000000002';
INSERT INTO storage.objects(bucket_id,name)
 SELECT DISTINCT 'kenz-model-photos',public.kenz_photo_reference(s.store_id,i.value->>'photo')
 FROM public.kenz_inventory_state s CROSS JOIN LATERAL jsonb_array_elements(s.payload->'items')i(value)
 WHERE s.store_id='10000000-0000-0000-0000-000000000002';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',true);
\timing on
INSERT INTO receipts VALUES('large-migration',public.kenz_migrate_photos('10000000-0000-0000-0000-000000000002',62));
\timing off
SELECT photo_test.assert(result#>>'{migration,unique_images}'='35' AND result#>>'{migration,photo_references}'='55'
 AND (result#>>'{migration,before_bytes}')::integer BETWEEN 7500000 AND 8000000
 AND (result#>>'{migration,after_bytes}')::integer<30000 AND result->>'revision'='63','large original safely becomes small metadata')
 FROM receipts WHERE label='large-migration';
SELECT result->'migration' AS large_migration_metrics FROM receipts WHERE label='large-migration';
RESET ROLE;
SELECT 'Private photo SQL/RLS integration tests passed' AS result;
ROLLBACK;
