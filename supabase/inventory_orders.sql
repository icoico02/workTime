-- Formal order workflow for the inventory module.
-- Run after inventory.sql, inventory_returns.sql and inventory_organizations.sql.
-- Existing quick-sale and return records are retained.

create table if not exists public.inventory_customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  customer_no text not null,
  name text not null,
  contact_name text,
  phone text,
  address text,
  default_delivery_method text not null default 'pickup' check (default_delivery_method in ('pickup','local_delivery','express','logistics','other')),
  note text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, customer_no)
);

create table if not exists public.inventory_order_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  order_id uuid not null references public.inventory_orders(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash','bank_transfer','wechat','alipay','bank_card','other')),
  note text,
  created_by uuid not null references auth.users(id) on delete restrict,
  request_key uuid not null,
  created_at timestamptz not null default now(),
  unique (organization_id, request_key)
);

create table if not exists public.inventory_order_audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.inventory_organizations(id) on delete cascade,
  order_id uuid not null references public.inventory_orders(id) on delete restrict,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_organization_settings (
  organization_id uuid primary key references public.inventory_organizations(id) on delete cascade,
  store_name text,
  allow_negative_stock boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

alter table public.inventory_products add column if not exists specification text;
alter table public.inventory_orders
  add column if not exists customer_id uuid references public.inventory_customers(id) on delete set null,
  add column if not exists customer_name text,
  add column if not exists contact_name text,
  add column if not exists contact_phone text,
  add column if not exists shipping_address text,
  add column if not exists customer_note text,
  add column if not exists internal_note text,
  add column if not exists salesperson_id uuid references auth.users(id) on delete set null,
  add column if not exists fulfillment_status text not null default 'not_fulfilled',
  add column if not exists shipping_method text not null default 'pickup',
  add column if not exists shipping_status text not null default 'not_shipped',
  add column if not exists shipped_at timestamptz,
  add column if not exists carrier text,
  add column if not exists tracking_no text,
  add column if not exists shipping_note text,
  add column if not exists freight numeric(12,2) not null default 0,
  add column if not exists received_amount numeric(12,2) not null default 0,
  add column if not exists outstanding_amount numeric(12,2) not null default 0,
  add column if not exists item_discount numeric(12,2) not null default 0,
  add column if not exists confirmed_at timestamptz,
  add column if not exists fulfilled_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
  add column if not exists deleted_at timestamptz,
  add column if not exists request_key uuid;

alter table public.inventory_order_items
  add column if not exists image_url text,
  add column if not exists specification text,
  add column if not exists discount_amount numeric(12,2) not null default 0,
  add column if not exists line_subtotal numeric(12,2);

alter table public.inventory_orders drop constraint if exists inventory_orders_order_status_check;
alter table public.inventory_orders add constraint inventory_orders_order_status_check
  check (order_status in ('pending_confirmation','pending_fulfillment','pending_shipment','shipped','completed','cancelled'));
alter table public.inventory_orders drop constraint if exists inventory_orders_payment_status_check;
alter table public.inventory_orders add constraint inventory_orders_payment_status_check
  check (payment_status in ('unpaid','partially_paid','paid','partially_refunded','refunded'));
alter table public.inventory_orders add constraint inventory_orders_fulfillment_status_check
  check (fulfillment_status in ('not_fulfilled','fulfilled'));
alter table public.inventory_orders add constraint inventory_orders_shipping_method_check
  check (shipping_method in ('pickup','local_delivery','express','logistics','other'));
alter table public.inventory_orders add constraint inventory_orders_shipping_status_check
  check (shipping_status in ('not_shipped','shipped','delivered'));
create unique index if not exists inventory_orders_request_key_idx on public.inventory_orders(organization_id, request_key) where request_key is not null;
create index if not exists inventory_customers_org_name_idx on public.inventory_customers(organization_id, name);
create index if not exists inventory_order_payments_order_idx on public.inventory_order_payments(order_id, created_at desc);
create index if not exists inventory_order_audit_order_idx on public.inventory_order_audit_logs(order_id, created_at desc);

-- Old completed orders remain completed. New orders use the explicit lifecycle.
update public.inventory_orders
set order_status = 'completed'
where order_status not in ('pending_confirmation','pending_fulfillment','pending_shipment','shipped','completed','cancelled');

create or replace function public.inventory_order_payment_status(p_total numeric, p_received numeric)
returns text language sql immutable as $$
  select case
    when p_received <= 0 then 'unpaid'
    when p_received < p_total then 'partially_paid'
    else 'paid'
  end
$$;

create or replace function public.inventory_create_order(
  p_items jsonb,
  p_customer jsonb default '{}'::jsonb,
  p_payment_method text default 'cash',
  p_initial_received numeric default 0,
  p_discount numeric default 0,
  p_freight numeric default 0,
  p_shipping_method text default 'pickup',
  p_customer_note text default null,
  p_internal_note text default null,
  p_request_key uuid default gen_random_uuid()
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.inventory_current_organization_id();
  v_order_id uuid;
  v_customer_id uuid;
  v_product public.inventory_products;
  v_item jsonb;
  v_quantity integer;
  v_price numeric;
  v_line_discount numeric;
  v_subtotal numeric := 0;
  v_cost numeric := 0;
  v_total numeric;
  v_received numeric := greatest(coalesce(p_initial_received, 0), 0);
  v_customer_no text;
  v_order_no text;
begin
  if v_org is null or not public.inventory_has_role(array['super_admin','admin','salesperson']) then raise exception 'Not allowed'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Order items are required'; end if;
  if p_discount < 0 or p_freight < 0 or p_payment_method not in ('cash','bank_transfer','wechat','alipay','bank_card','other') or p_shipping_method not in ('pickup','local_delivery','express','logistics','other') then raise exception 'Invalid order values'; end if;

  select id into v_order_id from public.inventory_orders where organization_id = v_org and request_key = p_request_key;
  if v_order_id is not null then return v_order_id; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;
    v_line_discount := greatest(coalesce((v_item->>'discount_amount')::numeric, 0), 0);
    if v_quantity <= 0 or v_price < 0 or v_line_discount > v_quantity * v_price then raise exception 'Invalid order item'; end if;
    select * into v_product from public.inventory_products where id = (v_item->>'product_id')::uuid and organization_id = v_org for update;
    if not found then raise exception 'Product not found'; end if;
    v_subtotal := v_subtotal + v_quantity * v_price - v_line_discount;
    v_cost := v_cost + v_quantity * v_product.cost_price;
  end loop;

  if coalesce(nullif(trim(p_customer->>'name'), ''), '') <> '' then
    v_customer_id := nullif(p_customer->>'id', '')::uuid;
    if v_customer_id is null then
      v_customer_no := 'C' || to_char(current_date, 'YYYYMMDD') || lpad((select (count(*) + 1)::text from public.inventory_customers where organization_id = v_org), 4, '0');
      insert into public.inventory_customers(organization_id, customer_no, name, contact_name, phone, address, default_delivery_method, note, created_by)
      values(v_org, v_customer_no, trim(p_customer->>'name'), nullif(trim(p_customer->>'contact_name'), ''), nullif(trim(p_customer->>'phone'), ''), nullif(trim(p_customer->>'address'), ''), p_shipping_method, nullif(trim(p_customer->>'note'), ''), auth.uid())
      returning id into v_customer_id;
    end if;
  end if;

  v_total := greatest(v_subtotal - p_discount, 0) + p_freight;
  if v_received > v_total then raise exception 'Received amount exceeds total'; end if;
  v_order_no := public.inventory_next_no('SO');
  insert into public.inventory_orders(
    user_id, organization_id, order_no, request_key, payment_method, subtotal, discount, item_discount, total_amount, total_cost, total_profit, net_sales, net_profit,
    order_status, payment_status, return_status, customer_id, customer_name, contact_name, contact_phone, shipping_address, customer_note, internal_note, salesperson_id,
    freight, received_amount, outstanding_amount, shipping_method, note
  ) values (
    auth.uid(), v_org, v_order_no, p_request_key, p_payment_method, v_subtotal + p_discount, p_discount, 0, v_total, v_cost, v_total - v_cost, v_total, v_total - v_cost,
    'pending_confirmation', public.inventory_order_payment_status(v_total, v_received), 'none', v_customer_id, nullif(trim(p_customer->>'name'), ''), nullif(trim(p_customer->>'contact_name'), ''), nullif(trim(p_customer->>'phone'), ''), nullif(trim(p_customer->>'address'), ''), p_customer_note, p_internal_note, auth.uid(),
    p_freight, v_received, v_total - v_received, p_shipping_method, p_internal_note
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := (v_item->>'quantity')::integer;
    v_price := (v_item->>'unit_price')::numeric;
    v_line_discount := greatest(coalesce((v_item->>'discount_amount')::numeric, 0), 0);
    select * into v_product from public.inventory_products where id = (v_item->>'product_id')::uuid and organization_id = v_org;
    insert into public.inventory_order_items(order_id, product_id, product_name, sku, image_url, specification, quantity, unit_price, unit_cost, discount_amount, line_subtotal, line_total, line_profit)
    values(v_order_id, v_product.id, v_product.name, v_product.sku, v_product.image_url, v_product.specification, v_quantity, v_price, v_product.cost_price, v_line_discount, v_quantity * v_price, v_quantity * v_price - v_line_discount, (v_quantity * v_price - v_line_discount) - v_quantity * v_product.cost_price);
  end loop;
  if v_received > 0 then insert into public.inventory_order_payments(organization_id, order_id, amount, payment_method, created_by, request_key) values(v_org, v_order_id, v_received, p_payment_method, auth.uid(), p_request_key); end if;
  insert into public.inventory_order_audit_logs(organization_id, order_id, action, after_data, created_by) values(v_org, v_order_id, 'created', jsonb_build_object('order_status','pending_confirmation'), auth.uid());
  return v_order_id;
end $$;

create or replace function public.inventory_save_product(
  p_product_id uuid default null,
  p_name text default null,
  p_sku text default null,
  p_category text default '未分类',
  p_image_url text default null,
  p_specification text default null,
  p_sale_price numeric default 0,
  p_cost_price numeric default 0,
  p_stock integer default 0,
  p_low_stock_threshold integer default 0
)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.inventory_current_organization_id(); v_id uuid;
begin
  if v_org is null or not public.inventory_has_role(array['super_admin','admin']) then raise exception 'Not allowed'; end if;
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_sku), '') = '' or p_sale_price < 0 or p_cost_price < 0 or p_stock < 0 or p_low_stock_threshold < 0 then raise exception 'Invalid product'; end if;
  if p_product_id is null then
    insert into public.inventory_products(user_id, organization_id, name, sku, category, image_url, specification, sale_price, cost_price, stock, low_stock_threshold)
    values(auth.uid(), v_org, trim(p_name), trim(p_sku), coalesce(nullif(trim(p_category), ''), '未分类'), nullif(trim(p_image_url), ''), nullif(trim(p_specification), ''), p_sale_price, p_cost_price, p_stock, p_low_stock_threshold)
    returning id into v_id;
  else
    update public.inventory_products set name = trim(p_name), sku = trim(p_sku), category = coalesce(nullif(trim(p_category), ''), '未分类'), image_url = nullif(trim(p_image_url), ''), specification = nullif(trim(p_specification), ''), sale_price = p_sale_price, cost_price = p_cost_price, low_stock_threshold = p_low_stock_threshold, updated_at = now()
    where id = p_product_id and organization_id = v_org
    returning id into v_id;
    if v_id is null then raise exception 'Product not found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.inventory_confirm_order_fulfillment(p_order_id uuid, p_request_key uuid default gen_random_uuid())
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.inventory_current_organization_id();
  v_order public.inventory_orders;
  v_item public.inventory_order_items;
  v_product public.inventory_products;
  v_allow_negative boolean := false;
begin
  if v_org is null or not public.inventory_has_role(array['super_admin','admin','warehouse']) then raise exception 'Not allowed'; end if;
  if exists(select 1 from public.inventory_order_audit_logs where organization_id = v_org and order_id = p_order_id and action = 'fulfilled:' || p_request_key::text) then return; end if;
  select * into v_order from public.inventory_orders where id = p_order_id and organization_id = v_org for update;
  if not found or v_order.order_status not in ('pending_confirmation','pending_fulfillment') then raise exception 'Order cannot be fulfilled'; end if;
  select allow_negative_stock into v_allow_negative from public.inventory_organization_settings where organization_id = v_org;
  for v_item in select * from public.inventory_order_items where order_id = p_order_id loop
    select * into v_product from public.inventory_products where id = v_item.product_id and organization_id = v_org for update;
    if not found or (not coalesce(v_allow_negative, false) and v_product.stock < v_item.quantity) then raise exception 'Insufficient stock: %', v_item.product_name; end if;
  end loop;
  for v_item in select * from public.inventory_order_items where order_id = p_order_id loop
    select * into v_product from public.inventory_products where id = v_item.product_id and organization_id = v_org for update;
    update public.inventory_products set stock = stock - v_item.quantity, updated_at = now() where id = v_product.id;
    insert into public.inventory_movements(user_id, organization_id, product_id, order_id, operation_type, quantity, unit_cost, unit_price, total_amount, note, before_sellable_stock, after_sellable_stock, business_type, business_id, business_no, operation_key)
    values(auth.uid(), v_org, v_product.id, v_order.id, 'sale', -v_item.quantity, v_item.unit_cost, v_item.unit_price, v_item.line_total, '订单确认出库', v_product.stock, v_product.stock - v_item.quantity, 'sale', v_order.id, v_order.order_no, p_request_key);
  end loop;
  update public.inventory_orders set order_status = case when shipping_method = 'pickup' then 'completed' else 'pending_shipment' end, fulfillment_status = 'fulfilled', fulfilled_at = now(), completed_at = case when shipping_method = 'pickup' then now() else completed_at end where id = v_order.id;
  insert into public.inventory_order_audit_logs(organization_id, order_id, action, before_data, after_data, created_by) values(v_org, v_order.id, 'fulfilled:' || p_request_key::text, jsonb_build_object('order_status',v_order.order_status), jsonb_build_object('fulfillment_status','fulfilled'), auth.uid());
end $$;

create or replace function public.inventory_record_order_payment(p_order_id uuid, p_amount numeric, p_payment_method text, p_note text default null, p_request_key uuid default gen_random_uuid())
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.inventory_current_organization_id(); v_order public.inventory_orders; v_payment_id uuid; v_received numeric;
begin
  if v_org is null or not public.inventory_has_role(array['super_admin','admin','salesperson']) then raise exception 'Not allowed'; end if;
  select id into v_payment_id from public.inventory_order_payments where organization_id = v_org and request_key = p_request_key; if v_payment_id is not null then return v_payment_id; end if;
  if p_amount <= 0 or p_payment_method not in ('cash','bank_transfer','wechat','alipay','bank_card','other') then raise exception 'Invalid payment'; end if;
  select * into v_order from public.inventory_orders where id = p_order_id and organization_id = v_org for update;
  if not found or v_order.order_status = 'cancelled' or v_order.received_amount + p_amount > v_order.total_amount then raise exception 'Payment cannot be recorded'; end if;
  insert into public.inventory_order_payments(organization_id, order_id, amount, payment_method, note, created_by, request_key) values(v_org, p_order_id, p_amount, p_payment_method, p_note, auth.uid(), p_request_key) returning id into v_payment_id;
  v_received := v_order.received_amount + p_amount;
  update public.inventory_orders set received_amount = v_received, outstanding_amount = total_amount - v_received, payment_status = public.inventory_order_payment_status(total_amount, v_received) where id = p_order_id;
  insert into public.inventory_order_audit_logs(organization_id, order_id, action, after_data, created_by) values(v_org, p_order_id, 'payment_recorded', jsonb_build_object('amount',p_amount), auth.uid());
  return v_payment_id;
end $$;

create or replace function public.inventory_cancel_order(p_order_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.inventory_current_organization_id(); v_order public.inventory_orders;
begin
  if v_org is null or not public.inventory_has_role(array['super_admin','admin']) then raise exception 'Not allowed'; end if;
  select * into v_order from public.inventory_orders where id = p_order_id and organization_id = v_org for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.fulfillment_status = 'fulfilled' then raise exception 'Fulfilled orders must use the return workflow'; end if;
  if v_order.order_status = 'cancelled' then return; end if;
  update public.inventory_orders set order_status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), internal_note = concat_ws(E'\n', internal_note, '取消原因：' || coalesce(nullif(trim(p_reason), ''), '未填写')) where id = p_order_id;
  insert into public.inventory_order_audit_logs(organization_id, order_id, action, before_data, after_data, created_by) values(v_org, p_order_id, 'cancelled', jsonb_build_object('order_status',v_order.order_status), jsonb_build_object('order_status','cancelled','reason',p_reason), auth.uid());
end $$;

alter table public.inventory_customers enable row level security;
alter table public.inventory_order_payments enable row level security;
alter table public.inventory_order_audit_logs enable row level security;
alter table public.inventory_organization_settings enable row level security;
drop policy if exists "Inventory members view customers" on public.inventory_customers;
drop policy if exists "Inventory members view payments" on public.inventory_order_payments;
drop policy if exists "Inventory members view audits" on public.inventory_order_audit_logs;
drop policy if exists "Inventory admins manage settings" on public.inventory_organization_settings;
create policy "Inventory members view customers" on public.inventory_customers for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin','admin','salesperson','warehouse']));
create policy "Inventory members view payments" on public.inventory_order_payments for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin','admin','salesperson']));
create policy "Inventory members view audits" on public.inventory_order_audit_logs for select to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin']));
create policy "Inventory admins manage settings" on public.inventory_organization_settings for all to authenticated using (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin'])) with check (organization_id = public.inventory_current_organization_id() and public.inventory_has_role(array['super_admin']));

grant execute on function public.inventory_create_order(jsonb,jsonb,text,numeric,numeric,numeric,text,text,text,uuid) to authenticated;
grant execute on function public.inventory_save_product(uuid,text,text,text,text,text,numeric,numeric,integer,integer) to authenticated;
grant execute on function public.inventory_confirm_order_fulfillment(uuid,uuid) to authenticated;
grant execute on function public.inventory_record_order_payment(uuid,numeric,text,text,uuid) to authenticated;
grant execute on function public.inventory_cancel_order(uuid,text) to authenticated;
