-- Incremental migration for returns, pending stock and traceable inventory.
-- Run after supabase/inventory.sql.

alter table public.inventory_products
  add column if not exists pending_stock integer not null default 0 check (pending_stock >= 0),
  add column if not exists damaged_quantity integer not null default 0 check (damaged_quantity >= 0);

alter table public.inventory_orders
  add column if not exists order_status text not null default 'completed' check (order_status in ('completed','cancelled')),
  add column if not exists payment_status text not null default 'paid' check (payment_status in ('unpaid','paid','partially_refunded','refunded')),
  add column if not exists return_status text not null default 'none' check (return_status in ('none','partial','full')),
  add column if not exists refunded_amount numeric(12,2) not null default 0 check (refunded_amount >= 0),
  add column if not exists net_sales numeric(12,2) not null default 0,
  add column if not exists net_profit numeric(12,2) not null default 0;

update public.inventory_orders
set net_sales = total_amount - refunded_amount,
    net_profit = total_profit
where net_sales = 0 and refunded_amount = 0;

alter table public.inventory_movements
  add column if not exists before_sellable_stock integer,
  add column if not exists after_sellable_stock integer,
  add column if not exists before_pending_stock integer,
  add column if not exists after_pending_stock integer,
  add column if not exists business_no text,
  add column if not exists source_movement_id uuid references public.inventory_movements(id) on delete restrict,
  add column if not exists operation_key uuid;

alter table public.inventory_movements
  add column if not exists business_type text,
  add column if not exists business_id uuid,
  add column if not exists original_business_id uuid,
  add column if not exists original_business_no text;

alter table public.inventory_movements drop constraint if exists inventory_movements_operation_type_check;
alter table public.inventory_movements add constraint inventory_movements_operation_type_check check (operation_type in (
  'inbound','sale','normal_outbound','loss','adjustment','sale_return','pending_in','pending_to_sale',
  'pending_to_loss','purchase_return','stocktake_in','stocktake_out','gift','personal_use'
));
drop index if exists public.inventory_movements_operation_key_idx;
create index if not exists inventory_movements_business_no_idx on public.inventory_movements(user_id, business_no);
create index if not exists inventory_movements_business_link_idx on public.inventory_movements(user_id, business_type, business_id);

create table if not exists public.inventory_document_counters (
  user_id uuid not null references auth.users(id) on delete cascade,
  document_date date not null,
  prefix text not null,
  last_number integer not null default 0,
  primary key (user_id, document_date, prefix)
);
alter table public.inventory_document_counters enable row level security;
drop policy if exists "Users manage own inventory document counters" on public.inventory_document_counters;
create policy "Users manage own inventory document counters"
on public.inventory_document_counters
for all
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create table if not exists public.inventory_returns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  return_no text not null unique,
  order_id uuid references public.inventory_orders(id) on delete restrict,
  is_walk_in boolean not null default false,
  refund_amount numeric(12,2) not null default 0 check (refund_amount >= 0),
  refund_method text not null check (refund_method in ('cash','wechat','alipay','bank_card','other')),
  reason text not null,
  note text,
  request_key uuid not null,
  created_at timestamptz not null default now(),
  unique(user_id, request_key),
  check ((order_id is null and is_walk_in) or (order_id is not null and not is_walk_in))
);

create table if not exists public.inventory_return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.inventory_returns(id) on delete cascade,
  order_item_id uuid references public.inventory_order_items(id) on delete restrict,
  product_id uuid not null references public.inventory_products(id) on delete restrict,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  unit_cost numeric(12,2) not null check (unit_cost >= 0),
  item_condition text not null check (item_condition in ('resellable','damaged','pending')),
  created_at timestamptz not null default now()
);
create index if not exists inventory_returns_order_idx on public.inventory_returns(order_id, created_at desc);
create index if not exists inventory_return_items_product_idx on public.inventory_return_items(product_id);

alter table public.inventory_returns enable row level security;
alter table public.inventory_return_items enable row level security;
drop policy if exists "Users manage own inventory returns" on public.inventory_returns;
drop policy if exists "Users view own return items" on public.inventory_return_items;
drop policy if exists "Users add own return items" on public.inventory_return_items;
create policy "Users manage own inventory returns" on public.inventory_returns for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "Users view own return items" on public.inventory_return_items for select to authenticated using (exists (select 1 from public.inventory_returns r where r.id = return_id and r.user_id = auth.uid()));
create policy "Users add own return items" on public.inventory_return_items for insert to authenticated with check (exists (select 1 from public.inventory_returns r where r.id = return_id and r.user_id = auth.uid()));

create or replace function public.inventory_next_no(p_prefix text)
returns text language plpgsql security invoker set search_path = public as $$
declare next_value integer; today date := current_date;
begin
  insert into inventory_document_counters(user_id, document_date, prefix, last_number)
  values(auth.uid(), today, p_prefix, 1)
  on conflict(user_id, document_date, prefix)
  do update set last_number = inventory_document_counters.last_number + 1
  returning last_number into next_value;
  return p_prefix || to_char(today, 'YYYYMMDD') || lpad(next_value::text, 4, '0');
end $$;

create or replace function public.inventory_create_sale(p_items jsonb, p_payment_method text default 'cash', p_discount numeric default 0, p_note text default null, p_request_key uuid default gen_random_uuid())
returns uuid language plpgsql security invoker set search_path = public as $$
declare item jsonb; p public.inventory_products; oid uuid; q integer; price numeric; subtotal numeric := 0; cost numeric := 0; final_total numeric; doc_no text;
begin
  select order_id into oid from inventory_movements where user_id = auth.uid() and operation_key = p_request_key limit 1;
  if oid is not null then return oid; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Sale items are required'; end if;
  if p_discount < 0 or p_payment_method not in ('cash','wechat','alipay','other') then raise exception 'Invalid order'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    q := (item->>'quantity')::integer; price := (item->>'unit_price')::numeric;
    if q <= 0 or price < 0 then raise exception 'Invalid sale item'; end if;
    select * into p from inventory_products where id = (item->>'product_id')::uuid and user_id = auth.uid() for update;
    if not found or p.stock < q then raise exception 'Insufficient stock'; end if;
    subtotal := subtotal + q * price; cost := cost + q * p.cost_price;
  end loop;
  final_total := greatest(subtotal - p_discount, 0); doc_no := inventory_next_no('SO');
  insert into inventory_orders(user_id, order_no, payment_method, subtotal, discount, total_amount, total_cost, total_profit, net_sales, net_profit, note)
  values(auth.uid(), doc_no, p_payment_method, subtotal, p_discount, final_total, cost, final_total - cost, final_total, final_total - cost, p_note) returning id into oid;
  for item in select value from jsonb_array_elements(p_items) loop
    q := (item->>'quantity')::integer; price := (item->>'unit_price')::numeric;
    select * into p from inventory_products where id = (item->>'product_id')::uuid and user_id = auth.uid() for update;
    update inventory_products set stock = stock - q, updated_at = now() where id = p.id;
    insert into inventory_order_items(order_id, product_id, product_name, sku, quantity, unit_price, unit_cost, line_total, line_profit)
    values(oid, p.id, p.name, p.sku, q, price, p.cost_price, q * price, q * (price - p.cost_price));
    insert into inventory_movements(user_id, product_id, order_id, operation_type, quantity, unit_cost, unit_price, total_amount, note, before_sellable_stock, after_sellable_stock, business_no, operation_key)
    values(auth.uid(), p.id, oid, 'sale', -q, p.cost_price, price, q * price, p_note, p.stock, p.stock - q, doc_no, p_request_key);
  end loop;
  update inventory_movements set business_type = 'sale', business_id = oid where order_id = oid and operation_key = p_request_key;
  return oid;
end $$;

create or replace function public.inventory_receive(p_product_id uuid,p_quantity integer,p_unit_cost numeric,p_supplier text default null,p_note text default null,p_request_key uuid default gen_random_uuid())
returns uuid language plpgsql security invoker set search_path=public as $$
declare p public.inventory_products; mid uuid; doc_no text;
begin
  select id into mid from inventory_movements where user_id=auth.uid() and operation_key=p_request_key limit 1; if mid is not null then return mid; end if;
  if p_quantity<=0 or p_unit_cost<0 then raise exception 'Invalid inbound values'; end if;
  select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if;
  doc_no:=inventory_next_no('PO'); update inventory_products set stock=stock+p_quantity,cost_price=p_unit_cost,updated_at=now() where id=p.id;
  insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,supplier,note,before_sellable_stock,after_sellable_stock,business_type,business_no,operation_key)
  values(auth.uid(),p.id,'inbound',p_quantity,p_unit_cost,p_quantity*p_unit_cost,p_supplier,p_note,p.stock,p.stock+p_quantity,'purchase_inbound',doc_no,p_request_key) returning id into mid;
  update inventory_movements set business_id=mid where id=mid; return mid;
end $$;

create or replace function public.inventory_create_sale_return(p_order_id uuid, p_items jsonb, p_refund_amount numeric, p_refund_method text, p_reason text, p_note text default null, p_request_key uuid default gen_random_uuid())
returns uuid language plpgsql security invoker set search_path = public as $$
declare item jsonb; oi public.inventory_order_items; p public.inventory_products; rid uuid; q integer; condition text; calc_refund numeric := 0; returned_cost numeric := 0; total_returned integer := 0; original_count integer; returned_count integer; doc_no text; order_row public.inventory_orders; allocated numeric;
begin
  select id into rid from inventory_returns where user_id = auth.uid() and request_key = p_request_key;
  if rid is not null then return rid; end if;
  select * into order_row from inventory_orders where id = p_order_id and user_id = auth.uid() for update;
  if not found or order_row.order_status <> 'completed' then raise exception 'Order cannot be returned'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or p_reason is null or length(trim(p_reason)) = 0 then raise exception 'Return details and reason are required'; end if;
  if p_refund_amount < 0 or p_refund_method not in ('cash','wechat','alipay','bank_card','other') then raise exception 'Invalid refund'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    q := (item->>'quantity')::integer; condition := item->>'condition';
    select * into oi from inventory_order_items where id = (item->>'order_item_id')::uuid and order_id = p_order_id for update;
    if not found or q <= 0 or condition not in ('resellable','damaged','pending') then raise exception 'Invalid return item'; end if;
    select coalesce(sum(quantity), 0) into returned_count from inventory_return_items where order_item_id = oi.id;
    if q + returned_count > oi.quantity then raise exception 'Return quantity exceeds available quantity'; end if;
    allocated := oi.unit_price * q * case when order_row.subtotal > 0 then order_row.total_amount / order_row.subtotal else 1 end;
    calc_refund := calc_refund + allocated; returned_cost := returned_cost + oi.unit_cost * q; total_returned := total_returned + q;
  end loop;
  if p_refund_amount > calc_refund then raise exception 'Refund exceeds the original paid amount'; end if;
  doc_no := inventory_next_no('SR');
  insert into inventory_returns(user_id, return_no, order_id, refund_amount, refund_method, reason, note, request_key)
  values(auth.uid(), doc_no, p_order_id, p_refund_amount, p_refund_method, trim(p_reason), p_note, p_request_key) returning id into rid;
  for item in select value from jsonb_array_elements(p_items) loop
    q := (item->>'quantity')::integer; condition := item->>'condition';
    select * into oi from inventory_order_items where id = (item->>'order_item_id')::uuid for update;
    select * into p from inventory_products where id = oi.product_id and user_id = auth.uid() for update;
    insert into inventory_return_items(return_id, order_item_id, product_id, product_name, quantity, unit_price, unit_cost, item_condition)
    values(rid, oi.id, p.id, p.name, q, oi.unit_price, oi.unit_cost, condition);
    if condition = 'resellable' then
      update inventory_products set stock = stock + q, updated_at = now() where id = p.id;
      insert into inventory_movements(user_id,product_id,order_id,operation_type,quantity,unit_cost,unit_price,total_amount,note,before_sellable_stock,after_sellable_stock,business_no,operation_key)
      values(auth.uid(),p.id,p_order_id,'sale_return',q,p.cost_price,oi.unit_price,0,p_note,p.stock,p.stock+q,doc_no,p_request_key);
    elsif condition = 'pending' then
      update inventory_products set pending_stock = pending_stock + q, updated_at = now() where id = p.id;
      insert into inventory_movements(user_id,product_id,order_id,operation_type,quantity,unit_cost,unit_price,total_amount,note,before_sellable_stock,after_sellable_stock,before_pending_stock,after_pending_stock,business_no,operation_key)
      values(auth.uid(),p.id,p_order_id,'pending_in',q,p.cost_price,oi.unit_price,0,p_note,p.stock,p.stock,p.pending_stock,p.pending_stock+q,doc_no,p_request_key);
    else
      update inventory_products set damaged_quantity = damaged_quantity + q, updated_at = now() where id = p.id;
      insert into inventory_movements(user_id,product_id,order_id,operation_type,quantity,unit_cost,unit_price,total_amount,note,before_sellable_stock,after_sellable_stock,business_no,operation_key)
      values(auth.uid(),p.id,p_order_id,'loss',-q,p.cost_price,oi.unit_price,0,p_note,p.stock,p.stock,doc_no,p_request_key);
    end if;
  end loop;
  select sum(quantity) into original_count from inventory_order_items where order_id = p_order_id;
  select coalesce(sum(ri.quantity),0) into returned_count from inventory_return_items ri join inventory_returns r on r.id=ri.return_id where r.order_id=p_order_id;
  update inventory_orders set refunded_amount = refunded_amount + p_refund_amount, net_sales = total_amount - refunded_amount - p_refund_amount,
    net_profit = total_profit - ((refunded_amount + p_refund_amount) - returned_cost),
    payment_status = case when refunded_amount + p_refund_amount >= total_amount then 'refunded' else 'partially_refunded' end,
    return_status = case when returned_count >= original_count then 'full' else 'partial' end
  where id = p_order_id;
  update inventory_movements set business_type='sale_return', business_id=rid, original_business_id=p_order_id, original_business_no=order_row.order_no where user_id=auth.uid() and operation_key=p_request_key;
  return rid;
end $$;

create or replace function public.inventory_create_walk_in_return(p_product_id uuid, p_quantity integer, p_refund_amount numeric, p_refund_method text, p_reason text, p_condition text, p_note text default null, p_request_key uuid default gen_random_uuid())
returns uuid language plpgsql security invoker set search_path = public as $$
declare p public.inventory_products; rid uuid; doc_no text;
begin
  select id into rid from inventory_returns where user_id=auth.uid() and request_key=p_request_key; if rid is not null then return rid; end if;
  if p_quantity<=0 or p_refund_amount<0 or p_reason is null or length(trim(p_reason))=0 or p_condition not in ('resellable','damaged','pending') then raise exception 'Invalid walk-in return'; end if;
  select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if;
  doc_no:=inventory_next_no('SR'); insert into inventory_returns(user_id,return_no,is_walk_in,refund_amount,refund_method,reason,note,request_key) values(auth.uid(),doc_no,true,p_refund_amount,p_refund_method,trim(p_reason),p_note,p_request_key) returning id into rid;
  insert into inventory_return_items(return_id,product_id,product_name,quantity,unit_price,unit_cost,item_condition) values(rid,p.id,p.name,p_quantity,p_refund_amount/p_quantity,p.cost_price,p_condition);
  if p_condition='resellable' then update inventory_products set stock=stock+p_quantity,updated_at=now() where id=p.id;
    insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note,before_sellable_stock,after_sellable_stock,business_no,operation_key) values(auth.uid(),p.id,'sale_return',p_quantity,p.cost_price,0,p_note,p.stock,p.stock+p_quantity,doc_no,p_request_key);
  elsif p_condition='pending' then update inventory_products set pending_stock=pending_stock+p_quantity,updated_at=now() where id=p.id;
    insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note,before_sellable_stock,after_sellable_stock,before_pending_stock,after_pending_stock,business_no,operation_key) values(auth.uid(),p.id,'pending_in',p_quantity,p.cost_price,0,p_note,p.stock,p.stock,p.pending_stock,p.pending_stock+p_quantity,doc_no,p_request_key);
  else update inventory_products set damaged_quantity=damaged_quantity+p_quantity,updated_at=now() where id=p.id;
    insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note,before_sellable_stock,after_sellable_stock,business_no,operation_key) values(auth.uid(),p.id,'loss',-p_quantity,p.cost_price,0,p_note,p.stock,p.stock,doc_no,p_request_key);
  end if;
  update inventory_movements set business_type='sale_return', business_id=rid where user_id=auth.uid() and operation_key=p_request_key;
  return rid;
end $$;

create or replace function public.inventory_resolve_pending(p_product_id uuid,p_quantity integer,p_action text,p_reason text,p_request_key uuid default gen_random_uuid())
returns void language plpgsql security invoker set search_path=public as $$
declare p public.inventory_products; doc_no text; begin
 if p_quantity<=0 or p_action not in ('restore','loss') or p_reason is null or length(trim(p_reason))=0 then raise exception 'Invalid pending-stock action'; end if;
 if exists(select 1 from inventory_movements where user_id=auth.uid() and operation_key=p_request_key) then return; end if;
 select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found or p.pending_stock<p_quantity then raise exception 'Insufficient pending stock'; end if; doc_no:=inventory_next_no('ST');
 if p_action='restore' then update inventory_products set pending_stock=pending_stock-p_quantity,stock=stock+p_quantity,updated_at=now() where id=p.id;
   insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note,before_sellable_stock,after_sellable_stock,before_pending_stock,after_pending_stock,business_no,operation_key) values(auth.uid(),p.id,'pending_to_sale',p_quantity,p.cost_price,0,p_reason,p.stock,p.stock+p_quantity,p.pending_stock,p.pending_stock-p_quantity,doc_no,p_request_key);
 else update inventory_products set pending_stock=pending_stock-p_quantity,damaged_quantity=damaged_quantity+p_quantity,updated_at=now() where id=p.id;
   insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note,before_sellable_stock,after_sellable_stock,before_pending_stock,after_pending_stock,business_no,operation_key) values(auth.uid(),p.id,'pending_to_loss',-p_quantity,p.cost_price,0,p_reason,p.stock,p.stock,p.pending_stock,p.pending_stock-p_quantity,doc_no,p_request_key);
 end if;
end $$;

create or replace function public.inventory_purchase_return(p_inbound_movement_id uuid,p_quantity integer,p_note text default null,p_request_key uuid default gen_random_uuid())
returns uuid language plpgsql security invoker set search_path=public as $$
declare source_row public.inventory_movements; p public.inventory_products; already_returned integer; doc_no text; movement_id uuid;
begin
  if p_quantity <= 0 then raise exception 'Invalid return quantity'; end if;
  select id into movement_id from inventory_movements where user_id=auth.uid() and operation_key=p_request_key limit 1;
  if movement_id is not null then return movement_id; end if;
  select * into source_row from inventory_movements where id=p_inbound_movement_id and user_id=auth.uid() and operation_type='inbound' for update;
  if not found then raise exception 'Inbound record not found'; end if;
  select coalesce(sum(abs(quantity)),0) into already_returned from inventory_movements where source_movement_id=source_row.id and operation_type='purchase_return';
  if p_quantity + already_returned > source_row.quantity then raise exception 'Purchase return quantity exceeds available quantity'; end if;
  select * into p from inventory_products where id=source_row.product_id and user_id=auth.uid() for update;
  if not found or p.stock < p_quantity then raise exception 'Insufficient sellable stock'; end if;
  doc_no:=inventory_next_no('PR');
  update inventory_products set stock=stock-p_quantity,updated_at=now() where id=p.id;
  insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,supplier,note,before_sellable_stock,after_sellable_stock,business_no,source_movement_id,operation_key)
  values(auth.uid(),p.id,'purchase_return',-p_quantity,source_row.unit_cost,p_quantity*source_row.unit_cost,source_row.supplier,p_note,p.stock,p.stock-p_quantity,doc_no,source_row.id,p_request_key)
  returning id into movement_id;
  update inventory_movements set business_type='purchase_return',business_id=movement_id,original_business_id=source_row.id,original_business_no=source_row.business_no where id=movement_id;
  return movement_id;
end $$;

create or replace function public.inventory_adjust_stock(p_product_id uuid,p_quantity integer,p_adjustment_type text,p_reason text,p_request_key uuid default gen_random_uuid())
returns void language plpgsql security invoker set search_path=public as $$
declare p public.inventory_products; doc_no text; direction integer; operation_name text;
begin
  if p_quantity <= 0 or p_reason is null or length(trim(p_reason))=0 or p_adjustment_type not in ('stocktake_in','stocktake_out','loss','gift','personal_use','adjustment') then raise exception 'Invalid stock adjustment'; end if;
  if exists(select 1 from inventory_movements where user_id=auth.uid() and operation_key=p_request_key) then return; end if;
  select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if;
  direction:=case when p_adjustment_type='stocktake_in' then 1 else -1 end;
  if direction < 0 and p.stock < p_quantity then raise exception 'Insufficient sellable stock'; end if;
  doc_no:=inventory_next_no('ST'); operation_name:=p_adjustment_type;
  update inventory_products set stock=stock + direction*p_quantity, damaged_quantity=damaged_quantity + case when p_adjustment_type='loss' then p_quantity else 0 end, updated_at=now() where id=p.id;
  insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note,before_sellable_stock,after_sellable_stock,business_no,operation_key)
  values(auth.uid(),p.id,operation_name,direction*p_quantity,p.cost_price,p_quantity*p.cost_price,trim(p_reason),p.stock,p.stock+direction*p_quantity,doc_no,p_request_key);
  update inventory_movements set business_type='stock_adjustment',business_id=id where user_id=auth.uid() and operation_key=p_request_key;
end $$;

grant execute on function public.inventory_next_no(text) to authenticated;
grant execute on function public.inventory_receive(uuid,integer,numeric,text,text,uuid) to authenticated;
grant execute on function public.inventory_create_sale(jsonb,text,numeric,text,uuid) to authenticated;
grant execute on function public.inventory_create_sale_return(uuid,jsonb,numeric,text,text,text,uuid) to authenticated;
grant execute on function public.inventory_create_walk_in_return(uuid,integer,numeric,text,text,text,text,uuid) to authenticated;
grant execute on function public.inventory_resolve_pending(uuid,integer,text,text,uuid) to authenticated;
grant execute on function public.inventory_purchase_return(uuid,integer,text,uuid) to authenticated;
grant execute on function public.inventory_adjust_stock(uuid,integer,text,text,uuid) to authenticated;
