<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import InventoryProfit from '../components/InventoryProfit.vue'
import { defaultProfitSettings, evaluateProfit } from '../inventoryProfit'
import { useRoute, useRouter } from 'vue-router'
import InventoryNavigation from '../components/InventoryNavigation.vue'
import FunctionHeader from '../components/FunctionHeader.vue'
import GlassModal from '../components/GlassModal.vue'
import InventorySearchSelect from '../components/InventorySearchSelect.vue'
import SalesPrintDialog from '../components/SalesPrintDialog.vue'
import { defaultPrintSettings, normalizePrintSettings, PRINT_FIELD_GROUPS, toPrintOrder } from '../inventoryPrint'
import { supabase } from '../supabase'

const route = useRoute()
const router = useRouter()
const products = ref([])
const movements = ref([])
const orders = ref([])
const returns = ref([])
const orderDetail = ref({ open: false, order: null, items: [], returns: [] })
const flowDetail = ref({ open: false, movement: null, record: null, items: [], loading: false, error: '' })
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
const orderCustomer = ref({ id: '', name: '', contact_name: '', phone: '', address: '' })
const customerPick = ref('')
const customers = ref([])
const pendingToast = ref('')
let pendingToastTimer = 0
let knownPendingIds = new Set()
let ordersChannel = null
let suppressPendingToast = true
const orderFreight = ref(0)
const orderReceived = ref(0)
const orderShipping = ref('pickup')
const organization = ref(null)
const organizationName = ref('')
const organizationLoading = ref(false)
const productSources = ref({})
const isSuperAdmin = ref(false)
const profitSettings = ref(defaultProfitSettings())
const profitDraft = ref(defaultProfitSettings())
const lowProfit = (revenue, cost, quantity) => evaluateProfit(revenue, cost, quantity, profitSettings.value)?.low || false
const savingProfitSettings = ref(false)
const profitSettingsError = ref('')
const printSettings = ref(defaultPrintSettings())
const printDraft = ref(defaultPrintSettings())
const savingPrintSettings = ref(false)
const printJob = ref(null)
const readInventory = (resource, id = null) => supabase.rpc('inventory_read', { p_resource: resource, p_id: id })
async function refreshProfitSettings() {
  if (!isSuperAdmin.value) return
  const { data, error } = await supabase.rpc('inventory_profit_settings')
  if (error) { profitSettingsError.value = error.message; return }
  profitSettings.value = data
  profitSettingsError.value = ''
}
async function refreshPrintSettings() {
  const { data, error } = await supabase.rpc('inventory_print_settings')
  if (error || !data) return
  printSettings.value = normalizePrintSettings({ ...data, company_name: data.company_name || organization.value?.name || '' })
}
async function openPrintSettings() {
  printDraft.value = normalizePrintSettings({ ...printSettings.value, company_name: printSettings.value.company_name || organization.value?.name || '' })
  openSection('print')
}
async function savePrintSettings() {
  if (!isSuperAdmin.value) return message('只有超级管理员可以修改打印设置。')
  savingPrintSettings.value = true
  const payload = normalizePrintSettings(printDraft.value)
  const { error } = await supabase.rpc('inventory_print_settings', { p_settings: payload })
  savingPrintSettings.value = false
  if (error) return message(`打印设置保存失败：${error.message}`)
  printSettings.value = payload
  message('打印设置已保存。')
}
async function openPrint(order, items) {
  let source = order
  let lines = items
  if (order?.id) {
    const { data, error } = await supabase.rpc('inventory_print_order', { p_order_id: order.id })
    if (!error && data?.order_no) { source = data; lines = data.inventory_order_items || lines }
  }
  const printable = toPrintOrder(source, lines)
  if (!printable) return message('这张单据没有可打印的销售单。')
  printJob.value = printable
}
async function openProfitControls() {
  await refreshProfitSettings()
  profitDraft.value = { ...profitSettings.value }
  openSection('controls')
}
async function saveProfitSettings() {
  savingProfitSettings.value = true
  try {
    const { data, error } = await supabase.rpc('inventory_profit_settings', { p_settings: profitDraft.value })
    if (error) throw error
    profitSettings.value = data
    profitSettingsError.value = ''
    message('经营控制已保存。')
  } catch (error) { profitSettingsError.value = error.message }
  finally { savingProfitSettings.value = false }
}
const productDetail = ref({ open: false, product: null, suppliers: [], batches: [] })

const sections = [['dashboard', '总览'], ['checkout', '开单'], ['pending', '待确认'], ['orders', '订单'], ['products', '商品'], ['inbound', '入库'], ['outbound', '出库'], ['returns', '退货'], ['stock', '库存'], ['logs', '流水'], ['documents', '单据']]
const currentSection = computed(() => route.params.section || 'dashboard')
const sectionTitle = computed(() => ({ controls: '经营控制', print: '打印设置', dashboard: '进销存总览', checkout: '快速开单', pending: '待确认出库', orders: '销售订单', products: '商品管理', inbound: '入库登记', outbound: '出库登记', returns: '销售退货', stock: '库存状态', logs: '经营流水', documents: '业务单据' }[currentSection.value] || '进销存总览'))
const categories = computed(() => [...new Set(products.value.map((p) => p.category).filter(Boolean))])
const productOptions = computed(() => products.value.map((product) => ({ id: product.id, label: product.name, description: `${product.sku}${product.specification ? ` · ${product.specification}` : ''} · 可售 ${product.stock} 件` })))
const supplierOptions = computed(() => [...new Set(movements.value.filter((item) => item.operation_type === 'inbound' && item.supplier).map((item) => item.supplier.trim()).filter(Boolean))].map((supplier) => ({ id: supplier, label: supplier, description: '历史入库供应商' })))
const customerOptions = computed(() => {
  const records = new Map()
  const keyOf = (name, address) => `${String(name || '').trim().toLowerCase()}|${String(address || '').trim().toLowerCase()}`
  for (const customer of customers.value) {
    const name = String(customer.name || '').trim()
    if (!name) continue
    const key = keyOf(name, customer.address)
    if (records.has(key)) continue
    records.set(key, {
      id: customer.id || '',
      name,
      contact_name: customer.contact_name || '',
      phone: customer.phone || '',
      address: customer.address || '',
      source: 'customer',
    })
  }
  for (const order of orders.value) {
    const name = String(order.customer_name || '').trim()
    if (!name) continue
    const key = keyOf(name, order.shipping_address)
    if (records.has(key)) continue
    records.set(key, {
      id: order.customer_id || '',
      name,
      contact_name: order.contact_name || '',
      phone: order.contact_phone || '',
      address: order.shipping_address || '',
      source: 'order',
    })
  }
  return [...records.values()].map((customer) => ({
    id: customer.id || `${customer.name}|${customer.address}`,
    label: customer.name,
    description: [customer.contact_name, customer.phone, customer.address].filter(Boolean).join(' · ') || (customer.source === 'customer' ? '客户资料' : '历史订单客户'),
    customer,
  }))
})
const orderListRows = computed(() => orders.value.map((order) => ({ ...order, items: order.inventory_order_items || [] })))
const pendingOrders = computed(() => orderListRows.value.filter((order) => order.fulfillment_status === 'not_fulfilled' && !['completed', 'cancelled'].includes(order.order_status)))
const pendingCount = computed(() => pendingOrders.value.length)
const completedOrderRows = computed(() => orderListRows.value.filter((order) => !pendingOrders.value.some((pending) => pending.id === order.id)))
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
const orderStatusText = (value) => ({ pending_confirmation: '待确认', pending_fulfillment: '待出库', pending_shipment: '待发货', shipped: '已发货', completed: '已完成', cancelled: '已取消', returned: '已退货', partially_returned: '部分退货' })[value] || value || '待处理'
const paymentStatusText = (value) => ({ unpaid: '待付款', partially_paid: '部分付款', paid: '已付款', partially_refunded: '部分退款', refunded: '已退款' })[value] || value || '待付款'
const fulfillmentStatusText = (value) => ({ not_fulfilled: '待出库', fulfilled: '已出库' })[value] || value || '待出库'
const shippingText = (value) => ({ pickup: '自提', local_delivery: '本地配送', express: '快递', logistics: '物流', other: '其他' })[value] || value || '自提'
const documentStatusText = (record, movement) => {
  if (record?.return_no) return '已完成'
  if (record?.order_status) return orderStatusText(record.order_status)
  if (movement?.operation_type === 'inbound') return '已入库'
  if (movement?.operation_type === 'purchase_return') return '已退回供应商'
  return '已完成'
}
const refundMethodText = (value) => ({ cash: '现金', wechat: '微信', alipay: '支付宝', bank_card: '银行卡', other: '其他' })[value] || value || '未填写'
const originalDocumentItem = (item) => flowDetail.value.record?.original_order?.inventory_order_items?.find((original) => original.id === item.order_item_id)
const documentItemSku = (item) => [item.specification || originalDocumentItem(item)?.specification, item.sku || originalDocumentItem(item)?.sku].filter(Boolean).join(' · ') || '—'
const documentItemSupplier = (item) => item.inventory_suppliers?.name || originalDocumentItem(item)?.inventory_suppliers?.name || flowDetail.value.movement?.supplier || '未指定'
function returnedQuantity(itemId) {
  return orderDetail.value.returns.flatMap((record) => record.inventory_return_items || []).filter((item) => item.order_item_id === itemId).reduce((sum, item) => sum + Number(item.quantity || 0), 0)
}

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
  productDetail.value.open = false
  printJob.value = null
}
function editProduct(product) { editor.value = product ? { ...product } : blankProduct(); showEditor.value = true }
function selectInbound() { if (selectedInbound.value && !inbound.value.price) inbound.value.price = selectedInbound.value.cost_price }
function status(product) { return Number(product.stock) <= 0 ? '缺货' : Number(product.stock) <= Number(product.low_stock_threshold) ? '库存不足' : '库存正常' }
function statusClass(product) { return Number(product.stock) <= 0 ? 'status-danger' : Number(product.stock) <= Number(product.low_stock_threshold) ? 'status-warning' : 'status-good' }

async function loadData() {
  if (!supabase) return
  loading.value = true
  errorMessage.value = ''
  const [productRes, movementRes, orderRes, returnRes, roleRes] = await Promise.all([
    readInventory('products'),
    readInventory('movements'),
    readInventory('orders'),
    readInventory('returns'),
    supabase.rpc('inventory_has_role', { p_roles: ['super_admin'] }),
  ])
  const failure = productRes.error || movementRes.error || orderRes.error || returnRes.error
  if (failure) errorMessage.value = `读取失败：${failure.message}。请确认已执行 inventory_profit_controls.sql。`
  else { products.value = productRes.data || []; movements.value = movementRes.data || []; orders.value = orderRes.data || []; returns.value = returnRes.data || []; isSuperAdmin.value = Boolean(roleRes.data) }
  const customerRes = await supabase.from('inventory_customers').select('id,name,contact_name,phone,address').order('updated_at', { ascending: false })
  if (!customerRes.error) customers.value = customerRes.data || []
  rememberPendingIds()
  suppressPendingToast = false
  await refreshProfitSettings()
  await refreshPrintSettings()
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
  bindOrdersRealtime()
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
  if (!isSuperAdmin.value) return message('采购成本由超级管理员登记。')
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
function blankCustomer() { return { id: '', name: '', contact_name: '', phone: '', address: '' } }
function selectCustomer(value) {
  const pick = String(value || '').trim()
  customerPick.value = pick
  if (!pick) {
    orderCustomer.value = blankCustomer()
    return
  }
  const match = customerOptions.value.find((item) => item.id === pick || item.label === pick)
  if (match?.customer) {
    orderCustomer.value = {
      id: match.customer.id || '',
      name: match.customer.name,
      contact_name: match.customer.contact_name || '',
      phone: match.customer.phone || '',
      address: match.customer.address || '',
    }
    return
  }
  orderCustomer.value = { ...orderCustomer.value, id: '', name: pick }
}
watch(customerPick, (value) => {
  const pick = String(value || '').trim()
  if (!pick) return
  if (customerOptions.value.some((item) => item.id === pick)) return
  if (orderCustomer.value.id || orderCustomer.value.name === pick) return
  orderCustomer.value = { ...orderCustomer.value, id: '', name: pick }
})
function showPendingToast(orderNo) {
  if (!orderNo) return
  pendingToast.value = `收到新的待确认订单：#${orderNo}`
  window.clearTimeout(pendingToastTimer)
  pendingToastTimer = window.setTimeout(() => { pendingToast.value = '' }, 4200)
}
function rememberPendingIds(list = pendingOrders.value) {
  knownPendingIds = new Set(list.map((order) => order.id).filter(Boolean))
}
function noticeNewPendingOrders(previousIds = knownPendingIds) {
  const next = pendingOrders.value
  const fresh = next.filter((order) => order.id && !previousIds.has(order.id))
  rememberPendingIds(next)
  if (suppressPendingToast || !fresh.length) return
  const newest = [...fresh].sort((a, b) => new Date(b.created_at) - new Date(a.created_at))[0]
  showPendingToast(newest.order_no)
}
async function refreshOrdersQuietly() {
  if (!supabase || !organization.value) return
  const previousIds = new Set(knownPendingIds)
  const orderRes = await readInventory('orders')
  if (orderRes.error) return
  orders.value = orderRes.data || []
  noticeNewPendingOrders(previousIds)
}
function bindOrdersRealtime() {
  if (!supabase || !organization.value?.id) return
  if (ordersChannel) supabase.removeChannel(ordersChannel)
  ordersChannel = supabase.channel(`inventory-orders:${organization.value.id}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'inventory_orders', filter: `organization_id=eq.${organization.value.id}` }, () => { refreshOrdersQuietly() })
    .subscribe()
}
function addCart(product) {
  if (!product.stock) return message('库存不足，不能加入订单。')
  const item = cart.value.find((p) => p.id === product.id)
  if (item) { if (item.quantity < product.stock) item.quantity += 1; else message('已达到可售库存。') }
  else {
    cart.value.push({ ...product, quantity: 1, unit_price: Number(product.sale_price), source_supplier_id: '' })
    loadProductSources(product.id)
  }
}
async function loadProductSources(productId) {
  const { data, error } = await supabase.rpc('inventory_available_sources', { p_product_id: productId })
  if (!error) productSources.value = { ...productSources.value, [productId]: data || [] }
}
async function openProductDetail(product) {
  let suppliers = []
  let batches = []
  if (isSuperAdmin.value) {
    const [supplierRes, batchRes] = await Promise.all([
      supabase.from('inventory_product_suppliers').select('*, inventory_suppliers(name)').eq('product_id', product.id),
      supabase.from('inventory_purchase_batches').select('*, inventory_suppliers(name)').eq('product_id', product.id).order('received_at', { ascending: true }),
    ])
    if (supplierRes.error || batchRes.error) return message(`商品详情读取失败：${supplierRes.error?.message || batchRes.error?.message}`)
    suppliers = supplierRes.data || []
    batches = batchRes.data || []
  }
  productDetail.value = { open: true, product, suppliers, batches }
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
    const { data: orderId, error } = await supabase.rpc('inventory_create_order', {
      p_items: cart.value.map((p) => ({ product_id: p.id, quantity: p.quantity, unit_price: Number(p.unit_price), discount_amount: 0 })),
      p_customer: {
        id: orderCustomer.value.id || null,
        name: orderCustomer.value.name,
        contact_name: orderCustomer.value.contact_name,
        phone: orderCustomer.value.phone,
        address: orderCustomer.value.address,
      },
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
    const selectedSources = cart.value.filter((item) => item.source_supplier_id)
    if (selectedSources.length) {
      const { data: savedOrders, error: itemsError } = await readInventory('orders', orderId)
      const orderItems = savedOrders?.[0]?.inventory_order_items || []
      if (itemsError) return message(`订单已创建，但来源保存失败：${itemsError.message}`)
      const { error: sourcesError } = await supabase.rpc('inventory_assign_order_sources', { p_order_id: orderId, p_sources: selectedSources.map((item) => ({ order_item_id: orderItems.find((row) => row.product_id === item.id)?.id, supplier_id: item.source_supplier_id })) })
      if (sourcesError) return message(`订单已创建，但来源保存失败：${sourcesError.message}`)
    }
    cart.value = []; payment.value = 'cash'; discount.value = 0; saleNote.value = ''; orderFreight.value = 0; orderReceived.value = 0; orderShipping.value = 'pickup'; orderCustomer.value = blankCustomer(); customerPick.value = ''
    suppressPendingToast = true
    await loadData()
    suppressPendingToast = false
    openSection('pending'); message('订单已保存，请在待确认页面确认出库。')
  } catch (error) {
    message('开单失败：' + (error.message || '请检查网络后重试'))
  } finally {
    submitting.value = false
  }
}
async function openOrder(order) {
  const [orderRes, returnRes] = await Promise.all([readInventory('orders', order.id), readInventory('returns', order.id)])
  if (orderRes.error || returnRes.error) return message('订单详情读取失败：' + (orderRes.error?.message || returnRes.error?.message))
  const freshOrder = orderRes.data?.[0]
  if (!freshOrder) return message('订单不存在或无权访问。')
  let allocations = []
  const items = freshOrder.inventory_order_items || []
  if (isSuperAdmin.value && items.length) {
    const result = await supabase.from('inventory_order_item_batch_allocations').select('*, inventory_purchase_batches(batch_no, inventory_suppliers(name))').in('order_item_id', items.map((item) => item.id))
    if (result.error) return message(result.error.message)
    allocations = result.data || []
  }
  orderDetail.value = { open: true, order: freshOrder, items, returns: returnRes.data || [], allocations }
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
  if (!order) return message('无法退货：订单信息未加载，请重新打开订单。')
  if (order.order_status === 'cancelled') return message('无法退货：该订单已取消。')
  if (order.return_status === 'full') return message('无法退货：该订单商品已全部退货。')
  if (order.order_status !== 'completed') return message('无法退货：当前订单状态为“' + orderStatusText(order.order_status) + '”，订单完成后才能退货。')
  if (!items.length) return message('无法退货：订单没有商品明细，请刷新后重试。')
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
  if (submitting.value) return
  const draft = returnDraft.value
  draft.error = ''
  const items = draft.items.filter((item) => Number(item.quantity) > 0)
  if (!items.length) { draft.error = '请选择退货商品并填写数量。'; return }
  if (!draft.reason.trim()) { draft.error = '请填写退货原因。'; return }
  if (items.some((item) => !Number.isInteger(Number(item.quantity)) || Number(item.quantity) > Number(item.max))) { draft.error = '退货数量必须为整数，且不能超过可退数量。'; return }
  submitting.value = true
  try {
    const { error } = await supabase.rpc('inventory_create_sale_return', {
      p_order_id: draft.order.id,
      p_items: items.map((item) => ({ order_item_id: item.id, quantity: Number(item.quantity), condition: item.condition })),
      p_refund_amount: Number(draft.refund || 0),
      p_refund_method: draft.method,
      p_reason: draft.reason.trim(),
      p_note: draft.note || null,
      p_request_key: draft.requestKey,
    })
    if (error) { draft.error = '退货失败：' + error.message; return }
    returnDraft.value.open = false
    orderDetail.value.open = false
    await loadData()
    message('退货完成，退款、订单状态、库存和流水已同步更新。')
  } catch (error) {
    draft.error = '退货提交异常：' + (error.message || '请检查网络及退货记录后重试')
  } finally {
    submitting.value = false
  }
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
  // Open first so a slow or incomplete legacy record never feels like a dead click.
  flowDetail.value = { open: true, movement, record: null, items: [], loading: true, error: '' }
  let result = null
  let items = []
  try {
    if (movement.business_type === 'sale') {
      const response = await readInventory('orders', movement.business_id || movement.order_id)
      if (response.error) throw response.error
      result = response.data?.find((row) => row.id === (movement.business_id || movement.order_id) || row.order_no === movement.business_no)
      items = result?.inventory_order_items || []
    } else if (movement.business_type === 'sale_return') {
      const [response, orderResponse] = await Promise.all([readInventory('returns', movement.order_id), readInventory('orders', movement.order_id)])
      if (response.error) throw response.error
      if (orderResponse.error) throw orderResponse.error
      result = response.data?.find((row) => row.id === movement.business_id || row.return_no === movement.business_no)
      if (result) result = { ...result, original_order: orderResponse.data?.[0] || null }
      items = result?.inventory_return_items || []
    }
  } catch (error) {
    flowDetail.value = { ...flowDetail.value, loading: false, error: error.message || '关联详情暂时无法读取。' }
    return
  }
  flowDetail.value = { ...flowDetail.value, record: result, items, loading: false }
}
async function copyBusinessNo(value) {
  try { await navigator.clipboard.writeText(value); message('业务单号已复制。') } catch { message('当前浏览器不支持复制，请手动复制单号。') }
}
function openRelatedOrder(order) {
  if (!order) return
  flowDetail.value.open = false
  openOrder(order)
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
  return { quantity: daily.reduce((sum, o) => sum + (o.inventory_order_items || []).reduce((n, i) => n + Number(i.quantity), 0), 0), sales: daily.reduce((n, o) => n + Number(o.total_amount), 0), netSales: daily.reduce((n, o) => n + Number(o.net_sales ?? o.total_amount), 0), profit: daily.reduce((n, o) => n + Number(o.net_profit ?? o.total_profit), 0), orders: daily.length, inbound: incoming.reduce((n, m) => n + Number(m.total_amount), 0), refunds: refunds.reduce((n, r) => n + Number(r.refund_amount), 0), returnQty: refunds.reduce((n, r) => n + (r.inventory_return_items || []).reduce((sum, item) => sum + Number(item.quantity), 0), 0), stockCost: products.value.reduce((n, p) => n + Number(p.stock) * Number(p.cost_price), 0) }
})
const trends = computed(() => {
  const rows = Array.from({ length: statsDays.value }, (_, index) => {
    const start = new Date(); start.setDate(start.getDate() - (statsDays.value - 1 - index)); start.setHours(0, 0, 0, 0)
    const end = new Date(start); end.setDate(end.getDate() + 1)
    const dayOrders = orders.value.filter((o) => new Date(o.created_at) >= start && new Date(o.created_at) < end)
    const qty = movements.value.filter((m) => m.operation_type === 'sale' && new Date(m.created_at) >= start && new Date(m.created_at) < end).reduce((n, m) => n + Math.abs(Number(m.quantity)), 0)
    return { day: `${start.getMonth() + 1}/${start.getDate()}`, sales: dayOrders.reduce((n, o) => n + Number(o.total_amount), 0), profit: dayOrders.reduce((n, o) => n + Number(o.total_profit ?? 0), 0), qty }
  })
  return { rows, max: Math.max(1, ...rows.flatMap((r) => [r.sales, r.profit, r.qty])) }
})
const ranking = computed(() => {
  const entries = new Map()
  const cutoff = Date.now() - statsDays.value * 86400000
  movements.value.filter((m) => m.operation_type === 'sale' && new Date(m.created_at).getTime() >= cutoff).forEach((m) => {
    const row = entries.get(m.product_id) || { name: m.inventory_products?.name || '商品', quantity: 0, profit: 0, revenue: 0, cost: 0 }
    row.quantity += Math.abs(Number(m.quantity)); row.revenue += Number(m.total_amount || 0); row.cost += Math.abs(Number(m.quantity)) * Number(m.unit_cost || 0); row.profit = row.revenue - row.cost; entries.set(m.product_id, row)
  })
  const all = [...entries.values()]
  return { hot: [...all].sort((a, b) => b.quantity - a.quantity).slice(0, 5), profit: [...all].sort((a, b) => b.profit - a.profit).slice(0, 5) }
})
let profitSettingsTimer
onMounted(async () => {
  await loadOrganization()
  if (organization.value) {
    await loadData()
    bindOrdersRealtime()
  }
  else loading.value = false
  profitDraft.value = { ...profitSettings.value }
  profitSettingsTimer = window.setInterval(refreshProfitSettings, 30000)
  window.addEventListener('focus', refreshProfitSettings)
})
onUnmounted(() => {
  window.clearInterval(profitSettingsTimer)
  window.clearTimeout(pendingToastTimer)
  window.removeEventListener('focus', refreshProfitSettings)
  if (ordersChannel) supabase?.removeChannel(ordersChannel)
})
</script>

<template>
  <div class="app-shell inventory-shell inventory-app">
    <FunctionHeader :title="sectionTitle" @back="goHome" @sign-out="signOut" />
    <InventoryNavigation :sections="sections" :badges="{ pending: pendingCount }" />
    <main class="inventory-content">
      <section v-if="!organization && !loading" class="inventory-glass-card movement-card"><div class="inventory-card-title"><div><p class="eyebrow">INVENTORY WORKSPACE</p><h2>创建店铺 / 组织</h2></div></div><p>进销存数据会在这个店铺内协同，计时、签到和其他功能不受影响。</p><form class="inventory-form" @submit.prevent="createOrganization"><label><span>店铺或组织名称</span><input v-model="organizationName" placeholder="例如：小王杂货铺" required /></label><button class="glass-primary-btn" :disabled="organizationLoading">{{ organizationLoading ? '创建中…' : '创建并进入进销存' }}</button></form></section>
      <section v-else-if="errorMessage" class="inventory-glass-card inventory-error"><strong>无法载入进销存</strong><p>{{ errorMessage }}</p><button class="glass-primary-btn" @click="loadData">重新读取</button></section>
      <section v-else-if="loading && !products.length" class="inventory-glass-card empty-state">正在读取真实库存数据…</section>

      <template v-else-if="currentSection === 'dashboard'">
        <div class="inventory-section-heading"><div><p class="eyebrow">BUSINESS TODAY</p><h2>今天的经营情况</h2></div><div class="inventory-form-actions"><button v-if="isSuperAdmin" class="glass-action-btn" @click="openProfitControls">经营控制</button><button v-if="isSuperAdmin" class="glass-action-btn" @click="openPrintSettings">打印设置</button><button class="glass-primary-btn" @click="openSection('checkout')">开始开单</button></div></div>
        <div class="inventory-metrics business-metrics">
          <button v-if="pendingCount" class="inventory-metric metric-pending" @click="openSection('pending')"><span>待确认订单</span><strong>{{ pendingCount }}</strong><small>点击查看并确认出库</small></button>
          <button class="inventory-metric metric-blue" @click="openSection('checkout')"><span>今日销售额</span><strong>{{ money(business.sales) }}</strong><small>销售完成后自动更新</small></button>
          <button v-if="isSuperAdmin" class="inventory-metric metric-purple" @click="openSection('logs')"><span>今日毛利</span><strong :class="{ 'profit-number-low': lowProfit(business.netSales, business.netSales - business.profit, business.quantity) }">{{ money(business.profit) }}</strong><small v-if="lowProfit(business.netSales, business.netSales - business.profit, business.quantity)" class="profit-warning-label">低毛利</small><small>已扣除商品成本</small></button>
          <button class="inventory-metric metric-green" @click="openSection('logs')"><span>今日订单</span><strong>{{ business.orders }}</strong><small>笔销售订单</small></button>
          <button v-if="isSuperAdmin" class="inventory-metric metric-orange" @click="openSection('inbound')"><span>今日入库</span><strong>{{ money(business.inbound) }}</strong><small>进货金额</small></button>
          <button class="inventory-metric metric-purple" @click="openSection('returns')"><span>今日退款</span><strong>{{ money(business.refunds) }}</strong><small>净销售 {{ money(business.netSales) }}</small></button>
          <button class="inventory-metric metric-rose" @click="openSection('stock')"><span>库存预警</span><strong>{{ warnings.length }}</strong><small>个商品需关注</small></button>
          <button v-if="isSuperAdmin" class="inventory-metric metric-indigo" @click="openSection('stock')"><span>库存总成本</span><strong>{{ money(business.stockCost) }}</strong><small>{{ products.length }} 个商品</small></button>
        </div>
        <section class="inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">INSIGHT</p><h3>经营统计</h3></div><div class="segmented"><button v-for="day in [7,30,90]" :class="{ active: statsDays === day }" @click="statsDays = day">近 {{ day }} 天</button></div></div>
          <div class="trend-grid"><article v-for="[key, title, color] in [['sales','销售额','trend-blue'], ...(isSuperAdmin ? [['profit','毛利','trend-purple']] : []), ['qty','销量','trend-orange']]" :key="key" class="trend-card"><strong>{{ title }}</strong><div class="trend-bars"><i v-for="row in trends.rows" :key="row.day" :title="`${row.day}: ${row[key]}${key === 'profit' && lowProfit(row.sales, row.sales - row.profit, row.qty) ? ' · 低毛利' : ''} `" :class="[color, { 'profit-bar-low': key === 'profit' && lowProfit(row.sales, row.sales - row.profit, row.qty) }]" :style="{ height: `${Math.max(4, row[key] / trends.max * 100)}%` }"></i></div></article></div>
          <div class="ranking-grid"><article><h4>热销商品</h4><p v-for="(item,index) in ranking.hot" :key="item.name"><b>{{ index + 1 }}</b>{{ item.name }}<span>{{ item.quantity }} 件</span></p><small v-if="!ranking.hot.length">该时段暂无销售数据</small></article><article v-if="isSuperAdmin"><h4>商品利润排行</h4><p v-for="(item,index) in ranking.profit" :key="item.name"><b>{{ index + 1 }}</b>{{ item.name }}<InventoryProfit :revenue="item.revenue" :cost="item.cost" :quantity="item.quantity" :settings="profitSettings" /></p><small v-if="!ranking.profit.length">该时段暂无销售数据</small></article></div>
        </section>
      </template>

      <template v-else-if="currentSection === 'controls'">
        <section v-if="isSuperAdmin" class="inventory-glass-card">
          <h2>经营控制</h2>
          <form class="inventory-form profit-settings-form" @submit.prevent="saveProfitSettings">
            <label><span>金额预警</span><input v-model="profitDraft.amount_warning_enabled" type="checkbox" /></label>
            <label><span>最低毛利（元/件）</span><input v-model.number="profitDraft.minimum_unit_profit" type="number" min="0" step="0.01" required /></label>
            <label><span>毛利率预警</span><input v-model="profitDraft.margin_warning_enabled" type="checkbox" /></label>
            <label><span>最低毛利率（%）</span><input v-model.number="profitDraft.minimum_margin" type="number" min="0" max="100" step="0.01" required /></label>
            <p v-if="profitSettingsError" role="alert" class="return-submit-error">{{ profitSettingsError }}</p>
            <button class="glass-primary-btn" :disabled="savingProfitSettings">{{ savingProfitSettings ? '保存中…' : '保存设置' }}</button>
          </form>
        </section>
        <p v-else class="empty-state">无权访问经营控制。</p>
      </template>
      <template v-else-if="currentSection === 'print'">
        <section v-if="isSuperAdmin" class="inventory-glass-card">
          <h2>打印设置</h2>
          <form class="inventory-form print-settings-form" @submit.prevent="savePrintSettings">
            <label><span>公司名称</span><input v-model="printDraft.company_name" maxlength="80" /></label>
            <label><span>公司地址</span><input v-model="printDraft.company_address" maxlength="160" /></label>
            <label><span>联系电话</span><input v-model="printDraft.company_phone" maxlength="40" /></label>
            <label><span>LOGO 图片地址</span><input v-model="printDraft.logo_url" type="url" placeholder="https://" /></label>
            <label><span>默认纸张</span><select v-model="printDraft.default_paper"><option value="continuous-2">二等分 241×140</option><option value="continuous-3">三等分 241×93</option><option value="continuous-1">一等分 241×280</option><option value="a4">A4</option></select></label>
            <label><span>默认模板</span><select v-model="printDraft.default_template"><option value="standard">销售单</option><option value="compact">简洁销售单</option><option value="a4">A4销售单</option></select></label>
            <label><span>页边距（毫米）</span><input v-model.number="printDraft.margin_mm" type="number" min="0" max="20" step="1" /></label>
            <label><span>字体大小（pt）</span><input v-model.number="printDraft.font_size_pt" type="number" min="7" max="14" step="0.5" /></label>
            <label><span>每页最大商品行数</span><input v-model.number="printDraft.rows_per_page" type="number" min="1" max="40" step="1" /></label>
            <label><span>底部声明</span><input v-model="printDraft.footer_note" maxlength="200" /></label>
            <div class="print-field-groups">
              <section v-for="[title, fields] in PRINT_FIELD_GROUPS" :key="title">
                <h3>{{ title }}</h3>
                <label v-for="[key, label] in fields" :key="key" class="checkbox"><input v-model="printDraft.fields[key]" type="checkbox" />{{ label }}</label>
              </section>
            </div>
            <button class="glass-primary-btn" :disabled="savingPrintSettings">{{ savingPrintSettings ? '保存中…' : '保存打印设置' }}</button>
          </form>
        </section>
        <p v-else class="empty-state">无权访问打印设置。</p>
      </template>
      <template v-else-if="currentSection === 'checkout'">
        <div class="inventory-section-heading"><div><p class="eyebrow">QUICK SALE</p><h2>点商品，直接开单</h2></div><button class="glass-action-btn" @click="openSection('products')">管理商品</button></div>
        <section class="checkout-layout"><div class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索商品或货号" /><select v-model="category"><option value="">全部分类</option><option v-for="item in categories" :key="item">{{ item }}</option></select></div><div class="checkout-product-grid"><button v-for="product in visibleProducts" :key="product.id" class="checkout-product" :disabled="!product.stock" @click="addCart(product)"><img v-if="product.image_url" :src="product.image_url" :alt="product.name" /><span v-else class="product-image-placeholder">{{ product.name.slice(0,1) }}</span><b>{{ product.name }}</b><small>{{ product.stock }} 件可售</small><strong>{{ money(product.sale_price) }}</strong></button><p v-if="!visibleProducts.length" class="empty-state">没有匹配的商品</p></div></div>
          <aside class="inventory-glass-card order-panel"><div class="inventory-card-title"><h3>当前订单</h3><span>{{ cart.length }} 种商品</span></div><p v-if="!cart.length" class="empty-state">点击商品加入订单</p><div class="cart-list"><article v-for="item in cart" :key="item.id"><div><strong>{{ item.name }}</strong><input v-model.number="item.unit_price" type="number" min="0" step="0.01" /></div><InventorySearchSelect v-model="item.source_supplier_id" :options="(productSources[item.id] || []).map((source) => ({ id: source.supplier_id, label: source.supplier_name, description: `可用 ${source.available_quantity} 件` }))" placeholder="自动分配库存来源" /><div class="quantity-stepper"><button @click="changeQuantity(item,-1)">−</button><b>{{ item.quantity }}</b><button @click="changeQuantity(item,1)">＋</button><span>{{ money(item.quantity * item.unit_price) }}</span></div><InventoryProfit v-if="isSuperAdmin" :revenue="item.quantity * item.unit_price" :cost="item.quantity * item.cost_price" :quantity="item.quantity" :settings="profitSettings" :estimated="true" /></article></div><label>客户名称<InventorySearchSelect v-model="customerPick" :options="customerOptions" :allow-custom="true" empty-text="没有匹配的客户" placeholder="输入客户名称搜索，也可直接填写" @change="selectCustomer" /></label><label>联系人 / 手机<input v-model="orderCustomer.contact_name" placeholder="联系人" /><input v-model="orderCustomer.phone" placeholder="手机号" /></label><label>收货地址<input v-model="orderCustomer.address" placeholder="自提可留空" /></label><label>配送方式<select v-model="orderShipping"><option value="pickup">自提</option><option value="local_delivery">本地配送</option><option value="express">快递</option><option value="logistics">物流</option><option value="other">其他</option></select></label><label>收款方式<select v-model="payment"><option value="cash">现金</option><option value="bank_transfer">转账</option><option value="wechat">微信</option><option value="alipay">支付宝</option><option value="bank_card">银行卡</option><option value="other">其他</option></select></label><label>整单优惠<input v-model.number="discount" type="number" min="0" step="0.01" /></label><label>运费<input v-model.number="orderFreight" type="number" min="0" step="0.01" /></label><label>已收金额<input v-model.number="orderReceived" type="number" min="0" step="0.01" /></label><label>客户备注<input v-model="saleNote" placeholder="选填" /></label><InventoryProfit v-if="isSuperAdmin" :revenue="cartTotal" :cost="cartCost" :quantity="cart.reduce((sum, item) => sum + Number(item.quantity), 0)" :settings="profitSettings" :estimated="true" /><div class="order-total"><span>应收合计</span><strong>{{ money(cartTotal) }}</strong><small>未收 {{ money(cartTotal - Number(orderReceived || 0)) }}</small></div><button class="glass-primary-btn checkout-submit" :disabled="submitting || !cart.length" @click="completeSale">{{ submitting ? '正在保存…' : '保存待确认订单' }}</button></aside>
        </section>
      </template>

      <template v-else-if="currentSection === 'pending'">
        <div class="inventory-section-heading"><div><p class="eyebrow">PENDING FULFILLMENT</p><h2>待确认出库</h2><p>仅显示尚未影响库存的销售订单。</p></div><strong class="status-pill status-warning">{{ pendingOrders.length }} 单待处理</strong></div>
        <section class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索订单号、客户、商品" /></div><div class="order-list order-list-rich"><article v-for="order in pendingOrders.filter((item) => `${item.order_no} ${item.customer_name || ''} ${item.contact_name || ''} ${item.items.map((line) => line.product_name).join(' ')}`.toLowerCase().includes(search.toLowerCase()))" :key="order.id" class="order-row-open order-row-pending" @click="openOrder(order)"><div><strong>{{ order.order_no }}</strong><small>{{ order.customer_name || '临时客户' }}{{ order.contact_name ? ` · ${order.contact_name}` : '' }} · {{ dateText(order.created_at) }}</small><small>{{ order.items.map((line) => `${line.product_name} × ${line.quantity}`).join('；') || '暂无商品明细' }}</small><small>{{ order.shipping_method }} · {{ order.payment_status }}</small></div><div class="order-list-amount"><b>{{ money(order.total_amount) }}</b><small class="pending-flag">待确认</small></div><button class="mini-btn edit-btn" @click.stop="openOrder(order)">确认出库</button></article><p v-if="!pendingOrders.length" class="empty-state">暂无待确认出库订单。</p></div></section>
      </template>

      <template v-else-if="currentSection === 'orders'">
        <div class="inventory-section-heading"><div><p class="eyebrow">SALES ORDERS</p><h2>销售订单列表</h2></div><button class="glass-primary-btn" @click="openSection('checkout')">新建订单</button></div>
        <section class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索订单号、客户、联系人、手机号" /></div><div class="order-list order-list-rich"><article v-for="order in completedOrderRows.filter((item) => `${item.order_no} ${item.customer_name || ''} ${item.contact_name || ''} ${item.contact_phone || ''} ${item.items.map((line) => line.product_name).join(' ')}`.toLowerCase().includes(search.toLowerCase()))" :key="order.id" class="order-row-open" @click="openOrder(order)"><div><strong>{{ order.order_no }}</strong><small>{{ order.customer_name || '临时客户' }}{{ order.contact_name ? ` · ${order.contact_name}` : '' }} · {{ dateText(order.created_at) }}</small><small>{{ order.items.map((line) => `${line.product_name} × ${line.quantity} · 售 ${money(line.unit_price)}${line.inventory_suppliers?.name ? ` · ${line.inventory_suppliers.name}` : ''}${isSuperAdmin ? ` · 成本 ${money(line.actual_cost ?? 0)}` : ''}`).join('；') || '暂无商品明细' }}</small><small>{{ order.order_status }} · {{ order.fulfillment_status }} · {{ order.payment_status }}</small></div><div class="order-list-amount"><b>{{ money(order.total_amount) }}</b><small v-if="isSuperAdmin">成本 {{ money(order.total_cost) }}</small><InventoryProfit v-if="isSuperAdmin" :revenue="order.total_amount" :cost="order.total_cost" :quantity="order.items.reduce((sum, item) => sum + Number(item.quantity), 0)" :settings="profitSettings" :estimated="order.fulfillment_status !== 'fulfilled'" /></div><button class="mini-btn edit-btn" @click.stop="openOrder(order)">查看详情</button></article><p v-if="!completedOrderRows.length" class="empty-state">暂无已处理订单。</p></div></section>
      </template>

      <template v-else-if="currentSection === 'products'">
        <div class="inventory-section-heading"><div><p class="eyebrow">CATALOG</p><h2>商品管理</h2></div><button class="glass-primary-btn" @click="editProduct()">新增商品</button></div>
        <section v-if="showEditor" class="inventory-glass-card"><form class="inventory-form" @submit.prevent="saveProduct"><label><span>商品名称</span><input v-model="editor.name" required /></label><label><span>SKU / 货号</span><input v-model="editor.sku" required /></label><label><span>规格</span><input v-model="editor.specification" placeholder="例如：500ml / 红色" /></label><label><span>分类</span><input v-model="editor.category" placeholder="例如：饮料" /></label><label><span>图片 URL</span><input v-model="editor.image_url" type="url" placeholder="选填" /></label><label v-if="isSuperAdmin"><span>进货价</span><input v-model.number="editor.cost_price" type="number" min="0" step="0.01" /></label><label><span>销售价</span><input v-model.number="editor.sale_price" type="number" min="0" step="0.01" /></label><label v-if="!editor.id"><span>初始可售库存</span><input v-model.number="editor.stock" type="number" min="0" step="1" /></label><label><span>库存预警值</span><input v-model.number="editor.low_stock_threshold" type="number" min="0" step="1" /></label><div class="inventory-form-actions"><button class="glass-secondary-btn" type="button" @click="showEditor=false">取消</button><button class="glass-primary-btn" :disabled="submitting">{{ submitting ? '保存中…' : '保存商品' }}</button></div></form></section>
        <section class="inventory-glass-card"><div class="product-toolbar"><input v-model="search" placeholder="搜索商品、SKU" /><select v-model="category"><option value="">全部分类</option><option v-for="item in categories" :key="item">{{ item }}</option></select></div><div class="product-manage-grid"><article v-for="product in visibleProducts" :key="product.id" class="product-manage-card inventory-stock-card-action" @click="openProductDetail(product)"><img v-if="product.image_url" :src="product.image_url" :alt="product.name" /><span v-else class="product-image-placeholder">{{ product.name.slice(0,1) }}</span><div><small>{{ product.category }} · {{ product.sku }}</small><h3>{{ product.name }}</h3><p v-if="isSuperAdmin">进 {{ money(product.cost_price) }} · 售 {{ money(product.sale_price) }}</p><p v-else>售价 {{ money(product.sale_price) }}</p><InventoryProfit v-if="isSuperAdmin" :revenue="product.sale_price" :cost="product.cost_price" :quantity="1" :settings="profitSettings" :estimated="true" /></div><strong>{{ product.stock }}<small> 件</small></strong><footer><button class="mini-btn edit-btn" @click.stop="editProduct(product)">快速修改</button><button v-if="isSuperAdmin" class="mini-btn delete-btn" @click.stop="deleteProduct(product)">删除</button></footer></article><p v-if="!visibleProducts.length" class="empty-state">还没有商品，先新增一件吧。</p></div></section>
      </template>

      <template v-else-if="currentSection === 'inbound'"><div class="inventory-section-heading"><div><p class="eyebrow">INBOUND</p><h2>入库登记</h2></div></div><section class="inventory-glass-card movement-card"><form class="inventory-form" @submit.prevent="submitInbound"><label><span>选择商品</span><InventorySearchSelect v-model="inbound.product" :options="productOptions" placeholder="输入商品名称、SKU 或规格" @change="selectInbound" /></label><label><span>入库数量</span><input v-model.number="inbound.quantity" type="number" min="1" /></label><label v-if="isSuperAdmin"><span>实际进货单价</span><input v-model.number="inbound.price" type="number" min="0" step="0.01" /></label><label v-if="isSuperAdmin"><span>进货总金额</span><output>{{ money(inboundTotal) }}</output></label><label><span>供应商</span><InventorySearchSelect v-model="inbound.supplier" :options="supplierOptions" :allow-custom="true" placeholder="输入或搜索历史供应商" /></label><label><span>备注</span><input v-model="inbound.note" placeholder="选填" /></label><button class="glass-primary-btn" :disabled="submitting || !isSuperAdmin">{{ !isSuperAdmin ? '需超级管理员登记采购成本' : submitting ? '提交中…' : '确认入库' }}</button></form></section></template>
      <template v-else-if="currentSection === 'outbound'"><div class="inventory-section-heading"><div><p class="eyebrow">OUTBOUND</p><h2>普通出库与损耗</h2></div><button class="glass-action-btn" @click="openSection('checkout')">销售开单</button></div><section class="inventory-glass-card movement-card"><form class="inventory-form" @submit.prevent="submitOutbound"><label><span>出库类型</span><select v-model="outbound.type"><option value="normal_outbound">普通出库</option><option value="loss">损耗</option></select></label><label><span>选择商品</span><InventorySearchSelect v-model="outbound.product" :options="productOptions" placeholder="输入商品名称、SKU 或规格" /></label><label><span>数量</span><input v-model.number="outbound.quantity" type="number" min="1" /></label><label><span>备注</span><input v-model="outbound.note" placeholder="例如：赠品、过期损耗" /></label><button class="glass-primary-btn" :disabled="submitting">{{ submitting ? '提交中…' : '确认出库' }}</button></form></section></template>
      <template v-else-if="currentSection === 'returns'"><div class="inventory-section-heading"><div><p class="eyebrow">RETURNS</p><h2>销售退货</h2></div><button class="glass-primary-btn" @click="walkInReturn={ open:true, product:'', quantity:1, refund:0, method:'cash', reason:'', condition:'resellable', note:'', requestKey:requestKey() }">无单退货</button></div><section class="inventory-glass-card"><p class="return-note">选择已出库或已完成订单，进入详情后点击“发起退货”；无原订单时可登记无单退货。</p><div class="order-list"><article v-for="order in orders" :key="order.id"><div><strong>{{ order.order_no }}</strong><small>{{ dateText(order.created_at) }} · {{ order.payment_status }} · {{ order.return_status }}</small></div><b>{{ money(order.net_sales ?? order.total_amount) }}</b><button class="mini-btn edit-btn" @click="openOrder(order)">{{ order.fulfillment_status === 'fulfilled' || order.order_status === 'completed' ? '发起退货' : '查看订单' }}</button></article><p v-if="!orders.length" class="empty-state">暂无销售订单。</p></div></section></template>
      <template v-else-if="currentSection === 'stock'"><div class="inventory-section-heading"><div><p class="eyebrow">STOCK HEALTH</p><h2>库存状态</h2></div></div><section class="inventory-stock-grid"><article v-for="product in products" :key="product.id" class="inventory-stock-card inventory-stock-card-action" @click="openProductDetail(product)"><div><small>{{ product.category }} · {{ product.sku }}</small><h3>{{ product.name }}</h3><p>可售 {{ product.stock }} · 待处理 {{ product.pending_stock }} · 损耗 {{ product.damaged_quantity }}</p></div><strong>{{ product.stock }}<small> 件</small></strong><span class="status-pill" :class="statusClass(product)">{{ status(product) }}</span><footer><span v-if="isSuperAdmin">库存成本 {{ money(product.stock * product.cost_price) }}</span><span v-else>点击查看商品详情</span><button v-if="product.pending_stock" class="mini-btn edit-btn" @click.stop="openPending(product)">处理待检查 {{ product.pending_stock }}</button></footer></article><p v-if="!products.length" class="empty-state inventory-glass-card">还没有库存数据。</p></section></template>
      <template v-else-if="currentSection === 'logs'"><div class="inventory-section-heading"><div><p class="eyebrow">AUDIT TRAIL</p><h2>统一经营流水</h2></div></div><section class="inventory-glass-card"><div class="log-filters"><select v-model="logFilters.type"><option value="">全部操作</option><option value="sale">销售</option><option value="inbound">入库</option><option value="normal_outbound">普通出库</option><option value="loss">损耗</option><option value="adjustment">库存调整</option></select><select v-model="logFilters.product"><option value="">全部商品</option><option v-for="product in products" :key="product.id" :value="product.id">{{ product.name }}</option></select><input v-model="logFilters.date" type="date" /></div><div class="flow-list"><article v-for="item in filteredLogs" :key="item.id"><span class="log-type" :class="`log-${item.operation_type}`">{{ typeText(item.operation_type) }}</span><div><strong>{{ item.inventory_products?.name || '商品' }}</strong><small>{{ dateText(item.created_at) }}{{ item.note ? ` · ${item.note}` : '' }}</small></div><b :class="item.quantity > 0 ? 'amount-in' : 'amount-out'">{{ item.quantity > 0 ? '+' : '' }}{{ item.quantity }} 件</b><em v-if="isSuperAdmin || item.operation_type === 'sale'">{{ money(item.total_amount) }}</em><InventoryProfit v-if="isSuperAdmin && item.operation_type === 'sale'" :revenue="item.total_amount" :cost="Math.abs(item.quantity) * item.unit_cost" :quantity="Math.abs(item.quantity)" :settings="profitSettings" /></article><p v-if="!filteredLogs.length" class="empty-state">没有符合条件的流水。</p></div></section></template>
      <template v-else-if="currentSection === 'documents'">
        <div class="inventory-section-heading"><div><p class="eyebrow">BUSINESS DOCUMENTS</p><h2>业务单据</h2></div></div>
        <section class="inventory-glass-card business-flow-center">
        <div class="inventory-card-title"><div><p class="eyebrow">BUSINESS DOCUMENTS</p><h3>业务单据</h3></div><input v-model="logFilters.business" placeholder="搜索业务单号" /></div>
        <div class="business-flow-list">
          <article v-for="item in filteredLogs.filter((row) => row.business_no)" :key="item.id" @click="openFlow(item)">
            <div><strong>{{ item.business_no }}</strong><small>{{ typeText(item.operation_type) }} · {{ item.inventory_products?.name || '商品' }} × {{ Math.abs(item.quantity) }} · {{ dateText(item.created_at) }}</small></div>
            <b v-if="isSuperAdmin || item.operation_type === 'sale'">{{ money(item.total_amount) }}</b><button class="mini-btn edit-btn" @click.stop="copyBusinessNo(item.business_no)">复制</button>
          </article>
          <p v-if="!filteredLogs.some((row) => row.business_no)" class="empty-state">新产生的业务单据会在这里显示。</p>
        </div>
        </section>
      </template>
    </main>
    <Teleport to="body">
    <div v-if="orderDetail.open || returnDraft.open || walkInReturn.open || pendingAction.open || flowDetail.open || productDetail.open" class="inventory-dialog-backdrop" @click.self="closeInventoryDialog">
      <section v-if="flowDetail.open" class="inventory-dialog inventory-glass-card order-detail-dialog document-detail-dialog">
        <header class="order-detail-header"><div><p class="eyebrow">BUSINESS DOCUMENT</p><div class="order-detail-title"><h3>单据详情</h3><strong>{{ flowDetail.movement.business_no || '未编号单据' }}</strong><span class="document-type-badge" :class="`document-type-${flowDetail.movement.operation_type}`">{{ typeText(flowDetail.movement.operation_type) }}</span><span class="order-status-badge">{{ documentStatusText(flowDetail.record, flowDetail.movement) }}</span></div><small class="document-created-at">创建时间 {{ dateText(flowDetail.record?.created_at || flowDetail.movement.created_at) }}</small></div><button class="mini-btn" aria-label="关闭单据详情" @click="flowDetail.open=false">关闭</button></header>
        <div class="order-detail-scroll">
          <div v-if="flowDetail.loading" class="document-loading">正在读取单据详情，请稍候…</div>
          <template v-else>
            <section class="order-detail-section"><h4>基本信息</h4><div class="order-info-grid document-info-grid"><p><span>业务类型</span><b>{{ typeText(flowDetail.movement.operation_type) }}</b></p><p><span>业务状态</span><b>{{ documentStatusText(flowDetail.record, flowDetail.movement) }}</b></p><p><span>付款 / 退款方式</span><b>{{ refundMethodText(flowDetail.record?.refund_method || flowDetail.record?.payment_method) }}</b></p><p><span>创建时间</span><b>{{ dateText(flowDetail.record?.created_at || flowDetail.movement.created_at) }}</b></p><p v-if="flowDetail.record?.original_order"><span>原销售单号</span><button class="document-link" @click="openRelatedOrder(flowDetail.record.original_order)">{{ flowDetail.record.original_order.order_no }}</button></p><p v-if="flowDetail.record?.return_no"><span>退货单号</span><b>{{ flowDetail.record.return_no }}</b></p><p><span>创建人</span><b>{{ flowDetail.record?.user_id || flowDetail.movement.user_id || '公司成员' }}</b></p><p><span>更新时间</span><b>{{ dateText(flowDetail.record?.updated_at || flowDetail.record?.created_at || flowDetail.movement.created_at) }}</b></p><p class="document-note"><span>备注</span><b>{{ flowDetail.record?.note || flowDetail.movement.note || '无备注' }}</b></p></div></section>
            <section v-if="flowDetail.record?.original_order" class="order-detail-section"><h4>客户信息</h4><div class="order-info-grid"><p><span>客户</span><b>{{ flowDetail.record.original_order.customer_name || '临时客户' }}</b></p><p><span>联系方式</span><b>{{ [flowDetail.record.original_order.contact_name, flowDetail.record.original_order.contact_phone].filter(Boolean).join(' · ') || '未填写' }}</b></p><p><span>配送方式</span><b>{{ shippingText(flowDetail.record.original_order.shipping_method) }}</b></p><p><span>收货地址</span><b>{{ flowDetail.record.original_order.shipping_address || '无需配送' }}</b></p></div></section>
            <section class="order-detail-section"><h4>商品明细</h4><div class="document-item-table"><div class="document-item-row document-item-head"><span>商品</span><span>规格 / SKU</span><span>供应商</span><span>数量</span><span>单价</span><span>小计</span></div><div v-for="item in flowDetail.items" :key="item.id" class="document-item-row"><div><strong>{{ item.product_name }}</strong><small v-if="flowDetail.record?.return_no">原购 {{ originalDocumentItem(item)?.quantity ?? '—' }} · 本次退 {{ item.quantity }}</small></div><span>{{ documentItemSku(item) }}</span><span>{{ documentItemSupplier(item) }}</span><span>{{ item.quantity }}</span><span>{{ money(item.unit_price) }}</span><b>{{ money(item.line_total ?? (item.unit_price * item.quantity)) }}</b></div><div v-if="!flowDetail.items.length" class="document-empty">暂无商品明细</div></div></section>
            <div class="document-summary-grid"><section class="order-detail-section order-amount-card"><h4>金额汇总</h4><div class="order-amount-lines"><p><span>商品金额</span><b>{{ money(flowDetail.record?.subtotal ?? flowDetail.items.reduce((sum, item) => sum + Number(item.line_total ?? item.unit_price * item.quantity), 0)) }}</b></p><p v-if="flowDetail.record?.discount !== undefined"><span>优惠</span><b>-{{ money(flowDetail.record.discount) }}</b></p><p v-if="flowDetail.record?.freight !== undefined"><span>运费</span><b>{{ money(flowDetail.record.freight) }}</b></p><div></div><p class="order-total-line"><span>{{ flowDetail.record?.return_no ? '退款金额' : '实付金额' }}</span><strong>{{ money(flowDetail.record?.refund_amount ?? flowDetail.record?.total_amount ?? flowDetail.movement.total_amount) }}</strong></p></div></section><section v-if="isSuperAdmin" class="order-detail-section order-cost-card"><h4>成本信息 <small>仅超级管理员</small></h4><div class="order-amount-lines"><p><span>成本合计</span><b>{{ money(flowDetail.record?.total_cost ?? flowDetail.items.reduce((sum, item) => sum + Number(item.unit_cost || 0) * Number(item.quantity || 0), 0)) }}</b></p><InventoryProfit :revenue="flowDetail.record?.refund_amount ?? flowDetail.record?.total_amount ?? flowDetail.movement.total_amount" :cost="flowDetail.record?.total_cost ?? flowDetail.items.reduce((sum, item) => sum + Number(item.unit_cost || 0) * Number(item.quantity || 0), 0)" :quantity="flowDetail.items.reduce((sum, item) => sum + Number(item.quantity || 0), 0)" :settings="profitSettings" /></div></section></div>
          </template>
          <p v-if="flowDetail.error" class="return-submit-error" role="alert">{{ flowDetail.error }}</p>
        </div>
        <footer class="order-detail-actions"><button v-if="flowDetail.record?.order_no" class="glass-action-btn" @click="openPrint(flowDetail.record, flowDetail.items)">打印</button><button class="glass-action-btn" @click="copyBusinessNo(flowDetail.movement.business_no)">复制单号</button><button class="glass-primary-btn" @click="flowDetail.open=false">关闭</button></footer>
      </section>
      <section v-else-if="productDetail.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">PRODUCT DETAIL</p><h3>{{ productDetail.product.name }}</h3></div><button class="mini-btn" @click="productDetail.open=false">关闭</button></div><div class="dialog-lines"><p><span>SKU / 规格</span><b>{{ productDetail.product.sku }} {{ productDetail.product.specification || '--' }}</b></p><p><span>分类 / 售价</span><b>{{ productDetail.product.category }} / {{ money(productDetail.product.sale_price) }}</b></p><p><span>库存</span><b>可售 {{ productDetail.product.stock }} · 待检查 {{ productDetail.product.pending_stock }} · 损耗 {{ productDetail.product.damaged_quantity }}</b></p><template v-if="isSuperAdmin"><InventoryProfit v-if="isSuperAdmin" :revenue="productDetail.product.sale_price" :cost="productDetail.product.cost_price" :quantity="1" :settings="profitSettings" :estimated="true" /><p><span>当前库存成本</span><b>{{ money(productDetail.product.stock * productDetail.product.cost_price) }}</b></p><p v-for="supplier in productDetail.suppliers" :key="supplier.id"><span>{{ supplier.inventory_suppliers?.name }} · 货号 {{ supplier.supplier_sku || '--' }}</span><b>参考 {{ money(supplier.reference_price) }} · 最近 {{ money(supplier.latest_price) }} · {{ supplier.latest_purchase_at ? dateText(supplier.latest_purchase_at) : '暂无采购' }}</b></p><p v-for="batch in productDetail.batches" :key="batch.id" class="order-cost-line"><span>{{ batch.inventory_suppliers?.name }} · {{ batch.batch_no }} · 入库 {{ batch.received_quantity }} · 在库 {{ batch.remaining_quantity }}</span><b>实际进价 {{ money(batch.unit_cost) }} · {{ dateText(batch.received_at) }}</b></p></template></div></section>
      <section v-else-if="orderDetail.open && !returnDraft.open" class="inventory-dialog inventory-glass-card order-detail-dialog">
        <header class="order-detail-header"><div><p class="eyebrow">ORDER DETAIL</p><div class="order-detail-title"><h3>订单详情</h3><strong>{{ orderDetail.order.order_no }}</strong><span class="order-status-badge">{{ orderStatusText(orderDetail.order.order_status) }}</span></div></div><button class="mini-btn" aria-label="关闭订单详情" @click="orderDetail.open=false">关闭</button></header>
        <div class="order-detail-scroll">
          <section class="order-detail-section"><h4>客户与配送</h4><div class="order-info-grid"><p><span>客户</span><b>{{ orderDetail.order.customer_name || '临时客户' }}</b></p><p><span>联系方式</span><b>{{ [orderDetail.order.contact_name, orderDetail.order.contact_phone].filter(Boolean).join(' · ') || '未填写' }}</b></p><p><span>配送方式</span><b>{{ shippingText(orderDetail.order.shipping_method) }}</b></p><p><span>收货地址</span><b>{{ orderDetail.order.shipping_address || '无需配送' }}</b></p></div></section>
          <section class="order-detail-section"><h4>商品明细</h4><div class="order-product-cards"><article v-for="item in orderDetail.items" :key="item.id" class="order-product-card"><div class="order-product-card-head"><div><h5>{{ item.product_name }}</h5><small>{{ item.sku || '无 SKU' }}<span v-if="item.specification"> · {{ item.specification }}</span></small></div><strong>{{ money(item.line_total) }}</strong></div><div class="order-product-meta"><span>供应商 <b>{{ item.inventory_suppliers?.name || '自动分配' }}</b></span><span>数量 <b>{{ item.quantity }}</b></span><span>单价 <b>{{ money(item.unit_price) }}</b></span><span>可退 <b>{{ Math.max(0, Number(item.quantity) - returnedQuantity(item.id)) }} 件</b></span></div></article><p v-if="!orderDetail.items.length" class="order-empty">暂无商品明细</p></div></section>
          <section class="order-detail-section order-amount-card"><h4>订单金额</h4><div class="order-amount-lines"><p><span>商品金额</span><b>{{ money(orderDetail.order.subtotal) }}</b></p><p><span>优惠</span><b>-{{ money(orderDetail.order.discount) }}</b></p><p><span>运费</span><b>{{ money(orderDetail.order.freight) }}</b></p><div></div><p class="order-total-line"><span>实付金额</span><strong>{{ money(orderDetail.order.total_amount) }}</strong></p><p><span>付款状态</span><b>{{ paymentStatusText(orderDetail.order.payment_status) }}</b></p></div></section>
          <section v-if="isSuperAdmin" class="order-detail-section order-cost-card"><h4>成本信息 <small>仅超级管理员</small></h4><div class="order-amount-lines"><p><span>订单成本</span><b>{{ money(orderDetail.order.total_cost) }}</b></p><InventoryProfit v-if="isSuperAdmin" :revenue="orderDetail.order.total_amount" :cost="orderDetail.order.total_cost" :quantity="orderDetail.items.reduce((sum, item) => sum + Number(item.quantity), 0)" :settings="profitSettings" :estimated="orderDetail.order.fulfillment_status !== 'fulfilled'" /><div v-for="item in orderDetail.items" :key="item.id" class="profit-item-cost"><p><span>{{ item.product_name }} · 单位成本</span><b>{{ money(item.unit_cost) }}</b></p><p><span>成本合计</span><b>{{ money(item.actual_cost ?? item.unit_cost * item.quantity) }}</b></p><InventoryProfit v-if="isSuperAdmin" :revenue="item.line_total" :cost="item.actual_cost ?? item.unit_cost * item.quantity" :quantity="item.quantity" :settings="profitSettings" :estimated="orderDetail.order.fulfillment_status !== 'fulfilled'" /></div><p><span>出库状态</span><b>{{ fulfillmentStatusText(orderDetail.order.fulfillment_status) }}</b></p></div></section>
        </div>
        <footer class="order-detail-actions"><button class="glass-action-btn" @click="openPrint(orderDetail.order, orderDetail.items)">打印</button><button class="glass-action-btn" @click="copyBusinessNo(orderDetail.order.order_no)">复制单号</button><button v-if="currentSection === 'pending' && orderDetail.order.fulfillment_status === 'not_fulfilled'" class="glass-primary-btn" :disabled="submitting" @click="fulfillOrder(orderDetail.order)">{{ submitting ? '出库中…' : '确认出库' }}</button><button v-else-if="currentSection === 'returns'" class="glass-primary-btn" @click="beginOrderReturn">退货</button></footer>
      </section>
      <section v-else-if="returnDraft.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">SALE RETURN</p><h3>销售退货</h3></div><button class="mini-btn" @click="returnDraft.open=false">关闭</button></div><div class="return-items"><article v-for="item in returnDraft.items" :key="item.id"><strong>{{ item.product_name }}</strong><small>可退 {{ item.max }} 件 · 原价 {{ money(item.unit_price) }}</small><input v-model.number="item.quantity" type="number" min="0" :max="item.max" @input="syncRefund" /><select v-model="item.condition"><option value="resellable">完好 / 可销售</option><option value="damaged">损坏 / 损耗</option><option value="pending">待检查</option></select></article></div><label>退款金额<input v-model.number="returnDraft.refund" type="number" min="0" step="0.01" :placeholder="money(suggestedRefund)" /></label><label>退款方式<select v-model="returnDraft.method"><option value="cash">现金</option><option value="wechat">微信</option><option value="alipay">支付宝</option><option value="bank_card">银行卡</option><option value="other">其他</option></select></label><label>退货原因（必填）<input v-model="returnDraft.reason" placeholder="请填写退货原因" /></label><label>备注<input v-model="returnDraft.note" /></label><p v-if="returnDraft.error" class="return-submit-error" role="alert">{{ returnDraft.error }}</p><button class="glass-primary-btn" :disabled="submitting" @click="submitOrderReturn">{{ submitting ? '处理中…' : '确认退货并退款' }}</button></section>
      <section v-else-if="walkInReturn.open" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">WALK-IN RETURN</p><h3>无原订单退货</h3></div><button class="mini-btn" @click="walkInReturn.open=false">关闭</button></div><label>商品<InventorySearchSelect v-model="walkInReturn.product" :options="productOptions" placeholder="输入商品名称、SKU 或规格" /></label><label>数量<input v-model.number="walkInReturn.quantity" type="number" min="1" /></label><label>退款金额<input v-model.number="walkInReturn.refund" type="number" min="0" step="0.01" /></label><label>退款方式<select v-model="walkInReturn.method"><option value="cash">现金</option><option value="wechat">微信</option><option value="alipay">支付宝</option><option value="bank_card">银行卡</option><option value="other">其他</option></select></label><label>商品状态<select v-model="walkInReturn.condition"><option value="resellable">完好 / 可销售</option><option value="damaged">损坏 / 损耗</option><option value="pending">待检查</option></select></label><label>退货原因<input v-model="walkInReturn.reason" /></label><label>备注<input v-model="walkInReturn.note" /></label><button class="glass-primary-btn" :disabled="submitting" @click="submitWalkInReturn">{{ submitting ? '处理中…' : '确认无单退货' }}</button></section>
      <section v-else-if="pendingAction.open && pendingAction.product" class="inventory-dialog inventory-glass-card"><div class="inventory-card-title"><div><p class="eyebrow">PENDING STOCK</p><h3>处理待检查库存</h3></div><button class="mini-btn" @click="pendingAction.open=false">关闭</button></div><p>{{ pendingAction.product.name }} · 当前待处理 {{ pendingAction.product.pending_stock }} 件</p><label>数量<input v-model.number="pendingAction.quantity" type="number" min="1" :max="pendingAction.product.pending_stock" /></label><label>处理结果<select v-model="pendingAction.action"><option value="restore">恢复可售</option><option value="loss">确认损耗</option></select></label><label>处理原因<input v-model="pendingAction.reason" /></label><button class="glass-primary-btn" :disabled="submitting" @click="submitPending">{{ submitting ? '处理中…' : '确认处理' }}</button></section>
    </div>
    </Teleport>
    <Teleport to="body">
    <GlassModal class="inventory-message-overlay" v-if="modal.show" :message="modal.message" :cancel-text="modal.mode === 'delete' ? '取消' : ''" :confirm-text="modal.mode === 'delete' ? '删除' : '知道了'" @close="closeModal" @cancel="closeModal" @confirm="confirmModal" />
    <SalesPrintDialog v-if="printJob" :order="printJob" :settings="printSettings" :company-name="organization?.name || ''" @close="printJob = null" />
    <button v-if="pendingToast" type="button" class="inventory-pending-toast" @click="pendingToast=''; openSection('pending')">{{ pendingToast }}</button>
    </Teleport>
  </div>
</template>
