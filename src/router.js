import { createRouter, createWebHashHistory } from 'vue-router'
import InventoryView from './views/InventoryView.vue'
import AdminView from './views/AdminView.vue'

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/inventory/:section?', component: InventoryView },
    { path: '/dashboard', component: () => import('./views/DataDashboardView.vue') },
    { path: '/admin', component: AdminView },
    { path: '/super-admin', component: AdminView },
  ],
})

export default router
