-- Local-only faithful fixture of the deployed v1 validation/access contract.
-- This file is never run against the user's Supabase project.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth,public to authenticated,anon;
grant execute on function auth.uid() to authenticated,anon;

create function public.kenz_inventory_valid_payload(doc jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare kind text; entry jsonb; field_spec record; n numeric; p text;
begin
 if doc is null or jsonb_typeof(doc) is distinct from 'object'
 or doc->'version' is distinct from '1'::jsonb
 or jsonb_typeof(doc->'items') is distinct from 'array'
 or jsonb_typeof(doc->'orders') is distinct from 'array' then return false; end if;
 if octet_length(doc::text)>10485760 then return false; end if;
 foreach kind in array array['items','orders'] loop
  for entry in select e.value from jsonb_array_elements(doc->kind) as e(value) loop
   if jsonb_typeof(entry) is distinct from 'object' then return false; end if;
   for field_spec in select * from(values ('id',100),('model',100),('color',60),('size',40)) as f(field_name,max_length) loop
    if jsonb_typeof(entry->field_spec.field_name) is distinct from 'string'
    or length(btrim(entry->>field_spec.field_name))=0
    or length(entry->>field_spec.field_name)>field_spec.max_length then return false; end if;
   end loop;
   if jsonb_typeof(entry->'price') is distinct from 'number'
   or jsonb_typeof(entry->'quantity') is distinct from 'number' then return false; end if;
   n:=(entry->>'price')::numeric;
   if n<0 or n>1000000000 then return false; end if;
   n:=(entry->>'quantity')::numeric;
   if n<0 or n>1000000 or n<>trunc(n) or(kind='orders' and n=0) then return false; end if;
   if entry?'photo' then
    if jsonb_typeof(entry->'photo') is distinct from 'string' then return false; end if;
    p:=entry->>'photo';
    if length(p)>400000 then return false; end if;
    if p<>'' and p!~'^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$' then return false; end if;
   end if;
   if kind='orders' then
    for field_spec in select * from(values
     ('itemId',100,true),('customer',100,true),('phone',40,false),('address',500,false),
     ('notes',500,false),('date',100,true),('status',30,true),('payment',30,true))
     as f(field_name,max_length,required) loop
     if jsonb_typeof(entry->field_spec.field_name) is distinct from 'string'
     or length(entry->>field_spec.field_name)>field_spec.max_length
     or(field_spec.required and length(btrim(entry->>field_spec.field_name))=0) then return false; end if;
    end loop;
    if entry->>'status' not in('جديد','قيد التوصيل','تم التوصيل','ملغي')
    or entry->>'payment' not in('غير مدفوع','مدفوع')
    or jsonb_typeof(entry->'deliveryFee') is distinct from 'number'
    or jsonb_typeof(entry->'number') is distinct from 'number' then return false; end if;
    n:=(entry->>'deliveryFee')::numeric;
    if n<0 or n>1000000000 then return false; end if;
    n:=(entry->>'number')::numeric;
    if n<1 or n>9007199254740991 or n<>trunc(n) then return false; end if;
   end if;
  end loop;
 end loop;
 if exists(select 1 from jsonb_array_elements(doc->'items')i(value) group by i.value->>'id' having count(*)>1)
 or exists(select 1 from jsonb_array_elements(doc->'orders')o(value) group by o.value->>'id' having count(*)>1)
 or exists(select 1 from jsonb_array_elements(doc->'orders')o(value) group by (o.value->>'number')::numeric having count(*)>1)
 or exists(select 1 from jsonb_array_elements(doc->'orders')o(value) where not exists(
  select 1 from jsonb_array_elements(doc->'items')i(value) where i.value->>'id'=o.value->>'itemId'))
 then return false; end if;
 return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end;$$;
revoke all on function public.kenz_inventory_valid_payload(jsonb) from public,anon,authenticated;

create table public.kenz_stores(
 id uuid primary key default gen_random_uuid(),owner_id uuid not null unique references auth.users(id) on delete cascade,
 created_at timestamptz not null default now());
create table public.kenz_store_members(
 user_id uuid primary key references auth.users(id) on delete cascade,
 store_id uuid not null references public.kenz_stores(id) on delete cascade,
 role text not null check(role in('owner','staff')),created_at timestamptz not null default now());
create unique index kenz_store_single_owner on public.kenz_store_members(store_id) where role='owner';
create table public.kenz_inventory_state(
 store_id uuid primary key references public.kenz_stores(id) on delete cascade,
 revision bigint not null default 0 check(revision>=0),
 payload jsonb not null default '{"version":1,"items":[],"orders":[]}'::jsonb,
 updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) on delete set null,
 constraint kenz_inventory_payload_valid check(public.kenz_inventory_valid_payload(payload)));
alter table public.kenz_stores enable row level security;
alter table public.kenz_store_members enable row level security;
alter table public.kenz_inventory_state enable row level security;
revoke all on table public.kenz_stores,public.kenz_store_members,public.kenz_inventory_state from public,anon,authenticated;
grant select on table public.kenz_stores,public.kenz_store_members,public.kenz_inventory_state to authenticated;
create policy kenz_member_read_self on public.kenz_store_members for select to authenticated using(user_id=(select auth.uid()));
create policy kenz_store_read_member on public.kenz_stores for select to authenticated using(exists(
 select 1 from public.kenz_store_members m where m.store_id=kenz_stores.id and m.user_id=(select auth.uid())));
create policy kenz_inventory_read_member on public.kenz_inventory_state for select to authenticated using(exists(
 select 1 from public.kenz_store_members m where m.store_id=kenz_inventory_state.store_id and m.user_id=(select auth.uid())));

create function public.kenz_membership_required(must_be_owner boolean)
returns public.kenz_store_members language plpgsql set search_path='' as $$
declare uid uuid:=auth.uid();membership public.kenz_store_members%rowtype;
begin
 if uid is null then raise exception using errcode='42501',message='يلزم تسجيل الدخول.';end if;
 select m.* into membership from public.kenz_store_members m where m.user_id=uid for share;
 if not found then raise exception using errcode='PT403',message='هذا الحساب غير مرتبط بالمتجر بعد.';end if;
 if must_be_owner and(membership.role<>'owner' or not exists(
 select 1 from public.kenz_stores s where s.id=membership.store_id and s.owner_id=uid)) then
 raise exception using errcode='PT403',message='هذا الإجراء متاح لصاحب المتجر فقط.';end if;
 return membership;
end;$$;
revoke all on function public.kenz_membership_required(boolean) from public,anon,authenticated;

create function public.kenz_get_state() returns jsonb language plpgsql security definer set search_path='' as $$
declare membership public.kenz_store_members%rowtype;saved public.kenz_inventory_state%rowtype;
begin
 membership:=public.kenz_membership_required(false);
 select s.* into strict saved from public.kenz_inventory_state s where s.store_id=membership.store_id;
 return jsonb_build_object('store_id',membership.store_id,'role',membership.role,'revision',saved.revision,'payload',saved.payload);
end;$$;
revoke all on function public.kenz_get_state() from public,anon,authenticated;
grant execute on function public.kenz_get_state() to authenticated;

create function public.kenz_save_state(expected_store_id uuid,expected_revision bigint,new_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare membership public.kenz_store_members%rowtype;saved public.kenz_inventory_state%rowtype;
begin
 membership:=public.kenz_membership_required(false);
 if expected_store_id is null or expected_store_id<>membership.store_id then
 raise exception using errcode='PT409',message='تغيّر المتجر المرتبط بالحساب.';end if;
 if expected_revision is null or expected_revision<0 or new_payload is null then
 raise exception using errcode='22023',message='بيانات الحفظ غير صالحة.';end if;
 begin
  update public.kenz_inventory_state s set payload=new_payload,revision=s.revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()
  where s.store_id=membership.store_id and s.store_id=expected_store_id and s.revision=expected_revision returning s.* into saved;
 exception when check_violation then raise exception using errcode='22023',message='البيانات غير صالحة أو تتجاوز حد 10 ميغابايت.';end;
 if not found then raise exception using errcode='PT409',message='تغيّر المخزون من جهاز آخر.';end if;
 return jsonb_build_object('store_id',membership.store_id,'role',membership.role,'revision',saved.revision,'payload',saved.payload);
end;$$;
revoke all on function public.kenz_save_state(uuid,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.kenz_save_state(uuid,bigint,jsonb) to authenticated;
