<script setup>
import { computed, onMounted, ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import FunctionHeader from '../components/FunctionHeader.vue'
import GlassModal from '../components/GlassModal.vue'
import { supabase } from '../supabase'

const PRODUCTS_KEY = 'inventoryProducts'
const LOGS_KEY = 'inventoryOperationLogs'
const route = useRoute()
const router = useRouter()

function loadStorage(key, fallback) {
  try {
    const saved = localStorage.getItem(key)
    const parsed = saved ? JSON.parse(saved) : fallback
    return Array.isArray(parsed) ? parsed : fallback
  } catch (error) {
    console.error(`读取${key}失败:`, error)
    return fallback
  }
}

const currentUserId = ref('')
const products = ref([])
const operationLogs = ref([])
const productForm = ref(emptyProduct())
const movementForm = ref(emptyMovement())
const editingProductId = ref('')
const isProductFormOpen = ref(false)
const modalState = ref({ show: false, message: '', mode: 'message', productId: '' })

function emptyProduct() {
  return { name: '', code: '', category: '', price: '', stock: 0, lowStockThreshold: 5 }
}

function emptyMovement() {
  return { productId: '', quantity: '', operatedAt: toDateTimeLocal(new Date()) }
}

function userStorageKey(key) {
  return currentUserId.value ? `${key}:${currentUserId.value}` : ''
}

function saveData() {
  const productsKey = userStorageKey(PRODUCTS_KEY)
  const logsKey = userStorageKey(LOGS_KEY)
  if (!productsKey || !logsKey) return

  localStorage.setItem(productsKey, JSON.stringify(products.value))
  localStorage.setItem(logsKey, JSON.stringify(operationLogs.value))
}

function toDateTimeLocal(date) {
  const pad = (value) => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function formatDateTime(value) {
  if (!value) return '--'
  return value.replace('T', ' ')
}

function todayKey() {
  return new Date().toISOString().slice(0, 10)
}

function recordLog(type, product, quantity = '') {
  operationLogs.value.unshift({
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    type,
    productName: product.name,
    productCode: product.code,
    quantity,
    user_id: currentUserId.value,
    operatedAt: toDateTimeLocal(new Date()),
  })
}

onMounted(async () => {
  if (!supabase) return

  const { data: { user } } = await supabase.auth.getUser()
  currentUserId.value = user?.id || ''

  if (currentUserId.value) {
    products.value = loadStorage(userStorageKey(PRODUCTS_KEY), []).map((product) => ({
      ...product,
      user_id: product.user_id || currentUserId.value,
    }))
    operationLogs.value = loadStorage(userStorageKey(LOGS_KEY), []).map((log) => ({
      ...log,
      user_id: log.user_id || currentUserId.value,
    }))
  }
})

const currentSection = computed(() => route.params.section || 'dashboard')
const sectionTitle = computed(() => ({
  dashboard: '进销存总览',
  products: '商品管理',
  inbound: '入库登记',
  outbound: '出库登记',
  stock: '库存状态',
  logs: '操作记录',
}[currentSection.value] || '进销存总览'))

const totalStock = computed(() => products.value.reduce((sum, product) => sum + Number(product.stock || 0), 0))
const warningProducts = computed(() => products.value.filter((product) => Number(product.stock) <= Number(product.lowStockThreshold)))
const todayInbound = computed(() => sumTodayLogs('入库'))
const todayOutbound = computed(() => sumTodayLogs('出库'))

function sumTodayLogs(type) {
  return operationLogs.value
    .filter((log) => log.type === type && String(log.operatedAt).slice(0, 10) === todayKey())
    .reduce((sum, log) => sum + Number(log.quantity || 0), 0)
}

function openSection(section) {
  router.push(`/inventory/${section}`)
}

function goHome() {
  router.push('/')
}

async function signOut() {
  if (supabase) await supabase.auth.signOut()
  router.push('/')
}

function openProductForm(product = null) {
  editingProductId.value = product?.id || ''
  productForm.value = product
    ? { ...product }
    : emptyProduct()
  isProductFormOpen.value = true
}

function closeProductForm() {
  isProductFormOpen.value = false
  editingProductId.value = ''
  productForm.value = emptyProduct()
}

function saveProduct() {
  if (!productForm.value.name || !productForm.value.code || !productForm.value.category) {
    showMessage('请完整填写商品名称、编号和分类')
    return
  }

  const product = {
    ...productForm.value,
    id: editingProductId.value || `${Date.now()}`,
    price: Number(productForm.value.price || 0),
    stock: Number(productForm.value.stock || 0),
    lowStockThreshold: Number(productForm.value.lowStockThreshold || 0),
    user_id: currentUserId.value,
  }

  if (editingProductId.value) {
    const index = products.value.findIndex((item) => item.id === editingProductId.value)
    if (index !== -1) {
      products.value[index] = product
      recordLog('商品修改', product)
    }
  } else {
    products.value.unshift(product)
    recordLog('商品新增', product)
  }

  saveData()
  closeProductForm()
}

function requestDeleteProduct(product) {
  modalState.value = {
    show: true,
    message: `确定删除商品“${product.name}”吗？`,
    mode: 'delete-product',
    productId: product.id,
  }
}

function confirmModal() {
  if (modalState.value.mode === 'delete-product') {
    const product = products.value.find((item) => item.id === modalState.value.productId)
    if (product) {
      products.value = products.value.filter((item) => item.id !== product.id)
      recordLog('商品删除', product)
      saveData()
    }
  }
  modalState.value = { show: false, message: '', mode: 'message', productId: '' }
}

function closeModal() {
  modalState.value = { show: false, message: '', mode: 'message', productId: '' }
}

function showMessage(message) {
  modalState.value = { show: true, message, mode: 'message', productId: '' }
}

function submitMovement(type) {
  const quantity = Number(movementForm.value.quantity)
  const product = products.value.find((item) => item.id === movementForm.value.productId)

  if (!product) {
    showMessage('请选择商品')
    return
  }

  if (!Number.isInteger(quantity) || quantity <= 0) {
    showMessage('请输入大于 0 的整数数量')
    return
  }

  if (type === '出库' && quantity > Number(product.stock)) {
    showMessage(`库存不足，当前库存为 ${product.stock}`)
    return
  }

  product.stock = Number(product.stock) + (type === '入库' ? quantity : -quantity)
  operationLogs.value.unshift({
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    type,
    productName: product.name,
    productCode: product.code,
    quantity,
    user_id: currentUserId.value,
    operatedAt: movementForm.value.operatedAt || toDateTimeLocal(new Date()),
  })
  saveData()
  movementForm.value = emptyMovement()
  showMessage(`${type}成功，${product.name}当前库存为 ${product.stock}`)
}

function stockStatus(product) {
  if (Number(product.stock) === 0) return '缺货'
  if (Number(product.stock) <= Number(product.lowStockThreshold)) return '库存预警'
  return '库存正常'
}

function statusClass(product) {
  if (Number(product.stock) === 0) return 'status-danger'
  if (Number(product.stock) <= Number(product.lowStockThreshold)) return 'status-warning'
  return 'status-good'
}
</script>

<template>
  <div class="app-shell inventory-shell">
    <FunctionHeader :title="sectionTitle" @back="goHome" @sign-out="signOut" />

    <nav class="inventory-nav" aria-label="进销存导航">
      <RouterLink to="/inventory/dashboard">总览</RouterLink>
      <RouterLink to="/inventory/products">商品</RouterLink>
      <RouterLink to="/inventory/inbound">入库</RouterLink>
      <RouterLink to="/inventory/outbound">出库</RouterLink>
      <RouterLink to="/inventory/stock">库存</RouterLink>
      <RouterLink to="/inventory/logs">记录</RouterLink>
    </nav>

    <main class="inventory-content">
      <section v-if="currentSection === 'dashboard'" class="inventory-section">
        <div class="inventory-section-heading">
          <div>
            <p class="eyebrow">WORKSPACE</p>
            <h2>今天的库存概览</h2>
          </div>
          <button class="glass-action-btn" type="button" @click="openSection('products')">管理商品</button>
        </div>

        <div class="inventory-metrics">
          <button class="inventory-metric metric-blue" type="button" @click="openSection('products')">
            <span>商品总数</span><strong>{{ products.length }}</strong><small>个商品</small>
          </button>
          <button class="inventory-metric metric-green" type="button" @click="openSection('stock')">
            <span>库存总量</span><strong>{{ totalStock }}</strong><small>件库存</small>
          </button>
          <button class="inventory-metric metric-purple" type="button" @click="openSection('inbound')">
            <span>今日入库</span><strong>{{ todayInbound }}</strong><small>件入库</small>
          </button>
          <button class="inventory-metric metric-orange" type="button" @click="openSection('outbound')">
            <span>今日出库</span><strong>{{ todayOutbound }}</strong><small>件出库</small>
          </button>
          <button class="inventory-metric metric-red" type="button" @click="openSection('stock')">
            <span>库存预警</span><strong>{{ warningProducts.length }}</strong><small>个商品需要关注</small>
          </button>
        </div>

        <section class="inventory-glass-card quick-actions">
          <h3>快捷操作</h3>
          <div class="quick-action-grid">
            <button class="glass-action-btn" type="button" @click="openSection('inbound')">＋ 入库</button>
            <button class="glass-action-btn" type="button" @click="openSection('outbound')">－ 出库</button>
            <button class="glass-action-btn" type="button" @click="openSection('logs')">查看记录</button>
          </div>
        </section>
      </section>

      <section v-else-if="currentSection === 'products'" class="inventory-section">
        <div class="inventory-section-heading">
          <div><p class="eyebrow">CATALOG</p><h2>商品管理</h2></div>
          <button class="glass-primary-btn" type="button" @click="openProductForm()">＋ 新增商品</button>
        </div>

        <div v-if="isProductFormOpen" class="inventory-glass-card product-form-card">
          <h3>{{ editingProductId ? '修改商品' : '新增商品' }}</h3>
          <form class="inventory-form" @submit.prevent="saveProduct">
            <label><span>商品名称</span><input v-model="productForm.name" type="text" placeholder="例如：无线键盘" /></label>
            <label><span>商品编号</span><input v-model="productForm.code" type="text" placeholder="例如：KB-001" /></label>
            <label><span>分类</span><input v-model="productForm.category" type="text" placeholder="例如：办公用品" /></label>
            <label><span>单价</span><input v-model="productForm.price" type="number" min="0" step="0.01" placeholder="0.00" /></label>
            <label><span>当前库存</span><input v-model="productForm.stock" type="number" min="0" step="1" /></label>
            <label><span>预警数量</span><input v-model="productForm.lowStockThreshold" type="number" min="0" step="1" /></label>
            <div class="inventory-form-actions">
              <button class="glass-secondary-btn" type="button" @click="closeProductForm">取消</button>
              <button class="glass-primary-btn" type="submit">保存商品</button>
            </div>
          </form>
        </div>

        <div class="inventory-glass-card table-card">
          <div v-if="!products.length" class="empty-state">还没有商品，先新增一件商品吧。</div>
          <div v-else class="inventory-table-wrap">
            <table class="inventory-table">
              <thead><tr><th>名称</th><th>编号</th><th>分类</th><th>单价</th><th>库存</th><th>操作</th></tr></thead>
              <tbody>
                <tr v-for="product in products" :key="product.id">
                  <td><strong>{{ product.name }}</strong></td><td>{{ product.code }}</td><td>{{ product.category }}</td><td>￥{{ Number(product.price).toFixed(2) }}</td><td>{{ product.stock }}</td>
                  <td class="table-actions"><button class="mini-btn edit-btn" type="button" @click="openProductForm(product)">修改</button><button class="mini-btn delete-btn" type="button" @click="requestDeleteProduct(product)">删除</button></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section v-else-if="currentSection === 'inbound' || currentSection === 'outbound'" class="inventory-section">
        <div class="inventory-section-heading"><div><p class="eyebrow">MOVEMENT</p><h2>{{ currentSection === 'inbound' ? '入库登记' : '出库登记' }}</h2></div></div>
        <div class="inventory-glass-card movement-card">
          <form class="inventory-form" @submit.prevent="submitMovement(currentSection === 'inbound' ? '入库' : '出库')">
            <label><span>选择商品</span><select v-model="movementForm.productId"><option value="">请选择商品</option><option v-for="product in products" :key="product.id" :value="product.id">{{ product.name }} · 当前 {{ product.stock }} 件</option></select></label>
            <label><span>{{ currentSection === 'inbound' ? '入库' : '出库' }}数量</span><input v-model="movementForm.quantity" type="number" min="1" step="1" placeholder="请输入数量" /></label>
            <label><span>{{ currentSection === 'inbound' ? '入库' : '出库' }}时间</span><input v-model="movementForm.operatedAt" type="datetime-local" /></label>
            <button class="glass-primary-btn" type="submit">确认{{ currentSection === 'inbound' ? '入库' : '出库' }}</button>
          </form>
        </div>
      </section>

      <section v-else-if="currentSection === 'stock'" class="inventory-section">
        <div class="inventory-section-heading"><div><p class="eyebrow">STOCK HEALTH</p><h2>库存状态</h2></div></div>
        <div class="inventory-stock-grid">
          <article v-for="product in products" :key="product.id" class="inventory-stock-card">
            <div><p>{{ product.category }}</p><h3>{{ product.name }}</h3><small>{{ product.code }}</small></div>
            <strong>{{ product.stock }}<small> 件</small></strong>
            <span class="status-pill" :class="statusClass(product)">{{ stockStatus(product) }}</span>
          </article>
          <div v-if="!products.length" class="empty-state inventory-glass-card">还没有商品库存数据。</div>
        </div>
      </section>

      <section v-else class="inventory-section">
        <div class="inventory-section-heading"><div><p class="eyebrow">AUDIT TRAIL</p><h2>操作记录</h2></div></div>
        <div class="inventory-glass-card table-card">
          <div v-if="!operationLogs.length" class="empty-state">暂无操作记录。</div>
          <div v-else class="inventory-table-wrap"><table class="inventory-table"><thead><tr><th>操作</th><th>商品</th><th>数量</th><th>时间</th></tr></thead><tbody><tr v-for="log in operationLogs" :key="log.id"><td><span class="log-type">{{ log.type }}</span></td><td>{{ log.productName }}<small>{{ log.productCode }}</small></td><td>{{ log.quantity || '—' }}</td><td>{{ formatDateTime(log.operatedAt) }}</td></tr></tbody></table></div>
        </div>
      </section>
    </main>

    <GlassModal v-if="modalState.show" :message="modalState.message" :cancel-text="modalState.mode === 'delete-product' ? '取消' : ''" :confirm-text="modalState.mode === 'delete-product' ? '好' : '知道了'" @close="closeModal" @cancel="closeModal" @confirm="confirmModal" />
  </div>
</template>
