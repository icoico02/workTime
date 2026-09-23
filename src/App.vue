<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { RouterView, useRoute, useRouter } from 'vue-router'
import FunctionHeader from './components/FunctionHeader.vue'
import GlassModal from './components/GlassModal.vue'
import SystemSidebar from './components/SystemSidebar.vue'
import { AUTH_STORAGE_KEY, authStorage, isSupabaseConfigured, supabase } from './supabase'

const authUser = ref(null)
const userProfile = ref(null)
const authGateMessage = ref('')
const pendingApprovalCount = ref(0)
const pendingApprovalLoading = ref(false)

const currentDate = ref(formatDate(new Date()))
const currentTime = ref(formatTime(new Date()))
const todayKey = ref(formatDateKey(new Date()))
const attendanceRecords = ref([])
const attendanceLoading = ref(false)

const todayRecord = computed(() => {
  return attendanceRecords.value.find((item) => item.date === todayKey.value) || null
})

const workDurationText = computed(() => {
  const record = todayRecord.value

  if (!record || !record.startTime || !record.endTime) {
    return '--:--'
  }

  const start = new Date(record.startTime)
  const end = new Date(record.endTime)

  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime()) || end < start) {
    return '--:--'
  }

  const totalMinutes = Math.round((end - start) / (1000 * 60))
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60

  return `${hours}小时${minutes}分钟`
})

const historyList = computed(() => {
  return [...attendanceRecords.value].sort((a, b) => {
    return new Date(b.startTime || b.date) - new Date(a.startTime || a.date)
  })
})

function userStorageKey(key) {
  return authUser.value ? `${key}:${authUser.value.id}` : ''
}

function formatDate(date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')

  return `${year}年${month}月${day}日`
}

function formatDateKey(date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')

  return `${year}-${month}-${day}`
}

function formatTime(date) {
  return date.toLocaleTimeString('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  })
}

function formatShortDate(dateString) {
  const date = new Date(`${dateString}T00:00:00`)
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')

  return `${month}/${day}`
}

function formatWeekday(dateString) {
  const date = new Date(`${dateString}T00:00:00`)
  const weekdayMap = ['日', '一', '二', '三', '四', '五', '六']

  return `周${weekdayMap[date.getDay()]}`
}

function formatAttendanceTime(value) {
  if (!value) return '--:--:--'
  return formatTime(new Date(value))
}

function parseLocalDateTimeToIso(dateString, timeString) {
  if (!dateString || !timeString) return null
  const localDate = new Date(`${dateString}T${timeString}`)
  return Number.isNaN(localDate.getTime()) ? null : localDate.toISOString()
}

function mapAttendanceRecord(record) {
  return {
    id: record.id,
    user_id: record.user_id,
    date: record.work_date,
    startTime: record.check_in_time,
    endTime: record.check_out_time,
  }
}

async function loadAttendanceRecords() {
  if (!supabase || !authUser.value) {
    attendanceRecords.value = []
    return
  }

  attendanceLoading.value = true
  const { data, error } = await supabase
    .from('attendance_records')
    .select('id, user_id, work_date, check_in_time, check_out_time, created_at')
    .eq('user_id', authUser.value.id)
    .order('work_date', { ascending: false })

  attendanceLoading.value = false

  if (error) {
    showTimerWarning('签到记录加载失败，请检查网络后重试。')
    return
  }

  attendanceRecords.value = (data || []).map(mapAttendanceRecord)
}

function getTodayRecord() {
  return attendanceRecords.value.find((item) => item.date === todayKey.value) || null
}

function updateClock() {
  const now = new Date()
  currentDate.value = formatDate(now)
  currentTime.value = formatTime(now)

  const newTodayKey = formatDateKey(now)
  if (newTodayKey !== todayKey.value) {
    todayKey.value = newTodayKey
  }
}

async function startWork() {
  if (!supabase || !authUser.value) {
    showTimerWarning('请先登录后再进行上班签到。')
    return
  }

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    showTimerWarning('登录状态已失效，请重新登录。')
    return
  }

  const { data: existingRecord, error: queryError } = await supabase
    .from('attendance_records')
    .select('id, user_id, work_date, check_in_time, check_out_time')
    .eq('user_id', user.id)
    .eq('work_date', todayKey.value)
    .maybeSingle()

  if (queryError) {
    showTimerWarning('签到记录查询失败，请检查网络后重试。')
    return
  }

  if (existingRecord?.check_in_time) {
    showTimerWarning('今天已经完成上班签到')
    return
  }

  const { error } = await supabase.from('attendance_records').insert({
    user_id: user.id,
    work_date: todayKey.value,
    check_in_time: new Date().toISOString(),
  })

  if (error) {
    showTimerWarning('上班签到失败，请检查网络后重试。')
    return
  }

  await loadAttendanceRecords()
}

async function endWork() {
  if (!supabase || !authUser.value) {
    showTimerWarning('请先登录后再进行下班签退。')
    return
  }

  const { data: { user } } = await supabase.auth.getUser()
  const record = getTodayRecord()

  if (!user || !record || !record.startTime) {
    showTimerWarning('请先进行上班签到')
    return
  }

  if (record.endTime) {
    showTimerWarning('今天已经完成下班签到')
    return
  }

  const { error } = await supabase
    .from('attendance_records')
    .update({ check_out_time: new Date().toISOString() })
    .eq('id', record.id)
    .eq('user_id', user.id)

  if (error) {
    showTimerWarning('下班签退失败，请检查网络后重试。')
    return
  }

  await loadAttendanceRecords()
}

function formatWorkDuration(item) {
  if (!item.startTime || !item.endTime) {
    return '--:--'
  }

  const start = new Date(item.startTime)
  const end = new Date(item.endTime)

  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime()) || end < start) {
    return '--:--'
  }

  const totalMinutes = Math.round((end - start) / (1000 * 60))
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60

  return `${hours}小时${minutes}分钟`
}

function isValidTimeString(value) {
  return /^\d{2}:\d{2}:\d{2}$/.test(value)
}

const deleteConfirmation = ref({ show: false, recordId: '' })

function openDeleteConfirmation(recordId) {
  deleteConfirmation.value = {
    show: true,
    recordId,
  }
}

function closeDeleteConfirmation() {
  deleteConfirmation.value = {
    show: false,
    recordId: '',
  }
}

async function confirmDeleteRecord() {
  if (!supabase || !authUser.value) return

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return

  const { error } = await supabase
    .from('attendance_records')
    .delete()
    .eq('id', deleteConfirmation.value.recordId)
    .eq('user_id', user.id)

  if (error) {
    showTimerWarning('删除签到记录失败，请检查网络后重试。')
    return
  }

  await loadAttendanceRecords()
  closeDeleteConfirmation()
}

const editForm = ref({
  recordDate: '',
  startTime: '',
  endTime: '',
})

const isEditPanelOpen = ref(false)
const isMakeUpPanelOpen = ref(false)
const makeUpForm = ref({
  recordDate: '',
  startTime: '09:00:00',
  endTime: '18:00:00',
})
const currentScreen = ref('home')
const pressedButton = ref('')
const router = useRouter()
const route = useRoute()
const isInventoryRoute = computed(() => route.path.startsWith('/inventory'))
const isAdminRoute = computed(() => route.path.startsWith('/admin') || route.path.startsWith('/super-admin'))
const isDashboardRoute = computed(() => route.path === '/dashboard')
const isAdmin = computed(() => ['admin', 'super_admin'].includes(userProfile.value?.role))
const isSuperAdmin = computed(() => userProfile.value?.role === 'super_admin')
const activeNavigation = computed(() => {
  if (route.path.startsWith('/inventory')) return 'inventory'
  if (route.path === '/dashboard') return 'dashboard'
  if (route.path.startsWith('/super-admin')) return 'super-admin'
  if (route.path.startsWith('/admin')) return 'admin'
  return currentScreen.value
})

async function loadPendingApprovalCount() {
  if (!supabase || !authUser.value || !isAdmin.value) {
    pendingApprovalCount.value = 0
    return
  }

  pendingApprovalLoading.value = true
  const { count, error } = await supabase
    .from('profiles')
    .select('id', { count: 'exact', head: true })
    .eq('approval_status', 'pending')
  pendingApprovalLoading.value = false

  if (error) {
    console.error(error)
    pendingApprovalCount.value = 0
    return
  }

  pendingApprovalCount.value = count || 0
}

function openPendingApprovals() {
  if (!isAdmin.value) return
  router.push(isSuperAdmin.value ? '/super-admin?section=pending' : '/admin')
}

function handlePendingApprovalChanged() {
  loadPendingApprovalCount()
}

function pressButton(buttonName) {
  pressedButton.value = buttonName
}

function releaseButton(buttonName) {
  if (pressedButton.value === buttonName) {
    pressedButton.value = ''
  }
}

const timerRunning = ref(false)
const timerStartedAt = ref(0)
const timerElapsedMs = ref(0)
const timerIntervalId = ref(null)
const timerSessionStartedAt = ref(0)
const timerSessionSaved = ref(false)
const timerHistory = ref([])
const timerHistoryLoading = ref(false)
const authLoading = ref(true)
const rememberDevice = ref(true)
const loginForm = ref({ username: '', password: '', confirmation: '' })
const loginError = ref('')
const loginSubmitting = ref(false)
const authMode = ref('login')
const registrationInProgress = ref(false)
const approvalStatusUsername = ref('')
const approvalStatusLoading = ref(false)
const approvalStatusResult = ref(null)
const authSubscription = ref(null)
const timerPendingRecord = ref(null)
const selectedTimerRecordIds = ref([])
const timerDeleteConfirmation = ref({ show: false, recordIds: [] })

watch(approvalStatusUsername, () => {
  approvalStatusResult.value = null
  if (authMode.value === 'status') {
    loginError.value = ''
  }
})

function activeTimerStorageKey() {
  return authUser.value ? `activeTimerSession:${authUser.value.id}` : ''
}

function formatTimerDisplay(ms) {
  const totalMs = Math.max(0, Math.floor(ms))
  const hours = Math.floor(totalMs / (1000 * 60 * 60))
  const minutes = Math.floor((totalMs % (1000 * 60 * 60)) / (1000 * 60))
  const seconds = Math.floor((totalMs % (1000 * 60)) / 1000)
  const milliseconds = totalMs % 1000

  return `${String(hours).padStart(2, '0')}h ${String(minutes).padStart(2, '0')}m ${String(seconds).padStart(2, '0')}s ${String(milliseconds).padStart(3, '0')}ms`
}

const timerDisplay = computed(() => formatTimerDisplay(timerElapsedMs.value))

const timerDisplayParts = computed(() => {
  const text = formatTimerDisplay(timerElapsedMs.value)
  const match = text.match(/^(\d{2})h\s+(\d{2})m\s+(\d{2})s\s+(\d{3})ms$/)

  if (!match) {
    return ['0', '0', '0', '0', '0', '0', '0', '0', '0']
  }

  return [
    ...match[1].split(''),
    ...match[2].split(''),
    ...match[3].split(''),
    ...match[4].split(''),
  ]
})

const timerWarning = ref({ show: false, message: '' })
const timerWarningAction = ref(null)

function showTimerWarning(message) {
  timerWarning.value = {
    show: true,
    message,
  }
  timerWarningAction.value = null
}

function closeTimerWarning() {
  timerWarning.value = {
    show: false,
    message: '',
  }
  timerWarningAction.value = null
}

function timerRecordSaveErrorMessage(error) {
  const detail = `${error?.code || ''} ${error?.message || ''}`.toLowerCase()

  if (detail.includes('total_milliseconds') || detail.includes('42703')) {
    return '计时记录表尚未升级，请先在 Supabase 执行 supabase/timer_records.sql。'
  }

  if (detail.includes('42501') || detail.includes('row-level security')) {
    return '没有保存计时记录的权限，请检查 timer_records 的 RLS 策略。'
  }

  return '记录保存失败，请检查网络后重试。'
}

function saveActiveTimerSession() {
  const storageKey = activeTimerStorageKey()

  if (!storageKey) {
    return
  }

  if (!timerSessionStartedAt.value) {
    localStorage.removeItem(storageKey)
    return
  }

  localStorage.setItem(storageKey, JSON.stringify({
    startTime: timerSessionStartedAt.value,
    startedAt: timerSessionStartedAt.value,
    timerStartedAt: timerStartedAt.value,
    elapsedMs: timerElapsedMs.value,
    running: timerRunning.value,
    saved: timerSessionSaved.value,
  }))
}

function clearActiveTimerSession() {
  const storageKey = activeTimerStorageKey()
  if (storageKey) localStorage.removeItem(storageKey)
}

function restoreActiveTimerSession() {
  try {
    const storageKey = activeTimerStorageKey()
    if (!storageKey) return

    const saved = localStorage.getItem(storageKey)
    const session = saved ? JSON.parse(saved) : null

    const sessionStartedAt = Number(session?.startTime || session?.startedAt)
    const elapsedMs = Math.max(0, Number(session?.elapsedMs || 0))

    if (!Number.isFinite(sessionStartedAt) || sessionStartedAt <= 0) {
      return
    }

    clearInterval(timerIntervalId.value)
    timerIntervalId.value = null
    timerSessionStartedAt.value = sessionStartedAt
    timerSessionSaved.value = Boolean(session.saved)
    timerElapsedMs.value = elapsedMs
    timerRunning.value = false

    if (session.running) {
      const runningStartedAt = Number(session.timerStartedAt)
      timerStartedAt.value = Number.isFinite(runningStartedAt) && runningStartedAt > 0
        ? runningStartedAt
        : Date.now() - elapsedMs
      timerRunning.value = true
      syncTimerElapsed()
      startTimerInterval()
    }
  } catch (error) {
    console.error('恢复计时状态失败:', error)
    const storageKey = activeTimerStorageKey()
    if (storageKey) localStorage.removeItem(storageKey)
  }
}

function syncTimerElapsed() {
  if (!timerRunning.value || !timerStartedAt.value) return
  timerElapsedMs.value = Math.max(0, Date.now() - timerStartedAt.value)
}

function persistTimerForPageLifecycle() {
  syncTimerElapsed()
  saveActiveTimerSession()
}

function handleTimerVisibilityChange() {
  if (document.visibilityState === 'hidden') {
    persistTimerForPageLifecycle()
    return
  }

  syncTimerElapsed()
}

function formatRecordTime(value) {
  if (!value) return '--:--:--'
  return new Date(value).toLocaleTimeString('zh-CN', { hour12: false })
}

function formatRecordDate(value) {
  if (!value) return '--'
  return new Date(value).toLocaleDateString('zh-CN')
}

function formatStoredDuration(record) {
  if (record.total_milliseconds != null && Number.isFinite(Number(record.total_milliseconds))) {
    return formatTimerDisplay(Number(record.total_milliseconds))
  }

  if (record.total_seconds != null && Number.isFinite(Number(record.total_seconds))) {
    return formatTimerDisplay(Number(record.total_seconds) * 1000)
  }

  const start = new Date(record.start_time).getTime()
  const end = new Date(record.end_time).getTime()
  const elapsed = Number.isFinite(start) && Number.isFinite(end)
    ? Math.max(0, end - start)
    : 0
  return formatTimerDisplay(elapsed)
}

async function loadTimerHistory() {
  if (!supabase || !authUser.value) {
    timerHistory.value = []
    return
  }

  timerHistoryLoading.value = true
  const { data, error } = await supabase
    .from('timer_records')
    .select('*')
    .eq('user_id', authUser.value.id)
    .order('created_at', { ascending: false })

  timerHistoryLoading.value = false

  if (error) {
    showTimerWarning('历史记录加载失败，请检查网络后重试。')
    return
  }

  timerHistory.value = data || []
  selectedTimerRecordIds.value = selectedTimerRecordIds.value.filter((id) => timerHistory.value.some((record) => record.id === id))
}

async function loadCurrentProfile(user) {
  if (!supabase || !user) return null

  const { data, error } = await supabase
    .from('profiles')
    .select('id, username, role, approval_status, created_at')
    .eq('id', user.id)
    .maybeSingle()

  if (error) {
    console.error(error)
    authGateMessage.value = '用户资料加载失败，请稍后重试。'
    return null
  }

  return data
}

async function handleAuthSession(session) {
  if (!session?.user) {
    authUser.value = null
    userProfile.value = null
    authStorage.setMode('local')
    return false
  }

  const profile = await loadCurrentProfile(session.user)
  const status = profile?.approval_status

  if (!profile || status !== 'approved') {
    if (status === 'pending') {
      authGateMessage.value = '您的账号正在等待管理员审批。'
    } else if (status === 'rejected') {
      authGateMessage.value = '您的注册申请未通过审批。'
    } else if (!profile) {
      authGateMessage.value = '用户资料不存在，请联系管理员。'
    }

    await supabase.auth.signOut()
    authUser.value = null
    userProfile.value = null
    authStorage.setMode('local')
    return false
  }

  authGateMessage.value = ''
  authUser.value = session.user
  userProfile.value = profile
  currentScreen.value = 'home'
  resetViewportScroll()
  if (isInventoryRoute.value || isAdminRoute.value) {
    await router.replace('/')
  }
  return true
}

async function signIn() {
  loginError.value = ''

  if (!supabase) {
    loginError.value = '登录服务尚未配置'
    return
  }

  const username = loginForm.value.username.trim()
  const password = loginForm.value.password

  if (!username || !password) {
    loginError.value = '请输入账号和密码'
    return
  }

  migrateSessionToStorage(rememberDevice.value ? 'local' : 'session')

  loginSubmitting.value = true
  const { error } = await supabase.auth.signInWithPassword({
    email: `${username}@attendance.local`,
    password,
  })
  loginSubmitting.value = false

  if (error) {
    loginError.value = '账号或密码错误'
    return
  }

  loginForm.value.password = ''
  loginForm.value.confirmation = ''
}

async function signUp() {
  loginError.value = ''

  if (!supabase) {
    loginError.value = '登录服务尚未配置'
    return
  }

  const username = loginForm.value.username.trim()
  const password = loginForm.value.password
  const confirmation = loginForm.value.confirmation

  if (!username || !password || !confirmation) {
    loginError.value = '请完整填写注册信息'
    return
  }

  if (!/^[a-zA-Z0-9._-]+$/.test(username)) {
    loginError.value = '账号只能包含字母、数字、点、下划线或短横线'
    return
  }

  if (password.length < 6) {
    loginError.value = '密码至少需要 6 位'
    return
  }

  if (password !== confirmation) {
    loginError.value = '两次输入的密码不一致'
    return
  }

  registrationInProgress.value = true
  loginSubmitting.value = true
  migrateSessionToStorage('local')
  const { data, error } = await supabase.auth.signUp({
    email: `${username}@attendance.local`,
    password,
  })
  loginSubmitting.value = false

  if (error) {
    registrationInProgress.value = false
    if (error.code === 'user_already_exists' || error.message?.toLowerCase().includes('already registered')) {
      loginError.value = '账号已存在，请直接登录'
    } else if (error.code === 'signup_disabled') {
      loginError.value = '当前暂未开放注册，请联系管理员'
    } else if (error.code === 'email_address_invalid') {
      loginError.value = '账号格式无效，请更换账号后重试'
    } else if (error.code === 'weak_password') {
      loginError.value = '密码强度不足，请使用至少 6 位密码'
    } else {
      loginError.value = '注册失败，请检查 Supabase Auth 配置'
    }
    return
  }

  const registeredUser = data.user
  if (!registeredUser) {
    registrationInProgress.value = false
    loginError.value = '注册失败，未获取到用户信息'
    return
  }

  const { error: profileError } = await supabase
    .from('profiles')
    .update({ username })
    .eq('id', registeredUser.id)

  registrationInProgress.value = false

  if (profileError) {
    console.error(profileError)
    loginError.value = '注册失败，用户资料保存失败，请稍后重试'
    return
  }

  if (data.session) {
    await supabase.auth.signOut()
  }

  loginForm.value = { username: '', password: '', confirmation: '' }
  loginError.value = '注册申请已提交，请等待管理员审批。'
  authMode.value = 'login'
}

function openApprovalStatusQuery() {
  authMode.value = 'status'
  loginError.value = ''
  approvalStatusUsername.value = ''
  approvalStatusResult.value = null
}

function closeApprovalStatusQuery() {
  authMode.value = 'login'
  loginError.value = ''
  approvalStatusUsername.value = ''
  approvalStatusResult.value = null
}

async function checkApprovalStatus() {
  loginError.value = ''
  approvalStatusResult.value = null

  if (!supabase) {
    loginError.value = '查询服务尚未配置'
    return
  }

  const username = approvalStatusUsername.value.trim()
  if (!username || !/^[a-zA-Z0-9._-]+$/.test(username)) {
    loginError.value = '请输入正确的用户名'
    return
  }

  approvalStatusLoading.value = true
  const { data, error } = await supabase.rpc('check_approval_status', {
    p_username: username,
  })
  approvalStatusLoading.value = false

  if (error) {
    console.error(error)
    loginError.value = '未找到该账号，请确认用户名是否正确。'
    return
  }

  const result = Array.isArray(data) ? data[0] : data
  const approvalStatus = result?.approval_status
  if (!['pending', 'approved', 'rejected'].includes(approvalStatus)) {
    loginError.value = '未找到该账号，请确认用户名是否正确。'
    return
  }

  approvalStatusResult.value = {
    status: approvalStatus,
    reason: result.rejection_reason || result.reason || '',
  }
}

async function signOut() {
  const storageKey = activeTimerStorageKey()
  if (supabase) {
    await supabase.auth.signOut()
  }
  if (storageKey) localStorage.removeItem(storageKey)
  authUser.value = null
  userProfile.value = null
  pendingApprovalCount.value = 0
  timerHistory.value = []
}

async function saveTimerRecord() {
  if (timerSessionSaved.value || !timerSessionStartedAt.value || !supabase) {
    return true
  }

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    timerPendingRecord.value = null
    showTimerWarning('登录状态已失效，请重新登录。')
    return false
  }

  const endTime = new Date()
  const totalMilliseconds = Math.floor(timerElapsedMs.value)
  const totalSeconds = Math.floor(timerElapsedMs.value / 1000)
  const record = {
    user_id: user.id,
    start_time: new Date(timerSessionStartedAt.value).toISOString(),
    end_time: endTime.toISOString(),
    total_milliseconds: totalMilliseconds,
    total_seconds: totalSeconds,
  }

  const { error } = await supabase.from('timer_records').insert(record)
  if (error) {
    console.error('保存计时记录失败:', error)
    timerPendingRecord.value = record
    timerWarning.value = { show: true, message: timerRecordSaveErrorMessage(error) }
    timerWarningAction.value = 'retry'
    return false
  }

  timerSessionSaved.value = true
  timerPendingRecord.value = null
  clearCompletedTimerState()
  await loadTimerHistory()
  timerWarning.value = { show: true, message: '记录已保存' }
  timerWarningAction.value = null
  return true
}

async function retryTimerRecord() {
  if (!timerPendingRecord.value || !supabase) return

  const { error } = await supabase.from('timer_records').insert(timerPendingRecord.value)
  if (error) {
    console.error('重试保存计时记录失败:', error)
    showTimerWarning(timerRecordSaveErrorMessage(error))
    timerWarningAction.value = 'retry'
    return
  }

  timerSessionSaved.value = true
  timerPendingRecord.value = null
  clearCompletedTimerState()
  await loadTimerHistory()
  showTimerWarning('记录已保存')
}

function openAttendancePage() {
  currentScreen.value = 'attendance'
}

function openTimerPage() {
  currentScreen.value = 'timer'
}

function goHome() {
  currentScreen.value = 'home'
  loadPendingApprovalCount()
}

function openInventoryPage() {
  router.push('/inventory/dashboard')
}

async function navigateWorkspace(target) {
  if (target === 'inventory') {
    await router.push('/inventory/dashboard')
    return
  }

  if (target === 'dashboard') {
    await router.push('/dashboard')
    return
  }

  if (target === 'admin') {
    await router.push('/admin')
    return
  }

  if (target === 'super-admin') {
    await router.push('/super-admin')
    return
  }

  if (route.path !== '/') await router.push('/')
  currentScreen.value = target
  if (target === 'home') loadPendingApprovalCount()
  resetViewportScroll()
}

function resetViewportScroll() {
  window.requestAnimationFrame(() => window.scrollTo(0, 0))
}

function startTimerInterval() {
  clearInterval(timerIntervalId.value)
  timerIntervalId.value = setInterval(() => {
    syncTimerElapsed()
  }, 10)
}

function startTimer() {
  if (timerRunning.value) {
    return
  }

  if (!timerSessionStartedAt.value || timerSessionSaved.value) {
    timerSessionStartedAt.value = Date.now()
    timerSessionSaved.value = false
    timerElapsedMs.value = 0
  }

  timerStartedAt.value = Date.now() - timerElapsedMs.value
  timerRunning.value = true
  saveActiveTimerSession()
  startTimerInterval()
}

function pauseTimer() {
  if (!timerRunning.value) {
    return
  }

  syncTimerElapsed()
  timerRunning.value = false
  clearInterval(timerIntervalId.value)
  timerIntervalId.value = null
  saveActiveTimerSession()
}

async function endTimer() {
  if (!timerSessionStartedAt.value) {
    showTimerWarning('请先开始计时')
    return
  }

  syncTimerElapsed()
  timerRunning.value = false
  clearInterval(timerIntervalId.value)
  timerIntervalId.value = null
  saveActiveTimerSession()
  await saveTimerRecord()
}

function clearCompletedTimerState() {
  clearInterval(timerIntervalId.value)
  timerIntervalId.value = null
  timerRunning.value = false
  timerStartedAt.value = 0
  timerElapsedMs.value = 0
  timerSessionStartedAt.value = 0
  timerSessionSaved.value = false
  timerPendingRecord.value = null
  clearActiveTimerSession()
}

function resetTimer() {
  if (timerRunning.value) {
    showTimerWarning('计时中，请先暂停，再重置')
    return
  }

  if (timerElapsedMs.value === 0) {
    showTimerWarning('当前计时器已是初始状态，无需重置')
    return
  }

  clearCompletedTimerState()
}

function requestDeleteTimerRecords(recordIds) {
  const ids = [...new Set(recordIds)].filter(Boolean)
  if (!ids.length) return

  timerDeleteConfirmation.value = { show: true, recordIds: ids }
}

function closeTimerDeleteConfirmation() {
  timerDeleteConfirmation.value = { show: false, recordIds: [] }
}

async function confirmDeleteTimerRecords() {
  const recordIds = timerDeleteConfirmation.value.recordIds
  if (!supabase || !authUser.value || !recordIds.length) return

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return

  const { error } = await supabase
    .from('timer_records')
    .delete()
    .in('id', recordIds)
    .eq('user_id', user.id)

  if (error) {
    showTimerWarning('删除计时记录失败，请检查网络后重试。')
    return
  }

  selectedTimerRecordIds.value = selectedTimerRecordIds.value.filter((id) => !recordIds.includes(id))
  closeTimerDeleteConfirmation()
  await loadTimerHistory()
}

function migrateSessionToStorage(mode) {
  if (!supabase || !authStorage.getItem(AUTH_STORAGE_KEY)) return
  if (authStorage.getMode() === mode) return
  authStorage.setMode(mode)
}

function openEditPanel(record) {
  editForm.value = {
    recordDate: record.date,
    startTime: record.startTime ? formatEditTime(record.startTime) : '08:00:00',
    endTime: record.endTime ? formatEditTime(record.endTime) : '18:00:00',
    recordId: record.id,
  }
  isEditPanelOpen.value = true
}

function formatEditTime(value) {
  return formatTime(new Date(value))
}

function closeEditPanel() {
  isEditPanelOpen.value = false
}

function openMakeUpPanel() {
  const yesterday = new Date()
  yesterday.setDate(yesterday.getDate() - 1)
  makeUpForm.value = {
    recordDate: formatDateKey(yesterday),
    startTime: '09:00:00',
    endTime: '18:00:00',
  }
  isMakeUpPanelOpen.value = true
}

function closeMakeUpPanel() {
  isMakeUpPanelOpen.value = false
}

async function submitMakeUpRecord() {
  const { recordDate, startTime, endTime } = makeUpForm.value
  const checkInTime = parseLocalDateTimeToIso(recordDate, startTime)
  const checkOutTime = parseLocalDateTimeToIso(recordDate, endTime)

  if (!recordDate || !isValidTimeString(startTime) || !isValidTimeString(endTime) || !checkInTime || !checkOutTime) {
    showTimerWarning('请填写有效的补签日期和时间')
    return
  }

  if (recordDate >= todayKey.value) {
    showTimerWarning('补签仅支持今天之前的日期')
    return
  }

  if (new Date(checkOutTime) <= new Date(checkInTime)) {
    showTimerWarning('下班时间需要晚于上班时间')
    return
  }

  if (!supabase || !authUser.value) return
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    showTimerWarning('登录状态已失效，请重新登录。')
    return
  }

  const { data: existingRecord, error: queryError } = await supabase
    .from('attendance_records')
    .select('id')
    .eq('user_id', user.id)
    .eq('work_date', recordDate)
    .maybeSingle()

  if (queryError) {
    showTimerWarning('补签记录查询失败，请检查网络后重试。')
    return
  }

  if (existingRecord) {
    showTimerWarning('该日期已有签到记录，请使用修改功能')
    return
  }

  const { error } = await supabase.from('attendance_records').insert({
    user_id: user.id,
    work_date: recordDate,
    check_in_time: checkInTime,
    check_out_time: checkOutTime,
  })

  if (error) {
    showTimerWarning('补签保存失败，请检查网络后重试。')
    return
  }

  await loadAttendanceRecords()
  closeMakeUpPanel()
}

async function submitEditRecord() {
  if (!editForm.value.recordDate) {
    showTimerWarning('请选择日期')
    return
  }

  if (!supabase || !authUser.value) return
  const { data: { user } } = await supabase.auth.getUser()
  const targetRecord = attendanceRecords.value.find((item) => item.id === editForm.value.recordId)

  if (!user || !targetRecord) {
    showTimerWarning('未找到对应日期记录')
    return
  }

  const { error } = await supabase
    .from('attendance_records')
    .update({
      work_date: editForm.value.recordDate,
      check_in_time: parseLocalDateTimeToIso(editForm.value.recordDate, editForm.value.startTime),
      check_out_time: parseLocalDateTimeToIso(editForm.value.recordDate, editForm.value.endTime),
    })
    .eq('id', targetRecord.id)
    .eq('user_id', user.id)

  if (error) {
    showTimerWarning('修改签到记录失败，请检查网络后重试。')
    return
  }

  await loadAttendanceRecords()
  closeEditPanel()
}

onMounted(async () => {
  updateClock()
  setInterval(updateClock, 1000)

  if (!supabase) {
    authLoading.value = false
    return
  }

  const { data: { session } } = await supabase.auth.getSession()
  const approved = await handleAuthSession(session)
  authLoading.value = false

  if (approved && authUser.value) {
    if (isInventoryRoute.value) {
      await router.replace('/')
    }
    await loadAttendanceRecords()
    restoreActiveTimerSession()
    await loadTimerHistory()
    await loadPendingApprovalCount()
  }

  const { data } = supabase.auth.onAuthStateChange((event, sessionState) => {
    if (registrationInProgress.value) {
      return
    }

    window.setTimeout(async () => {
      const approvedSession = await handleAuthSession(sessionState)
      if (approvedSession && authUser.value) {
        if (isInventoryRoute.value) {
          await router.replace('/')
        }
        await loadAttendanceRecords()
        restoreActiveTimerSession()
        await loadTimerHistory()
        await loadPendingApprovalCount()
      } else {
        currentScreen.value = 'home'
        attendanceRecords.value = []
        pendingApprovalCount.value = 0
        timerHistory.value = []
      }
    }, 0)
  })
  authSubscription.value = data.subscription
  window.addEventListener('pending-approval-changed', handlePendingApprovalChanged)
  window.addEventListener('pagehide', persistTimerForPageLifecycle)
  document.addEventListener('visibilitychange', handleTimerVisibilityChange)
})

onBeforeUnmount(() => {
  persistTimerForPageLifecycle()
  clearInterval(timerIntervalId.value)
  authSubscription.value?.unsubscribe()
  window.removeEventListener('pending-approval-changed', handlePendingApprovalChanged)
  window.removeEventListener('pagehide', persistTimerForPageLifecycle)
  document.removeEventListener('visibilitychange', handleTimerVisibilityChange)
})
</script>

<template>
  <div v-if="authLoading" class="login-page">
    <div class="auth-shell auth-loading-shell">
      <div class="auth-glass-card"><p>正在检查登录状态…</p></div>
    </div>
  </div>

  <div v-else-if="!authUser" class="login-page">
    <main class="auth-shell">
      <section class="auth-glass-card">
      <p class="auth-eyebrow">PERSONAL WORKSPACE</p>
      <h1>{{ authMode === 'login' ? '系统登录' : authMode === 'register' ? '创建账号' : '查询审批状态' }}</h1>
      <p class="auth-description">{{ authMode === 'status' ? '输入用户名查看注册申请状态' : '登录后访问全部工作功能' }}</p>

      <form v-if="authMode === 'status'" class="auth-form" @submit.prevent="checkApprovalStatus">
        <label>
          <span>用户名</span>
          <input v-model="approvalStatusUsername" type="text" autocomplete="username" placeholder="请输入用户名" />
        </label>
        <p v-if="loginError" class="auth-error" role="alert">{{ loginError }}</p>
        <div v-if="approvalStatusResult" class="approval-status-result">
          <strong v-if="approvalStatusResult.status === 'pending'" class="approval-pending">🟠 待审批</strong>
          <strong v-else-if="approvalStatusResult.status === 'approved'" class="approval-approved">🟢 已通过</strong>
          <strong v-else-if="approvalStatusResult.status === 'rejected'" class="approval-rejected">🔴 已拒绝</strong>
          <p v-if="approvalStatusResult.status === 'pending'">您的账号正在等待管理员审批，审批通过后即可登录系统。</p>
          <p v-else-if="approvalStatusResult.status === 'approved'">您的账号已经通过审批，可以登录系统。</p>
          <p v-else-if="approvalStatusResult.status === 'rejected'">该账号暂未通过审批。</p>
          <p v-if="approvalStatusResult.status === 'rejected' && approvalStatusResult.reason" class="approval-reason">拒绝原因：{{ approvalStatusResult.reason }}</p>
        </div>
        <button class="auth-submit-btn" type="submit" :disabled="approvalStatusLoading">
          {{ approvalStatusLoading ? '查询中…' : '查询状态' }}
        </button>
        <button class="auth-mode-btn" type="button" @click="closeApprovalStatusQuery">← 返回登录</button>
      </form>

      <form v-else class="auth-form" @submit.prevent="authMode === 'login' ? signIn() : signUp()">
        <label>
          <span>账号</span>
          <input v-model="loginForm.username" type="text" autocomplete="username" placeholder="请输入账号" />
        </label>
        <label>
          <span>密码</span>
          <input v-model="loginForm.password" type="password" autocomplete="current-password" placeholder="请输入密码" />
        </label>
        <label v-if="authMode === 'login'" class="remember-device">
          <input v-model="rememberDevice" type="checkbox" />
          <span class="remember-device-text">记住此设备</span>
          <span class="switch-track" aria-hidden="true">
            <span class="switch-thumb"></span>
          </span>
        </label>
        <label v-if="authMode === 'register'">
          <span>确认密码</span>
          <input v-model="loginForm.confirmation" type="password" autocomplete="new-password" placeholder="请再次输入密码" />
        </label>
        <p v-if="loginError || authGateMessage" class="auth-error" role="alert">{{ loginError || authGateMessage }}</p>
        <button class="auth-submit-btn" type="submit" :disabled="loginSubmitting">
          {{ loginSubmitting ? '处理中…' : authMode === 'login' ? '登录' : '注册' }}
        </button>
      </form>
      <div v-if="authMode !== 'status'" class="auth-footer-actions">
        <button class="auth-mode-btn" type="button" @click="authMode = authMode === 'login' ? 'register' : 'login'; loginError = ''">
          {{ authMode === 'login' ? '还没有账号？注册' : '已有账号？返回登录' }}
        </button>
        <button v-if="authMode === 'login'" class="auth-status-link" type="button" @click="openApprovalStatusQuery">🔍 查询审批状态</button>
      </div>
      </section>
    </main>
  </div>

  <div v-else class="system-layout">
    <SystemSidebar
      :active-item="activeNavigation"
      :is-admin="isAdmin"
      :is-super-admin="isSuperAdmin"
      :pending-count="pendingApprovalCount"
      :username="userProfile?.username || authUser?.email?.split('@')[0] || '用户'"
      @navigate="navigateWorkspace"
      @sign-out="signOut"
    />

    <div class="system-main">
      <RouterView v-if="isInventoryRoute || isAdminRoute || isDashboardRoute" />

      <div v-else class="app-shell" :class="{ 'home-app-shell': currentScreen === 'home' }">
    <div v-if="currentScreen === 'home'" class="home-screen">
      <header class="header home-header">
        <div class="home-heading">
          <p class="home-kicker">功能工作台</p>
          <h1>工作助手</h1>
          <p class="home-welcome">欢迎回来，今天也辛苦了</p>
        </div>
        <div class="home-account">
          <span class="home-user-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <circle cx="12" cy="8" r="3.5" />
              <path d="M5.5 20c.7-4 3-6 6.5-6s5.8 2 6.5 6" />
            </svg>
          </span>
          <span class="home-user-copy">
            <small>当前用户</small>
            <strong>{{ userProfile?.username || authUser?.email?.split('@')[0] || '用户' }}</strong>
          </span>
          <button class="sign-out-btn" type="button" @click="signOut">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
              <path d="M10 17l5-5-5-5M15 12H3" />
              <path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4" />
            </svg>
            <span>退出登录</span>
          </button>
        </div>
      </header>

      <section v-if="isAdmin && pendingApprovalCount > 0" class="pending-approval-banner">
        <span class="approval-banner-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
            <circle cx="9" cy="7" r="4" />
            <path d="M19 8v6M22 11h-6" />
          </svg>
        </span>
        <div class="approval-banner-copy">
          <strong>{{ pendingApprovalCount }} 位新用户等待审批</strong>
          <span>注册申请需要你的处理</span>
        </div>
        <button type="button" @click="openPendingApprovals">立即处理</button>
      </section>

      <main class="home-grid">
        <button
          class="home-card attendance-card"
          :class="{ 'is-pressed': pressedButton === 'home-attendance' }"
          type="button"
          @pointerdown="pressButton('home-attendance')"
          @pointerup="releaseButton('home-attendance')"
          @pointercancel="releaseButton('home-attendance')"
          @pointerleave="releaseButton('home-attendance')"
          @click="openAttendancePage"
        >
          <span class="home-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <rect x="3" y="4" width="18" height="17" rx="3" />
              <path d="M8 2v4M16 2v4M3 10h18M8 15l2.5 2.5L16 12" />
            </svg>
          </span>
          <span class="home-title">签到</span>
          <span class="home-subtitle">上下班打卡</span>
        </button>

        <button
          class="home-card timer-card"
          :class="{ 'is-pressed': pressedButton === 'home-timer' }"
          type="button"
          @pointerdown="pressButton('home-timer')"
          @pointerup="releaseButton('home-timer')"
          @pointercancel="releaseButton('home-timer')"
          @pointerleave="releaseButton('home-timer')"
          @click="openTimerPage"
        >
          <span class="home-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <circle cx="12" cy="13" r="8" />
              <path d="M12 9v4l3 2M9 2h6M12 5V2" />
            </svg>
          </span>
          <span class="home-title">计时</span>
          <span class="home-subtitle">时间统计</span>
        </button>

        <button class="home-card home-dashboard-card" type="button" @click="router.push('/dashboard')">
          <span class="home-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M4 19V9M10 19V5M16 19v-7M22 19H2" />
            </svg>
          </span>
          <span class="home-title">数据看板</span>
          <span class="home-subtitle">签到与计时统计</span>
        </button>

        <button
          class="home-card inventory-card"
          :class="{ 'is-pressed': pressedButton === 'home-inventory' }"
          type="button"
          @pointerdown="pressButton('home-inventory')"
          @pointerup="releaseButton('home-inventory')"
          @pointercancel="releaseButton('home-inventory')"
          @pointerleave="releaseButton('home-inventory')"
          @click="openInventoryPage"
        >
          <span class="home-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M4 7.5 12 3l8 4.5v9L12 21l-8-4.5v-9Z" />
              <path d="m4.5 7.7 7.5 4.2 7.5-4.2M12 12v9M8 5.3l8 4.5" />
            </svg>
          </span>
          <span class="home-title">进销存</span>
          <span class="home-subtitle">商品与库存管理</span>
        </button>
        <button
          v-if="isAdmin"
          class="home-card admin-card"
          type="button"
          @click="router.push('/admin')"
        >
          <span class="home-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
              <circle cx="9" cy="7" r="4" />
              <path d="M19 8v6M22 11h-6" />
            </svg>
          </span>
          <span class="home-title">用户审批</span>
          <span class="home-subtitle">处理注册申请</span>
        </button>

        <button
          v-if="isSuperAdmin"
          class="home-card super-admin-card"
          type="button"
          @click="router.push('/super-admin')"
        >
          <span class="home-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M4 7h10M18 7h2M4 17h2M10 17h10M14 4v6M10 14v6" />
              <circle cx="16" cy="7" r="2" />
              <circle cx="8" cy="17" r="2" />
            </svg>
          </span>
          <span class="home-title">管理后台</span>
          <span class="home-subtitle">系统管理</span>
        </button>
      </main>
    </div>

    <div v-else-if="currentScreen === 'attendance'" class="attendance-screen">
      <FunctionHeader title="上下班签到" @back="goHome" @sign-out="signOut" />

      <main class="screen">
        <div class="date-text">{{ currentDate }}</div>
        <div class="time-text">{{ currentTime }}</div>

        <section class="card">
          <h2>今日签到</h2>

          <div class="info-row">
            <span>上班时间</span>
            <strong>{{ todayRecord ? formatAttendanceTime(todayRecord.startTime) : '--:--:--' }}</strong>
          </div>

          <div class="info-row">
            <span>下班时间</span>
            <strong>{{ todayRecord ? formatAttendanceTime(todayRecord.endTime) : '--:--:--' }}</strong>
          </div>

          <div class="info-row">
            <span>工作时长</span>
            <strong>{{ workDurationText }}</strong>
          </div>
        </section>

        <div class="button-group">
          <button
            class="action-btn start-btn"
            :class="{ 'is-pressed': pressedButton === 'attendance-start' }"
            type="button"
            @pointerdown="pressButton('attendance-start')"
            @pointerup="releaseButton('attendance-start')"
            @pointercancel="releaseButton('attendance-start')"
            @pointerleave="releaseButton('attendance-start')"
            @click="startWork"
          >🟢 上班签到</button>
          <button
            class="action-btn end-btn"
            :class="{ 'is-pressed': pressedButton === 'attendance-end' }"
            type="button"
            @pointerdown="pressButton('attendance-end')"
            @pointerup="releaseButton('attendance-end')"
            @pointercancel="releaseButton('attendance-end')"
            @pointerleave="releaseButton('attendance-end')"
            @click="endWork"
          >🔴 下班签到</button>
          <button
            class="makeup-btn"
            :class="{ 'is-pressed': pressedButton === 'attendance-makeup' }"
            type="button"
            @pointerdown="pressButton('attendance-makeup')"
            @pointerup="releaseButton('attendance-makeup')"
            @pointercancel="releaseButton('attendance-makeup')"
            @pointerleave="releaseButton('attendance-makeup')"
            @click="openMakeUpPanel"
          >补签记录</button>
        </div>

        <section class="card history-card">
          <h2>历史记录</h2>

          <ul class="history-list">
            <li v-for="item in historyList" :key="item.date" class="history-item">
              <span>{{ formatShortDate(item.date) }} {{ formatWeekday(item.date) }}</span>
              <span>{{ item.startTime ? formatAttendanceTime(item.startTime) : '--:--' }}</span>
              <span>{{ item.endTime ? formatAttendanceTime(item.endTime) : '--:--' }}</span>
              <span>{{ formatWorkDuration(item) }}</span>
              <div class="record-actions">
                <button
                  class="mini-btn edit-btn"
                  :class="{ 'is-pressed': pressedButton === `edit-${item.date}` }"
                  type="button"
                  @pointerdown="pressButton(`edit-${item.date}`)"
                  @pointerup="releaseButton(`edit-${item.date}`)"
                  @pointercancel="releaseButton(`edit-${item.date}`)"
                  @pointerleave="releaseButton(`edit-${item.date}`)"
                  @click="openEditPanel(item)"
                >修改</button>
                <button
                  class="mini-btn delete-btn"
                  :class="{ 'is-pressed': pressedButton === `delete-${item.date}` }"
                  type="button"
                  @pointerdown="pressButton(`delete-${item.date}`)"
                  @pointerup="releaseButton(`delete-${item.date}`)"
                  @pointercancel="releaseButton(`delete-${item.date}`)"
                  @pointerleave="releaseButton(`delete-${item.date}`)"
                  @click="openDeleteConfirmation(item.id)"
                >删除</button>
              </div>
            </li>
          </ul>
        </section>
      </main>
    </div>

    <div v-else class="timer-page">
      <FunctionHeader title="计时工具" @back="goHome" @sign-out="signOut" />

      <main class="timer-page-panel">
        <div class="timer-display" aria-live="polite">
          <div class="timer-group">
            <div class="timer-digits">
              <span class="timer-unit timer-digit">{{ timerDisplayParts[0] }}</span>
              <span class="timer-unit timer-digit">{{ timerDisplayParts[1] }}</span>
            </div>
            <span class="timer-label">h</span>
          </div>

          <div class="timer-group">
            <div class="timer-digits">
              <span class="timer-unit timer-digit">{{ timerDisplayParts[2] }}</span>
              <span class="timer-unit timer-digit">{{ timerDisplayParts[3] }}</span>
            </div>
            <span class="timer-label">m</span>
          </div>

          <div class="timer-group">
            <div class="timer-digits">
              <span class="timer-unit timer-digit">{{ timerDisplayParts[4] }}</span>
              <span class="timer-unit timer-digit">{{ timerDisplayParts[5] }}</span>
            </div>
            <span class="timer-label">s</span>
          </div>

          <div class="timer-group timer-group-ms">
            <div class="timer-digits">
              <span class="timer-unit timer-ms-digit">{{ timerDisplayParts[6] }}</span>
              <span class="timer-unit timer-ms-digit">{{ timerDisplayParts[7] }}</span>
              <span class="timer-unit timer-ms-digit">{{ timerDisplayParts[8] }}</span>
            </div>
            <span class="timer-label">ms</span>
          </div>
        </div>

        <div class="timer-actions">
          <button
            class="timer-btn start full-width"
            :class="{ 'is-pressed': pressedButton === 'timer-start' }"
            type="button"
            @pointerdown="pressButton('timer-start')"
            @pointerup="releaseButton('timer-start')"
            @pointercancel="releaseButton('timer-start')"
            @pointerleave="releaseButton('timer-start')"
            @click="startTimer"
          >开始</button>
          <div class="timer-secondary-row">
            <button
              class="timer-btn pause"
              :class="{ 'is-pressed': pressedButton === 'timer-pause' }"
              type="button"
              @pointerdown="pressButton('timer-pause')"
              @pointerup="releaseButton('timer-pause')"
              @pointercancel="releaseButton('timer-pause')"
              @pointerleave="releaseButton('timer-pause')"
              @click="pauseTimer"
            >暂停</button>
            <button
              class="timer-btn reset"
              :class="{ 'is-pressed': pressedButton === 'timer-reset' }"
              type="button"
              @pointerdown="pressButton('timer-reset')"
              @pointerup="releaseButton('timer-reset')"
              @pointercancel="releaseButton('timer-reset')"
              @pointerleave="releaseButton('timer-reset')"
              @click="resetTimer"
            >重置</button>
          </div>
          <button
            class="timer-btn end full-width"
            :class="{ 'is-pressed': pressedButton === 'timer-end' }"
            type="button"
            @pointerdown="pressButton('timer-end')"
            @pointerup="releaseButton('timer-end')"
            @pointercancel="releaseButton('timer-end')"
            @pointerleave="releaseButton('timer-end')"
            @click="endTimer"
          >结束计时</button>
        </div>
      </main>

      <section class="timer-history-card">
        <div class="timer-history-heading">
          <h2>历史记录</h2>
          <div class="timer-history-actions">
            <button
              v-if="selectedTimerRecordIds.length"
              class="timer-history-delete-selected"
              type="button"
              @click="requestDeleteTimerRecords(selectedTimerRecordIds)"
            >删除已选（{{ selectedTimerRecordIds.length }}）</button>
            <span v-if="timerHistoryLoading">加载中…</span>
          </div>
        </div>
        <div v-if="!timerHistoryLoading && !timerHistory.length" class="timer-history-empty">暂无已保存的计时记录</div>
        <ul v-else class="timer-history-list">
          <li v-for="record in timerHistory" :key="record.id">
            <label class="timer-history-select" :aria-label="`选择 ${formatRecordDate(record.start_time)} 的计时记录`">
              <input v-model="selectedTimerRecordIds" type="checkbox" :value="record.id" />
              <span aria-hidden="true"></span>
            </label>
            <div>
              <strong>{{ formatRecordDate(record.start_time) }}</strong>
              <span>{{ formatRecordTime(record.start_time) }} → {{ formatRecordTime(record.end_time) }}</span>
            </div>
            <b>{{ formatStoredDuration(record) }}</b>
            <button class="timer-history-delete" type="button" @click="requestDeleteTimerRecords([record.id])">删除</button>
          </li>
        </ul>
      </section>
    </div>

    <GlassModal
      v-if="timerWarning.show"
      :message="timerWarning.message"
      :cancel-text="timerWarningAction === 'retry' ? '关闭' : ''"
      :confirm-text="timerWarningAction === 'retry' ? '重试' : '知道了'"
      @close="closeTimerWarning"
      @cancel="closeTimerWarning"
      @confirm="timerWarningAction === 'retry' ? retryTimerRecord() : closeTimerWarning()"
    />

    <GlassModal
      v-if="deleteConfirmation.show"
      message="确定删除这条签到记录吗？"
      cancel-text="取消"
      confirm-text="好"
      @close="closeDeleteConfirmation"
      @cancel="closeDeleteConfirmation"
      @confirm="confirmDeleteRecord"
    />

    <GlassModal
      v-if="timerDeleteConfirmation.show"
      :message="timerDeleteConfirmation.recordIds.length === 1 ? '确定删除这条计时记录吗？' : `确定删除选中的 ${timerDeleteConfirmation.recordIds.length} 条计时记录吗？`"
      cancel-text="取消"
      confirm-text="删除"
      @close="closeTimerDeleteConfirmation"
      @cancel="closeTimerDeleteConfirmation"
      @confirm="confirmDeleteTimerRecords"
    />

    <div v-if="isEditPanelOpen" class="edit-overlay" @click.self="closeEditPanel">
      <div class="edit-panel">
        <h3>修改签到记录</h3>

        <label class="field">
          <span>日期</span>
          <input v-model="editForm.recordDate" type="date" />
        </label>

        <label class="field">
          <span>上班时间</span>
          <div class="time-input-wrap">
            <input v-model="editForm.startTime" type="time" step="1" />
          </div>
        </label>

        <label class="field">
          <span>下班时间</span>
          <div class="time-input-wrap">
            <input v-model="editForm.endTime" type="time" step="1" />
          </div>
        </label>

        <div class="edit-actions">
          <button
            class="cancel-btn"
            :class="{ 'is-pressed': pressedButton === 'edit-cancel' }"
            type="button"
            @pointerdown="pressButton('edit-cancel')"
            @pointerup="releaseButton('edit-cancel')"
            @pointercancel="releaseButton('edit-cancel')"
            @pointerleave="releaseButton('edit-cancel')"
            @click="closeEditPanel"
          >取消</button>
          <button
            class="save-btn"
            :class="{ 'is-pressed': pressedButton === 'edit-save' }"
            type="button"
            @pointerdown="pressButton('edit-save')"
            @pointerup="releaseButton('edit-save')"
            @pointercancel="releaseButton('edit-save')"
            @pointerleave="releaseButton('edit-save')"
            @click="submitEditRecord"
          >保存</button>
        </div>
      </div>
    </div>

    <div v-if="isMakeUpPanelOpen" class="edit-overlay" @click.self="closeMakeUpPanel">
      <div class="edit-panel">
        <h3>补签记录</h3>

        <label class="field">
          <span>补签日期</span>
          <input v-model="makeUpForm.recordDate" type="date" :max="todayKey" />
        </label>

        <label class="field">
          <span>上班时间</span>
          <div class="time-input-wrap">
            <input v-model="makeUpForm.startTime" type="time" step="1" />
          </div>
        </label>

        <label class="field">
          <span>下班时间</span>
          <div class="time-input-wrap">
            <input v-model="makeUpForm.endTime" type="time" step="1" />
          </div>
        </label>

        <div class="edit-actions">
          <button class="cancel-btn" type="button" @click="closeMakeUpPanel">取消</button>
          <button class="save-btn" type="button" @click="submitMakeUpRecord">保存补签</button>
        </div>
      </div>
    </div>
      </div>
    </div>
  </div>
</template>
