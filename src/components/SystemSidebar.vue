<script setup>
defineProps({
  activeItem: { type: String, default: 'home' },
  isAdmin: Boolean,
  isSuperAdmin: Boolean,
  pendingCount: { type: Number, default: 0 },
  username: { type: String, default: '用户' },
})

defineEmits(['navigate', 'sign-out'])
</script>

<template>
  <aside class="system-sidebar">
    <div class="sidebar-brand">
      <span class="sidebar-brand-mark" aria-hidden="true">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
          <rect x="4" y="4" width="6" height="6" rx="1.5" /><rect x="14" y="4" width="6" height="6" rx="1.5" />
          <rect x="4" y="14" width="6" height="6" rx="1.5" /><rect x="14" y="14" width="6" height="6" rx="1.5" />
        </svg>
      </span>
      <span><strong>工作助手</strong><small>功能工作台</small></span>
    </div>

    <nav class="sidebar-nav" aria-label="功能导航">
      <button :class="{ active: activeItem === 'home' }" type="button" @click="$emit('navigate', 'home')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m3 11 9-8 9 8" /><path d="M5 10v10h14V10M9 20v-6h6v6" /></svg><span>首页</span>
      </button>
      <button :class="{ active: activeItem === 'attendance' }" type="button" @click="$emit('navigate', 'attendance')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="17" rx="3" /><path d="M8 2v4M16 2v4M3 10h18M8 15l2.5 2.5L16 12" /></svg><span>签到</span>
      </button>
      <button :class="{ active: activeItem === 'timer' }" type="button" @click="$emit('navigate', 'timer')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="13" r="8" /><path d="M12 9v4l3 2M9 2h6M12 5V2" /></svg><span>计时</span>
      </button>
      <button :class="{ active: activeItem === 'dashboard' }" type="button" @click="$emit('navigate', 'dashboard')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9M10 19V5M16 19v-7M22 19H2" /></svg><span>数据看板</span>
      </button>
      <button :class="{ active: activeItem === 'inventory' }" type="button" @click="$emit('navigate', 'inventory')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7.5 12 3l8 4.5v9L12 21l-8-4.5v-9Z" /><path d="m4.5 7.7 7.5 4.2 7.5-4.2M12 12v9" /></svg><span>进销存</span>
      </button>
      <button v-if="isAdmin" :class="{ active: activeItem === 'admin' }" type="button" @click="$emit('navigate', 'admin')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" /><path d="M19 8v6M22 11h-6" /></svg><span>用户审批</span><b v-if="pendingCount">{{ pendingCount }}</b>
      </button>
      <button v-if="isSuperAdmin" :class="{ active: activeItem === 'super-admin' }" type="button" @click="$emit('navigate', 'super-admin')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7h10M18 7h2M4 17h2M10 17h10M14 4v6M10 14v6" /><circle cx="16" cy="7" r="2" /><circle cx="8" cy="17" r="2" /></svg><span>管理后台</span>
      </button>
    </nav>

    <div class="sidebar-account">
      <span><small>当前用户</small><strong>{{ username }}</strong></span>
      <button type="button" title="退出登录" @click="$emit('sign-out')">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M10 17l5-5-5-5M15 12H3" /><path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4" /></svg>
      </button>
    </div>
  </aside>
</template>
