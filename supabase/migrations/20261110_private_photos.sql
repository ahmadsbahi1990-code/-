-- Private, immutable model photographs. Run once in Supabase SQL Editor / Database.
-- Installation does NOT change inventory rows. The owner starts migration in the app.
-- Keep this migration and the original payload archive for recovery.
BEGIN;

DO $security$
BEGIN
  IF NOT coalesce((SELECT c.relrowsecurity FROM pg_class c WHERE c.oid='storage.objects'::regclass),false)
    OR NOT coalesce((SELECT c.relrowsecurity FROM pg_class c WHERE c.oid='storage.buckets'::regclass),false) THEN
    RAISE EXCEPTION 'Supabase Storage row-level security must be enabled before installing private KENZ photos; no changes were made.';
  END IF;
END;
$security$;

DO $install$
DECLARE existing storage.buckets%ROWTYPE;
BEGIN
  SELECT b.* INTO existing FROM storage.buckets b WHERE b.id = 'kenz-model-photos' FOR UPDATE;
  IF FOUND THEN
    IF existing.public IS DISTINCT FROM false
      OR existing.file_size_limit IS DISTINCT FROM 1048576::bigint
      OR existing.allowed_mime_types IS NULL
      OR NOT (existing.allowed_mime_types @> ARRAY['image/jpeg','image/png','image/webp']::text[]
        AND existing.allowed_mime_types <@ ARRAY['image/jpeg','image/png','image/webp']::text[]) THEN
      RAISE EXCEPTION 'The kenz-model-photos bucket already exists with incompatible settings; no changes were made.';
    END IF;
  ELSE
    INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    VALUES('kenz-model-photos','kenz-model-photos',false,1048576,ARRAY['image/jpeg','image/png','image/webp']);
  END IF;
END;
$install$;

-- A malformed object name returns NULL, never a UUID-cast exception in an RLS policy.
CREATE OR REPLACE FUNCTION public.kenz_photo_store_id(object_name text)
RETURNS uuid LANGUAGE sql IMMUTABLE STRICT SET search_path = '' AS $$
  SELECT CASE WHEN object_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{64}\.(jpg|png|webp)$'
    THEN split_part(object_name,'/',1)::uuid ELSE NULL END
$$;
REVOKE ALL ON FUNCTION public.kenz_photo_store_id(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_photo_store_id(text) TO anon,authenticated;

-- Expose only whether the caller belongs to the named store. The definer helper
-- avoids imposing table SELECT privileges on anonymous access to other buckets.
CREATE OR REPLACE FUNCTION public.kenz_photo_member(object_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS(SELECT 1 FROM public.kenz_store_members m
    WHERE m.user_id=(SELECT auth.uid()) AND m.store_id=public.kenz_photo_store_id(object_name))
$$;
REVOKE ALL ON FUNCTION public.kenz_photo_member(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_photo_member(text) TO anon,authenticated;

-- The permissive policies grant access; the restrictive guards also protect this
-- bucket when a project already has broad permissive policies for other buckets.
DROP POLICY IF EXISTS kenz_photos_read ON storage.objects;
CREATE POLICY kenz_photos_read ON storage.objects FOR SELECT TO authenticated USING (
  bucket_id='kenz-model-photos' AND public.kenz_photo_member(name));
DROP POLICY IF EXISTS kenz_photos_insert ON storage.objects;
CREATE POLICY kenz_photos_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK (
  bucket_id='kenz-model-photos' AND public.kenz_photo_member(name));
DROP POLICY IF EXISTS kenz_photos_read_guard ON storage.objects;
CREATE POLICY kenz_photos_read_guard ON storage.objects AS RESTRICTIVE FOR SELECT TO PUBLIC USING (
  bucket_id<>'kenz-model-photos' OR public.kenz_photo_member(name));
DROP POLICY IF EXISTS kenz_photos_insert_guard ON storage.objects;
CREATE POLICY kenz_photos_insert_guard ON storage.objects AS RESTRICTIVE FOR INSERT TO PUBLIC WITH CHECK (
  bucket_id<>'kenz-model-photos' OR public.kenz_photo_member(name));
DROP POLICY IF EXISTS kenz_photos_no_update ON storage.objects;
CREATE POLICY kenz_photos_no_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO PUBLIC
  USING(bucket_id<>'kenz-model-photos') WITH CHECK(bucket_id<>'kenz-model-photos');
DROP POLICY IF EXISTS kenz_photos_no_delete ON storage.objects;
CREATE POLICY kenz_photos_no_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO PUBLIC USING(bucket_id<>'kenz-model-photos');
DROP POLICY IF EXISTS kenz_photo_bucket_no_update ON storage.buckets;
CREATE POLICY kenz_photo_bucket_no_update ON storage.buckets AS RESTRICTIVE FOR UPDATE TO PUBLIC
  USING(id<>'kenz-model-photos') WITH CHECK(id<>'kenz-model-photos');
DROP POLICY IF EXISTS kenz_photo_bucket_no_delete ON storage.buckets;
CREATE POLICY kenz_photo_bucket_no_delete ON storage.buckets AS RESTRICTIVE FOR DELETE TO PUBLIC USING(id<>'kenz-model-photos');

-- Preserve the exact deployed v1 validation rules once. Never clone the v2 wrapper
-- on a rerun: doing so would create recursion and weaken recovery compatibility.
DO $validator$
DECLARE original_definition text;
BEGIN
  IF to_regprocedure('public.kenz_inventory_valid_payload_v1(jsonb)') IS NULL THEN
    original_definition := pg_get_functiondef('public.kenz_inventory_valid_payload(jsonb)'::regprocedure);
    EXECUTE replace(original_definition,'FUNCTION public.kenz_inventory_valid_payload(',
      'FUNCTION public.kenz_inventory_valid_payload_v1(');
  END IF;
END;
$validator$;
REVOKE ALL ON FUNCTION public.kenz_inventory_valid_payload_v1(jsonb) FROM PUBLIC,anon,authenticated;

-- Keep the existing function OID and CHECK constraint. A v2 payload contains only
-- bounded private object references; all existing business-field rules still run.
CREATE OR REPLACE FUNCTION public.kenz_inventory_valid_payload(doc jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE normalized jsonb; kind text; entry jsonb; idx integer; p text;
BEGIN
  IF doc->'version'='1'::jsonb THEN RETURN public.kenz_inventory_valid_payload_v1(doc); END IF;
  IF doc IS NULL OR jsonb_typeof(doc) IS DISTINCT FROM 'object'
    OR doc->'version' IS DISTINCT FROM '2'::jsonb
    OR jsonb_typeof(doc->'items') IS DISTINCT FROM 'array'
    OR jsonb_typeof(doc->'orders') IS DISTINCT FROM 'array'
    OR octet_length(doc::text)>10485760 THEN RETURN false; END IF;
  normalized:=jsonb_set(doc,'{version}','1'::jsonb,false);
  FOREACH kind IN ARRAY ARRAY['items','orders'] LOOP
    idx:=0;
    FOR entry IN SELECT e.value FROM jsonb_array_elements(doc->kind)e(value) LOOP
      IF entry?'photo' THEN
        IF jsonb_typeof(entry->'photo') IS DISTINCT FROM 'string' THEN RETURN false; END IF;
        p:=entry->>'photo';
        IF p<>'' AND public.kenz_photo_store_id(p) IS NULL THEN RETURN false; END IF;
        normalized:=jsonb_set(normalized,ARRAY[kind,idx::text,'photo'],'""'::jsonb,false);
      END IF;
      idx:=idx+1;
    END LOOP;
  END LOOP;
  RETURN public.kenz_inventory_valid_payload_v1(normalized);
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_inventory_valid_payload(jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.kenz_photo_reference(store_id uuid,inline_photo text)
RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT SET search_path = '' AS $$
DECLARE mime text; raw_bytes bytea;
BEGIN
  IF inline_photo='' THEN RETURN ''; END IF;
  IF inline_photo!~'^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$' THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='صيغة إحدى الصور غير صالحة. لم تتغير البيانات.';
  END IF;
  mime:=split_part(split_part(inline_photo,';',1),'/',2);
  BEGIN raw_bytes:=decode(split_part(inline_photo,',',2),'base64');
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='تعذر قراءة إحدى الصور. لم تتغير البيانات.';
  END;
  RETURN store_id::text||'/'||encode(sha256(raw_bytes),'hex')||'.'||CASE mime WHEN 'jpeg' THEN 'jpg' ELSE mime END;
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_photo_reference(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE TABLE IF NOT EXISTS public.kenz_photo_migration_backups(
  store_id uuid PRIMARY KEY REFERENCES public.kenz_stores(id) ON DELETE CASCADE,
  source_revision bigint NOT NULL,
  original_payload jsonb NOT NULL,
  migrated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  migrated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  stats jsonb NOT NULL
);
ALTER TABLE public.kenz_photo_migration_backups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.kenz_photo_migration_backups FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.kenz_require_photo_objects()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE p text;
BEGIN
  IF TG_OP='UPDATE' AND OLD.payload->'version'='2'::jsonb AND NEW.payload->'version' IS DISTINCT FROM '2'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE='PT426',MESSAGE='حدّث صفحة التطبيق لاستخدام تخزين الصور الجديد.';
  END IF;
  IF NEW.payload->'version'='2'::jsonb THEN
    IF NOT public.kenz_inventory_valid_payload(NEW.payload) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='بيانات المخزون غير صالحة أو تتجاوز حد 10 ميغابايت.';
    END IF;
    FOR p IN SELECT DISTINCT e.value->>'photo'
      FROM jsonb_array_elements((NEW.payload->'items')||(NEW.payload->'orders'))e(value)
      WHERE coalesce(e.value->>'photo','')<>'' LOOP
      IF public.kenz_photo_store_id(p) IS DISTINCT FROM NEW.store_id
        OR NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='kenz-model-photos' AND o.name=p) THEN
        RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='إحدى الصور لم تُرفع إلى تخزين هذا المتجر. لم تتغير البيانات.';
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_require_photo_objects() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS kenz_inventory_photo_objects ON public.kenz_inventory_state;
CREATE TRIGGER kenz_inventory_photo_objects BEFORE INSERT OR UPDATE OF payload,store_id
  ON public.kenz_inventory_state FOR EACH ROW EXECUTE FUNCTION public.kenz_require_photo_objects();

CREATE OR REPLACE FUNCTION public.kenz_get_state_v2()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE membership public.kenz_store_members%ROWTYPE; saved public.kenz_inventory_state%ROWTYPE;
BEGIN
  membership:=public.kenz_membership_required(false);
  SELECT s.* INTO STRICT saved FROM public.kenz_inventory_state s WHERE s.store_id=membership.store_id;
  RETURN jsonb_build_object('store_id',membership.store_id,'role',membership.role,'revision',saved.revision,'payload',saved.payload);
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_get_state_v2() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_get_state_v2() TO authenticated;

CREATE OR REPLACE FUNCTION public.kenz_get_state()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  result:=public.kenz_get_state_v2();
  IF result->'payload'->'version'='2'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE='PT426',MESSAGE='تم تطوير تخزين الصور. حدّث صفحة التطبيق للمتابعة.';
  END IF;
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_get_state() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_get_state() TO authenticated;

-- The old endpoint must never accept a v2 payload: otherwise a stale or custom
-- client could skip the owner-only conversion and its original-data archive.
CREATE OR REPLACE FUNCTION public.kenz_save_state(expected_store_id uuid,expected_revision bigint,new_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE membership public.kenz_store_members%ROWTYPE; saved public.kenz_inventory_state%ROWTYPE;
BEGIN
  membership:=public.kenz_membership_required(false);
  IF expected_store_id IS NULL OR expected_store_id<>membership.store_id THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المتجر المرتبط بالحساب. حدّث البيانات.';
  END IF;
  IF new_payload->'version' IS DISTINCT FROM '1'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE='PT426',MESSAGE='حدّث صفحة التطبيق لاستخدام تخزين الصور الجديد.';
  END IF;
  IF expected_revision IS NULL OR expected_revision<0 OR NOT public.kenz_inventory_valid_payload_v1(new_payload) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='البيانات غير صالحة أو تتجاوز حد 10 ميغابايت.';
  END IF;
  SELECT s.* INTO saved FROM public.kenz_inventory_state s WHERE s.store_id=membership.store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='PT503',MESSAGE='لم تجهّز بيانات المتجر بعد.'; END IF;
  IF saved.payload->'version' IS DISTINCT FROM '1'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE='PT426',MESSAGE='حدّث صفحة التطبيق لاستخدام تخزين الصور الجديد.';
  END IF;
  IF saved.revision<>expected_revision THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المخزون من جهاز آخر. حدّث البيانات.';
  END IF;
  UPDATE public.kenz_inventory_state s SET payload=new_payload,revision=s.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()
  WHERE s.store_id=membership.store_id RETURNING s.* INTO saved;
  RETURN jsonb_build_object('store_id',membership.store_id,'role',membership.role,'revision',saved.revision,'payload',saved.payload);
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_save_state(uuid,bigint,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_save_state(uuid,bigint,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.kenz_save_state_v2(expected_store_id uuid,expected_revision bigint,new_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE membership public.kenz_store_members%ROWTYPE; saved public.kenz_inventory_state%ROWTYPE;
BEGIN
  membership:=public.kenz_membership_required(false);
  IF expected_store_id IS NULL OR expected_store_id<>membership.store_id THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المتجر المرتبط بالحساب. حدّث البيانات.';
  END IF;
  IF expected_revision IS NULL OR expected_revision<0 OR expected_revision>=9007199254740991
    OR new_payload->'version' IS DISTINCT FROM '2'::jsonb OR NOT public.kenz_inventory_valid_payload(new_payload) THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='بيانات الحفظ غير صالحة أو تتجاوز حد 10 ميغابايت.';
  END IF;
  SELECT s.* INTO saved FROM public.kenz_inventory_state s WHERE s.store_id=membership.store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='PT503',MESSAGE='لم تجهّز بيانات المتجر بعد.'; END IF;
  IF saved.payload->'version' IS DISTINCT FROM '2'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='يلزم أن ينهي صاحب المتجر نقل الصور أولاً.';
  END IF;
  IF saved.revision<>expected_revision THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المخزون من جهاز آخر. حدّث البيانات.';
  END IF;
  UPDATE public.kenz_inventory_state s SET payload=new_payload,revision=s.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()
  WHERE s.store_id=membership.store_id RETURNING s.* INTO saved;
  RETURN jsonb_build_object('store_id',membership.store_id,'role',membership.role,'revision',saved.revision,'payload',saved.payload);
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_save_state_v2(uuid,bigint,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_save_state_v2(uuid,bigint,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.kenz_migrate_photos(expected_store_id uuid,expected_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE membership public.kenz_store_members%ROWTYPE; saved public.kenz_inventory_state%ROWTYPE;
  converted jsonb; kind text; entry jsonb; idx integer; old_photo text; ref text;
  refs text[]:=ARRAY[]::text[]; photo_count integer:=0; stats jsonb; duplicate boolean:=false;
BEGIN
  membership:=public.kenz_membership_required(true);
  IF expected_store_id IS NULL OR expected_store_id<>membership.store_id THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المتجر المرتبط بالحساب. حدّث البيانات.';
  END IF;
  IF expected_revision IS NULL OR expected_revision<0 THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='رقم مراجعة المخزون غير صالح.';
  END IF;
  SELECT s.* INTO saved FROM public.kenz_inventory_state s WHERE s.store_id=membership.store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='PT503',MESSAGE='لم تجهّز بيانات المتجر بعد.'; END IF;
  IF saved.payload->'version'='2'::jsonb THEN
    SELECT b.stats INTO stats FROM public.kenz_photo_migration_backups b WHERE b.store_id=membership.store_id;
    duplicate:=true;
  ELSE
    IF saved.revision<>expected_revision THEN
      RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المخزون أثناء رفع الصور. حدّث البيانات وأعد نقل الصور.';
    END IF;
    IF saved.revision>=9007199254740991 OR NOT public.kenz_inventory_valid_payload_v1(saved.payload) THEN
      RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='تعذر التحقق من بيانات المتجر الأصلية. لم تتغير البيانات.';
    END IF;
    converted:=jsonb_set(saved.payload,'{version}','2'::jsonb,false);
    FOREACH kind IN ARRAY ARRAY['items','orders'] LOOP
      idx:=0;
      FOR entry IN SELECT e.value FROM jsonb_array_elements(saved.payload->kind)e(value) LOOP
        old_photo:=coalesce(entry->>'photo','');
        IF old_photo<>'' THEN
          ref:=public.kenz_photo_reference(membership.store_id,old_photo);
          IF NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='kenz-model-photos' AND o.name=ref) THEN
            RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='لم يكتمل رفع كل الصور. البيانات الأصلية لم تتغير؛ أعد المحاولة.';
          END IF;
          converted:=jsonb_set(converted,ARRAY[kind,idx::text,'photo'],to_jsonb(ref),false);
          photo_count:=photo_count+1; refs:=array_append(refs,ref);
        END IF;
        idx:=idx+1;
      END LOOP;
    END LOOP;
    SELECT jsonb_build_object('unique_images',count(DISTINCT r),'photo_references',photo_count,
      'before_bytes',octet_length(saved.payload::text),'after_bytes',octet_length(converted::text))
      INTO stats FROM unnest(refs)r;
    INSERT INTO public.kenz_photo_migration_backups(store_id,source_revision,original_payload,migrated_by,stats)
    VALUES(membership.store_id,saved.revision,saved.payload,auth.uid(),stats);
    UPDATE public.kenz_inventory_state s SET payload=converted,revision=s.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()
    WHERE s.store_id=membership.store_id RETURNING s.* INTO saved;
  END IF;
  RETURN jsonb_build_object('store_id',membership.store_id,'role',membership.role,'revision',saved.revision,
    'payload',saved.payload,'migration',stats,'duplicate',duplicate);
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_migrate_photos(uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_migrate_photos(uuid,bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.kenz_get_photo_migration_backup(expected_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE membership public.kenz_store_members%ROWTYPE; backup public.kenz_photo_migration_backups%ROWTYPE;
BEGIN
  membership:=public.kenz_membership_required(true);
  IF expected_store_id IS NULL OR expected_store_id<>membership.store_id THEN
    RAISE EXCEPTION USING ERRCODE='PT409',MESSAGE='تغيّر المتجر المرتبط بالحساب. حدّث البيانات.';
  END IF;
  SELECT b.* INTO backup FROM public.kenz_photo_migration_backups b WHERE b.store_id=membership.store_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='PT404',MESSAGE='لم تُنقل صور هذا المتجر بعد.'; END IF;
  RETURN jsonb_build_object('store_id',membership.store_id,'source_revision',backup.source_revision,
    'payload',backup.original_payload,'migrated_at',backup.migrated_at,'migration',backup.stats);
END;
$$;
REVOKE ALL ON FUNCTION public.kenz_get_photo_migration_backup(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_get_photo_migration_backup(uuid) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
