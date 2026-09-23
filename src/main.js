import { createApp } from 'vue'
import './style.css'
import App from './App.vue'
import router from './router'

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register(new URL('./sw.js', window.location.href)).catch((error) => {
      console.error('Service worker registration failed:', error)
    })
  })
}

createApp(App).use(router).mount('#app')
