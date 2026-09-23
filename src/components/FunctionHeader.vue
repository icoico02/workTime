<script setup>
defineProps({
  title: {
    type: String,
    required: true,
  },
})

defineEmits(['back', 'sign-out'])
</script>

<template>
  <header class="function-header">
    <button class="function-header-back" type="button" @click="$emit('back')">← 返回</button>
    <h1>{{ title }}</h1>
    <button class="function-header-sign-out" type="button" @click="$emit('sign-out')">退出登录</button>
  </header>
</template>
