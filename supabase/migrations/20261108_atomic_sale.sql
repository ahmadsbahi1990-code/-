-- Additive repair: record a sale without uploading/downloading the entire inventory.
-- Requires the existing KENZ shared-store schema. Existing rows, RPCs and RLS stay in place.
BEGIN;

CREATE OR REPLACE FUNCTION public.kenz_create_sale(
  expected_store_id uuid,
  expected_revision bigint,
  request_id text,
  item_id text,
  quantity integer,
  delivery_fee numeric,
  customer text,
  phone text,
  address text,
  notes text,
  status text,
  payment text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  membership public.kenz_store_members%ROWTYPE;
  saved public.kenz_inventory_state%ROWTYPE;
  existing_order jsonb;
  source_item jsonb;
  source_index integer;
  available integer;
  resulting_quantity integer;
  next_number bigint;
  resulting_revision bigint;
  clean_customer text := btrim(customer);
  clean_phone text := btrim(coalesce(phone, ''));
  clean_address text := btrim(coalesce(address, ''));
  clean_notes text := btrim(coalesce(notes, ''));
  request_meta jsonb;
  created_order jsonb;
  candidate jsonb;
BEGIN
  -- The helper holds a membership row lock until the transaction completes.
  membership := public.kenz_membership_required(false);
  IF expected_store_id IS NULL OR expected_store_id <> membership.store_id THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409',
      MESSAGE = 'تغيّر المتجر المرتبط بالحساب. أعد تحميل البيانات قبل تسجيل البيع.';
  END IF;
  IF expected_revision IS NULL OR expected_revision < 0
    OR request_id IS NULL OR length(btrim(request_id)) = 0 OR length(request_id) > 100
    OR item_id IS NULL OR length(btrim(item_id)) = 0 OR length(item_id) > 100
    OR quantity IS NULL OR quantity < 1 OR quantity > 1000000
    OR delivery_fee IS NULL OR delivery_fee < 0 OR delivery_fee > 1000000000
    OR delivery_fee <> round(delivery_fee, 2)
    OR clean_customer IS NULL OR length(clean_customer) = 0 OR length(clean_customer) > 100
    OR length(clean_phone) > 40 OR length(clean_address) > 500 OR length(clean_notes) > 500
    OR status IS NULL OR status NOT IN ('جديد', 'قيد التوصيل', 'تم التوصيل')
    OR payment IS NULL OR payment NOT IN ('غير مدفوع', 'مدفوع') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'راجع بيانات البيع والكمية ورسوم التوصيل.';
  END IF;

  -- Preserve original inputs so a retry still matches after an order is updated/cancelled.
  request_meta := jsonb_build_object(
    'v', 1, 'store_id', membership.store_id, 'item_id', item_id, 'quantity', quantity,
    'delivery_fee', delivery_fee, 'customer', clean_customer, 'phone', clean_phone,
    'address', clean_address, 'notes', clean_notes, 'status', status, 'payment', payment
  );
  SELECT s.* INTO saved
  FROM public.kenz_inventory_state AS s
  WHERE s.store_id = membership.store_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'PT503', MESSAGE = 'لم تجهّز بيانات المتجر بعد.';
  END IF;

  -- Check idempotence before revision CAS. A lost successful response must not sell twice.
  SELECT o.value INTO existing_order
  FROM jsonb_array_elements(saved.payload->'orders') AS o(value)
  WHERE o.value->>'id' = request_id;
  IF FOUND THEN
    IF existing_order->'_sale_request' IS DISTINCT FROM request_meta
      OR existing_order->>'itemId' IS DISTINCT FROM item_id THEN
      RAISE EXCEPTION USING ERRCODE = 'PT409',
        MESSAGE = 'رقم هذا الطلب مستخدم لعملية أخرى. حدّث البيانات وافتح عملية بيع جديدة.';
    END IF;
    SELECT i.value INTO source_item
    FROM jsonb_array_elements(saved.payload->'items') AS i(value)
    WHERE i.value->>'id' = item_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'تعذّر التحقق من رصيد الطلب السابق. حدّث البيانات.';
    END IF;
    resulting_quantity := (source_item->>'quantity')::numeric::integer;
    RETURN jsonb_build_object(
      'store_id', membership.store_id, 'role', membership.role, 'revision', saved.revision,
      'order', existing_order, 'new_quantity', resulting_quantity, 'duplicate', true
    );
  END IF;
  IF saved.revision <> expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'تغيّر المخزون من جهاز آخر. حدّث البيانات قبل تسجيل البيع.';
  END IF;
  SELECT i.value, (i.ordinality - 1)::integer INTO source_item, source_index
  FROM jsonb_array_elements(saved.payload->'items') WITH ORDINALITY AS i(value, ordinality)
  WHERE i.value->>'id' = item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'PT404', MESSAGE = 'القطعة المطلوبة غير موجودة في المخزون.';
  END IF;
  available := (source_item->>'quantity')::numeric::integer;
  IF quantity > available THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'الكمية المطلوبة غير متوفرة. حدّث المخزون.';
  END IF;
  resulting_quantity := available - quantity;
  SELECT coalesce(max((o.value->>'number')::numeric), 0) + 1 INTO next_number
  FROM jsonb_array_elements(saved.payload->'orders') AS o(value);
  IF next_number > 9007199254740991 OR saved.revision >= 9007199254740991 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'تجاوز عداد الطلبات أو المراجعات الحد المدعوم.';
  END IF;
  created_order := jsonb_build_object(
    'id', request_id, 'number', next_number, 'itemId', item_id,
    'model', source_item->>'model', 'color', source_item->>'color', 'size', source_item->>'size',
    'price', source_item->'price', 'photo', coalesce(source_item->>'photo', ''),
    'quantity', quantity, 'deliveryFee', delivery_fee, 'customer', clean_customer,
    'phone', clean_phone, 'address', clean_address, 'notes', clean_notes,
    'status', status, 'payment', payment,
    'date', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    '_sale_request', request_meta
  );
  candidate := jsonb_set(saved.payload, ARRAY['items', source_index::text, 'quantity'], to_jsonb(resulting_quantity), false);
  candidate := jsonb_set(candidate, '{orders}', (saved.payload->'orders') || jsonb_build_array(created_order), false);
  BEGIN
    UPDATE public.kenz_inventory_state AS s
    SET payload = candidate, revision = s.revision + 1, updated_at = clock_timestamp(), updated_by = auth.uid()
    WHERE s.store_id = membership.store_id AND s.revision = expected_revision
    RETURNING s.revision INTO resulting_revision;
  EXCEPTION WHEN check_violation THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'تعذر تسجيل البيع: بيانات المتجر غير صالحة أو تجاوزت 10 ميغابايت.';
  END;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'PT409', MESSAGE = 'تغيّر المخزون من جهاز آخر. حدّث البيانات.';
  END IF;
  RETURN jsonb_build_object(
    'store_id', membership.store_id, 'role', membership.role, 'revision', resulting_revision,
    'order', created_order, 'new_quantity', resulting_quantity, 'duplicate', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.kenz_create_sale(uuid, bigint, text, text, integer, numeric, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kenz_create_sale(uuid, bigint, text, text, integer, numeric, text, text, text, text, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
