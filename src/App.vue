<script setup>
import { computed, onMounted, ref } from 'vue'

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

const startTimePicker = ref(null)
const endTimePicker = ref(null)

const isEditPanelOpen = ref(false)

function openTimePicker(type) {
  const picker = type === 'start' ? startTimePicker.value : endTimePicker.value

  if (picker && typeof picker.showPicker === 'function') {
    picker.showPicker()
  }
}

function normalizeTimeString(value) {
  if (!value) {
    return '00:00:00'
  }

  const match = value.match(/^(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$/)

  if (!match) {
    return '00:00:00'
  }

  const hours = String(Math.min(Number(match[1] || 0), 23)).padStart(2, '0')
  const minutes = String(Math.min(Number(match[2] || 0), 59)).padStart(2, '0')
  const seconds = String(Math.min(Number(match[3] || 0), 59)).padStart(2, '0')

  return `${hours}:${minutes}:${seconds}`
}

function openEditPanel(record) {
  editForm.value = {
    recordDate: record.date,
    startTime: normalizeTimeString(record.startTime || '08:00:00'),
    endTime: normalizeTimeString(record.endTime || '18:00:00'),
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

  if (!isValidTimeString(editForm.value.startTime)) {
    alert('上班时间格式不正确，请使用 HH:mm:ss')
    return
  }

  if (!isValidTimeString(editForm.value.endTime)) {
    alert('下班时间格式不正确，请使用 HH:mm:ss')
    return
  }

  const targetRecord = attendanceRecords.value.find((item) => item.date === editForm.value.recordDate)

  if (!targetRecord) {
    alert('未找到对应日期记录')
    return
  }

  targetRecord.startTime = editForm.value.startTime
  targetRecord.endTime = editForm.value.endTime
  saveAttendanceRecords()
  closeEditPanel()
}

onMounted(() => {
  updateClock()
  setInterval(updateClock, 1000)
})
</script>

<template>
  <div class="app-shell">
    <header class="header">
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
            <input
              v-model="editForm.startTime"
              type="text"
              inputmode="numeric"
              maxlength="8"
              placeholder="HH:mm:ss"
              @blur="editForm.startTime = normalizeTimeString(editForm.startTime)"
            />
            <input
              ref="startTimePicker"
              v-model="editForm.startTime"
              type="time"
              step="1"
              class="native-time-input"
              @change="editForm.startTime = normalizeTimeString(editForm.startTime)"
            />
          </div>
        </label>

        <label class="field">
          <span>下班时间</span>
          <div class="time-input-wrap">
            <input
              v-model="editForm.endTime"
              type="text"
              inputmode="numeric"
              maxlength="8"
              placeholder="HH:mm:ss"
              @blur="editForm.endTime = normalizeTimeString(editForm.endTime)"
            />
            <input
              ref="endTimePicker"
              v-model="editForm.endTime"
              type="time"
              step="1"
              class="native-time-input"
              @change="editForm.endTime = normalizeTimeString(editForm.endTime)"
            />
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
