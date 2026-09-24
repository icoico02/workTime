-- Restore the organization-aware batch receipt RPC after legacy script replay.
-- Run on an existing installation with inventory_batches.sql applied.
begin;

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
  -- Purchase costs are a super-admin-only write as well as a read concern.
  if oid is null or not public.inventory_has_role(array['super_admin']) then raise exception 'Not allowed'; end if;
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

revoke all on function public.inventory_receive(uuid,integer,numeric,text,text,uuid) from public, anon;
grant execute on function public.inventory_receive(uuid,integer,numeric,text,text,uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
