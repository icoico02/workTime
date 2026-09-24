-- Deduplicate customers that share the same name + address within an organization.
-- Safe to run more than once. Replaces only the customer-matching part of order creation.

create or replace function public.inventory_normalize_customer_text(p_value text)
returns text language sql immutable as $$
  select lower(trim(coalesce(p_value, '')))
$$;

create or replace function public.inventory_find_customer(
  p_organization_id uuid,
  p_name text,
  p_address text default null
)
returns uuid language plpgsql stable security invoker set search_path = public as $$
declare
  v_id uuid;
  v_name text := public.inventory_normalize_customer_text(p_name);
  v_address text := public.inventory_normalize_customer_text(p_address);
begin
  if v_name = '' then return null; end if;
  select id into v_id
  from public.inventory_customers
  where organization_id = p_organization_id
    and public.inventory_normalize_customer_text(name) = v_name
    and public.inventory_normalize_customer_text(address) = v_address
  order by updated_at desc nulls last, created_at desc
  limit 1;
  return v_id;
end $$;

-- Merge existing duplicates: keep the newest row, retarget orders, delete the rest.
do $$
declare
  r record;
  keep_id uuid;
  dup_ids uuid[];
begin
  for r in
    select organization_id,
           public.inventory_normalize_customer_text(name) as norm_name,
           public.inventory_normalize_customer_text(address) as norm_address
    from public.inventory_customers
    group by 1, 2, 3
    having count(*) > 1
  loop
    select array_agg(id order by updated_at desc nulls last, created_at desc)
      into dup_ids
    from public.inventory_customers
    where organization_id = r.organization_id
      and public.inventory_normalize_customer_text(name) = r.norm_name
      and public.inventory_normalize_customer_text(address) = r.norm_address;
    keep_id := dup_ids[1];
    update public.inventory_orders
      set customer_id = keep_id
      where customer_id = any(dup_ids[2:]);
    delete from public.inventory_customers where id = any(dup_ids[2:]);
  end loop;
end $$;

create unique index if not exists inventory_customers_org_name_address_uidx
  on public.inventory_customers (
    organization_id,
    (public.inventory_normalize_customer_text(name)),
    (public.inventory_normalize_customer_text(address))
  );

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
  v_customer_name text := nullif(trim(p_customer->>'name'), '');
  v_customer_address text := nullif(trim(p_customer->>'address'), '');
  v_contact_name text := nullif(trim(p_customer->>'contact_name'), '');
  v_phone text := nullif(trim(p_customer->>'phone'), '');
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

  if v_customer_name is not null then
    v_customer_id := nullif(p_customer->>'id', '')::uuid;
    if v_customer_id is not null then
      if not exists (
        select 1 from public.inventory_customers
        where id = v_customer_id and organization_id = v_org
      ) then
        v_customer_id := null;
      end if;
    end if;
    if v_customer_id is null then
      v_customer_id := public.inventory_find_customer(v_org, v_customer_name, v_customer_address);
    end if;
    if v_customer_id is null then
      v_customer_no := 'C' || to_char(current_date, 'YYYYMMDD') || lpad((select (count(*) + 1)::text from public.inventory_customers where organization_id = v_org), 4, '0');
      insert into public.inventory_customers(organization_id, customer_no, name, contact_name, phone, address, default_delivery_method, note, created_by)
      values(v_org, v_customer_no, v_customer_name, v_contact_name, v_phone, v_customer_address, p_shipping_method, nullif(trim(p_customer->>'note'), ''), auth.uid())
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
    'pending_confirmation', public.inventory_order_payment_status(v_total, v_received), 'none', v_customer_id, v_customer_name, v_contact_name, v_phone, v_customer_address, p_customer_note, p_internal_note, auth.uid(),
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

grant execute on function public.inventory_normalize_customer_text(text) to authenticated;
grant execute on function public.inventory_find_customer(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
