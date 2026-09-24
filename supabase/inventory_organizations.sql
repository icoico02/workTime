-- Shared workspace for inventory only. Run after inventory.sql and inventory_returns.sql.

create table if not exists public.inventory_organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_organization_members (
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('super_admin','admin','salesperson','warehouse','user')),
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

alter table public.inventory_products add column if not exists organization_id uuid references public.inventory_organizations(id) on delete restrict;
alter table public.inventory_orders add column if not exists organization_id uuid references public.inventory_organizations(id) on delete restrict;
alter table public.inventory_movements add column if not exists organization_id uuid references public.inventory_organizations(id) on delete restrict;
alter table public.inventory_returns add column if not exists organization_id uuid references public.inventory_organizations(id) on delete restrict;
alter table public.inventory_document_counters add column if not exists organization_id uuid references public.inventory_organizations(id) on delete cascade;

create index if not exists inventory_products_organization_idx on public.inventory_products(organization_id);
create index if not exists inventory_orders_organization_idx on public.inventory_orders(organization_id, created_at desc);
create index if not exists inventory_movements_organization_idx on public.inventory_movements(organization_id, created_at desc);

create or replace function public.inventory_current_organization_id()
returns uuid language sql stable security definer set search_path = public as $$
  select organization_id
  from public.inventory_organization_members
  where user_id = auth.uid()
  order by created_at
  limit 1
$$;

create or replace function public.inventory_has_role(p_roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.inventory_organization_members
    where organization_id = public.inventory_current_organization_id()
      and user_id = auth.uid()
      and role = any(p_roles)
  )
$$;

create or replace function public.inventory_create_organization(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare oid uuid;
begin
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'Organization name is required'; end if;
  insert into public.inventory_organizations(name, owner_id)
  values(trim(p_name), auth.uid())
  returning id into oid;
  insert into public.inventory_organization_members(organization_id, user_id, role)
  values(oid, auth.uid(), 'super_admin');
  return oid;
end $$;

create or replace function public.inventory_add_organization_member(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare oid uuid;
begin
  oid := public.inventory_current_organization_id();
  if oid is null or not public.inventory_has_role(array['super_admin','admin']) then raise exception 'Not allowed'; end if;
  if p_role not in ('admin','salesperson','warehouse','user') then raise exception 'Invalid organization role'; end if;
  insert into public.inventory_organization_members(organization_id, user_id, role)
  values(oid, p_user_id, p_role)
  on conflict(organization_id, user_id) do update set role = excluded.role;
end $$;

alter table public.inventory_organizations enable row level security;
alter table public.inventory_organization_members enable row level security;

drop policy if exists "Inventory organization members can view organization" on public.inventory_organizations;
create policy "Inventory organization members can view organization" on public.inventory_organizations
for select to authenticated using (id = public.inventory_current_organization_id());

drop policy if exists "Inventory members can view memberships" on public.inventory_organization_members;
create policy "Inventory members can view memberships" on public.inventory_organization_members
for select to authenticated using (organization_id = public.inventory_current_organization_id());

-- Move each existing personal inventory workspace into its own organization once.
-- It deliberately preserves the record owner in user_id for audit history.
do $$
declare
  row record;
  oid uuid;
begin
  for row in
    select distinct user_id from (
      select user_id from public.inventory_products where organization_id is null
      union select user_id from public.inventory_orders where organization_id is null
      union select user_id from public.inventory_movements where organization_id is null
    ) users
  loop
    select organization_id into oid
    from public.inventory_organization_members
    where user_id = row.user_id
    order by created_at
    limit 1;
    if oid is null then
      insert into public.inventory_organizations(name, owner_id)
      values ('我的店铺', row.user_id)
      returning id into oid;
      insert into public.inventory_organization_members(organization_id, user_id, role)
      values (oid, row.user_id, 'super_admin');
    end if;
    update public.inventory_products set organization_id = oid where user_id = row.user_id and organization_id is null;
    update public.inventory_orders set organization_id = oid where user_id = row.user_id and organization_id is null;
    update public.inventory_movements set organization_id = oid where user_id = row.user_id and organization_id is null;
    update public.inventory_returns set organization_id = oid where user_id = row.user_id and organization_id is null;
    update public.inventory_document_counters set organization_id = oid where user_id = row.user_id and organization_id is null;
  end loop;
end $$;

alter table public.inventory_products alter column organization_id set default public.inventory_current_organization_id();
alter table public.inventory_orders alter column organization_id set default public.inventory_current_organization_id();
alter table public.inventory_movements alter column organization_id set default public.inventory_current_organization_id();
alter table public.inventory_returns alter column organization_id set default public.inventory_current_organization_id();
alter table public.inventory_document_counters alter column organization_id set default public.inventory_current_organization_id();

-- Document sequences belong to the shared organization, not to the individual
-- operator. This preserves unique SO/SR/PO/PR/ST numbers during concurrent use.
alter table public.inventory_document_counters drop constraint if exists inventory_document_counters_pkey;
alter table public.inventory_document_counters alter column organization_id set not null;
-- Some earlier installations retained the old user-based primary key. Keep an
-- explicit unique index as the conflict target used by inventory_next_no().
delete from public.inventory_document_counters counters
using (
  select ctid, row_number() over (
    partition by organization_id, document_date, prefix
    order by last_number desc, ctid desc
  ) as row_no
  from public.inventory_document_counters
) duplicates
where counters.ctid = duplicates.ctid and duplicates.row_no > 1;
alter table public.inventory_document_counters add primary key (organization_id, document_date, prefix);
create unique index if not exists inventory_document_counters_org_date_prefix_idx
  on public.inventory_document_counters(organization_id, document_date, prefix);
create or replace function public.inventory_next_no(p_prefix text)
returns text language plpgsql security definer set search_path = public as $$
declare next_value integer; today date := current_date; oid uuid := public.inventory_current_organization_id();
begin
  if oid is null then raise exception 'Organization is required'; end if;
  insert into public.inventory_document_counters(user_id, organization_id, document_date, prefix, last_number)
  values(auth.uid(), oid, today, p_prefix, 1)
  on conflict(organization_id, document_date, prefix)
  do update set last_number = public.inventory_document_counters.last_number + 1
  returning last_number into next_value;
  return p_prefix || to_char(today, 'YYYYMMDD') || lpad(next_value::text, 4, '0');
end $$;

create or replace function public.inventory_stock_out(
  p_product_id uuid,
  p_quantity integer,
  p_type text,
  p_note text default null
)
returns void language plpgsql security definer set search_path = public as $$
declare p public.inventory_products; oid uuid := public.inventory_current_organization_id(); doc_no text;
begin
  if oid is null or not public.inventory_has_role(array['super_admin','admin','warehouse']) then raise exception 'Not allowed'; end if;
  if p_quantity <= 0 or p_type not in ('normal_outbound','loss') then raise exception 'Invalid outbound values'; end if;
  select * into p from public.inventory_products where id = p_product_id and organization_id = oid for update;
  if not found then raise exception 'Product not found'; end if;
  if p.stock < p_quantity then raise exception 'Insufficient stock'; end if;
  doc_no := public.inventory_next_no('ST');
  update public.inventory_products set stock = stock - p_quantity, damaged_quantity = damaged_quantity + case when p_type = 'loss' then p_quantity else 0 end, updated_at = now() where id = p.id;
  insert into public.inventory_movements(user_id, organization_id, product_id, operation_type, quantity, unit_cost, total_amount, note, before_sellable_stock, after_sellable_stock, business_type, business_id, business_no)
  values(auth.uid(), oid, p.id, p_type, -p_quantity, p.cost_price, p_quantity * p.cost_price, p_note, p.stock, p.stock - p_quantity, 'stock_adjustment', gen_random_uuid(), doc_no);
end $$;

create or replace function public.inventory_receive(
  p_product_id uuid,
  p_quantity integer,
  p_unit_cost numeric,
  p_supplier text default null,
  p_note text default null,
  p_request_key uuid default gen_random_uuid()
)
returns uuid language plpgsql security definer set search_path = public as $$
declare p public.inventory_products; oid uuid := public.inventory_current_organization_id(); mid uuid; doc_no text;
begin
  if oid is null or not public.inventory_has_role(array['super_admin','admin','warehouse']) then raise exception 'Not allowed'; end if;
  select id into mid from public.inventory_movements where organization_id = oid and operation_key = p_request_key limit 1;
  if mid is not null then return mid; end if;
  if p_quantity <= 0 or p_unit_cost < 0 then raise exception 'Invalid inbound values'; end if;
  select * into p from public.inventory_products where id = p_product_id and organization_id = oid for update;
  if not found then raise exception 'Product not found'; end if;
  doc_no := public.inventory_next_no('PO');
  update public.inventory_products set stock = stock + p_quantity, cost_price = p_unit_cost, updated_at = now() where id = p.id;
  insert into public.inventory_movements(user_id, organization_id, product_id, operation_type, quantity, unit_cost, total_amount, supplier, note, before_sellable_stock, after_sellable_stock, business_type, business_id, business_no, operation_key)
  values(auth.uid(), oid, p.id, 'inbound', p_quantity, p_unit_cost, p_quantity * p_unit_cost, p_supplier, p_note, p.stock, p.stock + p_quantity, 'purchase_inbound', gen_random_uuid(), doc_no, p_request_key)
  returning id into mid;
  return mid;
end $$;

-- Replace the original personal policies with organization membership policies.
drop policy if exists "Users manage own inventory products" on public.inventory_products;
drop policy if exists "Users manage own inventory orders" on public.inventory_orders;
drop policy if exists "Users view own order items" on public.inventory_order_items;
drop policy if exists "Users add own order items" on public.inventory_order_items;
drop policy if exists "Users manage own inventory movements" on public.inventory_movements;
drop policy if exists "Users manage own inventory returns" on public.inventory_returns;
drop policy if exists "Users view own return items" on public.inventory_return_items;
drop policy if exists "Users add own return items" on public.inventory_return_items;
drop policy if exists "Organization members view products" on public.inventory_products;
drop policy if exists "Organization managers manage products" on public.inventory_products;
drop policy if exists "Organization members view orders" on public.inventory_orders;
drop policy if exists "Organization members view order items" on public.inventory_order_items;
drop policy if exists "Organization members view movements" on public.inventory_movements;
drop policy if exists "Organization members view returns" on public.inventory_returns;
drop policy if exists "Organization members view return items" on public.inventory_return_items;

create policy "Organization members view products" on public.inventory_products for select to authenticated using (organization_id = public.inventory_current_organization_id());
create policy "Organization managers manage products" on public.inventory_products for all to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin','admin'])) with check (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin','admin']));
create policy "Organization members view orders" on public.inventory_orders for select to authenticated using (organization_id = public.inventory_current_organization_id() and (public.inventory_has_role(array['super_admin','admin','warehouse']) or salesperson_id = auth.uid() or user_id = auth.uid()));
create policy "Organization members view order items" on public.inventory_order_items for select to authenticated using (exists (select 1 from public.inventory_orders o where o.id = order_id and o.organization_id = public.inventory_current_organization_id() and (public.inventory_has_role(array['super_admin','admin','warehouse']) or o.salesperson_id = auth.uid() or o.user_id = auth.uid())));
create policy "Organization members view movements" on public.inventory_movements for select to authenticated using (organization_id = public.inventory_current_organization_id());
create policy "Organization members view returns" on public.inventory_returns for select to authenticated using (organization_id = public.inventory_current_organization_id());
create policy "Organization members view return items" on public.inventory_return_items for select to authenticated using (exists (select 1 from public.inventory_returns r where r.id = return_id and r.organization_id = public.inventory_current_organization_id()));

grant execute on function public.inventory_current_organization_id() to authenticated;
grant execute on function public.inventory_has_role(text[]) to authenticated;
grant execute on function public.inventory_create_organization(text) to authenticated;
grant execute on function public.inventory_add_organization_member(uuid, text) to authenticated;

-- Return RPCs write several inventory tables atomically. They must bypass the
-- caller's table RLS after organization membership has been verified by the
-- function's own user and organization checks.
alter function public.inventory_create_sale_return(uuid, jsonb, numeric, text, text, text, uuid) security definer;
alter function public.inventory_create_walk_in_return(uuid, integer, numeric, text, text, text, text, uuid) security definer;
