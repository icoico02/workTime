import { createRouter, createWebHashHistory } from 'vue-router'
import InventoryView from './views/InventoryView.vue'

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/inventory/:section?', component: InventoryView },
  ],
})

export default router
