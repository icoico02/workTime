<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import FunctionHeader from '../components/FunctionHeader.vue'
import GlassModal from '../components/GlassModal.vue'
import { supabase } from '../supabase'

const route = useRoute()
const router = useRouter()
const users = ref([])
const logs = ref([])
const loading = ref(true)
const logsLoading = ref(false)
const currentProfile = ref(null)
const reason = ref('')
const modal = ref({ show: false, message: '' })
const expandedLogUserId = ref('')

const isSuperAdmin = computed(() => route.path === '/super-admin')
const pendingOnly = computed(() => !isSuperAdmin.value || route.query.section === 'pending')
const title = computed(() => isSuperAdmin.value ? '审批操作记录' : '用户审批')
const visibleUsers = computed(() => !pendingOnly.value
  ? users.value
  : users.value.filter((user) => user.approval_status === 'pending'))
const metrics = computed(() => ({
  total: users.value.length,
  pending: users.value.filter((user) => user.approval_status === 'pending').length,
  admins: users.value.filter((user) => user.role === 'admin').length,
}))
const groupedApprovalLogs = computed(() => {
  const profiles = new Map(users.value.map((user) => [user.id, user]))
  const groups = new Map()
  const sortedLogs = [...logs.value].sort((a, b) => new Date(b.created_at) - new Date(a.created_at))

  sortedLogs.forEach((log) => {
    const userId = String(log.actor_user_id || 'unknown')
    if (!groups.has(userId)) groups.set(userId, [])
    groups.get(userId).push(log)
  })

  return [...groups.entries()].map(([userId, userLogs]) => {
    const profile = profiles.get(userId)
    const latestLog = userLogs[0]

    return {
      userId,
      username: profile?.username || latestLog.actor_username || (userId === 'unknown' ? '未知管理员' : userId),
      status: profile?.approval_status || 'unknown',
      role: profile?.role || 'admin',
      latestAt: latestLog.created_at,
      logs: userLogs,
    }
  })
})

function formatDateTime(value) {
  if (!value) return '--'
  return new Date(value).toLocaleString('zh-CN', { hour12: false })
}

function usernameFor(userId) {
  return users.value.find((user) => user.id === userId)?.username || userId || '--'
}

function toggleLogUser(userId) {
  expandedLogUserId.value = expandedLogUserId.value === userId ? '' : userId
}

function formatActionType(log) {
  const action = String(log.action_type || log.operation_type || '').toLowerCase()

  if (action.includes('approve') || action === 'approval') return '批准'
  if (action.includes('reject')) return '拒绝'
  if (action.includes('promote') || action.includes('demote') || action.includes('role')) return '修改角色'
  return log.action_type || log.operation_type || '审批操作'
}

function hasStatusChange(log) {
  return Boolean(log.old_status && log.new_status && log.old_status !== log.new_status)
}

function hasRoleChange(log) {
  return Boolean(log.old_role && log.new_role && log.old_role !== log.new_role)
}

function hasReason(log) {
  return Boolean(String(log.reason || '').trim())
}

function showMessage(message) {
  modal.value = { show: true, message }
}

function closeMessage() {
  modal.value = { show: false, message: '' }
}

async function loadUsers() {
  if (!supabase) return

  const { data: { user } } = await supabase.auth.getUser()
  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('id, username, role, approval_status, created_at')
    .eq('id', user.id)
    .maybeSingle()

  if (profileError || !profile) {
    console.error(profileError)
    showMessage('管理员资料加载失败。')
    loading.value = false
    return
  }

  currentProfile.value = profile
  if (isSuperAdmin.value && profile.role !== 'super_admin') {
    showMessage('你没有权限访问管理后台。')
    await router.replace('/')
    return
  }

  if (!isSuperAdmin.value && !['admin', 'super_admin'].includes(profile.role)) {
    showMessage('你没有权限访问用户审批。')
    await router.replace('/')
    return
  }

  let query = supabase
    .from('profiles')
    .select('id, username, role, approval_status, created_at')
    .order('created_at', { ascending: false })

  if (pendingOnly.value) {
    query = query.eq('approval_status', 'pending')
  }

  const { data, error } = await query
  loading.value = false

  if (error) {
    console.error(error)
    showMessage('用户列表加载失败，请检查权限或网络。')
    return
  }

  users.value = data || []
}

async function loadLogs() {
  if (!supabase || !isSuperAdmin.value) return

  logsLoading.value = true
  const { data, error } = await supabase
    .from('user_approval_logs')
    .select('*')
    .order('created_at', { ascending: false })
  logsLoading.value = false

  if (error) {
    console.error(error)
    showMessage('审批操作记录加载失败。')
    return
  }

  logs.value = data || []
}

async function approveUser(userId, approved) {
  if (!supabase) return

  const { data, error } = await supabase.rpc('approve_user', {
    p_target_user_id: userId,
    p_approved: approved,
    p_reason: reason.value.trim() || null,
  })

  if (error) {
    console.error(error)
    showMessage(approved ? '通过用户失败，请稍后重试。' : '拒绝用户失败，请稍后重试。')
    return
  }

  reason.value = ''
  showMessage(approved ? '用户已通过审批。' : '用户已拒绝。')
  window.dispatchEvent(new Event('pending-approval-changed'))
  await loadUsers()
  await loadLogs()
}

async function promoteUser(userId) {
  if (!supabase) return

  const { data, error } = await supabase.rpc('promote_to_admin', {
    p_target_user_id: userId,
  })

  if (error) {
    console.error(error)
    showMessage('升级管理员失败，请稍后重试。')
    return
  }

  showMessage('用户已升级为管理员。')
  window.dispatchEvent(new Event('pending-approval-changed'))
  await loadUsers()
  await loadLogs()
}

async function demoteUser(userId) {
  if (!supabase) return

  const { data, error } = await supabase.rpc('demote_to_user', {
    p_target_user_id: userId,
  })

  if (error) {
    console.error(error)
    showMessage('取消管理员失败，请稍后重试。')
    return
  }

  showMessage('管理员已降级为普通用户。')
  window.dispatchEvent(new Event('pending-approval-changed'))
  await loadUsers()
  await loadLogs()
}

function goHome() {
  router.push('/')
}

function signOut() {
  supabase?.auth.signOut()
  router.push('/')
}

onMounted(async () => {
  await loadUsers()
  await loadLogs()
})

watch(() => route.query.section, async () => {
  loading.value = true
  await loadUsers()
})
</script>

<template>
  <div class="app-shell admin-shell">
    <FunctionHeader :title="title" @back="goHome" @sign-out="signOut" />

    <main class="admin-content">
      <div v-if="loading" class="inventory-glass-card admin-empty">正在加载…</div>

      <template v-else>
        <section v-if="isSuperAdmin" class="admin-metrics">
          <article class="admin-metric"><span>用户总数</span><strong>{{ metrics.total }}</strong></article>
          <article class="admin-metric"><span>待审批</span><strong>{{ metrics.pending }}</strong></article>
          <article class="admin-metric"><span>管理员</span><strong>{{ metrics.admins }}</strong></article>
        </section>

        <section class="inventory-glass-card admin-users-card">
          <div class="admin-section-heading">
            <div><p class="eyebrow">{{ pendingOnly ? 'APPROVAL QUEUE' : 'USER MANAGEMENT' }}</p><h2>{{ pendingOnly ? '待审批用户' : '用户列表' }}</h2></div>
            <span>{{ visibleUsers.length }} 位用户</span>
          </div>

          <label v-if="!isSuperAdmin && visibleUsers.length" class="admin-reason-field">
            <span>审批备注（可选）</span>
            <input v-model="reason" type="text" placeholder="填写通过或拒绝原因" />
          </label>

          <div v-if="!visibleUsers.length" class="admin-empty">暂无待处理用户。</div>
          <div v-else class="admin-user-list">
            <article v-for="user in visibleUsers" :key="user.id" class="admin-user-row">
              <div class="admin-user-main">
                <strong>{{ user.username || user.id }}</strong>
                <span>{{ formatDateTime(user.created_at) }}</span>
              </div>
              <span class="admin-role" :class="`role-${user.role}`">{{ user.role }}</span>
              <span class="admin-status" :class="`status-${user.approval_status}`">{{ user.approval_status }}</span>
              <div class="admin-row-actions">
                <template v-if="user.approval_status === 'pending'">
                  <button class="glass-primary-btn" type="button" @click="approveUser(user.id, true)">通过</button>
                  <button class="glass-danger-btn" type="button" @click="approveUser(user.id, false)">拒绝</button>
                </template>
                <template v-else-if="isSuperAdmin && user.role === 'user' && user.approval_status === 'approved'">
                  <button class="glass-primary-btn" type="button" @click="promoteUser(user.id)">设为管理员</button>
                </template>
                <template v-else-if="isSuperAdmin && user.role === 'admin'">
                  <button class="glass-secondary-btn" type="button" @click="demoteUser(user.id)">取消管理员</button>
                </template>
                <span v-else class="admin-no-action">不可操作</span>
              </div>
            </article>
          </div>
        </section>

        <section v-if="isSuperAdmin" class="inventory-glass-card admin-logs-card">
          <div class="admin-section-heading">
            <div><p class="eyebrow">AUDIT TRAIL</p><h2>管理员操作记录</h2></div>
            <span>{{ logsLoading ? '加载中…' : `${groupedApprovalLogs.length} 位管理员` }}</span>
          </div>
          <div v-if="!groupedApprovalLogs.length" class="admin-empty">暂无审批操作记录。</div>
          <div v-else class="approval-user-list">
            <article v-for="group in groupedApprovalLogs" :key="group.userId" class="approval-user-group">
              <button
                class="approval-user-summary"
                :class="{ expanded: expandedLogUserId === group.userId }"
                type="button"
                :aria-expanded="expandedLogUserId === group.userId"
                @click="toggleLogUser(group.userId)"
              >
                <span class="approval-user-main">
                  <strong>{{ group.username }}</strong>
                  <small>最近审批 {{ formatDateTime(group.latestAt) }}</small>
                </span>
                <span class="approval-user-tags">
                  <span class="admin-status" :class="`status-${group.status}`">{{ group.status }}</span>
                  <span class="admin-role" :class="`role-${group.role}`">{{ group.role }}</span>
                </span>
                <span class="approval-log-count">{{ group.logs.length }} 条记录</span>
                <span class="approval-chevron" aria-hidden="true">⌄</span>
              </button>

              <div v-if="expandedLogUserId === group.userId" class="approval-timeline">
                <article v-for="log in group.logs" :key="log.id" class="approval-timeline-item">
                  <span class="approval-timeline-dot" aria-hidden="true"></span>
                  <div class="approval-record-card">
                    <div class="approval-record-heading">
                      <strong>{{ group.username }} 对 {{ usernameFor(log.target_user_id) }}：{{ formatActionType(log) }}</strong>
                      <time>操作时间 {{ formatDateTime(log.created_at) }}</time>
                    </div>
                    <dl class="approval-record-details">
                      <div><dt>审批人</dt><dd>{{ group.username }}</dd></div>
                      <div><dt>操作对象</dt><dd>{{ usernameFor(log.target_user_id) }}</dd></div>
                      <div><dt>操作类型</dt><dd>{{ formatActionType(log) }}</dd></div>
                      <div v-if="hasStatusChange(log)" class="approval-change-row">
                        <dt>状态变更</dt>
                        <dd><span :class="`status-text-${log.old_status}`">{{ log.old_status }}</span><b>→</b><span :class="`status-text-${log.new_status}`">{{ log.new_status }}</span></dd>
                      </div>
                      <div v-if="hasRoleChange(log)" class="approval-change-row">
                        <dt>角色变更</dt><dd><span>{{ log.old_role }}</span><b>→</b><span>{{ log.new_role }}</span></dd>
                      </div>
                      <div v-if="hasReason(log)" class="approval-note-row"><dt>备注</dt><dd>{{ log.reason }}</dd></div>
                    </dl>
                  </div>
                </article>
              </div>
            </article>
          </div>
        </section>
      </template>
    </main>

    <GlassModal v-if="modal.show" :message="modal.message" @close="closeMessage" />
  </div>
</template>
