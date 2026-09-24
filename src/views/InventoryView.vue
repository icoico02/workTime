<script setup>
import { computed, onMounted, ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import FunctionHeader from '../components/FunctionHeader.vue'
import GlassModal from '../components/GlassModal.vue'
import InventorySearchSelect from '../components/InventorySearchSelect.vue'
import { supabase } from '../supabase'

const route = useRoute()
const router = useRouter()
const products = ref([])
const movements = ref([])
const orders = ref([])
const returns = ref([])
const orderDetail = ref({ open: false, order: null, items: [], returns: [] })
const flowDetail = ref({ open: false, movement: null, record: null, items: [] })
const returnDraft = ref({ open: false, order: null, items: [], refund: 0, method: 'cash', reason: '', note: '', requestKey: '' })
const walkInReturn = ref({ open: false, product: '', quantity: 1, refund: 0, method: 'cash', reason: '', condition: 'resellable', note: '', requestKey: '' })
const pendingAction = ref({ open: false, product: null, quantity: 1, action: 'restore', reason: '', requestKey: '' })
const loading = ref(true)
const submitting = ref(false)
const errorMessage = ref('')
const search = ref('')
const category = ref('')
const statsDays = ref(7)
const logFilters = ref({ type: '', product: '', date: '', business: '' })
const modal = ref({ show: false, message: '', mode: '', id: '' })
const editor = ref(blankProduct())
const showEditor = ref(false)
const inbound = ref({ product: '', quantity: 1, price: '', supplier: '', note: '' })
const outbound = ref({ product: '', quantity: 1, type: 'normal_outbound', note: '' })
const cart = ref([])
const payment = ref('cash')
const discount = ref(0)
const saleNote = ref('')
const orderCustomer = ref({ name: '', contact_name: '', phone: '', address: '' })
const orderFreight = ref(0)
const orderReceived = ref(0)
const orderShipping = ref('pickup')
const organization = ref(null)
const organizationName = ref('')
const organizationLoading = ref(false)

const sections = [['dashboard', '总览'], ['checkout', '开单'], ['orders', '订单'], ['products', '商品'], ['inbound', '入库'], ['outbound', '出库'], ['returns', '退货'], ['stock', '库存'], ['logs', '流水']]
const currentSection = computed(() => route.params.section || 'dashboard')
const sectionTitle = computed(() => ({ dashboard: '进销存总览', checkout: '快速开单', orders: '销售订单', products: '商品管理', inbound: '入库登记', outbound: '出库登记', returns: '销售退货', stock: '库存状态', logs: '经营流水' }[currentSection.value] || '进销存总览'))
const categories = computed(() => [...new Set(products.value.map((p) => p.category).filter(Boolean))])
const productOptions = computed(() => products.value.map((product) => ({ id: product.id, label: product.name, description: `${product.sku}${product.specification ? ` · ${product.specification}` : ''} · 可售 ${product.stock} 件` })))
const supplierOptions = computed(() => [...new Set(movements.value.filter((item) => item.operation_type === 'inbound' && item.supplier).map((item) => item.supplier.trim()).filter(Boolean))].map((supplier) => ({ id: supplier, label: supplier, description: '历史入库供应商' })))
const visibleProducts = computed(() => products.value.filter((p) => (!category.value || p.category === category.value) && `${p.name} ${p.sku}`.toLowerCase().includes(search.value.toLowerCase())))
const warnings = computed(() => products.value.filter((p) => Number(p.stock) <= Number(p.low_stock_threshold)))
const selectedInbound = computed(() => products.value.find((p) => p.id === inbound.value.product))
const inboundTotal = computed(() => Number(inbound.value.quantity || 0) * Number(inbound.value.price || 0))
const cartSubtotal = computed(() => cart.value.reduce((sum, p) => sum + p.quantity * p.unit_price, 0))
const cartCost = computed(() => cart.value.reduce((sum, p) => sum + p.quantity * Number(p.cost_price), 0))
const cartTotal = computed(() => Math.max(0, cartSubtotal.value - Number(discount.value || 0)) + Number(orderFreight.value || 0))
const cartProfit = computed(() => cartTotal.value - cartCost.value)
const filteredLogs = computed(() => movements.value.filter((m) => (!logFilters.value.type || m.operation_type === logFilters.value.type) && (!logFilters.value.product || m.product_id === logFilters.value.product) && (!logFilters.value.date || m.created_at.slice(0, 10) === logFilters.value.date) && (!logFilters.value.business || String(m.business_no || '').toLowerCase().includes(logFilters.value.business.toLowerCase()))))
const money = (value) => `￥${Number(value || 0).toFixed(2)}`
const dateText = (value) => value ? new Intl.DateTimeFormat('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(value)) : '--'
const typeText = (value) => ({ inbound: '采购入库', sale: '销售出库', sale_return: '销售退货', purchase_return: '采购退货', normal_outbound: '普通出库', loss: '损耗', pending_in: '待处理入库', pending_to_sale: '待处理恢复可售', pending_to_loss: '待处理确认损耗', stocktake_in: '盘点增加', stocktake_out: '盘点减少', gift: '赠送', personal_use: '自用', adjustment: '库存调整' })[value] || value

function blankProduct() { return { id: '', name: '', image_url: '', category: '', sku: '', specification: '', cost_price: 0, sale_price: 0, stock: 0, low_stock_threshold: 3 } }
function requestKey() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID()
  const random = () => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0')
  return random() + random() + '-' + random() + '-4' + random().slice(1) + '-' + (8 + Math.floor(Math.random() * 4)).toString(16) + random().slice(1) + '-' + random() + random() + random()
}
function openSection(section) { router.push(`/inventory/${section}`) }
function goHome() { router.push('/') }
async function signOut() { await supabase?.auth.signOut(); router.push('/') }
function message(text) { modal.value = { show: true, message: text, mode: '', id: '' } }
function closeModal() { modal.value = { show: false, message: '', mode: '', id: '' } }
function closeInventoryDialog() {
  orderDetail.value.open = false
  flowDetail.value.open = false
  returnDraft.value.open = false
  walkInReturn.value.open = false
  pendingAction.value.open = false
}
function editProduct(product) { editor.value = product ? { ...product } : blankProduct(); showEditor.value = true }
function selectInbound() { if (selectedInbound.value && !inbound.value.price) inbound.value.price = selectedInbound.value.cost_price }
function status(product) { return Number(product.stock) <= 0 ? '缺货' : Number(product.stock) <= Number(product.low_stock_threshold) ? '库存不足' : '库存正常' }
function statusClass(product) { return Number(product.stock) <= 0 ? 'status-danger' : Number(product.stock) <= Number(product.low_stock_threshold) ? 'status-warning' : 'status-good' }

async function loadData() {
  if (!supabase) return
  loading.value = true
  errorMessage.value = ''
  const [productRes, movementRes, orderRes, returnRes] = await Promise.all([
    supabase.from('inventory_products').select('*').order('updated_at', { ascending: false }),
    supabase.from('inventory_movements').select('*, inventory_products(name, sku)').order('created_at', { ascending: false }).limit(500),
    supabase.from('inventory_orders').select('*').order('created_at', { ascending: false }).limit(500),
    supabase.from('inventory_returns').select('*, inventory_return_items(quantity)').order('created_at', { ascending: false }).limit(500),
  ])
  const failure = productRes.error || movementRes.error || orderRes.error || returnRes.error
  if (failure) errorMessage.value = failure.message.includes('inventory_') ? '进销存数据表尚未创建，请先在 Supabase 执行 supabase/inventory.sql。' : `读取失败：${failure.message}`
  else { products.value = productRes.data || []; movements.value = movementRes.data || []; orders.value = orderRes.data || []; returns.value = returnRes.data || [] }
  loading.value = false
}

async function loadOrganization() {
  if (!supabase) return
  const { data, error } = await supabase.rpc('inventory_current_organization_id')
  if (error) return
  if (!data) { organization.value = null; return }
  const { data: record } = await supabase.from('inventory_organizations').select('id,name').eq('id', data).maybeSingle()
  organization.value = record || { id: data, name: '我的店铺' }
}

async function createOrganization() {
  if (!organizationName.value.trim()) return message('请填写店铺或组织名称。')
  organizationLoading.value = true
  const { error } = await supabase.rpc('inventory_create_organization', { p_name: organizationName.value.trim() })
  organizationLoading.value = false
  if (error) return message(`创建店铺失败：${error.message}`)
  await loadOrganization()
  await loadData()
}

async function saveProduct() {
  if (!editor.value.name.trim() || !editor.value.sku.trim()) return message('请填写商品名称和 SKU/货号。')
  submitting.value = true
  const value = { name: editor.value.name.trim(), image_url: editor.value.image_url?.trim() || null, category: editor.value.category?.trim() || '未分类', sku: editor.value.sku.trim(), cost_price: Number(editor.value.cost_price || 0), sale_price: Number(editor.value.sale_price || 0), stock: Number(editor.value.stock || 0), low_stock_threshold: Number(editor.value.low_stock_threshold || 0) }
  const result = await supabase.rpc('inventory_save_product', { p_product_id: editor.value.id || null, p_name: value.name, p_sku: value.sku, p_category: value.category, p_image_url: value.image_url, p_specification: editor.value.specification || null, p_sale_price: value.sale_price, p_cost_price: value.cost_price, p_stock: value.stock, p_low_stock_threshold: value.low_stock_threshold })
  submitting.value = false
  if (result.error) return message(`保存失败：${result.error.message}`)
  showEditor.value = false
  await loadData()
}
function deleteProduct(product) { modal.value = { show: true, message: `确定删除商品“${product.name}”吗？有流水的商品不能删除。`, mode: 'delete', id: product.id } }
async function confirmModal() {
  if (modal.value.mode !== 'delete') return closeModal()
  const { error } = await supabase.from('inventory_products').delete().eq('id', modal.value.id)
  if (error) message(`删除失败：${error.message}`); else { closeModal(); await loadData() }
}
async function submitInbound() {
  if (!inbound.value.product || Number(inbound.value.quantity) <= 0 || Number(inbound.value.price) < 0) return message('请选择商品并填写正确的数量与进货价。')
  submitting.value = true
  const { error } = await supabase.rpc('inventory_receive', { p_product_id: inbound.value.product, p_quantity: Number(inbound.value.quantity), p_unit_cost: Number(inbound.value.price), p_supplier: inbound.value.supplier || null, p_note: inbound.value.note || null, p_request_key: requestKey() })
  submitting.value = false
  if (error) return message(`入库失败：${error.message}`)
  inbound.value = { product: '', quantity: 1, price: '', supplier: '', note: '' }
  await loadData(); message('入库成功，库存与流水已同步更新。')
}
async function submitOutbound() {
  if (!outbound.value.product || Number(outbound.value.quantity) <= 0) return message('请选择商品并填写正确数量。')
  submitting.value = true
  const { error } = await supabase.rpc('inventory_stock_out', { p_product_id: outbound.value.product, p_quantity: Number(outbound.value.quantity), p_type: outbound.value.type, p_note: outbound.value.note || null })
  submitting.value = false
  if (error) return message(error.message.includes('Insufficient') ? '库存不足，不能出库。' : `出库失败：${error.message}`)
  outbound.value = { product: '', quantity: 1, type: 'normal_outbound', note: '' }
  await loadData(); message('出库成功，库存与流水已同步更新。')
}
function addCart(product) {
  if (!product.stock) return message('库存不足，不能加入订单。')
  const item = cart.value.find((p) => p.id === product.id)
  if (item) { if (item.quantity < product.stock) item.quantity += 1; else message('已达到可售库存。') }
  else cart.value.push({ ...product, quantity: 1, unit_price: Number(product.sale_price) })
}
function changeQuantity(item, delta) {
  const next = item.quantity + delta
  if (next <= 0) cart.value = cart.value.filter((p) => p.id !== item.id)
  else if (next <= Number(item.stock)) item.quantity = next
}
async function completeSale() {
  if (!cart.value.length) return message('请先选择商品。')
  submitting.value = true
  try {
    if (Number(orderReceived.value || 0) > cartTotal.value) return message('已收金额不能大于应收金额。')
    const { error } = await supabase.rpc('inventory_create_order', {
      p_items: cart.value.map((p) => ({ product_id: p.id, quantity: p.quantity, unit_price: Number(p.unit_price), discount_amount: 0 })),
      p_customer: orderCustomer.value,
      p_payment_method: payment.value,
      p_initial_received: Number(orderReceived.value || 0),
      p_discount: Number(discount.value || 0),
      p_freight: Number(orderFreight.value || 0),
      p_shipping_method: orderShipping.value,
      p_customer_note: saleNote.value || null,
      p_internal_note: null,
      p_request_key: requestKey(),
    })
    if (error) return message(error.message.includes('Insufficient') ? '库存不足，请刷新后检查订单。' : '开单失败：' + error.message)
    cart.value = []; payment.value = 'cash'; discount.value = 0; saleNote.value = ''; orderFreight.value = 0; orderReceived.value = 0; orderShipping.value = 'pickup'; orderCustomer.value = { name: '', contact_name: '', phone: '', address: '' }
    await loadData(); openSection('orders'); message('订单已保存，请在订单详情确认出库。')
  } catch (error) {
    message('开单失败：' + (error.message || '请检查网络后重试'))
  } finally {
    submitting.value = false
  }
}
async function openOrder(order) {
  const [itemRes, returnRes] = await Promise.all([
    supabase.from('inventory_order_items').select('*').eq('order_id', order.id),
    supabase.from('inventory_returns').select('*, inventory_return_items(*)').eq('order_id', order.id).order('created_at', { ascending: false }),
  ])
  if (itemRes.error || returnRes.error) return message('订单详情读取失败：' + (itemRes.error?.message || returnRes.error?.message))
  orderDetail.value = { open: true, order, items: itemRes.data || [], returns: returnRes.data || [] }
}
async function fulfillOrder(order) {
  submitting.value = true
  try {
    const { error } = await supabase.rpc('inventory_confirm_order_fulfillment', { p_order_id: order.id, p_request_key: requestKey() })
    if (error) return message(error.message.includes('Insufficient') ? '库存不足，无法确认出库。' : `确认出库失败：${error.message}`)
    orderDetail.value.open = false
    await loadData()
    message('已确认出库，库存和流水已同步更新。')
  } finally { submitting.value = false }
}
function beginOrderReturn() {
  const { order, items, returns: existing } = orderDetail.value
  const returned = new Map()
  existing.flatMap((record) => record.inventory_return_items || []).forEach((item) => returned.set(item.order_item_id, (returned.get(item.order_item_id) || 0) + Number(item.quantity)))
  const draftItems = items.map((item) => ({ ...item, max: Number(item.quantity) - (returned.get(item.id) || 0), quantity: 0, condition: 'resellable' })).filter((item) => item.max > 0)
  if (!draftItems.length) return message('该订单商品已全部退货。')
  returnDraft.value = { open: true, order, items: draftItems, refund: 0, method: 'cash', reason: '', note: '', requestKey: requestKey() }
}
const suggestedRefund = computed(() => {
  const draft = returnDraft.value
  if (!draft.order) return 0
  const ratio = Number(draft.order.subtotal) > 0 ? Number(draft.order.total_amount) / Number(draft.order.subtotal) : 1
  return draft.items.reduce((sum, item) => sum + Number(item.quantity || 0) * Number(item.unit_price) * ratio, 0)
})
function syncRefund() { returnDraft.value.refund = Number(suggestedRefund.value.toFixed(2)) }
async function submitOrderReturn() {
  const draft = returnDraft.value
  const items = draft.items.filter((item) => Number(item.quantity) > 0)
  if (!items.length || !draft.reason.trim()) return message('请选择退货商品、数量并填写退货原因。')
  if (items.some((item) => Number(item.quantity) > Number(item.max))) return message('退货数量不能超过可退数量。')
  submitting.value = true
  const { error } = await supabase.rpc('inventory_create_sale_return', {
    p_order_id: draft.order.id,
    p_items: items.map((item) => ({ order_item_id: item.id, quantity: Number(item.quantity), condition: item.condition })),
    p_refund_amount: Number(draft.refund || 0),
    p_refund_method: draft.method,
    p_reason: draft.reason.trim(),
    p_note: draft.note || null,
    p_request_key: draft.requestKey,
  })
  submitting.value = false
  if (error) return message('退货失败：' + error.message)
  returnDraft.value.open = false; orderDetail.value.open = false
  await loadData(); message('退货完成，退款、订单状态、库存和流水已同步更新。')
}
async function submitWalkInReturn() {
  const draft = walkInReturn.value
  if (!draft.product || Number(draft.quantity) <= 0 || !draft.reason.trim()) return message('请完整填写无单退货信息。')
  submitting.value = true
  const { error } = await supabase.rpc('inventory_create_walk_in_return', { p_product_id: draft.product, p_quantity: Number(draft.quantity), p_refund_amount: Number(draft.refund || 0), p_refund_method: draft.method, p_reason: draft.reason.trim(), p_condition: draft.condition, p_note: draft.note || null, p_request_key: draft.requestKey })
  submitting.value = false
  if (error) return message('无单退货失败：' + error.message)
  walkInReturn.value = { open: false, product: '', quantity: 1, refund: 0, method: 'cash', reason: '', condition: 'resellable', note: '', requestKey: '' }
  await loadData(); message('无单退货已保存。')
}
function openPending(product) { pendingAction.value = { open: true, product, quantity: 1, action: 'restore', reason: '', requestKey: requestKey() } }
async function openFlow(movement) {
  let result = null
  let items = []
  if (movement.business_type === 'sale') {
    const [orderRes, itemRes] = await Promise.all([supabase.from('inventory_orders').select('*').eq('id', movement.business_id).maybeSingle(), supabase.from('inventory_order_items').select('*').eq('order_id', movement.business_id)])
    if (orderRes.error) return message('单据详情读取失败：' + orderRes.error.message)
    result = orderRes.data; items = itemRes.data || []
  } else if (movement.business_type === 'sale_return') {
    const [returnRes, itemRes] = await Promise.all([supabase.from('inventory_returns').select('*').eq('id', movement.business_id).maybeSingle(), supabase.from('inventory_return_items').select('*').eq('return_id', movement.business_id)])
    if (returnRes.error) return message('退货详情读取失败：' + returnRes.error.message)
    result = returnRes.data; items = itemRes.data || []
  }
  flowDetail.value = { open: true, movement, record: result, items }
}
async function copyBusinessNo(value) {
  try { await navigator.clipboard.writeText(value); message('业务单号已复制。') } catch { message('当前浏览器不支持复制，请手动复制单号。') }
}
async function submitPending() {
  const draft = pendingAction.value
  if (!draft.reason.trim() || Number(draft.quantity) <= 0 || Number(draft.quantity) > Number(draft.product.pending_stock)) return message('请填写原因，并确认待处理数量。')
  submitting.value = true
  const { error } = await supabase.rpc('inventory_resolve_pending', { p_product_id: draft.product.id, p_quantity: Number(draft.quantity), p_action: draft.action, p_reason: draft.reason.trim(), p_request_key: draft.requestKey })
  submitting.value = false
  if (error) return message('处理失败：' + error.message)
  pendingAction.value.open = false; await loadData(); message('待处理库存已完成处置。')
}

const business = computed(() => {
  const start = new Date(); start.setHours(0, 0, 0, 0)
  const daily = orders.value.filter((o) => new Date(o.created_at) >= start)
  const incoming = movements.value.filter((m) => m.operation_type === 'inbound' && new Date(m.created_at) >= start)
  const refunds = returns.value.filter((r) => new Date(r.created_at) >= start)
  return { sales: daily.reduce((n, o) => n + Number(o.total_amount), 0), netSales: daily.reduce((n, o) => n + Number(o.net_sales ?? o.total_amount), 0), profit: daily.reduce((n, o) => n + Number(o.net_profit ?? o.total_profit), 0), orders: daily.length, inbound: incoming.reduce((n, m) => n + Number(m.total_amount), 0), refunds: refunds.reduce((n, r) => n + Number(r.refund_amount), 0), returnQty: refunds.reduce((n, r) => n + (r.inventory_return_items || []).reduce((sum, item) => sum + Number(item.quantity), 0), 0), stockCost: products.value.reduce((n, p) => n + Number(p.stock) * Number(p.cost_price), 0) }
})
const trends = computed(() => {
  const rows = Array.from({ length: statsDays.value }, (_, index) => {
    const start = new Date(); start.setDate(start.getDate() - (statsDays.value - 1 - index)); start.setHours(0, 0, 0, 0)
    const end = new Date(start); end.setDate(end.getDate() + 1)
    const dayOrders = orders.value.filter((o) => new Date(o.created_at) >= start && new Date(o.created_at) < end)
    const qty = movements.value.filter((m) => m.operation_type === 'sale' && new Date(m.created_at) >= start && new Date(m.created_at) < end).reduce((n, m) => n + Math.abs(Number(m.quantity)), 0)
    return { day: `${start.getMonth() + 1}/${start.getDate()}`, sales: dayOrders.reduce((n, o) => n + Number(o.total_amount), 0), profit: dayOrders.reduce((n, o) => n + Number(o.total_profit), 0), qty }
  })
  return { rows, max: Math.max(1, ...rows.flatMap((r) => [r.sales, r.profit, r.qty])) }
})
const ranking = computed(() => {
  const entries = new Map()
  const cutoff = Date.now() - statsDays.value * 86400000
  movements.value.filter((m) => m.operation_type === 'sale' && new Date(m.created_at).getTime() >= cutoff).forEach((m) => {
    const row = entries.get(m.product_id) || { name: m.inventory_products?.name || '商品', quantity: 0, profit: 0 }
    row.quantity += Math.abs(Number(m.quantity)); row.profit += Math.abs(Number(m.quantity)) * (Number(m.unit_price) - Number(m.unit_cost)); entries.set(m.product_id, row)
  })
  const all = [...entries.values()]
  return { hot: [...all].sort((a, b) => b.quantity - a.quantity).slice(0, 5), profit: [...all].sort((a, b) => b.profit - a.profit).slice(0, 5) }
})
onMounted(async () => { await loadOrganization(); if (organization.value) await loadData(); else loading.value = false })
</script>

<template>
  <div class="app-shell inventory-shell inventory-app">
    <FunctionHeader :title="sectionTitle" @back="goHome" @sign-out="signOut" />
    <nav class="inventory-nav"><RouterLink v-for="[key, label] in sections" :key="key" :to="`/inventory/${key}`">{{ label }}</RouterLink></nav>
    <main class="inventory-content">
      <section v-if="!organization && !loading" class="inventory-glass-card movement-card"><div class="inventory-card-title"><div><p class="eyebrow">INVENTORY WORKSPACE</p><h2>创建店铺 / 组织</h2></div></div><p>进销存数据会在这个店铺内协同，计时、签到和其他功能不受影响。</p><form class="inventory-form" @submit.prevent="createOrganization"><label><span>店铺或组织名称</span><input v-model="organizationName" placeholder="例如：小王杂货铺" required /></label><button class="glass-primary-btn" :disabled="organizationLoading">{{ organizationLoading ? '创建中…' : '创建并进入进销存' }}</button></form></section>
      <section v-else-if="errorMessage" class="inventory-glass-card inventory-error"><strong>无法载入进销存</strong><p>{{ errorMessage }}</p><button class="glass-primary-btn" @click="loadData">重新读取</button></section>
      <section v-else-if="loading && !products.length" class="inventory-glass-card empty-state">正在读取真实库存数据…</section>

      <template v-else-if="currentSection === 'dashboard'">
        <div class="inventory-section-heading"><div><p class="eyebrow">BUSINESS TODAY</p><h2>今天的经营情况</h2></div><button class="glass-primary-btn" @click="openSection('checkout')">开始开单</button></div>
        <div class="inventory-metrics business-metrics">
          <button class="inventory-metric metric-blue" @click="openSection('checkout')"><span>今日销售额</span><strong>{{ money(business.sales) }}</strong><small>销售完成后自动更新</small></button>
          <button class="inventory-metric metric-purple" @click="openSection('logs')"><span>今日毛利</span><strong>{{ money(business.profit) }}</strong><small>已扣除商品成本</small></button>
          <button class="inventory-metric metric-green" @click="openSection('logs')"><span>今日订单</span><strong>{{ business.orders }}</strong><small>笔销售订单</small></button>
          <button class="inventory-metric metric-orange" @click="openSection('inbound')"><span>今日入库</span><strong>{{ money(business.inbound) }}</strong><small>进货金额</small></button>
          <button class="inventory-metric metric-purple" @click="openSection('returns')"><span>今日退款</span><strong>{{ money(business.refunds) }}</strong><small>净销售 {{ money(business.netSales) }}</small></button>
          <button class="inventory-metric metric-rose" @click="openSection('stock')"><span>库存预警</span><strong>{{ warnings.length }}</strong><small>个商品需关注</small></button>
          <button class="inventory-metric metric-indigo" @click="openSection('stock')"><span>库存总成本</span><strong>{{ money(business.stockCost) }}</strong><small>{{ products.length }} 个商品</small></button>
        </div>
        <section class="inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">INSIGHT</p><h3>经营统计</h3></div><div class="segmented"><button v-for="day in [7,30,90]" :class="{ active: statsDays === day }" @click="statsDays = day">近 {{ day }} 天</button></div></div>
          <div class="trend-grid"><article v-for="[key, title, color] in [['sales','销售额','trend-blue'],['profit','毛利','trend-purple'],['qty','销量','trend-orange']]" :key="key" class="trend-card"><strong>{{ title }}</strong><div class="trend-bars"><i v-for="row in trends.rows" :key="row.day" :title="`${row.day}: ${row[key]}`" :class="color" :style="{ height: `${Math.max(4, row[key] / trends.max * 100)}%` }"></i></div></article></div>
          <div class="ranking-grid"><article><h4>热销商品</h4><p v-for="(item,index) in ranking.hot" :key="item.name"><b>{{ index + 1 }}</b>{{ item.name }}<span>{{ item.quantity }} 件</span></p><small v-if="!ranking.hot.length">该时段暂无销售数据</small></article><article><h4>商品利润排行</h4><p v-for="(item,index) in ranking.profit" :key="item.name"><b>{{ index + 1 }}</b>{{ item.name }}<span>{{ money(item.profit) }}</span></p><small v-if="!ranking.profit.length">该时段暂无销售数据</small></article></div>
        </section>
      </template>

      <template v-else-if="currentSection === 'checkout'">
        <div class="inventory-section-heading"><div><p class="eyebrow">QUICK SALE</p><h2>点商品，直接开单</h2></div><button class="glass-action-btn" @click="openSection('products')">管理商品</button></div>
        <section class="checkout-layout"><div class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索商品或货号" /><select v-model="category"><option value="">全部分类</option><option v-for="item in categories" :key="item">{{ item }}</option></select></div><div class="checkout-product-grid"><button v-for="product in visibleProducts" :key="product.id" class="checkout-product" :disabled="!product.stock" @click="addCart(product)"><img v-if="product.image_url" :src="product.image_url" :alt="product.name" /><span v-else class="product-image-placeholder">{{ product.name.slice(0,1) }}</span><b>{{ product.name }}</b><small>{{ product.stock }} 件可售</small><strong>{{ money(product.sale_price) }}</strong></button><p v-if="!visibleProducts.length" class="empty-state">没有匹配的商品</p></div></div>
          <aside class="inventory-glass-card order-panel"><div class="inventory-card-title"><h3>当前订单</h3><span>{{ cart.length }} 种商品</span></div><p v-if="!cart.length" class="empty-state">点击商品加入订单</p><div class="cart-list"><article v-for="item in cart" :key="item.id"><div><strong>{{ item.name }}</strong><input v-model.number="item.unit_price" type="number" min="0" step="0.01" /></div><div class="quantity-stepper"><button @click="changeQuantity(item,-1)">−</button><b>{{ item.quantity }}</b><button @click="changeQuantity(item,1)">＋</button><span>{{ money(item.quantity * item.unit_price) }}</span></div></article></div><label>客户名称<input v-model="orderCustomer.name" placeholder="临时客户可直接填写" /></label><label>联系人 / 手机<input v-model="orderCustomer.contact_name" placeholder="联系人" /><input v-model="orderCustomer.phone" placeholder="手机号" /></label><label>收货地址<input v-model="orderCustomer.address" placeholder="自提可留空" /></label><label>配送方式<select v-model="orderShipping"><option value="pickup">自提</option><option value="local_delivery">本地配送</option><option value="express">快递</option><option value="logistics">物流</option><option value="other">其他</option></select></label><label>收款方式<select v-model="payment"><option value="cash">现金</option><option value="bank_transfer">转账</option><option value="wechat">微信</option><option value="alipay">支付宝</option><option value="bank_card">银行卡</option><option value="other">其他</option></select></label><label>整单优惠<input v-model.number="discount" type="number" min="0" step="0.01" /></label><label>运费<input v-model.number="orderFreight" type="number" min="0" step="0.01" /></label><label>已收金额<input v-model.number="orderReceived" type="number" min="0" step="0.01" /></label><label>客户备注<input v-model="saleNote" placeholder="选填" /></label><div class="order-total"><span>应收合计</span><strong>{{ money(cartTotal) }}</strong><small>未收 {{ money(cartTotal - Number(orderReceived || 0)) }}</small></div><button class="glass-primary-btn checkout-submit" :disabled="submitting || !cart.length" @click="completeSale">{{ submitting ? '正在保存…' : '保存待确认订单' }}</button></aside>
        </section>
      </template>

      <template v-else-if="currentSection === 'orders'">
        <div class="inventory-section-heading"><div><p class="eyebrow">SALES ORDERS</p><h2>订单列表</h2></div><button class="glass-primary-btn" @click="openSection('checkout')">新建订单</button></div>
        <section class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索订单号、客户、联系人、手机号" /></div><div class="order-list"><article v-for="order in orders.filter((item) => `${item.order_no} ${item.customer_name || ''} ${item.contact_name || ''} ${item.contact_phone || ''}`.toLowerCase().includes(search.toLowerCase()))" :key="order.id"><div><strong>{{ order.order_no }}</strong><small>{{ order.customer_name || '临时客户' }}{{ order.contact_name ? ` · ${order.contact_name}` : '' }} · {{ dateText(order.created_at) }}</small><small>{{ order.order_status }} · {{ order.fulfillment_status }} · {{ order.payment_status }}</small></div><b>{{ money(order.total_amount) }}</b><button class="mini-btn edit-btn" @click="openOrder(order)">{{ order.fulfillment_status === 'not_fulfilled' ? '查看 / 确认出库' : '查看详情' }}</button></article><p v-if="!orders.length" class="empty-state">还没有订单。</p></div></section>
      </template>

      <template v-else-if="currentSection === 'products'">
        <div class="inventory-section-heading"><div><p class="eyebrow">CATALOG</p><h2>商品管理</h2></div><button class="glass-primary-btn" @click="editProduct()">新增商品</button></div>
        <section v-if="showEditor" class="inventory-glass-card"><form class="inventory-form" @submit.prevent="saveProduct"><label><span>商品名称</span><input v-model="editor.name" required /></label><label><span>SKU / 货号</span><input v-model="editor.sku" required /></label><label><span>规格</span><input v-model="editor.specification" placeholder="例如：500ml / 红色" /></label><label><span>分类</span><input v-model="editor.category" placeholder="例如：饮料" /></label><label><span>图片 URL</span><input v-model="editor.image_url" type="url" placeholder="选填" /></label><label><span>进货价</span><input v-model.number="editor.cost_price" type="number" min="0" step="0.01" /></label><label><span>销售价</span><input v-model.number="editor.sale_price" type="number" min="0" step="0.01" /></label><label v-if="!editor.id"><span>初始可售库存</span><input v-model.number="editor.stock" type="number" min="0" step="1" /></label><label><span>库存预警值</span><input v-model.number="editor.low_stock_threshold" type="number" min="0" step="1" /></label><div class="inventory-form-actions"><button class="glass-secondary-btn" type="button" @click="showEditor=false">取消</button><button class="glass-primary-btn" :disabled="submitting">{{ submitting ? '保存中…' : '保存商品' }}</button></div></form></section>
        <section class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索商品、SKU" /><select v-model="category"><option value="">全部分类</option><option v-for="item in categories" :key="item">{{ item }}</option></select></div><div class="product-manage-grid"><article v-for="product in visibleProducts" :key="product.id" class="product-manage-card"><img v-if="product.image_url" :src="product.image_url" :alt="product.name" /><span v-else class="product-image-placeholder">{{ product.name.slice(0,1) }}</span><div><small>{{ product.category }} · {{ product.sku }}</small><h3>{{ product.name }}</h3><p>进 {{ money(product.cost_price) }} · 售 {{ money(product.sale_price) }}</p><p>单件毛利 <b>{{ money(product.sale_price - product.cost_price) }}</b></p></div><strong>{{ product.stock }}<small> 件</small></strong><footer><button class="mini-btn edit-btn" @click="editProduct(product)">快速修改</button><button class="mini-btn delete-btn" @click="deleteProduct(product)">删除</button></footer></article><p v-if="!visibleProducts.length" class="empty-state">还没有商品，先新增一件吧。</p></div></section>
      </template>

      <template v-else-if="currentSection === 'inbound'"><div class="inventory-section-heading"><div><p class="eyebrow">INBOUND</p><h2>入库登记</h2></div></div><section class="inventory-glass-card movement-card"><form class="inventory-form" @submit.prevent="submitInbound"><label><span>选择商品</span><InventorySearchSelect v-model="inbound.product" :options="productOptions" placeholder="输入商品名称、SKU 或规格" @change="selectInbound" /></label><label><span>入库数量</span><input v-model.number="inbound.quantity" type="number" min="1" /></label><label><span>实际进货单价</span><input v-model.number="inbound.price" type="number" min="0" step="0.01" /></label><label><span>进货总金额</span><output>{{ money(inboundTotal) }}</output></label><label><span>供应商</span><InventorySearchSelect v-model="inbound.supplier" :options="supplierOptions" :allow-custom="true" placeholder="输入或搜索历史供应商" /></label><label><span>备注</span><input v-model="inbound.note" placeholder="选填" /></label><button class="glass-primary-btn" :disabled="submitting">{{ submitting ? '提交中…' : '确认入库' }}</button></form></section></template>
      <template v-else-if="currentSection === 'outbound'"><div class="inventory-section-heading"><div><p class="eyebrow">OUTBOUND</p><h2>普通出库与损耗</h2></div><button class="glass-action-btn" @click="openSection('checkout')">销售开单</button></div><section class="inventory-glass-card movement-card"><form class="inventory-form" @submit.prevent="submitOutbound"><label><span>出库类型</span><select v-model="outbound.type"><option value="normal_outbound">普通出库</option><option value="loss">损耗</option></select></label><label><span>选择商品</span><InventorySearchSelect v-model="outbound.product" :options="productOptions" placeholder="输入商品名称、SKU 或规格" /></label><label><span>数量</span><input v-model.number="outbound.quantity" type="number" min="1" /></label><label><span>备注</span><input v-model="outbound.note" placeholder="例如：赠品、过期损耗" /></label><button class="glass-primary-btn" :disabled="submitting">{{ submitting ? '提交中…' : '确认出库' }}</button></form></section></template>
      <template v-else-if="currentSection === 'returns'"><div class="inventory-section-heading"><div><p class="eyebrow">RETURNS</p><h2>销售退货</h2></div><button class="glass-primary-btn" @click="walkInReturn={ open:true, product:'', quantity:1, refund:0, method:'cash', reason:'', condition:'resellable', note:'', requestKey:requestKey() }">无单退货</button></div><section class="inventory-glass-card"><p class="return-note">优先从订单详情发起退货；无原订单时可登记无单退货。</p><div class="order-list"><article v-for="order in orders" :key="order.id"><div><strong>{{ order.order_no }}</strong><small>{{ dateText(order.created_at) }} · {{ order.payment_status }} · {{ order.return_status }}</small></div><b>{{ money(order.net_sales ?? order.total_amount) }}</b><button class="mini-btn edit-btn" @click="openOrder(order)">查看 / 退货</button></article><p v-if="!orders.length" class="empty-state">暂无销售订单。</p></div></section></template>
      <template v-else-if="currentSection === 'stock'"><div class="inventory-section-heading"><div><p class="eyebrow">STOCK HEALTH</p><h2>库存状态</h2></div></div><section class="inventory-stock-grid"><article v-for="product in products" :key="product.id" class="inventory-stock-card"><div><small>{{ product.category }} · {{ product.sku }}</small><h3>{{ product.name }}</h3><p>可售 {{ product.stock }} · 待处理 {{ product.pending_stock }} · 损耗 {{ product.damaged_quantity }}</p></div><strong>{{ product.stock }}<small> 件</small></strong><span class="status-pill" :class="statusClass(product)">{{ status(product) }}</span><footer>库存成本 {{ money(product.stock * product.cost_price) }} <button v-if="product.pending_stock" class="mini-btn edit-btn" @click="openPending(product)">处理待检查 {{ product.pending_stock }}</button></footer></article><p v-if="!products.length" class="empty-state inventory-glass-card">还没有库存数据。</p></section></template>
      <template v-else><div class="inventory-section-heading"><div><p class="eyebrow">AUDIT TRAIL</p><h2>统一经营流水</h2></div></div><section class="inventory-glass-card"><div class="log-filters"><select v-model="logFilters.type"><option value="">全部操作</option><option value="sale">销售</option><option value="inbound">入库</option><option value="normal_outbound">普通出库</option><option value="loss">损耗</option><option value="adjustment">库存调整</option></select><select v-model="logFilters.product"><option value="">全部商品</option><option v-for="product in products" :key="product.id" :value="product.id">{{ product.name }}</option></select><input v-model="logFilters.date" type="date" /></div><div class="flow-list"><article v-for="item in filteredLogs" :key="item.id"><span class="log-type" :class="`log-${item.operation_type}`">{{ typeText(item.operation_type) }}</span><div><strong>{{ item.inventory_products?.name || '商品' }}</strong><small>{{ dateText(item.created_at) }}{{ item.note ? ` · ${item.note}` : '' }}</small></div><b :class="item.quantity > 0 ? 'amount-in' : 'amount-out'">{{ item.quantity > 0 ? '+' : '' }}{{ item.quantity }} 件</b><em>{{ money(item.total_amount) }}</em></article><p v-if="!filteredLogs.length" class="empty-state">没有符合条件的流水。</p></div></section></template>
      <section v-if="currentSection === 'logs'" class="inventory-glass-card business-flow-center">
        <div class="inventory-card-title"><div><p class="eyebrow">BUSINESS DOCUMENTS</p><h3>业务单据</h3></div><input v-model="logFilters.business" placeholder="搜索业务单号" /></div>
        <div class="business-flow-list">
          <article v-for="item in filteredLogs.filter((row) => row.business_no)" :key="item.id" @click="openFlow(item)">
            <div><strong>{{ item.business_no }}</strong><small>{{ typeText(item.operation_type) }} · {{ item.inventory_products?.name || '商品' }} × {{ Math.abs(item.quantity) }} · {{ dateText(item.created_at) }}</small></div>
            <b>{{ money(item.total_amount) }}</b><button class="mini-btn edit-btn" @click.stop="copyBusinessNo(item.business_no)">复制</button>
          </article>
          <p v-if="!filteredLogs.some((row) => row.business_no)" class="empty-state">新产生的业务单据会在这里显示。</p>
        </div>
      </section>
    </main>
    <div v-if="orderDetail.open || returnDraft.open || walkInReturn.open || pendingAction.open || flowDetail.open" class="inventory-dialog-backdrop" @click.self="closeInventoryDialog">
      <section v-if="flowDetail.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">BUSINESS DETAIL</p><h3>{{ flowDetail.movement.business_no || '库存流水详情' }}</h3></div><button class="mini-btn" @click="flowDetail.open=false">关闭</button></div><p>{{ typeText(flowDetail.movement.operation_type) }} · {{ dateText(flowDetail.movement.created_at) }}</p><div v-if="flowDetail.record" class="dialog-lines"><p><span>业务状态</span><b>{{ flowDetail.record.order_status || flowDetail.record.return_no || '已完成' }}</b></p><p><span>付款/退款</span><b>{{ flowDetail.record.payment_status || flowDetail.record.refund_method || '--' }}</b></p><p v-if="flowDetail.record.original_business_no"><span>原业务单号</span><b>{{ flowDetail.record.original_business_no }}</b></p><p v-for="item in flowDetail.items" :key="item.id"><span>{{ item.product_name }} × {{ item.quantity }}</span><b>{{ money(item.line_total ?? (item.unit_price * item.quantity)) }}</b></p></div><div v-else class="dialog-lines"><p><span>商品</span><b>{{ flowDetail.movement.inventory_products?.name || '--' }}</b></p><p><span>库存变化</span><b>{{ flowDetail.movement.before_sellable_stock ?? '--' }} → {{ flowDetail.movement.quantity }} → {{ flowDetail.movement.after_sellable_stock ?? '--' }}</b></p><p><span>备注</span><b>{{ flowDetail.movement.note || '--' }}</b></p></div><button class="glass-action-btn" @click="copyBusinessNo(flowDetail.movement.business_no)">复制单号</button></section>
      <section v-else-if="orderDetail.open && !returnDraft.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">ORDER</p><h3>{{ orderDetail.order.order_no }}</h3></div><button class="mini-btn" @click="orderDetail.open=false">关闭</button></div><p class="order-status">{{ orderDetail.order.order_status }} / {{ orderDetail.order.payment_status }} / {{ orderDetail.order.fulfillment_status }}</p><div class="dialog-lines"><p><span>客户 / 联系方式</span><b>{{ orderDetail.order.customer_name || '临时客户' }} {{ orderDetail.order.contact_phone || '' }}</b></p><p><span>配送</span><b>{{ orderDetail.order.shipping_method }} {{ orderDetail.order.tracking_no || '' }}</b></p><p><span>金额</span><b>应收 {{ money(orderDetail.order.total_amount) }} · 已收 {{ money(orderDetail.order.received_amount) }}</b></p><p v-for="item in orderDetail.items" :key="item.id"><span>{{ item.product_name }} {{ item.specification || '' }} × {{ item.quantity }}</span><b>{{ money(item.line_total) }}</b></p></div><div class="dialog-lines" v-if="orderDetail.returns.length"><p v-for="item in orderDetail.returns" :key="item.id"><span>{{ item.return_no }} · {{ item.reason }}</span><b>退款 {{ money(item.refund_amount) }}</b></p></div><div class="inventory-form-actions"><button v-if="orderDetail.order.fulfillment_status === 'not_fulfilled' && orderDetail.order.order_status !== 'cancelled'" class="glass-primary-btn" :disabled="submitting" @click="fulfillOrder(orderDetail.order)">{{ submitting ? '出库中…' : '确认出库' }}</button><button v-if="orderDetail.order.fulfillment_status === 'fulfilled'" class="glass-primary-btn" :disabled="orderDetail.order.return_status === 'full'" @click="beginOrderReturn">发起退货</button><button class="glass-action-btn" @click="copyBusinessNo(orderDetail.order.order_no)">复制单号</button></div></section>
      <section v-else-if="returnDraft.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">SALE RETURN</p><h3>销售退货</h3></div><button class="mini-btn" @click="returnDraft.open=false">关闭</button></div><div class="return-items"><article v-for="item in returnDraft.items" :key="item.id"><strong>{{ item.product_name }}</strong><small>可退 {{ item.max }} 件 · 原价 {{ money(item.unit_price) }}</small><input v-model.number="item.quantity" type="number" min="0" :max="item.max" @input="syncRefund" /><select v-model="item.condition"><option value="resellable">完好 / 可销售</option><option value="damaged">损坏 / 损耗</option><option value="pending">待检查</option></select></article></div><label>退款金额<input v-model.number="returnDraft.refund" type="number" min="0" step="0.01" :placeholder="money(suggestedRefund)" /></label><label>退款方式<select v-model="returnDraft.method"><option value="cash">现金</option><option value="wechat">微信</option><option value="alipay">支付宝</option><option value="bank_card">银行卡</option><option value="other">其他</option></select></label><label>退货原因<input v-model="returnDraft.reason" /></label><label>备注<input v-model="returnDraft.note" /></label><button class="glass-primary-btn" :disabled="submitting" @click="submitOrderReturn">{{ submitting ? '处理中…' : '确认退货并退款' }}</button></section>
      <section v-else-if="walkInReturn.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">WALK-IN RETURN</p><h3>无原订单退货</h3></div><button class="mini-btn" @click="walkInReturn.open=false">关闭</button></div><label>商品<InventorySearchSelect v-model="walkInReturn.product" :options="productOptions" placeholder="输入商品名称、SKU 或规格" /></label><label>数量<input v-model.number="walkInReturn.quantity" type="number" min="1" /></label><label>退款金额<input v-model.number="walkInReturn.refund" type="number" min="0" step="0.01" /></label><label>退款方式<select v-model="walkInReturn.method"><option value="cash">现金</option><option value="wechat">微信</option><option value="alipay">支付宝</option><option value="bank_card">银行卡</option><option value="other">其他</option></select></label><label>商品状态<select v-model="walkInReturn.condition"><option value="resellable">完好 / 可销售</option><option value="damaged">损坏 / 损耗</option><option value="pending">待检查</option></select></label><label>退货原因<input v-model="walkInReturn.reason" /></label><label>备注<input v-model="walkInReturn.note" /></label><button class="glass-primary-btn" :disabled="submitting" @click="submitWalkInReturn">{{ submitting ? '处理中…' : '确认无单退货' }}</button></section>
      <section v-else class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">PENDING STOCK</p><h3>处理待检查库存</h3></div><button class="mini-btn" @click="pendingAction.open=false">关闭</button></div><p>{{ pendingAction.product.name }} · 当前待处理 {{ pendingAction.product.pending_stock }} 件</p><label>数量<input v-model.number="pendingAction.quantity" type="number" min="1" :max="pendingAction.product.pending_stock" /></label><label>处理结果<select v-model="pendingAction.action"><option value="restore">恢复可售</option><option value="loss">确认损耗</option></select></label><label>处理原因<input v-model="pendingAction.reason" /></label><button class="glass-primary-btn" :disabled="submitting" @click="submitPending">{{ submitting ? '处理中…' : '确认处理' }}</button></section>
    </div>
    <GlassModal v-if="modal.show" :message="modal.message" :cancel-text="modal.mode === 'delete' ? '取消' : ''" :confirm-text="modal.mode === 'delete' ? '删除' : '知道了'" @close="closeModal" @cancel="closeModal" @confirm="confirmModal" />
  </div>
</template>
