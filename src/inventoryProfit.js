export const defaultProfitSettings = () => ({ minimum_unit_profit: 10, minimum_margin: 15, amount_warning_enabled: true, margin_warning_enabled: true })

export function evaluateProfit(revenue, cost, quantity, settings) {
  if ([revenue, cost, quantity].some((value) => value == null || !Number.isFinite(Number(value))) || Number(quantity) <= 0) return null
  const profit = Number(revenue) - Number(cost)
  const unitProfit = profit / Number(quantity)
  const margin = Number(revenue) > 0 ? profit / Number(revenue) * 100 : null
  const lowAmount = settings.amount_warning_enabled && unitProfit < Number(settings.minimum_unit_profit)
  const lowMargin = settings.margin_warning_enabled && (margin == null ? profit < 0 : margin < Number(settings.minimum_margin))
  return { profit, unitProfit, margin, low: Boolean(lowAmount || lowMargin) }
}
