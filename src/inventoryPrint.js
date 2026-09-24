export const PRINT_TEMPLATES = [
  { id: 'standard', label: '销售单', description: '针式连续纸，字段完整' },
  { id: 'compact', label: '简洁销售单', description: '只保留名称、规格、数量和金额' },
  { id: 'a4', label: 'A4销售单', description: '同样的销售单内容，按 A4 排版' },
]

export const PAPER_SIZES = [
  { id: 'continuous-2', label: '二等分 241×140', width: 241, height: 140 },
  { id: 'continuous-3', label: '三等分 241×93', width: 241, height: 93 },
  { id: 'continuous-1', label: '一等分 241×280', width: 241, height: 280 },
  { id: 'a4', label: 'A4 210×297', width: 210, height: 297 },
]

const FIELD_KEYS = [
  'company_name', 'logo', 'company_address', 'company_phone', 'order_no', 'sold_at', 'salesperson',
  'customer_name', 'contact_name', 'contact_phone', 'address', 'index', 'product_name', 'sku', 'brand',
  'oe', 'specification', 'fitment', 'quantity', 'unit', 'unit_price', 'amount', 'line_note',
  'total_qty', 'subtotal', 'discount', 'freight', 'receivable', 'amount_words', 'payment_method',
  'note', 'prepared_by', 'shipper_sign', 'receiver_sign', 'footer_note',
]

const COMPACT_HIDDEN = new Set(['sku', 'brand', 'oe', 'fitment', 'line_note', 'logo', 'company_address'])

export function defaultPrintSettings() {
  return {
    company_name: '',
    company_address: '',
    company_phone: '',
    logo_url: '',
    default_paper: 'continuous-2',
    default_template: 'standard',
    margin_mm: 4,
    font_size_pt: 9,
    rows_per_page: 8,
    footer_note: '货物请当面点清，离柜概不负责。',
    fields: Object.fromEntries(FIELD_KEYS.map((key) => [key, true])),
  }
}

export function normalizePrintSettings(raw) {
  const defaults = defaultPrintSettings()
  const source = raw && typeof raw === 'object' ? raw : {}
  const fields = { ...defaults.fields }
  if (source.fields && typeof source.fields === 'object') {
    for (const key of FIELD_KEYS) if (typeof source.fields[key] === 'boolean') fields[key] = source.fields[key]
  }
  const paper = PAPER_SIZES.some((item) => item.id === source.default_paper) ? source.default_paper : defaults.default_paper
  const template = PRINT_TEMPLATES.some((item) => item.id === source.default_template) ? source.default_template : defaults.default_template
  const margin = clamp(source.margin_mm, 0, 20, defaults.margin_mm)
  const font = clamp(source.font_size_pt, 7, 14, defaults.font_size_pt)
  const rows = clamp(source.rows_per_page, 1, 40, defaults.rows_per_page)
  return {
    company_name: text(source.company_name, 80),
    company_address: text(source.company_address, 160),
    company_phone: text(source.company_phone, 40),
    logo_url: safeLogo(source.logo_url),
    default_paper: paper,
    default_template: template,
    margin_mm: margin,
    font_size_pt: font,
    rows_per_page: rows,
    footer_note: text(source.footer_note, 200),
    fields,
  }
}

export function moneyText(value) {
  const amount = Number(value)
  return (Number.isFinite(amount) ? amount : 0).toFixed(2)
}

export function paymentText(value) {
  return { cash: '现金', bank_transfer: '转账', wechat: '微信', alipay: '支付宝', bank_card: '银行卡', other: '其他' }[value] || '未填写'
}

export function amountInChinese(value) {
  const amount = Math.round(Number(value || 0) * 100) / 100
  if (!Number.isFinite(amount) || amount < 0 || amount >= 1e12) return ''
  if (amount === 0) return '零元整'
  const digits = ['零', '壹', '贰', '叁', '肆', '伍', '陆', '柒', '捌', '玖']
  const [yuanPart, centPart] = amount.toFixed(2).split('.')
  const yuan = convertInteger(yuanPart, digits)
  const jiao = Number(centPart[0])
  const fen = Number(centPart[1])
  let text = yuan ? `${yuan}元` : '零元'
  if (!jiao && !fen) return `${text}整`
  if (yuan && !jiao && fen) text += '零'
  if (jiao) text += `${digits[jiao]}角`
  if (fen) text += `${digits[fen]}分`
  else text += '整'
  return text
}

export function toPrintOrder(order, items = []) {
  if (!order?.order_no) return null
  const lines = (items.length ? items : order.inventory_order_items || []).map((item, index) => ({
    id: item.id || `line-${index}`,
    product_name: item.product_name || '',
    sku: item.sku || '',
    brand: item.brand || '',
    oe: item.oe_number || item.oe || '',
    specification: item.specification || '',
    fitment: item.fitment || item.compatible || '',
    quantity: Number(item.quantity || 0),
    unit: item.unit || '件',
    unit_price: Number(item.unit_price || 0),
    amount: Number(item.line_total ?? (Number(item.unit_price || 0) * Number(item.quantity || 0))),
    note: item.line_note || '',
  }))
  return {
    order_no: order.order_no,
    created_at: order.created_at || null,
    salesperson_name: order.salesperson_name || '',
    prepared_by: order.prepared_by || order.salesperson_name || '',
    customer_name: order.customer_name || '',
    contact_name: order.contact_name || '',
    contact_phone: order.contact_phone || '',
    shipping_address: order.shipping_address || '',
    payment_method: order.payment_method || '',
    note: order.customer_note || '',
    subtotal: Number(order.subtotal || 0),
    discount: Number(order.discount || 0),
    freight: Number(order.freight || 0),
    total_amount: Number(order.total_amount || 0),
    items: lines,
  }
}

export function paginateItems(items, rowsPerPage) {
  const size = Math.max(1, Number(rowsPerPage) || 8)
  if (!items.length) return [[]]
  const pages = []
  for (let index = 0; index < items.length; index += size) pages.push(items.slice(index, index + size))
  return pages
}

export function visibleColumns(settings, template, session) {
  const fields = { ...settings.fields }
  if (template === 'compact') COMPACT_HIDDEN.forEach((key) => { fields[key] = false })
  if (session && session.showPrices === false) { fields.unit_price = false; fields.amount = false }
  if (session && session.showOe === false) fields.oe = false
  if (session && session.showFitment === false) fields.fitment = false
  const columns = [
    ['index', '序号'], ['product_name', '商品名称'], ['sku', '商品编号'], ['brand', '品牌'],
    ['oe', 'OE号/零件号'], ['specification', '规格'], ['fitment', '适配信息'], ['quantity', '数量'],
    ['unit', '单位'], ['unit_price', '单价'], ['amount', '金额'], ['line_note', '备注'],
  ].filter(([key]) => fields[key])
  return columns
}

export function paperSpec(id, orientation = 'portrait') {
  const paper = PAPER_SIZES.find((item) => item.id === id) || PAPER_SIZES[0]
  const landscape = orientation === 'landscape'
  return { ...paper, width: landscape ? paper.height : paper.width, height: landscape ? paper.width : paper.height }
}

export function sessionDefaults(settings, template) {
  return {
    copies: 1,
    paper: template === 'a4' ? 'a4' : settings.default_paper,
    orientation: 'portrait',
    showPrices: settings.fields.unit_price !== false || settings.fields.amount !== false,
    showOe: template !== 'compact' && settings.fields.oe !== false,
    showFitment: template !== 'compact' && settings.fields.fitment !== false,
  }
}

export const PRINT_FIELD_GROUPS = [
  ['抬头', [['company_name', '公司名称'], ['logo', 'LOGO'], ['company_address', '公司地址'], ['company_phone', '联系电话'], ['footer_note', '底部声明']]],
  ['单据', [['order_no', '单据编号'], ['sold_at', '销售日期'], ['salesperson', '销售人员'], ['customer_name', '客户名称'], ['contact_name', '联系人'], ['contact_phone', '电话'], ['address', '客户地址']]],
  ['明细', [['index', '序号'], ['product_name', '商品名称'], ['sku', '商品编号'], ['brand', '品牌'], ['oe', 'OE号'], ['specification', '规格'], ['fitment', '适配信息'], ['quantity', '数量'], ['unit', '单位'], ['unit_price', '单价'], ['amount', '金额'], ['line_note', '行备注']]],
  ['底部', [['total_qty', '商品总数量'], ['subtotal', '小计'], ['discount', '优惠金额'], ['freight', '运费'], ['receivable', '应收金额'], ['amount_words', '合计大写'], ['payment_method', '付款方式'], ['note', '备注'], ['prepared_by', '制单人'], ['shipper_sign', '发货人签字'], ['receiver_sign', '收货人签字']]],
]

function convertInteger(value, digits) {
  const groups = []
  let rest = value.replace(/^0+/, '') || '0'
  if (rest === '0') return ''
  while (rest.length) {
    groups.unshift(rest.slice(-4))
    rest = rest.slice(0, -4)
  }
  return groups.map((group, index) => {
    const converted = convertGroup(group.padStart(4, '0'), digits)
    const unit = ['', '万', '亿', '兆'][groups.length - 1 - index]
    return converted ? converted + unit : ''
  }).join('').replace(/零+/g, '零').replace(/零$/g, '')
}

function convertGroup(group, digits) {
  const labels = ['仟', '佰', '拾', '']
  let text = ''
  let zero = false
  for (let index = 0; index < 4; index += 1) {
    const digit = Number(group[index])
    if (!digit) { zero = text.length > 0; continue }
    if (zero) { text += '零'; zero = false }
    text += digits[digit] + labels[index]
  }
  return text
}

function clamp(value, min, max, fallback) {
  const number = Number(value)
  if (!Number.isFinite(number)) return fallback
  return Math.min(max, Math.max(min, number))
}

function text(value, max) {
  return String(value || '').trim().slice(0, max)
}

function safeLogo(value) {
  const url = text(value, 500)
  return /^(https?:\/\/|data:image\/)/i.test(url) ? url : ''
}
