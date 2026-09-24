-- Run this migration in the Supabase SQL editor before using the inventory module.
create table if not exists public.inventory_products (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, image_url text, category text not null default '未分类', sku text not null,
  cost_price numeric(12,2) not null default 0 check (cost_price >= 0), sale_price numeric(12,2) not null default 0 check (sale_price >= 0),
  stock integer not null default 0 check (stock >= 0), low_stock_threshold integer not null default 0 check (low_stock_threshold >= 0),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(user_id, sku)
);
create table if not exists public.inventory_orders (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade, order_no text not null unique,
  payment_method text not null default 'cash' check (payment_method in ('cash','wechat','alipay','other')),
  subtotal numeric(12,2) not null default 0, discount numeric(12,2) not null default 0 check(discount >= 0), total_amount numeric(12,2) not null default 0 check(total_amount >= 0),
  total_cost numeric(12,2) not null default 0 check(total_cost >= 0), total_profit numeric(12,2) not null default 0, note text, created_at timestamptz not null default now()
);
create table if not exists public.inventory_order_items (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.inventory_orders(id) on delete cascade,
  product_id uuid not null references public.inventory_products(id) on delete restrict, product_name text not null, sku text not null,
  quantity integer not null check(quantity > 0), unit_price numeric(12,2) not null check(unit_price >= 0), unit_cost numeric(12,2) not null check(unit_cost >= 0), line_total numeric(12,2) not null, line_profit numeric(12,2) not null
);
create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.inventory_products(id) on delete restrict, order_id uuid references public.inventory_orders(id) on delete set null,
  operation_type text not null check(operation_type in ('inbound','sale','normal_outbound','loss','adjustment')), quantity integer not null check(quantity <> 0),
  unit_cost numeric(12,2), unit_price numeric(12,2), total_amount numeric(12,2), supplier text, note text, created_at timestamptz not null default now()
);
create index if not exists inventory_products_user_idx on public.inventory_products(user_id);
create index if not exists inventory_orders_user_date_idx on public.inventory_orders(user_id,created_at desc);
create index if not exists inventory_movements_user_date_idx on public.inventory_movements(user_id,created_at desc);
alter table public.inventory_products enable row level security;
alter table public.inventory_orders enable row level security;
alter table public.inventory_order_items enable row level security;
alter table public.inventory_movements enable row level security;
drop policy if exists "Users manage own inventory products" on public.inventory_products;
drop policy if exists "Users manage own inventory orders" on public.inventory_orders;
drop policy if exists "Users view own order items" on public.inventory_order_items;
drop policy if exists "Users add own order items" on public.inventory_order_items;
drop policy if exists "Users manage own inventory movements" on public.inventory_movements;
create policy "Users manage own inventory products" on public.inventory_products for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
create policy "Users manage own inventory orders" on public.inventory_orders for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
create policy "Users view own order items" on public.inventory_order_items for select to authenticated using(exists(select 1 from public.inventory_orders o where o.id=order_id and o.user_id=auth.uid()));
create policy "Users add own order items" on public.inventory_order_items for insert to authenticated with check(exists(select 1 from public.inventory_orders o where o.id=order_id and o.user_id=auth.uid()));
create policy "Users manage own inventory movements" on public.inventory_movements for all to authenticated using(auth.uid()=user_id) with check(auth.uid()=user_id);
create or replace function public.inventory_receive(p_product_id uuid,p_quantity integer,p_unit_cost numeric,p_supplier text default null,p_note text default null) returns void language plpgsql security invoker set search_path=public as $$
declare p public.inventory_products; begin
 if p_quantity<=0 or p_unit_cost<0 then raise exception 'Invalid inbound values'; end if;
 select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if;
 update inventory_products set stock=p.stock+p_quantity,cost_price=p_unit_cost,updated_at=now() where id=p.id;
 insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,supplier,note) values(auth.uid(),p.id,'inbound',p_quantity,p_unit_cost,p_quantity*p_unit_cost,p_supplier,p_note);
end $$;
create or replace function public.inventory_stock_out(p_product_id uuid,p_quantity integer,p_type text,p_note text default null) returns void language plpgsql security invoker set search_path=public as $$
declare p public.inventory_products; begin
 if p_quantity<=0 or p_type not in('normal_outbound','loss') then raise exception 'Invalid outbound values'; end if;
 select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if;
 if p.stock<p_quantity then raise exception 'Insufficient stock'; end if;
 update inventory_products set stock=p.stock-p_quantity,updated_at=now() where id=p.id;
 insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note) values(auth.uid(),p.id,p_type,-p_quantity,p.cost_price,p_quantity*p.cost_price,p_note);
end $$;
create or replace function public.inventory_adjust_product(p_product_id uuid,p_stock integer,p_cost_price numeric,p_sale_price numeric,p_note text default null) returns void language plpgsql security invoker set search_path=public as $$
declare p public.inventory_products; d integer; begin
 if p_stock<0 or p_cost_price<0 or p_sale_price<0 then raise exception 'Invalid product values'; end if;
 select * into p from inventory_products where id=p_product_id and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if; d:=p_stock-p.stock;
 update inventory_products set stock=p_stock,cost_price=p_cost_price,sale_price=p_sale_price,updated_at=now() where id=p.id;
 if d<>0 then insert into inventory_movements(user_id,product_id,operation_type,quantity,unit_cost,total_amount,note) values(auth.uid(),p.id,'adjustment',d,p_cost_price,abs(d)*p_cost_price,coalesce(p_note,'库存调整')); end if;
end $$;
create or replace function public.inventory_create_sale(p_items jsonb,p_payment_method text default 'cash',p_discount numeric default 0,p_note text default null) returns uuid language plpgsql security invoker set search_path=public as $$
declare item jsonb; p public.inventory_products; oid uuid; q integer; price numeric; subtotal numeric:=0; cost numeric:=0; final_total numeric; begin
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale items are required'; end if;
 if p_discount<0 or p_payment_method not in('cash','wechat','alipay','other') then raise exception 'Invalid order'; end if;
 for item in select value from jsonb_array_elements(p_items) loop q:=(item->>'quantity')::integer; price:=(item->>'unit_price')::numeric; if q<=0 or price<0 then raise exception 'Invalid sale item'; end if; select * into p from inventory_products where id=(item->>'product_id')::uuid and user_id=auth.uid() for update; if not found then raise exception 'Product not found'; end if; if p.stock<q then raise exception 'Insufficient stock: %',p.name; end if; subtotal:=subtotal+q*price; cost:=cost+q*p.cost_price; end loop;
 final_total:=greatest(subtotal-p_discount,0); insert into inventory_orders(user_id,order_no,payment_method,subtotal,discount,total_amount,total_cost,total_profit,note) values(auth.uid(),'SO-'||to_char(now(),'YYYYMMDDHH24MISSMS')||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,5),p_payment_method,subtotal,p_discount,final_total,cost,final_total-cost,p_note) returning id into oid;
 for item in select value from jsonb_array_elements(p_items) loop q:=(item->>'quantity')::integer; price:=(item->>'unit_price')::numeric; select * into p from inventory_products where id=(item->>'product_id')::uuid and user_id=auth.uid() for update; update inventory_products set stock=stock-q,updated_at=now() where id=p.id; insert into inventory_order_items(order_id,product_id,product_name,sku,quantity,unit_price,unit_cost,line_total,line_profit) values(oid,p.id,p.name,p.sku,q,price,p.cost_price,q*price,q*(price-p.cost_price)); insert into inventory_movements(user_id,product_id,order_id,operation_type,quantity,unit_cost,unit_price,total_amount,note) values(auth.uid(),p.id,oid,'sale',-q,p.cost_price,price,q*price,p_note); end loop;
 return oid;
end $$;
grant execute on function public.inventory_receive(uuid,integer,numeric,text,text) to authenticated;
grant execute on function public.inventory_stock_out(uuid,integer,text,text) to authenticated;
grant execute on function public.inventory_adjust_product(uuid,integer,numeric,numeric,text) to authenticated;
grant execute on function public.inventory_create_sale(jsonb,text,numeric,text) to authenticated;
