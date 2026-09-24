import assert from 'node:assert/strict'
import { evaluateProfit, defaultProfitSettings } from '../src/inventoryProfit.js'

const settings = defaultProfitSettings()
assert.equal(evaluateProfit(100, 90, 1, settings).low, true)
assert.equal(evaluateProfit(100, 85, 1, settings).low, false)
assert.equal(evaluateProfit(20, 11, 1, settings).low, true)
assert.equal(evaluateProfit(100, 85, 2, settings).low, true)
assert.equal(evaluateProfit(100, 90, 1, { ...settings, margin_warning_enabled: false }).low, false)
assert.equal(evaluateProfit(20, 11, 1, { ...settings, amount_warning_enabled: false }).low, false)
assert.equal(evaluateProfit(1, 20, 1, { ...settings, amount_warning_enabled: false, margin_warning_enabled: false }).low, false)
assert.equal(evaluateProfit(0, 20, 1, settings).low, true)
assert.equal(evaluateProfit(0, 20, 1, settings).margin, null)
assert.equal(evaluateProfit(100, undefined, 1, settings), null)
assert.equal(evaluateProfit(100, 20, 0, settings), null)
console.log('PASS profit thresholds, per-unit calculation, toggles, missing cost, zero sales')
