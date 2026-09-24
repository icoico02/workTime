-- Run LAST, after inventory_batches.sql. Apply as one transaction.
begin;

alter table public.inventory_organization_settings
  add column if not exists minimum_unit_profit numeric(12,2) not null default 10 check (minimum_unit_profit >= 0),
  add column if not exists minimum_margin numeric(6,2) not null default 15 check (minimum_margin between 0 and 100),
  add column if not exists amount_warning_enabled boolean not null default true,
  add column if not exists margin_warning_enabled boolean not null default true;

-- Restrictive policies also apply when an older permissive policy still exists.
do $$
declare t text;
begin
  foreach t in array array['inventory_products','inventory_orders','inventory_order_items',
    'inventory_movements','inventory_return_items','inventory_purchase_batches',
    'inventory_product_suppliers','inventory_order_item_batch_allocations',
    'inventory_order_audit_logs','inventory_organization_settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists inventory_cost_access_guard on public.%I', t);
    execute format('create policy inventory_cost_access_guard on public.%I as restrictive for all to public using (public.inventory_has_role(array[''super_admin''])) with check (public.inventory_has_role(array[''super_admin'']))', t);
  end loop;
end $$;

-- Whitelist projection: new columns are never automatically exposed to members.
create or replace function public.inventory_public_fields(p_row jsonb, p_keys text[])
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  from jsonb_each(p_row) where key = any(p_keys)
$$;

create or replace function public.inventory_read(p_resource text, p_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  org uuid := public.inventory_current_organization_id();
  privileged boolean := public.inventory_has_role(array['super_admin']);
  team boolean := public.inventory_has_role(array['super_admin','admin','warehouse']);
  result jsonb;
begin
  if auth.uid() is null or org is null then raise exception 'Not allowed'; end if;
  if p_resource = 'products' then
    select coalesce(jsonb_agg(case when privileged then to_jsonb(p) else
      public.inventory_public_fields(to_jsonb(p), array['id','name','sku','image_url','specification','category','sale_price','stock','pending_stock','damaged_quantity','low_stock_threshold','created_at','updated_at']) end order by p.updated_at desc), '[]') into result
    from public.inventory_products p where p.organization_id = org and (p_id is null or p.id = p_id);
  elsif p_resource = 'orders' then
    select coalesce(jsonb_agg((case when privileged then to_jsonb(o) else
      public.inventory_public_fields(to_jsonb(o), array['id','order_no','user_id','salesperson_id','customer_name','contact_name','contact_phone','shipping_address','shipping_method','shipping_status','shipping_note','carrier','tracking_no','customer_note','order_status','payment_status','fulfillment_status','return_status','subtotal','discount','freight','total_amount','received_amount','outstanding_amount','refunded_amount','net_sales','created_at','fulfilled_at']) end)
      || jsonb_build_object('inventory_order_items', coalesce((
        select jsonb_agg((case when privileged then to_jsonb(i) else public.inventory_public_fields(to_jsonb(i), array['id','order_id','product_id','product_name','sku','specification','image_url','quantity','unit_price','line_total','discount_amount','source_supplier_id']) end)
          || jsonb_build_object('inventory_suppliers', jsonb_build_object('name', s.name)) order by i.id)
        from public.inventory_order_items i left join public.inventory_suppliers s on s.id = i.source_supplier_id and s.organization_id = org where i.order_id = o.id
      ), '[]'::jsonb)) order by o.created_at desc), '[]') into result
    from (select * from public.inventory_orders where organization_id = org and (p_id is null or id = p_id)
      order by created_at desc limit 500) o;
  elsif p_resource = 'returns' then
    select coalesce(jsonb_agg(public.inventory_public_fields(to_jsonb(r), array['id','order_id','return_no','refund_amount','refund_method','reason','note','created_at'])
      || jsonb_build_object('inventory_return_items', coalesce((select jsonb_agg(case when privileged then to_jsonb(i) else public.inventory_public_fields(to_jsonb(i), array['id','order_item_id','product_id','product_name','quantity','unit_price','item_condition']) end) from public.inventory_return_items i where i.return_id = r.id), '[]'::jsonb)) order by r.created_at desc), '[]') into result
    from public.inventory_returns r where r.organization_id = org and (p_id is null or r.order_id = p_id);
  elsif p_resource = 'movements' then
    select coalesce(jsonb_agg((case when privileged then to_jsonb(m) else
      public.inventory_public_fields(to_jsonb(m), array['id','product_id','order_id','operation_type','quantity','supplier','before_sellable_stock','after_sellable_stock','before_pending_stock','after_pending_stock','business_type','business_id','business_no','original_business_no','created_at'])
      || case when m.operation_type = 'sale' then jsonb_build_object('unit_price', m.unit_price, 'total_amount', m.total_amount) else '{}'::jsonb end end)
      || jsonb_build_object('inventory_products', jsonb_build_object('name', p.name, 'sku', p.sku)) order by m.created_at desc), '[]') into result
    from (select * from public.inventory_movements where organization_id = org and (p_id is null or id = p_id) order by created_at desc limit 500) m
    left join public.inventory_products p on p.id = m.product_id and p.organization_id = org;
  else raise exception 'Unknown inventory resource';
  end if;
  return result;
end $$;

create or replace function public.inventory_profit_settings(p_settings jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare org uuid := public.inventory_current_organization_id(); result jsonb;
begin
  if auth.uid() is null or org is null or not public.inventory_has_role(array['super_admin']) then raise exception 'Not allowed'; end if;
  if p_settings is not null then
    if jsonb_typeof(p_settings) <> 'object' or not (p_settings ?& array['minimum_unit_profit','minimum_margin','amount_warning_enabled','margin_warning_enabled']) then raise exception 'Invalid settings'; end if;
    insert into public.inventory_organization_settings(organization_id, minimum_unit_profit, minimum_margin, amount_warning_enabled, margin_warning_enabled, updated_by)
    values(org, (p_settings->>'minimum_unit_profit')::numeric, (p_settings->>'minimum_margin')::numeric, (p_settings->>'amount_warning_enabled')::boolean, (p_settings->>'margin_warning_enabled')::boolean, auth.uid())
    on conflict(organization_id) do update set minimum_unit_profit = excluded.minimum_unit_profit, minimum_margin = excluded.minimum_margin,
      amount_warning_enabled = excluded.amount_warning_enabled, margin_warning_enabled = excluded.margin_warning_enabled, updated_at = now(), updated_by = auth.uid();
  end if;
  select public.inventory_public_fields(to_jsonb(s), array['minimum_unit_profit','minimum_margin','amount_warning_enabled','margin_warning_enabled','updated_at']) into result from public.inventory_organization_settings s where organization_id = org;
  return coalesce(result, '{"minimum_unit_profit":10,"minimum_margin":15,"amount_warning_enabled":true,"margin_warning_enabled":true}'::jsonb);
end $$;

revoke all on function public.inventory_read(text,uuid) from public, anon;
revoke all on function public.inventory_profit_settings(jsonb) from public, anon;
grant execute on function public.inventory_read(text,uuid) to authenticated;
grant execute on function public.inventory_profit_settings(jsonb) to authenticated;

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
  if not public.inventory_has_role(array['super_admin']) then
    if p_product_id is null then p_cost_price := 0;
    else select cost_price into p_cost_price from public.inventory_products where id = p_product_id and organization_id = v_org;
    end if;
  end if;
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

notify pgrst, 'reload schema';
commit;
