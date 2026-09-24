-- Print settings and a cost-free sales-order projection.
-- Run after inventory_profit_controls.sql. Does not change orders, stock, or existing grants.

alter table public.inventory_organization_settings
  add column if not exists print_settings jsonb;

create or replace function public.inventory_print_settings(p_settings jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  org uuid := public.inventory_current_organization_id();
  saved jsonb;
begin
  if auth.uid() is null or org is null then raise exception 'Not allowed'; end if;
  if p_settings is not null then
    if not public.inventory_has_role(array['super_admin']) then raise exception 'Not allowed'; end if;
    if jsonb_typeof(p_settings) <> 'object' then raise exception 'Invalid settings'; end if;
    if coalesce((p_settings->>'margin_mm')::numeric, 4) not between 0 and 20
      or coalesce((p_settings->>'font_size_pt')::numeric, 9) not between 7 and 14
      or coalesce((p_settings->>'rows_per_page')::numeric, 8) not between 1 and 40
      or coalesce(p_settings->>'default_paper', 'continuous-2') not in ('continuous-1','continuous-2','continuous-3','a4')
      or coalesce(p_settings->>'default_template', 'standard') not in ('standard','compact','a4')
    then raise exception 'Invalid settings'; end if;
    insert into public.inventory_organization_settings(organization_id, print_settings, updated_by)
    values(org, p_settings, auth.uid())
    on conflict (organization_id) do update
      set print_settings = excluded.print_settings, updated_at = now(), updated_by = auth.uid();
  end if;
  select print_settings into saved from public.inventory_organization_settings where organization_id = org;
  return saved;
end $$;

create or replace function public.inventory_print_order(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  org uuid := public.inventory_current_organization_id();
  v_order public.inventory_orders;
  v_sales text;
  v_maker text;
  v_items jsonb;
begin
  if auth.uid() is null or org is null then raise exception 'Not allowed'; end if;
  select * into v_order from public.inventory_orders where id = p_order_id and organization_id = org;
  if not found then raise exception 'Not allowed'; end if;
  if to_regclass('public.profiles') is not null then
    if v_order.salesperson_id is not null then
      execute 'select username from public.profiles where id = $1' into v_sales using v_order.salesperson_id;
    end if;
    execute 'select username from public.profiles where id = $1' into v_maker using v_order.user_id;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'product_name', i.product_name,
    'sku', i.sku,
    'specification', i.specification,
    'quantity', i.quantity,
    'unit_price', i.unit_price,
    'line_total', i.line_total
  ) order by i.id), '[]'::jsonb) into v_items
  from public.inventory_order_items i where i.order_id = v_order.id;
  return jsonb_build_object(
    'order_no', v_order.order_no,
    'created_at', v_order.created_at,
    'salesperson_name', v_sales,
    'prepared_by', coalesce(v_maker, v_sales),
    'customer_name', v_order.customer_name,
    'contact_name', v_order.contact_name,
    'contact_phone', v_order.contact_phone,
    'shipping_address', v_order.shipping_address,
    'payment_method', v_order.payment_method,
    'customer_note', v_order.customer_note,
    'subtotal', v_order.subtotal,
    'discount', v_order.discount,
    'freight', v_order.freight,
    'total_amount', v_order.total_amount,
    'inventory_order_items', v_items
  );
end $$;

revoke all on function public.inventory_print_settings(jsonb) from public, anon;
revoke all on function public.inventory_print_order(uuid) from public, anon;
grant execute on function public.inventory_print_settings(jsonb) to authenticated;
grant execute on function public.inventory_print_order(uuid) to authenticated;

notify pgrst, 'reload schema';
