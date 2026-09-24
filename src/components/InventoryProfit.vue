<script setup>
import { computed } from 'vue'
import { evaluateProfit } from '../inventoryProfit'
const props = defineProps({ revenue: [Number, String], cost: [Number, String], quantity: [Number, String], settings: { type: Object, required: true }, estimated: Boolean })
const result = computed(() => evaluateProfit(props.revenue, props.cost, props.quantity, props.settings))
const money = (value) => `¥${value.toFixed(2)}`
</script>

<template>
  <span v-if="result" class="inventory-profit" :class="{ 'inventory-profit-low': result.low }">
    <span>{{ estimated ? '预估毛利' : '毛利' }} {{ money(result.profit) }}</span>
    <span>每件 {{ money(result.unitProfit) }}</span>
    <span>毛利率 {{ result.margin == null ? '不适用' : `${result.margin.toFixed(2)}%` }}</span>
    <strong v-if="result.low" class="profit-warning-label">低毛利</strong>
  </span>
  <span v-else class="inventory-profit">成本待核算</span>
</template>
