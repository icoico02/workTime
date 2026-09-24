<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { RouterLink } from 'vue-router'
import Sortable from 'sortablejs'
import { supabase } from '../supabase'

const props = defineProps({
  sections: { type: Array, required: true },
  badges: { type: Object, default: () => ({}) },
})
const list = ref(null)
const userId = ref(null)
const order = ref([])
const notice = ref('')
const defaults = computed(() => props.sections.filter(([key]) => key !== 'dashboard').map(([key]) => key))
const entries = computed(() => normalize(order.value).map(key => props.sections.find(([id]) => id === key)))
let sortable, subscription
let disposed = false
let suppressClickUntil = 0
const storageKey = () => `inventory-navigation:v1:${userId.value}`
function normalize(value) {
  return [...new Set([...(Array.isArray(value) ? value.filter(key => defaults.value.includes(key)) : []), ...defaults.value])]
}
function badgeCount(key) {
  const value = Number(props.badges?.[key] || 0)
  return value > 0 ? (value > 99 ? '99+' : String(value)) : ''
}
function loadUser(id) {
  userId.value = id || null
  notice.value = ''
  try { order.value = normalize(id ? JSON.parse(localStorage.getItem(storageKey()) || '[]') : []) }
  catch { order.value = normalize([]) }
  sortable?.option('disabled', !id)
}
function save() {
  if (!userId.value) return
  try { localStorage.setItem(storageKey(), JSON.stringify(order.value)); notice.value = '' }
  catch { notice.value = '排序暂未保存，浏览器存储不可用。' }
}
function reset() { order.value = normalize([]); save() }
function blockDragClick(event) {
  if (Date.now() < suppressClickUntil) { event.preventDefault(); event.stopPropagation() }
}
onMounted(async () => {
  sortable = Sortable.create(list.value, {
    animation: 160,
    draggable: '.inventory-sortable-link',
    delay: 350,
    delayOnTouchOnly: true,
    touchStartThreshold: 6,
    fallbackTolerance: 6,
    ghostClass: 'inventory-nav-placeholder',
    chosenClass: 'inventory-nav-chosen',
    dragClass: 'inventory-nav-dragging',
    disabled: true,
    onStart() { suppressClickUntil = Infinity },
    onEnd(event) {
      const keys = entries.value.map(([key]) => key)
      const siblings = [...event.from.children].filter(node => node !== event.item)
      event.from.insertBefore(event.item, siblings[event.oldIndex] || null)
      if (event.oldIndex !== event.newIndex) {
        const [key] = keys.splice(event.oldIndex, 1)
        keys.splice(event.newIndex, 0, key)
        order.value = keys
        save()
      }
      suppressClickUntil = Date.now() + 350
    },
  })
  if (!supabase) return
  subscription = supabase.auth.onAuthStateChange((_event, session) => {
    if (!disposed && userId.value !== (session?.user?.id || null)) loadUser(session?.user?.id)
  }).data.subscription
  const { data } = await supabase.auth.getSession()
  if (!disposed) loadUser(data.session?.user?.id)
})
onUnmounted(() => { disposed = true; sortable?.destroy(); subscription?.unsubscribe() })
</script>

<template>
  <div>
    <nav class="inventory-nav inventory-custom-nav" aria-label="进销存功能">
      <RouterLink to="/inventory/dashboard" class="inventory-nav-overview">总览</RouterLink>
      <div ref="list" class="inventory-nav-sortable" @click.capture="blockDragClick">
        <RouterLink v-for="[key, label] in entries" :key="key" :to="`/inventory/${key}`" class="inventory-sortable-link">
          <span>{{ label }}</span>
          <em v-if="badgeCount(key)" class="inventory-nav-badge">{{ badgeCount(key) }}</em>
        </RouterLink>
      </div>
      <button type="button" class="inventory-nav-reset" :disabled="!userId" title="恢复默认排序" aria-label="恢复默认排序" @click="reset">↺</button>
    </nav>
    <p v-if="notice" role="status">{{ notice }}</p>
  </div>
</template>

<style scoped>
.inventory-custom-nav { align-items: center; overflow: visible; }
.inventory-nav-sortable { display: flex; flex: 1; min-width: 0; gap: 7px; overflow-x: auto; padding: 8px 4px; scrollbar-width: none; }
.inventory-nav-sortable::-webkit-scrollbar { display: none; }
.inventory-sortable-link { position: relative; user-select: none; -webkit-touch-callout: none; cursor: grab; }
.inventory-nav-badge {
  position: absolute;
  top: -6px;
  right: -4px;
  min-width: 18px;
  height: 18px;
  padding: 0 5px;
  border-radius: 999px;
  background: #e5484d;
  color: #fff;
  font-size: 0.68rem;
  font-style: normal;
  font-weight: 800;
  line-height: 18px;
  text-align: center;
  box-shadow: 0 4px 10px rgba(180, 40, 55, 0.28);
}
.inventory-nav-overview { flex-shrink: 0; }
.inventory-nav-placeholder { opacity: 0.5; outline: 2px dashed #6396ca; outline-offset: -2px; background: rgba(175, 208, 239, 0.6); }
.inventory-nav-chosen { transform: scale(1.04); box-shadow: 0 5px 14px rgba(56, 86, 120, 0.2); cursor: grabbing; }
.inventory-nav-dragging { opacity: 0.9; }
.inventory-nav-reset { flex: 0 0 38px; width: 38px; height: 38px; border: 1px solid rgba(255,255,255,.62); border-radius: 50%; background: rgba(255,255,255,.4); color: #536074; font-size: 24px; cursor: pointer; }
.inventory-nav-reset:disabled { opacity: .5; cursor: default; }
</style>
