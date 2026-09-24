// Run with: node tests/inventory-profit-security.mjs /path/to/pglite/dist/index.js
import fs from 'node:fs'
import assert from 'node:assert/strict'
const { PGlite } = await import(process.argv[2])
const db = new PGlite()
await db.exec(`create role anon; create role authenticated; create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated,anon;
grant execute on function auth.uid() to authenticated,anon;`)
for (const file of ['inventory.sql', 'inventory_returns.sql', 'inventory_organizations.sql', 'inventory_orders.sql', 'inventory_batches.sql', 'inventory_profit_controls.sql', 'inventory_print.sql']) {
  // Existing migrations have a circular dependency on this column.
  if (file === 'inventory_organizations.sql') await db.exec('alter table public.inventory_orders add column salesperson_id uuid')
  await db.exec(fs.readFileSync(new URL('../supabase/' + file, import.meta.url), 'utf8'))
}
await db.exec(fs.readFileSync(new URL('../supabase/inventory_profit_controls.sql', import.meta.url), 'utf8'))
const ids = Array.from({ length: 9 }, (_, i) => `00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`)
const [owner, admin, sales, warehouse, user, outsider, org, otherOrg, product] = ids
for (const id of ids.slice(0, 6)) await db.query('insert into auth.users values ($1)', [id])
await db.query("insert into inventory_organizations(id,name,owner_id) values ($1,'Store',$2),($3,'Other',$4)", [org, owner, otherOrg, outsider])
for (const [id, role] of [[owner, 'super_admin'], [admin, 'admin'], [sales, 'salesperson'], [warehouse, 'warehouse'], [user, 'user'], [outsider, 'super_admin']]) {
  await db.query('insert into inventory_organization_members(organization_id,user_id,role) values($1,$2,$3)', [id === outsider ? otherOrg : org, id, role])
}
await db.query("insert into inventory_products(id,user_id,organization_id,name,sku,cost_price,sale_price,stock) values ($1,$2,$3,'Product','SKU',83.71,100,10)", [product, owner, org])
await db.query("insert into inventory_movements(user_id,organization_id,product_id,operation_type,quantity,unit_cost,total_amount) values ($1,$2,$3,'inbound',10,83.71,837.10)", [owner, org, product])
await db.exec('grant select,insert,update,delete on all tables in schema public to authenticated; grant usage on schema public to authenticated,anon;')
async function login(id) {
  await db.exec('reset role')
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id])
  await db.exec('set role authenticated')
}
async function rpc(resource, id = null) {
  return (await db.query('select inventory_read($1,$2) as data', [resource, id])).rows[0].data
}
const prohibited = new Set(['cost_price', 'unit_cost', 'actual_cost', 'total_cost', 'total_profit', 'line_profit', 'net_profit', 'reference_price', 'latest_price'])
function noCosts(value) {
  if (!value || typeof value !== 'object') return
  for (const [key, nested] of Object.entries(value)) { assert.ok(!prohibited.has(key), key); noCosts(nested) }
}
await login(owner)
const order = (await db.query("select inventory_create_order($1::jsonb) as id", [JSON.stringify([{ product_id: product, quantity: 1, unit_price: 100 }])])).rows[0].id
assert.equal((await rpc('products'))[0].cost_price, 83.71)
const itemId = (await rpc('orders', order))[0].inventory_order_items[0].id
await db.exec('reset role')
await db.query("update inventory_orders set order_status='completed', salesperson_id=$2 where id=$1", [order, sales])
await login(owner)
try {
  await db.query("select inventory_create_sale_return($1,$2::jsonb,0,'cash','test')", [order, JSON.stringify([{ order_item_id: itemId, condition: 'resellable' }])])
  assert.fail('Malformed return should fail')
} catch (error) {
  assert.doesNotMatch(JSON.stringify(error), /83\.71|Failing row contains/)
}
await db.query('select inventory_profit_settings($1::jsonb)', [JSON.stringify({ minimum_unit_profit: 20, minimum_margin: 18, amount_warning_enabled: true, margin_warning_enabled: false })])
for (const id of [admin, sales, warehouse, user]) {
  await login(id)
  assert.equal((await db.query('select cost_price from inventory_products')).rows.length, 0)
  assert.equal((await db.query('select total_cost from inventory_orders')).rows.length, 0)
  for (const resource of ['products', 'orders', 'returns', 'movements']) noCosts(await rpc(resource))
  const inbound = (await rpc('movements')).find(row => row.operation_type === 'inbound')
  assert.equal(inbound.total_amount, undefined)
  await assert.rejects(() => db.query('select inventory_profit_settings()'), /Not allowed/)
  await assert.rejects(() => db.query('select inventory_profit_settings($1::jsonb)', ['{}']), /Not allowed/)
  await assert.rejects(() => db.query("select inventory_receive($1,1,1,'supplier',null,gen_random_uuid())", [product]), /Not allowed/)
}
await login(sales)
assert.equal((await rpc('orders', order)).length, 1)
noCosts(await rpc('orders', order))
await login(admin)
await db.query("select inventory_save_product(p_product_id=>$1,p_name=>'Edited',p_sku=>'SKU',p_sale_price=>100,p_cost_price=>0)", [product])
await login(owner)
assert.equal((await rpc('products'))[0].cost_price, 83.71)
assert.equal((await db.query('select inventory_profit_settings() as data')).rows[0].data.minimum_unit_profit, 20)
await assert.rejects(() => db.query('select inventory_profit_settings($1::jsonb)', [JSON.stringify({ minimum_unit_profit: -1, minimum_margin: 15, amount_warning_enabled: true, margin_warning_enabled: true })]), /check constraint/)
// Reproduce an old returns script overwriting the organization allocator.
await db.exec('reset role')
await db.exec(`create or replace function public.inventory_next_no(p_prefix text)
returns text language plpgsql security invoker set search_path=public as $$
begin
  insert into inventory_document_counters(user_id,document_date,prefix,last_number)
  values(auth.uid(),current_date,p_prefix,1)
  on conflict(user_id,document_date,prefix) do update set last_number=inventory_document_counters.last_number+1;
  return 'broken';
end $$;`)
await login(owner)
const returnItems = JSON.stringify([{ order_item_id: itemId, quantity: 1, condition: 'resellable' }])
await assert.rejects(() => db.query("select inventory_create_sale_return($1,$2::jsonb,100,'cash','test')", [order, returnItems]), /no unique or exclusion constraint/)
await db.exec('reset role')
const numberFix = fs.readFileSync(new URL('../supabase/inventory_document_number_fix.sql', import.meta.url), 'utf8')
await db.exec(numberFix)
await db.exec(numberFix)
const returnsSql = fs.readFileSync(new URL('../supabase/inventory_returns.sql', import.meta.url), 'utf8')
await db.exec(returnsSql.match(/do \$bootstrap\$[\s\S]*?end \$bootstrap\$;/)[0])
await login(owner)
const stockBefore = (await rpc('products'))[0].stock
const returnId = (await db.query("select inventory_create_sale_return($1,$2::jsonb,100,'cash','test') as id", [order, returnItems])).rows[0].id
assert.ok((await rpc('returns', order)).some(row => row.id === returnId && row.refund_amount === 100))
assert.equal((await rpc('products'))[0].stock, stockBefore + 1)
assert.equal((await rpc('orders', order))[0].refunded_amount, 100)
console.log('PASS old allocator failure reproduced; standalone fix twice; bootstrap preserves allocator; successful return and stock/refund updates')
await db.exec('reset role')
const receiptFix = fs.readFileSync(new URL('../supabase/inventory_receive_fix.sql', import.meta.url), 'utf8')
await db.exec(receiptFix)
await db.exec(receiptFix)
await db.exec(returnsSql.match(/do \$receive_bootstrap\$[\s\S]*?end \$receive_bootstrap\$;/)[0])
await login(owner)
const beforeReceipt = (await rpc('products'))[0].stock
const receiptKey = '10000000-0000-4000-8000-000000000001'
const receiptArgs = [product, receiptKey]
const receive = () => db.query("select inventory_receive($1,2,12,'Receipt supplier',null,$2) as id", receiptArgs)
const receipt = (await receive()).rows[0].id
assert.equal((await receive()).rows[0].id, receipt)
assert.equal((await rpc('products'))[0].stock, beforeReceipt + 2)
assert.equal((await db.query('select remaining_quantity from inventory_purchase_batches where inbound_movement_id=$1', [receipt])).rows[0].remaining_quantity, 2)
await login(admin)
await assert.rejects(receive, /Not allowed/)
console.log('PASS receipt patch twice; legacy bootstrap preserves RPC; stock, batch, idempotent retry and role checks')
await login(outsider)
assert.deepEqual(await rpc('products', product), [])
assert.deepEqual(await rpc('orders', order), [])
await login(sales)
const printed = (await db.query('select inventory_print_order($1) as data', [order])).rows[0].data
assert.equal(printed.order_no.length > 0, true)
assert.equal(printed.payment_method, 'cash')
noCosts(printed)
await assert.rejects(() => db.query('select inventory_print_settings($1::jsonb)', [JSON.stringify({ company_name: 'X', default_paper: 'a4', default_template: 'standard', margin_mm: 4, font_size_pt: 9, rows_per_page: 8, fields: {} })]), /Not allowed/)
await login(owner)
await db.query('select inventory_print_settings($1::jsonb)', [JSON.stringify({ company_name: '测试公司', default_paper: 'a4', default_template: 'standard', margin_mm: 4, font_size_pt: 9, rows_per_page: 8, fields: { order_no: true } })])
await login(sales)
assert.equal((await db.query('select inventory_print_settings() as data')).rows[0].data.company_name, '测试公司')
await db.exec('reset role; set role anon;')
await assert.rejects(() => rpc('products'), /permission denied/)
await assert.rejects(() => db.query('select inventory_print_order($1)', [order]), /permission denied/)
await db.close()
console.log('PASS migrations twice; super/admin/sales/warehouse/user/outsider/anonymous reads; settings permissions; admin edit preserves cost')
