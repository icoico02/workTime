<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'

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

function deleteRecord(recordDate) {
  const confirmed = window.confirm('确定删除这条签到记录吗？')

  if (!confirmed) {
    return
  }

  attendanceRecords.value = attendanceRecords.value.filter((item) => item.date !== recordDate)
  saveAttendanceRecords()
}

const editForm = ref({
  recordDate: '',
  startTime: '',
  endTime: '',
})

const isEditPanelOpen = ref(false)
const currentScreen = ref('home')

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
    return ['00', '00', '00', '000']
  }

  return [match[1], match[2], match[3], match[4]]
})

function openAttendancePage() {
  currentScreen.value = 'attendance'
}

function openTimerPage() {
  currentScreen.value = 'timer'
}

function goHome() {
  currentScreen.value = 'home'
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
    alert('计时中，请先暂停，再重置')
    return
  }

  if (timerElapsedMs.value === 0) {
    alert('当前计时器已是初始状态，无需重置')
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
  <div class="app-shell">
    <div v-if="currentScreen === 'home'" class="home-screen">
      <header class="header home-header">
        <h1>工作助手</h1>
      </header>

      <main class="home-grid">
        <button class="home-card attendance-card" type="button" @click="openAttendancePage">
          <span class="home-icon">✅</span>
          <span class="home-title">签到</span>
          <span class="home-subtitle">上下班打卡</span>
        </button>

        <button class="home-card timer-card" type="button" @click="openTimerPage">
          <span class="home-icon">⏱</span>
          <span class="home-title">计时</span>
          <span class="home-subtitle">时间统计</span>
        </button>
      </main>
    </div>

    <div v-else-if="currentScreen === 'attendance'" class="attendance-screen">
      <header class="header">
        <button class="nav-back-btn" type="button" @click="goHome">← 返回</button>
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
          <button class="action-btn start-btn" type="button" @click="startWork">🟢 上班签到</button>
          <button class="action-btn end-btn" type="button" @click="endWork">🔴 下班签到</button>
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
                <button class="mini-btn edit-btn" type="button" @click="openEditPanel(item)">修改</button>
                <button class="mini-btn delete-btn" type="button" @click="deleteRecord(item.date)">删除</button>
              </div>
            </li>
          </ul>
        </section>
      </main>
    </div>

    <div v-else class="timer-page">
      <header class="header">
        <button class="nav-back-btn" type="button" @click="goHome">← 返回</button>
        <h1>计时工具</h1>
      </header>

      <main class="timer-page-panel">
        <div class="timer-display" aria-live="polite">
          <span class="timer-unit timer-hour">{{ timerDisplayParts[0] }}</span>
          <span class="timer-label">h</span>
          <span class="timer-unit">{{ timerDisplayParts[1] }}</span>
          <span class="timer-label">m</span>
          <span class="timer-unit">{{ timerDisplayParts[2] }}</span>
          <span class="timer-label">s</span>
          <span class="timer-unit timer-ms">{{ timerDisplayParts[3] }}</span>
          <span class="timer-label">ms</span>
        </div>

        <div class="timer-actions">
          <button class="timer-btn start" type="button" @click="startTimer">开始</button>
          <button class="timer-btn pause" type="button" @click="pauseTimer">暂停</button>
          <button class="timer-btn reset" type="button" @click="resetTimer">重置</button>
        </div>
      </main>
    </div>

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
          <button class="cancel-btn" type="button" @click="closeEditPanel">取消</button>
          <button class="save-btn" type="button" @click="submitEditRecord">保存</button>
        </div>
      </div>
    </div>
  </div>
</template>
