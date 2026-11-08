-- Run as the test database owner after each pair of race_session.sql processes.
DO $$
DECLARE saved public.kenz_inventory_state%ROWTYPE;
BEGIN
  SELECT * INTO STRICT saved FROM public.kenz_inventory_state WHERE store_id = '20000000-0000-0000-0000-000000000001';
  IF saved.revision <> 1 OR saved.payload#>>'{items,0,quantity}' <> '0'
    OR jsonb_array_length(saved.payload->'orders') <> 1 THEN
    RAISE EXCEPTION 'Concurrent sale violated stock/order/revision invariants';
  END IF;
END;
$$;
