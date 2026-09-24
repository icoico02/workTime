import assert from 'node:assert/strict'
import { amountInChinese, moneyText, paginateItems, toPrintOrder, visibleColumns, defaultPrintSettings, sessionDefaults } from '../src/inventoryPrint.js'

assert.equal(moneyText(1), '1.00')
assert.equal(moneyText('12.345'), '12.35')
assert.equal(moneyText(null), '0.00')
assert.equal(amountInChinese(0), '零元整')
assert.equal(amountInChinese(10), '壹拾元整')
assert.equal(amountInChinese(1001), '壹仟零壹元整')
assert.equal(amountInChinese(1010.06), '壹仟零壹拾元零陆分')
assert.equal(amountInChinese(0.5), '零元伍角整')
assert.equal(amountInChinese(1234.56), '壹仟贰佰叁拾肆元伍角陆分')

const printed = toPrintOrder({
  order_no: 'SO-1', customer_name: '张三', subtotal: 10, discount: 1, freight: 2, total_amount: 11,
  total_cost: 4, total_profit: 7, unit_cost: 4, note: '内部备注', customer_note: '客户备注',
  inventory_order_items: [{ product_name: '刹车片', sku: 'A1', quantity: 2, unit_price: 5, line_total: 10, unit_cost: 3, line_profit: 4, actual_cost: 6 }],
})
assert.equal(printed.note, '客户备注')
assert.equal(JSON.stringify(printed).includes('unit_cost'), false)
assert.equal(JSON.stringify(printed).includes('total_cost'), false)
assert.equal(JSON.stringify(printed).includes('profit'), false)
assert.equal(printed.items[0].unit, '件')
assert.equal(printed.items[0].amount, 10)

assert.deepEqual(paginateItems([1, 2, 3, 4, 5], 2).map((page) => page.length), [2, 2, 1])
const settings = defaultPrintSettings()
assert.equal(visibleColumns(settings, 'compact', sessionDefaults(settings, 'compact')).some(([key]) => key === 'oe'), false)
assert.equal(visibleColumns(settings, 'standard', { showPrices: false, showOe: true, showFitment: false }).some(([key]) => key === 'unit_price'), false)
console.log('PASS print amounts, pagination, cost stripping and column visibility')
