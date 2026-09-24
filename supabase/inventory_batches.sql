-- Supplier, purchase-batch and FIFO cost allocation.
-- Run after inventory.sql, inventory_returns.sql, inventory_organizations.sql and inventory_orders.sql.

create table if not exists public.inventory_suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  name text not null,
  contact_name text,
  phone text,
  address text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

create table if not exists public.inventory_product_suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  product_id uuid not null references public.inventory_products(id) on delete restrict,
  supplier_id uuid not null references public.inventory_suppliers(id) on delete restrict,
  supplier_sku text,
  reference_price numeric(12,2),
  latest_price numeric(12,2),
  latest_purchase_at timestamptz,
  is_default boolean not null default false,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, product_id, supplier_id)
);

create table if not exists public.inventory_purchase_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  product_id uuid not null references public.inventory_products(id) on delete restrict,
  supplier_id uuid not null references public.inventory_suppliers(id) on delete restrict,
  inbound_movement_id uuid unique references public.inventory_movements(id) on delete restrict,
  batch_no text not null,
  received_quantity integer not null check (received_quantity > 0),
  remaining_quantity integer not null check (remaining_quantity >= 0 and remaining_quantity <= received_quantity),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),
  received_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id) on delete restrict,
  note text,
  unique (organization_id, batch_no)
);

create table if not exists public.inventory_order_item_batch_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  order_item_id uuid not null references public.inventory_order_items(id) on delete restrict,
  batch_id uuid not null references public.inventory_purchase_batches(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),
  total_cost numeric(12,2) not null check (total_cost >= 0),
  created_at timestamptz not null default now(),
  unique (order_item_id, batch_id)
);

alter table public.inventory_order_items add column if not exists source_supplier_id uuid references public.inventory_suppliers(id) on delete set null;
alter table public.inventory_order_items add column if not exists actual_cost numeric(12,2);
create index if not exists inventory_batches_product_fifo_idx on public.inventory_purchase_batches(organization_id, product_id, supplier_id, received_at, id) where remaining_quantity > 0;
create index if not exists inventory_batch_allocations_item_idx on public.inventory_order_item_batch_allocations(order_item_id);

-- Existing on-hand inventory becomes a traceable opening batch. It preserves
-- the recorded historical cost while all new stock gets its own purchase batch.
insert into public.inventory_suppliers(organization_id, name, note)
select distinct p.organization_id, '历史期初库存', '系统迁移生成'
from public.inventory_products p
where p.organization_id is not null and p.stock > 0
on conflict (organization_id, name) do nothing;

insert into public.inventory_purchase_batches(organization_id, product_id, supplier_id, batch_no, received_quantity, remaining_quantity, unit_cost, received_at, created_by, note)
select p.organization_id, p.id, s.id, 'OB' || to_char(current_date, 'YYYYMMDD') || substr(replace(p.id::text, '-', ''), 1, 8), p.stock, p.stock, p.cost_price, p.created_at, p.user_id, '历史期初库存'
from public.inventory_products p
join public.inventory_suppliers s on s.organization_id = p.organization_id and s.name = '历史期初库存'
where p.organization_id is not null and p.stock > 0
  and not exists (select 1 from public.inventory_purchase_batches b where b.organization_id = p.organization_id and b.product_id = p.id);

create or replace function public.inventory_available_sources(p_product_id uuid)
returns table(supplier_id uuid, supplier_name text, available_quantity integer)
language sql stable security definer set search_path = public as $$
  select b.supplier_id, s.name, sum(b.remaining_quantity)::integer
  from public.inventory_purchase_batches b
  join public.inventory_suppliers s on s.id = b.supplier_id
  where b.organization_id = public.inventory_current_organization_id()
    and b.product_id = p_product_id
    and b.remaining_quantity > 0
  group by b.supplier_id, s.name
  order by s.name
$$;

create or replace function public.inventory_receive(
  p_product_id uuid,
  p_quantity integer,
  p_unit_cost numeric,
  p_supplier text default null,
  p_note text default null,
  p_request_key uuid default gen_random_uuid()
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p public.inventory_products;
  oid uuid := public.inventory_current_organization_id();
  mid uuid;
  sid uuid;
  doc_no text;
  batch_no text;
begin
  if oid is null or not public.inventory_has_role(array['super_admin','admin','warehouse']) then raise exception 'Not allowed'; end if;
  if coalesce(trim(p_supplier), '') = '' then raise exception 'Supplier is required'; end if;
  select id into mid from public.inventory_movements where organization_id = oid and operation_key = p_request_key limit 1;
  if mid is not null then return mid; end if;
  if p_quantity <= 0 or p_unit_cost < 0 then raise exception 'Invalid inbound values'; end if;
  select * into p from public.inventory_products where id = p_product_id and organization_id = oid for update;
  if not found then raise exception 'Product not found'; end if;
  insert into public.inventory_suppliers(organization_id, name) values(oid, trim(p_supplier))
  on conflict(organization_id, name) do update set updated_at = now()
  returning id into sid;
  insert into public.inventory_product_suppliers(organization_id, product_id, supplier_id, latest_price, latest_purchase_at)
  values(oid, p.id, sid, p_unit_cost, now())
  on conflict(organization_id, product_id, supplier_id) do update set latest_price = excluded.latest_price, latest_purchase_at = excluded.latest_purchase_at, updated_at = now();
  doc_no := public.inventory_next_no('PO');
  update public.inventory_products set stock = stock + p_quantity, updated_at = now() where id = p.id;
  insert into public.inventory_movements(user_id, organization_id, product_id, operation_type, quantity, unit_cost, total_amount, supplier, note, before_sellable_stock, after_sellable_stock, business_type, business_id, business_no, operation_key)
  values(auth.uid(), oid, p.id, 'inbound', p_quantity, p_unit_cost, p_quantity * p_unit_cost, trim(p_supplier), p_note, p.stock, p.stock + p_quantity, 'purchase_inbound', gen_random_uuid(), doc_no, p_request_key)
  returning id into mid;
  batch_no := 'PB' || to_char(current_date, 'YYYYMMDD') || substr(replace(mid::text, '-', ''), 1, 8);
  insert into public.inventory_purchase_batches(organization_id, product_id, supplier_id, inbound_movement_id, batch_no, received_quantity, remaining_quantity, unit_cost, created_by, note)
  values(oid, p.id, sid, mid, batch_no, p_quantity, p_quantity, p_unit_cost, auth.uid(), p_note);
  return mid;
end $$;

create or replace function public.inventory_confirm_order_fulfillment(p_order_id uuid, p_request_key uuid default gen_random_uuid())
returns void language plpgsql security definer set search_path = public as $$
declare
  oid uuid := public.inventory_current_organization_id();
  o public.inventory_orders;
  i public.inventory_order_items;
  p public.inventory_products;
  b public.inventory_purchase_batches;
  remaining integer;
  taken integer;
  item_cost numeric;
  order_cost numeric := 0;
begin
  if oid is null or not public.inventory_has_role(array['super_admin','admin','warehouse']) then raise exception 'Not allowed'; end if;
  if exists(select 1 from public.inventory_order_audit_logs where organization_id = oid and order_id = p_order_id and action = 'fulfilled:' || p_request_key::text) then return; end if;
  select * into o from public.inventory_orders where id = p_order_id and organization_id = oid for update;
  if not found or o.order_status not in ('pending_confirmation','pending_fulfillment') then raise exception 'Order cannot be fulfilled'; end if;
  for i in select * from public.inventory_order_items where order_id = p_order_id order by id loop
    select * into p from public.inventory_products where id = i.product_id and organization_id = oid for update;
    if not found or p.stock < i.quantity then raise exception 'Insufficient stock: %', i.product_name; end if;
    remaining := i.quantity;
    item_cost := 0;
    for b in select * from public.inventory_purchase_batches where organization_id = oid and product_id = i.product_id and remaining_quantity > 0 and (i.source_supplier_id is null or supplier_id = i.source_supplier_id) order by received_at, id for update loop
      exit when remaining = 0;
      taken := least(remaining, b.remaining_quantity);
      update public.inventory_purchase_batches set remaining_quantity = remaining_quantity - taken where id = b.id;
      insert into public.inventory_order_item_batch_allocations(organization_id, order_item_id, batch_id, quantity, unit_cost, total_cost)
      values(oid, i.id, b.id, taken, b.unit_cost, taken * b.unit_cost);
      item_cost := item_cost + taken * b.unit_cost;
      remaining := remaining - taken;
    end loop;
    if remaining > 0 then raise exception 'Batch stock is insufficient: %', i.product_name; end if;
    update public.inventory_order_items set actual_cost = item_cost, unit_cost = item_cost / i.quantity, line_profit = line_total - item_cost where id = i.id;
    update public.inventory_products set stock = stock - i.quantity, updated_at = now() where id = p.id;
    insert into public.inventory_movements(user_id, organization_id, product_id, order_id, operation_type, quantity, unit_cost, unit_price, total_amount, note, before_sellable_stock, after_sellable_stock, business_type, business_id, business_no, operation_key)
    values(auth.uid(), oid, p.id, o.id, 'sale', -i.quantity, item_cost / i.quantity, i.unit_price, i.line_total, '订单确认出库', p.stock, p.stock - i.quantity, 'sale', o.id, o.order_no, p_request_key);
    order_cost := order_cost + item_cost;
  end loop;
  update public.inventory_orders set total_cost = order_cost, total_profit = total_amount - order_cost, net_profit = net_sales - order_cost, order_status = case when shipping_method = 'pickup' then 'completed' else 'pending_shipment' end, fulfillment_status = 'fulfilled', fulfilled_at = now(), completed_at = case when shipping_method = 'pickup' then now() else completed_at end where id = o.id;
  insert into public.inventory_order_audit_logs(organization_id, order_id, action, before_data, after_data, created_by) values(oid, o.id, 'fulfilled:' || p_request_key::text, jsonb_build_object('order_status',o.order_status), jsonb_build_object('fulfillment_status','fulfilled'), auth.uid());
end $$;

create or replace function public.inventory_assign_order_sources(p_order_id uuid, p_sources jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare oid uuid := public.inventory_current_organization_id(); o public.inventory_orders; source jsonb; item_id uuid; v_supplier_id uuid;
begin
  if oid is null or not public.inventory_has_role(array['super_admin','admin','salesperson']) then raise exception 'Not allowed'; end if;
  select * into o from public.inventory_orders where id = p_order_id and organization_id = oid for update;
  if not found or o.order_status <> 'pending_confirmation' then raise exception 'Order source cannot be changed'; end if;
  if jsonb_typeof(p_sources) <> 'array' then raise exception 'Invalid sources'; end if;
  for source in select value from jsonb_array_elements(p_sources) loop
    item_id := nullif(source->>'order_item_id', '')::uuid;
    v_supplier_id := nullif(source->>'supplier_id', '')::uuid;
    if item_id is null then raise exception 'Order item is required'; end if;
    if v_supplier_id is not null and not exists(select 1 from public.inventory_purchase_batches b where b.organization_id = oid and b.supplier_id = v_supplier_id and b.remaining_quantity > 0 and b.product_id = (select product_id from public.inventory_order_items where id = item_id and order_id = p_order_id)) then raise exception 'Supplier has no available batch stock'; end if;
    update public.inventory_order_items set source_supplier_id = v_supplier_id where id = item_id and order_id = p_order_id;
  end loop;
end $$;

alter table public.inventory_suppliers enable row level security;
alter table public.inventory_product_suppliers enable row level security;
alter table public.inventory_purchase_batches enable row level security;
alter table public.inventory_order_item_batch_allocations enable row level security;
drop policy if exists "Super admins view supplier costs" on public.inventory_suppliers;
drop policy if exists "Super admins view product supplier costs" on public.inventory_product_suppliers;
drop policy if exists "Super admins view purchase batches" on public.inventory_purchase_batches;
drop policy if exists "Super admins view batch allocations" on public.inventory_order_item_batch_allocations;
create policy "Super admins view supplier costs" on public.inventory_suppliers for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin']));
create policy "Super admins view product supplier costs" on public.inventory_product_suppliers for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin']));
create policy "Super admins view purchase batches" on public.inventory_purchase_batches for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin']));
create policy "Super admins view batch allocations" on public.inventory_order_item_batch_allocations for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin']));

grant execute on function public.inventory_available_sources(uuid) to authenticated;
grant execute on function public.inventory_receive(uuid,integer,numeric,text,text,uuid) to authenticated;
grant execute on function public.inventory_confirm_order_fulfillment(uuid,uuid) to authenticated;
grant execute on function public.inventory_assign_order_sources(uuid,jsonb) to authenticated;
