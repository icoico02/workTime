<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue'

const props = defineProps({
  modelValue: { type: String, default: '' },
  options: { type: Array, default: () => [] },
  placeholder: { type: String, default: '输入搜索' },
  allowCustom: { type: Boolean, default: false },
})

const emit = defineEmits(['update:modelValue', 'change'])
const open = ref(false)
const query = ref('')

const selected = computed(() => props.options.find((item) => item.id === props.modelValue))
const filtered = computed(() => {
  const keyword = query.value.trim().toLowerCase()
  if (!keyword) return props.options.slice(0, 12)
  return props.options.filter((item) => `${item.label} ${item.description || ''}`.toLowerCase().includes(keyword)).slice(0, 12)
})

watch(selected, (item) => { if (!open.value) query.value = item?.label || '' }, { immediate: true })

function choose(item) {
  query.value = item.label
  open.value = false
  emit('update:modelValue', item.id)
  emit('change', item.id)
}

function handleInput() {
  open.value = true
  if (props.allowCustom) emit('update:modelValue', query.value)
}

function clearInvalid() {
  window.setTimeout(() => {
    open.value = false
    if (selected.value) query.value = selected.value.label
    else if (props.allowCustom && query.value.trim()) {
      const value = query.value.trim()
      emit('update:modelValue', value)
      emit('change', value)
    } else if (query.value) query.value = ''
  }, 120)
}

onBeforeUnmount(() => window.clearTimeout())
</script>

<template>
  <div class="inventory-search-select">
    <input
      v-model="query"
      type="search"
      :placeholder="placeholder"
      autocomplete="off"
      @focus="open = true"
      @input="handleInput"
      @blur="clearInvalid"
    />
    <button v-if="modelValue" type="button" class="inventory-search-clear" aria-label="清除选择" @mousedown.prevent @click="choose({ id: '', label: '' })">×</button>
    <div v-if="open" class="inventory-search-options">
      <button v-for="item in filtered" :key="item.id" type="button" @mousedown.prevent @click="choose(item)"><strong>{{ item.label }}</strong><small>{{ item.description }}</small></button>
      <p v-if="!filtered.length">没有匹配的商品</p>
    </div>
  </div>
</template>
