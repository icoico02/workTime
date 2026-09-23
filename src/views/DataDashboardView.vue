<script setup>
import { Chart, registerables } from 'chart.js'
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import FunctionHeader from '../components/FunctionHeader.vue'
import { supabase } from '../supabase'

Chart.register(...registerables)

const router = useRouter()
const attendanceRecords = ref([])
const timerRecords = ref([])
const approvalLogs = ref([])
const loading = ref(true)
const hasLoaded = ref(false)
const loadError = ref('')
const attendanceRange = ref(7)
const timerRange = ref(7)
const attendanceType = ref('clock-lines')
const attendanceReference = ref(false)
const timerType = ref('bar')
const timerMetric = ref('total')
const approvalRange = ref(7)
const approvalType = ref('bar')
const attendanceCanvas = ref(null)
const timerCanvas = ref(null)
const approvalCanvas = ref(null)
const attendanceChart = ref(null)
const timerChart = ref(null)
const approvalChart = ref(null)
const currentUserId = ref('')
const isSuperAdmin = ref(false)
let realtimeChannel = null

const chartTypes = [
  { value: 'line', label: '折线图' },
  { value: 'bar', label: '柱状图' },
  { value: 'doughnut', label: '饼图' },
]

const attendanceTypes = [
  { value: 'clock-lines', label: '双折线图' },
  { value: 'interval', label: '区间图' },
  { value: 'scatter', label: '散点图' },
  { value: 'duration', label: '工作时长柱状图' },
]

const rangeOptions = [7, 30, 90]
const timerMetrics = [
  { value: 'count', label: '次数' },
  { value: 'single', label: '单次耗时' },
  { value: 'total', label: '总时长' },
]

function localDateKey(value) {
  const date = new Date(value)
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function rangeDays(days) {
  return Array.from({ length: days }, (_, index) => {
    const date = new Date()
    date.setHours(0, 0, 0, 0)
    date.setDate(date.getDate() - (days - index - 1))
    return localDateKey(date)
  })
}

function rangeLabel(dateKey) {
  const [, month, day] = dateKey.split('-')
  return `${Number(month)}/${Number(day)}`
}

function chartSettingKey(module) {
  return currentUserId.value ? `dashboard-chart-type:${currentUserId.value}:${module}` : ''
}

function restoreChartSettings() {
  const attendanceSaved = localStorage.getItem(chartSettingKey('attendance'))
  const timerSaved = localStorage.getItem(chartSettingKey('timer'))
  const approvalSaved = localStorage.getItem(chartSettingKey('approval'))
  const timerMetricSaved = localStorage.getItem(chartSettingKey('timer-metric'))
  const attendanceReferenceSaved = localStorage.getItem(chartSettingKey('attendance-reference'))
  if (attendanceTypes.some((item) => item.value === attendanceSaved)) attendanceType.value = attendanceSaved
  if (chartTypes.some((item) => item.value === timerSaved)) timerType.value = timerSaved
  if (chartTypes.some((item) => item.value === approvalSaved)) approvalType.value = approvalSaved
  if (timerMetrics.some((item) => item.value === timerMetricSaved)) timerMetric.value = timerMetricSaved
  attendanceReference.value = attendanceReferenceSaved === 'true'
}

function persistChartSettings() {
  const attendanceKey = chartSettingKey('attendance')
  const timerKey = chartSettingKey('timer')
  if (attendanceKey) localStorage.setItem(attendanceKey, attendanceType.value)
  if (timerKey) localStorage.setItem(timerKey, timerType.value)
  const approvalKey = chartSettingKey('approval')
  if (approvalKey) localStorage.setItem(approvalKey, approvalType.value)
  const timerMetricKey = chartSettingKey('timer-metric')
  if (timerMetricKey) localStorage.setItem(timerMetricKey, timerMetric.value)
  const attendanceReferenceKey = chartSettingKey('attendance-reference')
  if (attendanceReferenceKey) localStorage.setItem(attendanceReferenceKey, String(attendanceReference.value))
}

function timerMilliseconds(record) {
  if (record.total_milliseconds != null) return Number(record.total_milliseconds) || 0
  return (Number(record.total_seconds) || 0) * 1000
}

function timerRecordsInRange(days) {
  const dates = new Set(rangeDays(days))
  return timerRecords.value
    .filter((record) => dates.has(localDateKey(record.start_time)))
    .sort((a, b) => new Date(a.start_time) - new Date(b.start_time))
}

function formatDuration(milliseconds) {
  const totalSeconds = Math.floor(Math.max(0, milliseconds) / 1000)
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  if (hours) return `${hours}小时${minutes}分`
  if (minutes) return `${minutes}分${seconds}秒`
  return `${seconds}秒`
}

function recordTimeLabel(value) {
  const date = new Date(value)
  return `${date.getMonth() + 1}/${date.getDate()} ${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

function timeToMinutes(value) {
  if (!value) return null
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return date.getHours() * 60 + date.getMinutes() + date.getSeconds() / 60
}

function formatClockTime(minutes) {
  if (!Number.isFinite(Number(minutes))) return ''
  const normalized = Math.max(0, Math.round(Number(minutes)))
  return `${String(Math.floor(normalized / 60)).padStart(2, '0')}:${String(normalized % 60).padStart(2, '0')}`
}

function formatMinutesDuration(minutes) {
  const totalMinutes = Math.max(0, Math.round(Number(minutes) || 0))
  const hours = Math.floor(totalMinutes / 60)
  const remainder = totalMinutes % 60
  return hours ? `${hours}小时${remainder}分` : `${remainder}分`
}

function timerValueColors(values) {
  const numericValues = values.map((value) => Math.max(0, Number(value) || 0))
  const maximum = Math.max(...numericValues, 0)
  const light = [226, 221, 246]
  const dark = [112, 93, 171]

  return numericValues.map((value) => {
    if (!value || !maximum) return 'rgba(203, 210, 223, 0.3)'
    const ratio = Math.sqrt(value / maximum)
    const color = light.map((channel, index) => Math.round(channel + (dark[index] - channel) * ratio))
    const alpha = 0.4 + ratio * 0.38
    return `rgba(${color.join(', ')}, ${alpha})`
  })
}

const timerSummary = computed(() => {
  const records = timerRecordsInRange(timerRange.value)
  const totalMilliseconds = records.reduce((sum, record) => sum + timerMilliseconds(record), 0)
  return {
    count: records.length,
    total: formatDuration(totalMilliseconds),
    average: formatDuration(records.length ? totalMilliseconds / records.length : 0),
  }
})

function attendanceChartConfig(days, type) {
  const labels = rangeDays(days)
  const byDate = new Map()
  attendanceRecords.value.forEach((record) => {
    if (!labels.includes(record.work_date)) return
    const current = byDate.get(record.work_date)
    if (!current || new Date(record.check_in_time || record.check_out_time || 0) > new Date(current.check_in_time || current.check_out_time || 0)) {
      byDate.set(record.work_date, record)
    }
  })

  const records = labels.map((date) => byDate.get(date))
  const checkIn = records.map((record) => timeToMinutes(record?.check_in_time))
  const checkOut = records.map((record) => timeToMinutes(record?.check_out_time))

  if (type === 'interval') {
    return {
      type: 'bar',
      data: {
        labels: labels.map(rangeLabel),
        datasets: [{
          label: '工作区间',
          data: records.map((record) => {
            const start = timeToMinutes(record?.check_in_time)
            const end = timeToMinutes(record?.check_out_time)
            return start == null || end == null ? null : [start, end]
          }),
          backgroundColor: 'rgba(147, 197, 253, 0.62)',
          borderColor: '#76a9e6',
          borderWidth: 1,
          borderRadius: 8,
          intervalUnit: true,
        }],
      },
    }
  }

  if (type === 'scatter') {
    return {
      type: 'scatter',
      data: {
        labels: labels.map(rangeLabel),
        datasets: [
          { label: '上班打卡', data: checkIn.map((value, index) => value == null ? null : { x: rangeLabel(labels[index]), y: value }).filter(Boolean), backgroundColor: '#5b8bd1', pointRadius: 5, pointHoverRadius: 6, clockUnit: true },
          { label: '下班打卡', data: checkOut.map((value, index) => value == null ? null : { x: rangeLabel(labels[index]), y: value }).filter(Boolean), backgroundColor: '#66a987', pointRadius: 5, pointHoverRadius: 6, clockUnit: true },
        ],
      },
    }
  }

  if (type === 'duration') {
    return {
      type: 'bar',
      data: {
        labels: labels.map(rangeLabel),
        datasets: [{
          label: '工作时长',
          data: records.map((record) => {
            const start = timeToMinutes(record?.check_in_time)
            const end = timeToMinutes(record?.check_out_time)
            return start == null || end == null ? null : Math.max(0, end - start)
          }),
          borderColor: '#a78bda',
          backgroundColor: 'rgba(196, 181, 253, 0.62)',
          borderRadius: 8,
          durationMinutesUnit: true,
        }],
      },
    }
  }

  const datasets = [
    { label: '上班打卡', data: checkIn, borderColor: '#5b8bd1', backgroundColor: 'rgba(147, 197, 253, 0.2)', pointBackgroundColor: '#5b8bd1', pointRadius: 3, tension: 0.3, clockUnit: true },
    { label: '下班打卡', data: checkOut, borderColor: '#66a987', backgroundColor: 'rgba(167, 243, 208, 0.2)', pointBackgroundColor: '#66a987', pointRadius: 3, tension: 0.3, clockUnit: true },
  ]
  if (attendanceReference.value) {
    datasets.push(
      { label: '上班基准 09:00', data: labels.map(() => 9 * 60), borderColor: 'rgba(91, 139, 209, 0.48)', borderDash: [5, 5], pointRadius: 0, tension: 0, clockUnit: true, referenceLine: true },
      { label: '下班基准 18:00', data: labels.map(() => 18 * 60), borderColor: 'rgba(102, 169, 135, 0.48)', borderDash: [5, 5], pointRadius: 0, tension: 0, clockUnit: true, referenceLine: true },
    )
  }

  return {
    type: 'line',
    data: { labels: labels.map(rangeLabel), datasets },
  }
}

function timerData(days, type, metric) {
  const labels = rangeDays(days)
  const countsByDate = new Map(labels.map((date) => [date, 0]))
  const durationByDate = new Map(labels.map((date) => [date, 0]))
  const records = timerRecordsInRange(days)

  records.forEach((record) => {
    const date = localDateKey(record.start_time)
    if (!durationByDate.has(date)) return
    countsByDate.set(date, countsByDate.get(date) + 1)
    durationByDate.set(date, durationByDate.get(date) + timerMilliseconds(record))
  })

  const isCount = metric === 'count'
  const isSingle = metric === 'single'
  const values = isSingle
    ? records.map((record) => timerMilliseconds(record))
    : labels.map((date) => isCount ? countsByDate.get(date) : durationByDate.get(date))
  const chartLabels = isSingle ? records.map((record) => recordTimeLabel(record.start_time)) : labels.map(rangeLabel)
  const label = isCount ? '计时次数' : isSingle ? '单次耗时（毫秒）' : '总时长（毫秒）'
  const colors = timerValueColors(values)

  if (type === 'doughnut') {
    const entries = chartLabels.map((chartLabel, index) => ({ label: chartLabel, value: values[index], color: colors[index] })).filter((entry) => entry.value > 0)
    return {
      labels: entries.length ? entries.map((entry) => entry.label) : ['暂无数据'],
      datasets: [{ label, data: entries.length ? entries.map((entry) => entry.value) : [1], backgroundColor: entries.length ? entries.map((entry) => entry.color) : ['rgba(203, 210, 223, 0.3)'], borderColor: '#ffffff', borderWidth: 3, durationUnit: !isCount }],
    }
  }

  return {
    labels: chartLabels,
    datasets: [{
      label,
      data: values,
      borderColor: '#7c6bb1',
      backgroundColor: type === 'bar' ? colors : 'rgba(196, 181, 253, 0.3)',
      pointBackgroundColor: colors,
      pointBorderColor: colors,
      pointHoverBackgroundColor: colors,
      pointRadius: type === 'line' ? 4 : 0,
      pointHoverRadius: type === 'line' ? 5 : 0,
      fill: type === 'line',
      tension: 0.35,
      borderRadius: 8,
      durationUnit: !isCount,
    }],
  }
}

function approvalData(days, type) {
  const labels = rangeDays(days)
  const byDate = new Map(labels.map((date) => [date, 0]))
  const byAction = new Map()

  approvalLogs.value.forEach((log) => {
    const date = localDateKey(log.created_at)
    if (byDate.has(date)) byDate.set(date, byDate.get(date) + 1)
    const action = log.action_type || log.operation_type || '审批操作'
    byAction.set(action, (byAction.get(action) || 0) + 1)
  })

  if (type === 'doughnut') {
    const entries = [...byAction.entries()]
    return {
      labels: entries.length ? entries.map(([action]) => action) : ['暂无数据'],
      datasets: [{ data: entries.length ? entries.map(([, count]) => count) : [1], backgroundColor: entries.length ? ['#f9a8d4', '#c4b5fd', '#fdba74', '#99f6e4', '#bae6fd'] : ['#e5e7eb'], borderColor: '#ffffff', borderWidth: 3 }],
    }
  }

  return {
    labels: labels.map(rangeLabel),
    datasets: [{ label: '审批操作数', data: labels.map((date) => byDate.get(date)), borderColor: '#b76f92', backgroundColor: 'rgba(249, 168, 212, 0.46)', fill: type === 'line', tension: 0.35, borderRadius: 8 }],
  }
}

function renderChart(canvas, chartRef, type, data) {
  if (!canvas) return
  chartRef.value?.destroy()
  chartRef.value = new Chart(canvas, {
    type,
    data,
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: type === 'doughnut', position: 'bottom', labels: { boxWidth: 10, color: '#68758a', font: { size: 11 } } },
        tooltip: {
          backgroundColor: 'rgba(42, 55, 77, 0.88)',
          padding: 10,
          cornerRadius: 8,
          callbacks: {
            label(context) {
              if (context.dataset.intervalUnit && Array.isArray(context.raw)) {
                return `${context.dataset.label}：${formatClockTime(context.raw[0])} - ${formatClockTime(context.raw[1])}`
              }
              const value = context.parsed.y ?? context.parsed
              if (context.dataset.clockUnit) return `${context.dataset.label}：${formatClockTime(value)}`
              if (context.dataset.durationMinutesUnit) return `${context.dataset.label}：${formatMinutesDuration(value)}`
              return context.dataset.durationUnit ? `${context.dataset.label}：${formatDuration(value)}` : `${context.dataset.label}：${value}`
            },
          },
        },
      },
      scales: type === 'doughnut' ? {} : {
        x: { grid: { display: false }, ticks: { color: '#8490a3', font: { size: 10 } } },
        y: {
          beginAtZero: true,
          grid: { color: 'rgba(148, 163, 184, 0.13)' },
          ticks: {
            color: '#8490a3',
            font: { size: 10 },
            callback(value) {
              const dataset = data.datasets.find((item) => item.clockUnit || item.intervalUnit || item.durationMinutesUnit || item.durationUnit)
              if (dataset?.clockUnit || dataset?.intervalUnit) return formatClockTime(value)
              if (dataset?.durationMinutesUnit) return formatMinutesDuration(value)
              return dataset?.durationUnit ? formatDuration(Number(value)) : value
            },
          },
        },
      },
    },
  })
}

function resizeOnNextFrame(chartRef) {
  requestAnimationFrame(() => chartRef.value?.resize())
}

async function renderAttendanceChart() {
  await nextTick()
  const config = attendanceChartConfig(attendanceRange.value, attendanceType.value)
  renderChart(attendanceCanvas.value, attendanceChart, config.type, config.data)
  resizeOnNextFrame(attendanceChart)
}

async function renderTimerChart() {
  await nextTick()
  renderChart(timerCanvas.value, timerChart, timerType.value, timerData(timerRange.value, timerType.value, timerMetric.value))
  resizeOnNextFrame(timerChart)
}

async function renderApprovalChart() {
  if (!isSuperAdmin.value) return
  await nextTick()
  renderChart(approvalCanvas.value, approvalChart, approvalType.value, approvalData(approvalRange.value, approvalType.value))
  resizeOnNextFrame(approvalChart)
}

async function loadDashboardData() {
  if (!supabase || !currentUserId.value) return
  loading.value = true
  loadError.value = ''
  const requests = [
    supabase.from('attendance_records').select('work_date, check_in_time, check_out_time').eq('user_id', currentUserId.value),
    supabase.from('timer_records').select('start_time, total_milliseconds, total_seconds').eq('user_id', currentUserId.value),
  ]
  if (isSuperAdmin.value) requests.push(supabase.from('user_approval_logs').select('*'))
  const [attendanceResult, timerResult, approvalResult] = await Promise.all(requests)

  if (attendanceResult.error || timerResult.error || approvalResult?.error) {
    console.error('加载数据看板失败:', attendanceResult.error || timerResult.error || approvalResult?.error)
    loadError.value = '统计数据加载失败，请稍后重试。'
    loading.value = false
    return
  }

  attendanceRecords.value = attendanceResult.data || []
  timerRecords.value = timerResult.data || []
  approvalLogs.value = approvalResult?.data || []
  hasLoaded.value = true
  loading.value = false
  await renderAttendanceChart()
  await renderTimerChart()
  await renderApprovalChart()
}

async function refreshAttendanceData() {
  if (!supabase || !currentUserId.value) return
  const { data, error } = await supabase
    .from('attendance_records')
    .select('work_date, check_in_time, check_out_time')
    .eq('user_id', currentUserId.value)

  if (error) {
    console.error('刷新签到统计失败:', error)
    return
  }

  attendanceRecords.value = data || []
  await renderAttendanceChart()
}

async function refreshTimerData() {
  if (!supabase || !currentUserId.value) return
  const { data, error } = await supabase
    .from('timer_records')
    .select('start_time, total_milliseconds, total_seconds')
    .eq('user_id', currentUserId.value)

  if (error) {
    console.error('刷新计时统计失败:', error)
    return
  }

  timerRecords.value = data || []
  await renderTimerChart()
}

async function refreshApprovalData() {
  if (!supabase || !currentUserId.value || !isSuperAdmin.value) return
  const { data, error } = await supabase.from('user_approval_logs').select('*')

  if (error) {
    console.error('刷新审批统计失败:', error)
    return
  }

  approvalLogs.value = data || []
  await renderApprovalChart()
}

function subscribeToChanges() {
  if (!supabase || !currentUserId.value) return
  realtimeChannel = supabase
    .channel(`dashboard:${currentUserId.value}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'attendance_records', filter: `user_id=eq.${currentUserId.value}` }, refreshAttendanceData)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'timer_records', filter: `user_id=eq.${currentUserId.value}` }, refreshTimerData)
  if (isSuperAdmin.value) realtimeChannel.on('postgres_changes', { event: '*', schema: 'public', table: 'user_approval_logs' }, refreshApprovalData)
  realtimeChannel
    .subscribe()
}

async function signOut() {
  await supabase?.auth.signOut()
  await router.push('/')
}

watch([attendanceRange, attendanceType, attendanceReference], async () => {
  if (!hasLoaded.value) return
  persistChartSettings()
  await renderAttendanceChart()
})

watch([timerRange, timerType, timerMetric], async () => {
  if (!hasLoaded.value) return
  persistChartSettings()
  await renderTimerChart()
})

watch([approvalRange, approvalType], async () => {
  if (!hasLoaded.value) return
  persistChartSettings()
  await renderApprovalChart()
})

onMounted(async () => {
  if (!supabase) {
    loadError.value = '数据服务尚未配置。'
    loading.value = false
    return
  }

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    await router.push('/')
    return
  }

  currentUserId.value = user.id
  const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).maybeSingle()
  isSuperAdmin.value = profile?.role === 'super_admin'
  restoreChartSettings()
  await loadDashboardData()
  subscribeToChanges()
})

onBeforeUnmount(() => {
  attendanceChart.value?.destroy()
  timerChart.value?.destroy()
  approvalChart.value?.destroy()
  if (realtimeChannel) supabase?.removeChannel(realtimeChannel)
})
</script>

<template>
  <div class="app-shell dashboard-shell">
    <FunctionHeader title="数据看板" @back="router.push('/')" @sign-out="signOut" />

    <main class="dashboard-content">
      <p class="dashboard-intro">签到与计时数据会在新增、删除后自动更新。</p>
      <div v-if="loadError" class="dashboard-empty">{{ loadError }}</div>
      <div v-else-if="loading && !hasLoaded" class="dashboard-empty">正在加载统计数据…</div>
      <div v-else class="dashboard-grid" :class="{ loading }">
        <section class="dashboard-card">
          <div class="dashboard-card-heading">
            <div><p>ATTENDANCE</p><h2>签到趋势</h2></div>
            <div class="dashboard-card-controls">
              <select v-model="attendanceType" aria-label="签到趋势图表类型">
                <option v-for="item in attendanceTypes" :key="item.value" :value="item.value">{{ item.label }}</option>
              </select>
              <button class="dashboard-reference-toggle" :class="{ active: attendanceReference }" type="button" :aria-pressed="attendanceReference" @click="attendanceReference = !attendanceReference">基准线</button>
            </div>
          </div>
          <div class="dashboard-range" aria-label="签到趋势时间范围">
            <button v-for="days in rangeOptions" :key="days" :class="{ active: attendanceRange === days }" type="button" @click="attendanceRange = days">近 {{ days }} 天</button>
          </div>
          <div class="dashboard-chart"><canvas ref="attendanceCanvas"></canvas></div>
        </section>

        <section class="dashboard-card">
          <div class="dashboard-card-heading">
            <div><p>TIMER</p><h2>计时统计</h2></div>
            <div class="dashboard-card-controls">
              <select v-model="timerMetric" aria-label="计时统计维度">
                <option v-for="item in timerMetrics" :key="item.value" :value="item.value">{{ item.label }}</option>
              </select>
              <select v-model="timerType" aria-label="计时统计图表类型">
                <option v-for="item in chartTypes" :key="item.value" :value="item.value">{{ item.label }}</option>
              </select>
            </div>
          </div>
          <div class="timer-summary" aria-label="计时汇总">
            <div><span>计时次数</span><strong>{{ timerSummary.count }}</strong></div>
            <div><span>总时长</span><strong>{{ timerSummary.total }}</strong></div>
            <div><span>平均单次耗时</span><strong>{{ timerSummary.average }}</strong></div>
          </div>
          <div class="dashboard-range" aria-label="计时统计时间范围">
            <button v-for="days in rangeOptions" :key="days" :class="{ active: timerRange === days }" type="button" @click="timerRange = days">近 {{ days }} 天</button>
          </div>
          <div class="dashboard-chart"><canvas ref="timerCanvas"></canvas></div>
        </section>

        <section v-if="isSuperAdmin" class="dashboard-card">
          <div class="dashboard-card-heading">
            <div><p>APPROVAL</p><h2>审批操作</h2></div>
            <select v-model="approvalType" aria-label="审批操作图表类型">
              <option v-for="item in chartTypes" :key="item.value" :value="item.value">{{ item.label }}</option>
            </select>
          </div>
          <div class="dashboard-range" aria-label="审批操作时间范围">
            <button v-for="days in rangeOptions" :key="days" :class="{ active: approvalRange === days }" type="button" @click="approvalRange = days">近 {{ days }} 天</button>
          </div>
          <div class="dashboard-chart"><canvas ref="approvalCanvas"></canvas></div>
        </section>
      </div>
    </main>
  </div>
</template>
