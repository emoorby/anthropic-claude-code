# CLAUDE.md — AI Assistant Guide for HiLo_Breakout_EA

## Project Overview

This repository contains a single **MQL4 Expert Advisor (EA)** for MetaTrader 4: an automated Forex/gold trading robot implementing a breakout strategy using the "3 Level ZZ Semafor" indicator.

**Single source file:** `HiLo_Breakout_EA.mq4` (≈ 1,026 lines)

---

## Technology Stack

| Item | Details |
|------|---------|
| Language | MQL4 (MetaQuotes Language 4) |
| Platform | MetaTrader 4 (MT4) |
| Artifact type | Expert Advisor (.mq4 → compiled .ex4) |
| Compilation | Done by the MT4 terminal on file save — no external build tool |
| Tests | MT4 built-in Strategy Tester (backtesting); no unit test framework |
| Dependencies | "3 Level ZZ Semafor" custom indicator must be installed in MT4 |
| Package manager | None |
| CI/CD | None |

---

## Codebase Structure

The entire EA lives in one file, organized into clearly demarcated sections:

| Lines | Section | Purpose |
|-------|---------|---------|
| 1–18 | Header / Enums | Copyright, version, `LOT_MODE_*` enum |
| 22–65 | Input parameters | All user-configurable settings (`extern` vars) |
| 68–89 | Global variables | Runtime state (`g_*` prefix) and buffer index constants |
| 92–237 | Utility functions | Logging, pip size init, indicator value retrieval, ATR, spread helpers |
| 240–293 | Filter functions | `CheckSpreadFilter()`, `CheckATRFilter()`, `CheckERFilter()` |
| 296–359 | Order query helpers | Count open positions, find ticket by magic+type, last ticket info |
| 361–452 | Order state checks | `IsOrderTriggered()`, `IsOrderClosed()`, `IsOrderStoppedOut()` |
| 457–550 | Order placement | `PlaceSellStop()`, `PlaceBuyStop()` |
| 555–632 | Order modification | Breakeven and trailing-stop update functions |
| 637–676 | Initial order placement | Called from `OnInit()` to seed orders on EA load |
| 681–758 | M30 candle monitoring | Detects new bars, reads indicator buffers, triggers order placement |
| 763–806 | Order state monitoring | Checks if pending orders triggered or were closed |
| 811–901 | Open position management | Applies breakeven and trailing stop rules |
| 906–971 | `OnInit()` | EA initialization callback |
| 976–979 | `OnDeinit()` | EA cleanup callback |
| 984–1025 | `OnTick()` | Main loop — called on every price tick |

---

## Core Trading Strategy

The EA implements a **breakout strategy** driven by the "3 Level ZZ Semafor" indicator on M30 bars:

- **Buffer 4 (value 5 on chart)** — local lows → places a **Sell Stop** order
- **Buffer 5 (value 6 on chart)** — local highs → places a **Buy Stop** order

**Order sizing:**
```
Entry  = SignalLevel ± (PipsToRisk / 2)
StopLoss = SignalLevel ∓ (PipsToRisk / 2)
TakeProfit = Entry ± (ATR(period) × ProfitTargetFactor)
```

**Position management** (applied per tick while a position is open):
- **Breakeven:** move SL to entry once profit ≥ `ATR × BreakevenTriggerFactor`
- **Trailing Stop:** activate once profit ≥ `ATR × TrailTriggerFactor`, trail at `TrailDistPips` distance

---

## Key Architectural Patterns

### 1. Separation of Concerns (Procedural)
Utility, filter, order management, monitoring, and position management are distinct function groups — never mix concerns across sections.

### 2. Two-Side Independence
Sell and buy logic operate independently through dedicated state variables:
- Tickets: `g_sellTicket` / `g_buyTicket`
- Waiting flags: `g_sellWaitingSignal` / `g_buyWaitingSignal`

One side can be closed/waiting while the other remains active.

### 3. Order Lifecycle State Machine
```
[No order]
  → signal detected → [Pending Stop Order]
  → price triggers  → [Open Position]
  → SL/TP/manual    → [Closed] → set WaitingSignal = true
  → new signal      → [Pending Stop Order] (cycle repeats)
```

### 4. Event-Driven MT4 Callbacks
- `OnInit()` — runs once on EA load; initializes pip size, places initial orders
- `OnTick()` — runs on every price tick; orchestrates all monitoring and management
- `OnDeinit()` — runs on EA removal; logs shutdown

### 5. Two-Layer Efficiency Ratio (ER) Filtering
- **Layer 1:** Blocks new order placement if ER < `ER_Layer1_Threshold`
- **Layer 2:** Deletes existing pending orders if ER drops below `ER_Layer2_Threshold`
Both layers are independently enabled/disabled via input parameters.

---

## Naming Conventions

| Category | Convention | Example |
|----------|-----------|---------|
| Global variables | `g_` prefix, camelCase | `g_pipSize`, `g_sellTicket`, `g_lastM30Bar` |
| Input parameters | PascalCase | `MagicNumber`, `ProfitTargetFactor`, `EnableLogging` |
| Constants / buffer indices | ALL_CAPS | `BUF_VALUE5`, `BUF_VALUE6`, `LOT_MODE_FIXED` |
| Boolean inputs | `Enable` prefix | `EnableLogging`, `EnableATRFilter`, `EnableER_Layer1` |
| Helper functions | Descriptive verbs | `PlaceSellStop()`, `CheckSpreadFilter()`, `UpdateBreakeven()` |

---

## Logging Convention

All logging uses the central `Log()` helper, which respects the `EnableLogging` input:

```mql4
Log("=== SECTION HEADER ===");
Log("SELL STOP placed ticket=" + IntegerToString(ticket));
Log("ER Layer 2 BLOCKED - deleting pending order");
```

- Prefix: `[HiLo_BRK]` is prepended by `Log()`
- Use `=== ... ===` headers for major lifecycle sections in `OnInit`/`OnTick`
- Log all significant state changes: order placed, modified, triggered, closed, blocked

---

## Function Header Comment Style

```mql4
//+------------------------------------------------------------------+
//| FunctionName                                                      |
//+------------------------------------------------------------------+
void FunctionName()
{
   // implementation
}
```

Use this box-style header for every function.

---

## Pip Size Handling

MT4 pip sizes vary by instrument — always use `g_pipSize` (set in `InitPipSize()`):

| Instrument type | Pip value |
|----------------|-----------|
| 5-digit pairs (e.g. EURUSD) | `Point × 10` |
| XAUUSD (gold, 2-digit) | `0.10` |
| 3-digit pairs | `Point × 10` |
| Others | `Point` |

Never hardcode pip values; always multiply by `g_pipSize`.

---

## Input Parameter Groups

When adding new inputs, place them in the appropriate existing group:

1. **General** — `MagicNumber`, `EnableLogging`
2. **Indicator** — `IndicatorName`, ER settings
3. **Trade parameters** — `PipsToRisk`, `MaxSpreadPips`, `ProfitTargetFactor`
4. **ATR filter** — `EnableATRFilter`, `ATR_Period`, `ATR_MinValue`
5. **Efficiency Ratio** — `EnableER_Layer1/2`, threshold values
6. **Position management** — breakeven, trailing stop, lot sizing inputs

---

## Error Handling Conventions

- Validate indicator values before use: `if (val == 0.0 || val == EMPTY_VALUE) return;`
- Check order existence before modification/deletion
- Validate stop distances against broker minimum: use `MarketInfo(Symbol(), MODE_STOPLEVEL)`
- Verify spread before placing orders via `CheckSpreadFilter()`
- Log every failure path with the reason

---

## Development Workflow

Since there is no build tool or CI, the workflow is:

1. Edit `HiLo_Breakout_EA.mq4` in MetaEditor (or any text editor)
2. Save → MT4 auto-compiles to `HiLo_Breakout_EA.ex4`
3. Fix any compiler errors/warnings shown in MetaEditor's Toolbox → Errors tab
4. Test using MT4 **Strategy Tester** (View → Strategy Tester)
   - Select the EA, symbol (e.g. XAUUSD), M30 timeframe
   - Run backtest over a representative date range
   - Review trade log and equity curve
5. Forward-test on a demo account before any live use
6. Commit changes to git with a descriptive message following existing commit style

**Commit message style** (inferred from history):
```
Short imperative summary (e.g. "Add ATR-based trailing stop trigger")

Optional body explaining why, not what.
```

---

## Key Domain Knowledge for AI Assistants

- **MQL4 order types:** `OP_SELLSTOP`, `OP_BUYSTOP` are pending orders; `OP_SELL`, `OP_BUY` are market orders. When a stop order triggers, its type becomes the corresponding market order.
- **`OrderSelect()`** must be called before accessing `OrderOpenPrice()`, `OrderStopLoss()`, etc.
- **Magic number** (`MagicNumber` input) uniquely identifies this EA's orders on the account, enabling multiple EAs to coexist.
- **`OrderSend()` on modification (`OP_MODIFY`)** does not exist — use `OrderModify()` to change SL/TP.
- **Broker stop level** (`MODE_STOPLEVEL`) is the minimum distance in points between price and SL/TP — always validate before sending orders.
- **ATR** (Average True Range) is used for dynamic sizing of TP, breakeven trigger, and trail trigger. Period defaults to 30 (M30 bars ≈ 15 hours).
- **Efficiency Ratio** measures trend quality: `(net price change) / (sum of absolute bar changes)`. Values near 1 = strong trend; near 0 = choppy. The EA uses a custom indicator for this.

---

## What NOT to Do

- Do not add hardcoded pip values — always use `g_pipSize`
- Do not access `Order*()` functions without calling `OrderSelect()` first
- Do not create external dependencies or additional files — keep it single-file
- Do not remove the `g_` prefix from global state variables
- Do not bypass the `Log()` helper with raw `Print()` calls (unless debugging only)
- Do not remove filter checks (`CheckSpreadFilter`, `CheckATRFilter`, `CheckERFilter`) from order placement paths
