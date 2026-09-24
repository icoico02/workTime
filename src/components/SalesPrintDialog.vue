<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { PAPER_SIZES, PRINT_TEMPLATES, amountInChinese, moneyText, paginateItems, paperSpec, paymentText, sessionDefaults, visibleColumns } from '../inventoryPrint'

const props = defineProps({
  order: { type: Object, required: true },
  settings: { type: Object, required: true },
  companyName: { type: String, default: '' },
})
const emit = defineEmits(['close'])

const step = ref('choose')
const template = ref(props.settings.default_template || 'standard')
const session = ref(sessionDefaults(props.settings, template.value))
const frame = ref(null)
const scale = ref(1)
const fitHeight = ref('280px')
const fitWidth = ref('100%')

const paper = computed(() => paperSpec(session.value.paper, session.value.orientation))
const columns = computed(() => visibleColumns(props.settings, template.value, session.value))
const pages = computed(() => paginateItems(props.order.items, props.settings.rows_per_page))
const copies = computed(() => Math.min(5, Math.max(1, Number(session.value.copies) || 1)))
const copyPages = computed(() => Array.from({ length: copies.value }, (_, copy) => pages.value.map((rows, index) => ({ copy, index, rows, number: index + 1, total: pages.value.length }))))
const quantity = computed(() => props.order.items.reduce((sum, item) => sum + Number(item.quantity || 0), 0))
const company = computed(() => props.settings.company_name || props.companyName || '')
const fields = computed(() => props.settings.fields)
const pageStyle = computed(() => ({
  width: `${paper.value.width}mm`,
  minHeight: `${paper.value.height}mm`,
  padding: `${props.settings.margin_mm}mm`,
  fontSize: `${props.settings.font_size_pt}pt`,
}))
const pageCss = computed(() => `@media print { @page { size: ${paper.value.width}mm ${paper.value.height}mm; margin: 0; } }`)

watch(template, (value) => { session.value = { ...session.value, ...sessionDefaults(props.settings, value), copies: session.value.copies } })
watch([paper, () => props.settings.margin_mm, () => props.settings.font_size_pt, () => props.settings.rows_per_page, columns, pages, copies, step], () => nextTick(() => nextTick(fit)))

function choose(id) {
  template.value = id
  step.value = 'preview'
  nextTick(fit)
}
function cell(item, key, index) {
  if (key === 'index') return index
  if (key === 'unit_price' || key === 'amount') return moneyText(item[key])
  if (key === 'quantity') return item.quantity
  return item[key] || ''
}
function dateTime(value) {
  if (!value) return ''
  const date = new Date(value)
  const pad = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}
function fit() {
  if (!frame.value) return
  const sheet = frame.value.querySelector('.sales-print-scale')
  const px = paper.value.width * 96 / 25.4
  const next = Math.min(1, Math.max(0.2, (frame.value.clientWidth - 24) / px))
  scale.value = next
  if (!sheet) return
  fitWidth.value = `${Math.ceil(sheet.scrollWidth * next)}px`
  fitHeight.value = `${Math.ceil(sheet.scrollHeight * next) + 8}px`
}
function printSlip() {
  window.print()
}
function onKeydown(event) {
  if (event.key === 'Escape') emit('close')
}
onMounted(() => {
  window.addEventListener('resize', fit)
  window.addEventListener('keydown', onKeydown)
  nextTick(fit)
})
onUnmounted(() => {
  window.removeEventListener('resize', fit)
  window.removeEventListener('keydown', onKeydown)
})
</script>

<template>
  <Teleport to="body">
    <div id="sales-print-root" @click.self="emit('close')">
      <component :is="'style'">{{ pageCss }}</component>
      <button v-if="step === 'choose'" class="sales-print-backdrop" type="button" aria-label="关闭打印模板" @click="emit('close')"></button>
      <section class="sales-print-chrome inventory-glass-card">
        <header class="sales-print-ui order-detail-header">
          <div>
            <p class="eyebrow">PRINT</p>
            <h3>{{ step === 'choose' ? '选择打印模板' : '打印预览' }}</h3>
          </div>
          <button class="mini-btn" type="button" @click="emit('close')">关闭</button>
        </header>

        <div v-if="step === 'choose'" class="sales-print-ui sales-template-list">
          <button v-for="item in PRINT_TEMPLATES" :key="item.id" type="button" class="sales-template-option" :class="{ active: template === item.id }" @click="choose(item.id)">
            <strong>{{ item.label }}</strong>
            <small>{{ item.description }}</small>
          </button>
        </div>

        <template v-else>
          <div class="sales-print-ui sales-print-options">
            <label>份数<input v-model.number="session.copies" type="number" min="1" max="5" /></label>
            <label>纸张<select v-model="session.paper"><option v-for="item in PAPER_SIZES" :key="item.id" :value="item.id">{{ item.label }}</option></select></label>
            <label>方向<select v-model="session.orientation"><option value="portrait">纵向</option><option value="landscape">横向</option></select></label>
            <label class="checkbox"><input v-model="session.showPrices" type="checkbox" />单价 / 金额</label>
            <label class="checkbox"><input v-model="session.showOe" type="checkbox" />OE号</label>
            <label class="checkbox"><input v-model="session.showFitment" type="checkbox" />适配信息</label>
          </div>
          <p class="sales-print-ui empty-state">预览已按屏幕收窄。打印时按所选纸张的实际毫米尺寸输出，浏览器对话框中的份数请保持为 1。</p>
          <div ref="frame" class="sales-print-fit">
            <div class="sales-print-sizer" :style="{ width: fitWidth, height: fitHeight }">
            <div class="sales-print-scale" :style="{ width: `${paper.width}mm`, transform: `scale(${scale})` }">
              <article v-for="(pageSet, copyIndex) in copyPages" :key="copyIndex">
                <section v-for="page in pageSet" :key="`${copyIndex}-${page.number}`" class="sales-slip-page sales-slip" :class="{ 'is-last-sheet': copyIndex === copies - 1 && page.number === page.total }" :style="pageStyle">
                  <header class="sales-slip-head">
                    <img v-if="fields.logo && settings.logo_url" class="sales-slip-logo" :src="settings.logo_url" alt="" />
                    <span v-else></span>
                    <div class="sales-slip-title">
                      <strong v-if="fields.company_name && company">{{ company }}</strong>
                      <b>销售单</b>
                    </div>
                    <span class="sales-slip-page-no">{{ page.number }}/{{ page.total }}<small v-if="copies > 1"><br />第 {{ copyIndex + 1 }} 份</small></span>
                  </header>
                  <div v-if="page.number === 1" class="sales-slip-meta">
                    <p v-if="fields.order_no">单据编号：{{ order.order_no }}</p>
                    <p v-if="fields.sold_at">销售日期：{{ dateTime(order.created_at) }}</p>
                    <p v-if="fields.salesperson">销售人员：{{ order.salesperson_name || '—' }}</p>
                    <p v-if="fields.customer_name">客户名称：{{ order.customer_name || '临时客户' }}</p>
                    <p v-if="fields.contact_name">联系人：{{ order.contact_name || '—' }}</p>
                    <p v-if="fields.contact_phone">电话：{{ order.contact_phone || '—' }}</p>
                    <p v-if="fields.address" class="sales-slip-wide">客户地址：{{ order.shipping_address || '—' }}</p>
                  </div>
                  <p v-else class="sales-slip-meta"><span>单据编号：{{ order.order_no }}</span><span>续页</span></p>
                  <table>
                    <colgroup><col v-for="[key] in columns" :key="key" :style="{ width: key === 'product_name' ? '22%' : 'auto' }" /></colgroup>
                    <thead><tr><th v-for="[key, label] in columns" :key="key" :class="{ name: key === 'product_name', note: key === 'line_note' || key === 'fitment' }">{{ label }}</th></tr></thead>
                    <tbody>
                      <tr v-for="(item, row) in page.rows" :key="item.id">
                        <td v-for="[key] in columns" :key="key" :class="{ name: key === 'product_name', note: key === 'line_note' || key === 'fitment' }">{{ cell(item, key, (page.number - 1) * settings.rows_per_page + row + 1) }}</td>
                      </tr>
                      <tr v-if="!page.rows.length"><td :colspan="columns.length">暂无商品明细</td></tr>
                    </tbody>
                  </table>
                  <footer v-if="page.number === page.total" class="sales-slip-foot">
                    <p v-if="fields.total_qty">商品总数量：{{ quantity }}</p>
                    <p v-if="fields.subtotal">小计：{{ moneyText(order.subtotal) }}</p>
                    <p v-if="fields.discount">优惠金额：{{ moneyText(order.discount) }}</p>
                    <p v-if="fields.freight && Number(order.freight)">运费：{{ moneyText(order.freight) }}</p>
                    <p v-if="fields.receivable">应收金额：{{ moneyText(order.total_amount) }}</p>
                    <p v-if="fields.amount_words" class="sales-slip-wide">合计金额大写：{{ amountInChinese(order.total_amount) }}</p>
                    <p v-if="fields.payment_method">付款方式：{{ paymentText(order.payment_method) }}</p>
                    <p v-if="fields.note" class="sales-slip-wide">备注：{{ order.note || '—' }}</p>
                    <div class="sales-slip-sign sales-slip-wide">
                      <span v-if="fields.prepared_by">制单人：{{ order.prepared_by || '—' }}</span>
                      <span v-if="fields.shipper_sign">发货人签字：<b>&nbsp;</b></span>
                      <span v-if="fields.receiver_sign">收货人签字：<b>&nbsp;</b></span>
                    </div>
                    <p v-if="fields.footer_note && settings.footer_note" class="sales-slip-disclaimer sales-slip-wide">{{ settings.footer_note }}</p>
                  </footer>
                </section>
              </article>
            </div>
            </div>
          </div>
          <footer class="sales-print-ui order-detail-actions">
            <button class="glass-action-btn" type="button" @click="step = 'choose'">返回选模板</button>
            <button class="glass-primary-btn" type="button" @click="printSlip">打印</button>
          </footer>
        </template>
      </section>
    </div>
  </Teleport>
</template>

<style src="./sales-print.css"></style>
