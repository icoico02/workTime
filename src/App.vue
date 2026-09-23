<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { RouterView, useRoute, useRouter } from 'vue-router'
import GlassModal from './components/GlassModal.vue'

const STORAGE_KEY = 'attendanceRecords'

const currentDate = ref(formatDate(new Date()))
const currentTime = ref(formatTime(new Date()))
const todayKey = ref(formatDateKey(new Date()))
const attendanceRecords = ref(loadAttendanceRecords())

const todayRecord = computed(() => {
  return attendanceRecords.value.find((item) => item.date === todayKey.value) || null
})

const workDurationText = computed(() => {
  const record = todayRecord.value

  if (!record || !record.startTime || !record.endTime) {
    return '--:--'
  }

  const start = new Date(`${record.date}T${record.startTime}`)
  const end = new Date(`${record.date}T${record.endTime}`)

  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime()) || end < start) {
    return '--:--'
  }

  const totalMinutes = Math.round((end - start) / (1000 * 60))
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60

  return `${hours}小时${minutes}分钟`
})

const historyList = computed(() => {
  return [...attendanceRecords.value].sort((a, b) => new Date(b.date) - new Date(a.date))
})

function loadAttendanceRecords() {
  try {
    const savedRecords = localStorage.getItem(STORAGE_KEY)
    const parsedRecords = savedRecords ? JSON.parse(savedRecords) : []

    return Array.isArray(parsedRecords) ? parsedRecords : []
  } catch (error) {
    console.error('读取签到数据失败:', error)
    return []
  }
}

function saveAttendanceRecords() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(attendanceRecords.value))
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
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')
  const seconds = String(date.getSeconds()).padStart(2, '0')

  return `${hours}:${minutes}:${seconds}`
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

function getTodayRecord() {
  return attendanceRecords.value.find((item) => item.date === todayKey.value) || null
}

function createTodayRecord() {
  let record = getTodayRecord()

  if (!record) {
    record = {
      date: todayKey.value,
      startTime: '',
      endTime: '',
    }

    attendanceRecords.value.unshift(record)
    saveAttendanceRecords()
  }

  return record
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

function startWork() {
  const record = createTodayRecord()

  if (record.startTime) {
    alert('今天已经完成上班签到')
    return
  }

  record.startTime = currentTime.value
  saveAttendanceRecords()
}

function endWork() {
  const record = getTodayRecord()

  if (!record || !record.startTime) {
    alert('请先进行上班签到')
    return
  }

  if (record.endTime) {
    alert('今天已经完成下班签到')
    return
  }

  record.endTime = currentTime.value
  saveAttendanceRecords()
}

function formatWorkDuration(item) {
  if (!item.startTime || !item.endTime) {
    return '--:--'
  }

  const start = new Date(`${item.date}T${item.startTime}`)
  const end = new Date(`${item.date}T${item.endTime}`)

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

const deleteConfirmation = ref({ show: false, recordDate: '' })

function openDeleteConfirmation(recordDate) {
  deleteConfirmation.value = {
    show: true,
    recordDate,
  }
}

function closeDeleteConfirmation() {
  deleteConfirmation.value = {
    show: false,
    recordDate: '',
  }
}

function confirmDeleteRecord() {
  const recordDate = deleteConfirmation.value.recordDate
  attendanceRecords.value = attendanceRecords.value.filter((item) => item.date !== recordDate)
  saveAttendanceRecords()
  closeDeleteConfirmation()
}

const editForm = ref({
  recordDate: '',
  startTime: '',
  endTime: '',
})

const isEditPanelOpen = ref(false)
const currentScreen = ref('home')
const pressedButton = ref('')
const router = useRouter()
const route = useRoute()
const isInventoryRoute = computed(() => route.path.startsWith('/inventory'))

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

function showTimerWarning(message) {
  timerWarning.value = {
    show: true,
    message,
  }
}

function closeTimerWarning() {
  timerWarning.value = {
    show: false,
    message: '',
  }
}

function openAttendancePage() {
  currentScreen.value = 'attendance'
}

function openTimerPage() {
  currentScreen.value = 'timer'
}

function goHome() {
  currentScreen.value = 'home'
}

function openInventoryPage() {
  router.push('/inventory/dashboard')
}

function startTimer() {
  if (timerRunning.value) {
    return
  }

  timerStartedAt.value = Date.now() - timerElapsedMs.value
  timerRunning.value = true

  timerIntervalId.value = setInterval(() => {
    timerElapsedMs.value = Date.now() - timerStartedAt.value
  }, 10)
}

function pauseTimer() {
  if (!timerRunning.value) {
    return
  }

  timerRunning.value = false
  clearInterval(timerIntervalId.value)
  timerIntervalId.value = null
  timerElapsedMs.value = Date.now() - timerStartedAt.value
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

  timerRunning.value = false
  clearInterval(timerIntervalId.value)
  timerIntervalId.value = null
  timerElapsedMs.value = 0
  timerStartedAt.value = 0
}

function openEditPanel(record) {
  editForm.value = {
    recordDate: record.date,
    startTime: record.startTime || '08:00:00',
    endTime: record.endTime || '18:00:00',
  }
  isEditPanelOpen.value = true
}

function closeEditPanel() {
  isEditPanelOpen.value = false
}

function submitEditRecord() {
  if (!editForm.value.recordDate) {
    alert('请选择日期')
    return
  }

  const targetRecord = attendanceRecords.value.find((item) => item.date === editForm.value.recordDate)

  if (!targetRecord) {
    alert('未找到对应日期记录')
    return
  }

  targetRecord.startTime = editForm.value.startTime || ''
  targetRecord.endTime = editForm.value.endTime || ''
  saveAttendanceRecords()
  closeEditPanel()
}

onMounted(() => {
  updateClock()
  setInterval(updateClock, 1000)
})

onBeforeUnmount(() => {
  clearInterval(timerIntervalId.value)
})
</script>

<template>
  <RouterView v-if="isInventoryRoute" />

  <div v-else class="app-shell">
    <div v-if="currentScreen === 'home'" class="home-screen">
      <header class="header home-header">
        <h1>工作助手</h1>
      </header>

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
          <span class="home-icon">✅</span>
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
          <span class="home-icon">⏱</span>
          <span class="home-title">计时</span>
          <span class="home-subtitle">时间统计</span>
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
          <span class="home-icon">📦</span>
          <span class="home-title">进销存</span>
          <span class="home-subtitle">商品与库存</span>
        </button>
      </main>
    </div>

    <div v-else-if="currentScreen === 'attendance'" class="attendance-screen">
      <header class="header">
        <button
          class="nav-back-btn"
          :class="{ 'is-pressed': pressedButton === 'attendance-back' }"
          type="button"
          @pointerdown="pressButton('attendance-back')"
          @pointerup="releaseButton('attendance-back')"
          @pointercancel="releaseButton('attendance-back')"
          @pointerleave="releaseButton('attendance-back')"
          @click="goHome"
        >← 返回</button>
        <h1>上下班签到</h1>
      </header>

      <main class="screen">
        <div class="date-text">{{ currentDate }}</div>
        <div class="time-text">{{ currentTime }}</div>

        <section class="card">
          <h2>今日签到</h2>

          <div class="info-row">
            <span>上班时间</span>
            <strong>{{ todayRecord && todayRecord.startTime ? todayRecord.startTime : '--:--:--' }}</strong>
          </div>

          <div class="info-row">
            <span>下班时间</span>
            <strong>{{ todayRecord && todayRecord.endTime ? todayRecord.endTime : '--:--:--' }}</strong>
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
        </div>

        <section class="card history-card">
          <h2>历史记录</h2>

          <ul class="history-list">
            <li v-for="item in historyList" :key="item.date" class="history-item">
              <span>{{ formatShortDate(item.date) }} {{ formatWeekday(item.date) }}</span>
              <span>{{ item.startTime || '--:--' }}</span>
              <span>{{ item.endTime || '--:--' }}</span>
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
                  @click="openDeleteConfirmation(item.date)"
                >删除</button>
              </div>
            </li>
          </ul>
        </section>
      </main>
    </div>

    <div v-else class="timer-page">
      <header class="header">
        <button
          class="nav-back-btn"
          :class="{ 'is-pressed': pressedButton === 'timer-back' }"
          type="button"
          @pointerdown="pressButton('timer-back')"
          @pointerup="releaseButton('timer-back')"
          @pointercancel="releaseButton('timer-back')"
          @pointerleave="releaseButton('timer-back')"
          @click="goHome"
        >← 返回</button>
        <h1>计时工具</h1>
      </header>

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
        </div>
      </main>
    </div>

    <GlassModal
      v-if="timerWarning.show"
      :message="timerWarning.message"
      @close="closeTimerWarning"
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
  </div>
</template>
