# 📈 H4 EMA Pullback — Next Level Expert Advisor

> An MQL5 Expert Advisor for MetaTrader 5 that trades pullbacks to the EMA50 zone in the direction of the EMA50/200 trend, targeting the nearest fractal swing level as take-profit with full ATR-based risk sizing and multiple optional false-break filters.

![MQL5](https://img.shields.io/badge/MQL5-MetaTrader%205-1B3A5C?style=flat-square)
![Timeframe](https://img.shields.io/badge/Timeframe-H4-0A66C2?style=flat-square)
![Status](https://img.shields.io/badge/Status-Active%20Development-orange?style=flat-square)

---

## Strategy Overview

The EA implements a **trend-following pullback strategy** on the H4 chart. The core idea: in an established trend (EMA50 above/below EMA200), the market frequently pulls back to the EMA50 zone before resuming. The EA waits for that pullback, then enters when a candle confirms the rejection — touching the zone, closing in the trend direction, and reclaiming the EMA21.

**Entry logic (long example):**
1. EMA50 is above EMA200 — confirmed uptrend
2. Candle low reaches or enters the EMA50 zone (within ATR tolerance)
3. Candle closes bullish (close > open)
4. Candle close is above EMA21 — momentum reclaimed

**Take-profit:** The nearest historical swing high (fractal) above entry. Falls back to a fixed risk:reward multiple if no valid level is found.

**Stop loss:** Placed below the signal candle's low (long) or above its high (short), with an ATR buffer and a broker-enforced minimum distance.

---

## Signal Conditions

### Long entry
| Condition | Logic |
|---|---|
| Trend | EMA50 > EMA200 |
| Zone touch | Candle low ≤ EMA50 + (ZoneAtrMult × ATR) |
| Confirmation | Candle closes bullish (close > open) |
| Momentum | Close > EMA21 |

### Short entry
| Condition | Logic |
|---|---|
| Trend | EMA50 < EMA200 |
| Zone touch | Candle high ≥ EMA50 − (ZoneAtrMult × ATR) |
| Confirmation | Candle closes bearish (close < open) |
| Momentum | Close < EMA21 |

---

## Risk Management

### Stop loss placement
```
SL (long)  = candle low  − (SlBufferAtr × ATR)
SL (short) = candle high + (SlBufferAtr × ATR)
SL distance enforced ≥ max(MinSlAtr × ATR, 10 × point)
```

### Take-profit placement
```
1. Scan last LevelLookbackBars bars for nearest fractal swing high/low beyond entry
2. Use that level if distance ≥ MinTpAtr × ATR
3. Otherwise: TP = entry ± (SL distance × FallbackRR)
```

### Lot sizing
```
Risk money  = Account balance × (RiskPercent / 100)
Money/lot   = (SL distance / tick size) × tick value
Raw lots    = Risk money / money per lot
Final lots  = clamp(raw lots, MinLot, MaxLot) → normalised to broker step
```

---

## Optional Filters

All four false-break filters are **disabled by default** and can be enabled independently:

| Filter | Input | Description |
|---|---|---|
| **Body ratio** | `UseBodyRatioFilter` | Signal candle body must be ≥ `MinBodyRatio` × candle range — rejects indecision candles |
| **EMA50 slope** | `UseEmaSlopeFilter` | EMA50 must be rising (long) or falling (short) over `EmaSlopeBars` bars — avoids flat/choppy markets |
| **Break of previous candle** | `UseBreakOfPreviousCandle` | Close must clear the previous candle's high (long) or low (short) by `BreakBufferAtr × ATR` |
| **Reclaim buffer** | `UseReclaimBuffer` | Close must exceed EMA21 by `ReclaimBufferAtr × ATR` — avoids barely reclaiming the level |
| **ADX** | `UseAdxFilter` | Only trade when ADX ≥ `MinAdx` — filters low-momentum environments |

---

## Trade Guards

| Guard | Parameter | Default |
|---|---|---|
| Maximum trades per day | `MaxTradesPerDay` | 1 |
| Daily drawdown limit | `MaxDailyLossPct` | 3.0% of start-of-day equity |
| Maximum spread | `MaxSpreadPrice` | 0.40 price units |
| Trade window | `TradeStartHour` / `TradeEndHour` | 00:00–00:00 (always on) |
| Force-close outside window | `ForceCloseAtEnd` | false |
| One position at a time | — | Always enforced |

---

## Fractal Swing Level Detection

The EA detects swing highs and lows using a **fractal algorithm** with configurable left/right bar confirmation:

```
Swing high at bar i:
  iHigh[i] > iHigh[i-k]  for k = 1..SwingLeft
  iHigh[i] ≥ iHigh[i+k]  for k = 1..SwingRight

Swing low at bar i:
  iLow[i] < iLow[i-k]    for k = 1..SwingLeft
  iLow[i] ≤ iLow[i+k]    for k = 1..SwingRight
```

The nearest qualifying level beyond the entry price is used as TP. The lookback window is capped at `LevelLookbackBars` bars.

---

## Execution Flow

```
OnTick()
├── ForceCloseAtEnd check (optional)
├── IsNewBar() — exit if not a new bar (bar-based, not tick-based)
├── ResetDailyIfNeeded()
├── Guards: daily loss limit, trade count, spread, trade window, open position
├── Read indicators: ATR[1], EMA50[1], EMA200[1], EMA21[1]
├── Evaluate LongSignal() / ShortSignal()
│   ├── Trend filter (EMA50 vs EMA200)
│   ├── Zone touch, directional close, EMA21 reclaim
│   └── Optional filters (body ratio, slope, break, reclaim buffer, ADX)
├── Calculate entry, SL, TP
├── Validate SL/TP against broker stops/freeze level
├── Size lots from risk %
└── Place Buy / Sell order → increment tradesToday
```

---

## Parameters Reference

### Core
| Parameter | Default | Description |
|---|---|---|
| `RiskPercent` | 0.50 | Risk per trade as % of account balance |
| `MaxLot` | 0.10 | Hard cap on lot size |
| `MinLot` | 0.10 | Minimum lot size |
| `TF` | H4 | Operating timeframe |

### Indicators
| Parameter | Default | Description |
|---|---|---|
| `AtrPeriod` | 14 | ATR period |
| `EmaFastPeriod` | 50 | EMA50 period |
| `EmaSlowPeriod` | 200 | EMA200 period |
| `EmaMidPeriod` | 21 | EMA21 period |

### Zone & SL
| Parameter | Default | Description |
|---|---|---|
| `ZoneAtrMult` | 0.40 | How far from EMA50 the zone extends (ATR multiplier) |
| `SlBufferAtr` | 0.20 | SL buffer beyond candle extreme (ATR multiplier) |
| `MinSlAtr` | 1.00 | Minimum SL distance in ATR units |

### Take-Profit
| Parameter | Default | Description |
|---|---|---|
| `SwingLeft` | 2 | Bars left of fractal for confirmation |
| `SwingRight` | 2 | Bars right of fractal for confirmation |
| `LevelLookbackBars` | 300 | Max bars to scan for swing levels |
| `MinTpAtr` | 1.2 | Minimum TP distance from entry (ATR multiplier) |
| `FallbackRR` | 3.0 | Risk:reward ratio used when no valid level found |

---

## Installation

1. Copy `H4_NextLevel_EA.mq5` to your MetaTrader 5 `Experts` directory:
   ```
   [MT5 Data Folder]/MQL5/Experts/
   ```
2. Open MetaEditor and compile the file (`F7`)
3. Attach the EA to an H4 chart of your chosen instrument
4. Configure inputs in the EA properties panel
5. Enable **AutoTrading** in MetaTrader 5

> **Recommended:** Run in the Strategy Tester on historical data before live deployment. Optimise `ZoneAtrMult`, `SlBufferAtr`, and `FallbackRR` for your instrument.

---

## Notes & Limitations

- **Bar-based execution** — the EA only evaluates signals on confirmed bar closes, not on every tick. This avoids repainting and reduces noise.
- **Single position** — the EA holds at most one open position per symbol at any time.
- **Strict risk sizing** — with `StrictRiskSizing = true`, trades are skipped entirely if the mathematically correct lot size falls below `MinLot`. With it off (default), the lot is clamped to `MinLot`, which slightly over-risks the trade.
- **Spread filter** — `MaxSpreadPrice` is in price units (e.g. dollars for XAUUSD), not pips. Set appropriately for your instrument.
- **Trade window** — setting `TradeStartHour = TradeEndHour = 0` is a wrap-around case that evaluates to always-on.

---

> ⚠️ **Disclaimer:** This EA is provided for educational and research purposes. Past performance in backtesting does not guarantee future results. Always test thoroughly before deploying real capital.

---

*Part of an automated CFD trading algorithm project — backtested to a 2.5 Sharpe ratio on 2025 financial year data.*
