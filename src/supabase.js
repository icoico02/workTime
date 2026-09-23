import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
export const AUTH_STORAGE_KEY = 'sb-worktime-auth-token'

class SwitchableStorage {
  mode = 'local'

  setMode(mode) {
    this.mode = mode === 'session' ? 'session' : 'local'
  }

  getMode() {
    return this.mode
  }

  getStorage() {
    return this.mode === 'session' ? sessionStorage : localStorage
  }

  getItem(key) {
    try {
      return this.getStorage().getItem(key)
    } catch {
      return null
    }
  }

  setItem(key, value) {
    try {
      this.getStorage().setItem(key, value)
    } catch {
      // Ignore storage errors (e.g. Safari private mode)
    }
  }

  removeItem(key) {
    try {
      this.getStorage().removeItem(key)
    } catch {
      // Ignore storage errors
    }
  }
}

export const authStorage = new SwitchableStorage()

export const supabase = supabaseUrl && supabaseKey
  ? createClient(supabaseUrl, supabaseKey, {
      auth: {
        storage: authStorage,
        storageKey: AUTH_STORAGE_KEY,
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false,
      },
    })
  : null

export const isSupabaseConfigured = Boolean(supabase)
