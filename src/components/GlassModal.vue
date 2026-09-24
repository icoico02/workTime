<script setup>
import { ref } from 'vue'

defineProps({
  message: {
    type: String,
    required: true,
  },
  cancelText: {
    type: String,
    default: '',
  },
  confirmText: {
    type: String,
    default: '知道了',
  },
})

const emit = defineEmits(['close', 'cancel', 'confirm'])
const pressedButton = ref('')

function pressButton(buttonName) {
  pressedButton.value = buttonName
}

function releaseButton(buttonName) {
  if (pressedButton.value === buttonName) {
    pressedButton.value = ''
  }
}

function emitCancel() {
  emit('cancel')
}

function emitConfirm() {
  emit('confirm')
}
</script>

<template>
  <div class="timer-warning-overlay" @click.self="emit('close')">
    <div class="timer-warning-modal" role="dialog" aria-modal="true" @click.stop>
      <p>{{ message }}</p>

      <div v-if="cancelText" class="timer-warning-actions">
        <button
          class="timer-warning-btn timer-warning-cancel"
          :class="{ 'is-pressed': pressedButton === 'cancel' }"
          type="button"
          @pointerdown="pressButton('cancel')"
          @pointerup="releaseButton('cancel')"
          @pointercancel="releaseButton('cancel')"
          @pointerleave="releaseButton('cancel')"
          @click="emitCancel"
        >{{ cancelText }}</button>
        <button
          class="timer-warning-btn"
          :class="{ 'is-pressed': pressedButton === 'confirm' }"
          type="button"
          @pointerdown="pressButton('confirm')"
          @pointerup="releaseButton('confirm')"
          @pointercancel="releaseButton('confirm')"
          @pointerleave="releaseButton('confirm')"
          @click="emitConfirm"
        >{{ confirmText }}</button>
      </div>

      <button
        v-else
        class="timer-warning-btn"
        :class="{ 'is-pressed': pressedButton === 'confirm' }"
        type="button"
        @pointerdown="pressButton('confirm')"
        @pointerup="releaseButton('confirm')"
        @pointercancel="releaseButton('confirm')"
        @pointerleave="releaseButton('confirm')"
        @click="emit('close')"
      >{{ confirmText }}</button>
    </div>
  </div>
</template>
