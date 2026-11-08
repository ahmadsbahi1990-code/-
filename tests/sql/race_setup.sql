-- Local-only persistent fixture for independent concurrent PostgreSQL sessions.
INSERT INTO auth.users(id, email) VALUES
  ('00000000-0000-0000-0000-000000000005', 'race-owner@example.invalid')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.kenz_stores(id, owner_id) VALUES
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.kenz_store_members(user_id, store_id, role) VALUES
  ('00000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001', 'owner')
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO public.kenz_inventory_state(store_id, payload) VALUES
  ('20000000-0000-0000-0000-000000000001', '{"version":1,"items":[{"id":"last-piece","model":"Last piece","color":"red","size":"M","price":2200,"quantity":1}],"orders":[]}')
ON CONFLICT (store_id) DO UPDATE SET revision = 0, payload = EXCLUDED.payload, updated_by = NULL;
