# NQ Strategy Portfolio EA: Strategy Specification v1.3

> **v1.3 (Nov 2026):** EA v1.20 adds market presets (US500, US30, DE40, XAUUSD New York/London, JP225), account-wide risk checks and a shared halt across charts. Multi-market test results are in section 9. **Final line-up unchanged: USTEC S3 + S1. US500 S3 is validated as a backup or an optional 25% split of S3 risk.**

> **v1.2 (Nov 2026):** final line-up after USTEC backtests (see section 8). **S3 (core) + S1 (support)**; S2 and S4 disabled. S3 stop widened to 0.40 × ADR; S1 stops for the day after its first loss. LIVE profile gains a trailing drawdown-from-high stop.

Source material: MatfinOrg interview "3 strategies" (S1–S3) and the "Golden Ticket" interview (S4).
Original backtests: MultiCharts, NQ futures, Jan 2022 – Sep 2026, **no commission or slippage**.
Target platform: MT5, IC Markets (Global entity), symbol **USTEC**, hedging account.

Status key: **[CONFIRMED]** from whiteboard/chart/your checks · **[DEFAULT]** our choice where the source is silent · **[TEST]** ambiguous, so both variants get tested.

---

## 0. Global settings

### 0.1 Instrument (USTEC, ICM Global)
| Item | Value |
|---|---|
| Contract size | 1 → **1.0 lot = $1 per index point**, 0.1 lot = $0.10/pt |
| Min lot / step | 0.1 / 0.1 |
| NQ equivalence | 1 NQ = $20/pt = 20 lots USTEC · 1 MNQ = 2 lots · **0.1 lot = 1/200 NQ** |
| Stops level | Read at runtime (`SYMBOL_TRADE_STOPS_LEVEL`), and the EA adjusts or skips if violated |
| Leverage | Global entity, so margin is not a binding constraint at these sizes |

### 0.2 Time
- Broker server time is **GMT+2/+3 aligned to US daylight saving** (confirmed: the US-open spike was at 16:30 server).
- **CT = server − 8 h, ET = server − 7 h, all year.** Input `ServerMinusCT = 8` as an override.
- One server day = one futures trading day (16:00 CT → 16:00 CT), so every rule below stays inside a single server day.

| CT | Server | Used by |
|---|---|---|
| 23:00 (prev. evening) | 07:00 | S3 overnight-range variant |
| 00:00 | 08:00 | S1 session open + VWAP anchor; S3 overnight range (default) |
| 08:30 | 16:30 | US cash open: S2/S4 VWAP anchor, S2 opening range start, S3 bias check |
| 08:45 | 16:45 | S3 opening range ends |
| 09:00 | 17:00 | S2 opening range ends |
| 09:30 | 17:30 | S4 trading starts (first hour excluded) |
| 10:00 / 10:30 | 18:00 / 18:30 | S1 entry window start [TEST] |
| 14:00 | 22:00 | S3 entry cutoff [DEFAULT] |
| 14:30 | 22:30 | S1 window end + time exit; S3 time exit; S2/S4 no new entries |
| 14:55 | 22:55 | S2 time exit (default), S4 close all |
| 15:55 | 23:55 | S2 time exit variant [TEST] |

### 0.3 Bar and execution conventions
- MT5 labels bars by **open** time; MultiCharts labels by **close** time. All rules here use **clock time of the bar close** ("signal at bar close at t, market entry at t").
- Signals are evaluated **only on completed bars**. Entry is a market order on the first tick of the next bar.
- TP = broker-side limit order; SL = broker-side stop. Both are attached at entry and measured from the **actual fill price**.
- Long positions fill at ask and exit at bid. The spread cost is therefore built into every trade (MultiCharts results had none).

### 0.4 Shared calculations
**AvgDailyRange (ADR15)**: used by S1 noise level and S3 stop.
- Built from broker **D1 bars** (00:00–24:00 server = full futures session), using the **15 most recent completed days**. Today's bar is excluded.
- Mode A [DEFAULT]: 15-day simple average of ATR(14) ("15-period moving average of traditional ATR").
- Mode B [TEST]: simple average of daily True Range over 15 days.
- Fixed for the whole day once calculated at 00:00 CT.

**VWAP**: Σ(typical price × tick volume) / Σ(tick volume), typical = (H+L+C)/3, cumulative from the anchor time and reset daily.
- CFDs have **tick volume only**. This is an approximation of the futures VWAP, and the biggest data risk for S2/S4.
- Calculated on each strategy's own timeframe (to mirror MultiCharts), with an option to use M1.

**ADX**: Wilder's original (`iADXWilder`), period 14, on the strategy's own timeframe.

### 0.5 Day filters
- Skip US market holidays and **early-close days** (Jul 3, the day after Thanksgiving, Dec 24 when they fall on weekdays). The EA works these out itself; Good Friday is calculated from Easter.
- Spread filter: no entry if the current spread > `MaxSpreadPts` (per strategy, set after the spread check).

---

## 1. Risk and portfolio layer

| Rule | Spec |
|---|---|
| Strategy identity | Each strategy has its own magic number, on/off switch, and daily counters |
| Positions | Max 1 open position **per strategy**; strategies run independently (hedging allowed) |
| Sizing mode | `RiskPercent` per strategy: lots = risk $ ÷ (SL distance pts × $1 per lot), rounded **down** to 0.1. Alternative mode: fixed lots |
| Minimum sizing distance | Lots are sized as if the stop were at least `InpMinSizingPts` (10 pts) away, so a very tight S2 stop can't create an oversized position |
| Session-close safety | Every position is closed `InpSessionEndBufMin` (5) minutes before the broker's trading session ends, whatever its exit time |
| Below minimum lot | If calculated lots < 0.1, either **skip** [DEFAULT] or take 0.1 only if the resulting risk ≤ `MaxRiskPerTrade%` |
| **Static drawdown floor** | Floor = initial balance × (1 − 5%). **Pre-trade check**: no new trade if equity − (open risk of all positions) − (this trade's risk) < floor + buffer. **Hard stop**: if equity ≤ floor + buffer → close everything and halt |
| Buffer | `FloorBuffer%` default 0.5% of initial balance (protects against slippage and gaps) |
| Final risk % | Set by Monte Carlo on our own CFD backtest trades (target: P(breach) below a level you choose) |
| **Account profiles** | `PROP`: 5% static floor (measured on **equity** [DEFAULT, conservative]) + **7% profit target**: when equity ≥ initial × 1.07, close everything and halt. `LIVE`: floor optional, with its own setting (no 5% rule), and no target |
| Prop sizing objective | Choose risk % to maximise P(reach +7% before −5%), accepting a longer time to pass. A pure coin flip at this target/floor gives 5 / (7+5) = 41.7%; the edge plus smaller size moves it above that |
| **LIVE trailing stop (v1.2)** | `InpLiveTrailDDPct` (20%): halt if equity falls 20% from its highest point; the high is saved across restarts; `InpResetHalt` restarts it from current equity |
| Prop account size | ≥ $25k recommended (ideally $50k) so 0.1-lot steps allow ~0.25% risk per trade with fine control |
| Benching (phase 2) | Shadow-trade a strategy whose drawdown exceeds its Monte Carlo 75th percentile; resume trading at a new equity high |

---

## 2. S1 – Vault Break (M30, long only)

| Element | Rule | Status |
|---|---|---|
| Session open | Open of the M30 bar starting 00:00 CT (08:00 server) | [CONFIRMED] whiteboard + chart (grey line starts at midnight) |
| Noise level | Session open + **0.30 × ADR15**, fixed all day | [CONFIRMED] |
| VWAP | Anchored 00:00 CT | [CONFIRMED] |
| Signal | M30 bar **closes** above the noise level **and** above VWAP | [CONFIRMED] |
| Entry window | Signal bar close in **[10:00, 14:30) CT**; variant **[10:30, 14:30)** | [TEST] |
| Entry | Market at the next bar's open | [CONFIRMED] |
| Re-entry | No fresh breakout needed. After any exit, the next qualifying bar close re-enters | [CONFIRMED] chart |
| Limits | 1 position at a time, **max 3 entries per day** | [CONFIRMED] |
| **Daily loss stop (v1.2)** | **Stop for the day after the first loss** (`InpS1_MaxLosses = 1`) | [TESTED v1.2] |
| TP / SL | **+40 pts / −75 pts** fixed ($800/$1,500 on NQ). Variant: scale both by ADR15 ÷ its 2022–26 median | [CONFIRMED] / scaling [TEST] |
| Time exit | 14:30 CT (22:30 server) | [CONFIRMED] |

**Validation targets (MultiCharts, no costs, 2022–26):** 1,151 trades (about 1/day) · 67.7% win · avg win 37.0 pts · avg loss 60.2 pts · avg trade **5.6 pts** · break-even win rate 61.9%.
**Risk:** the thinnest margin of S1–S3. A spread of 1–2 pts removes 18–36% of the edge.

---

## 3. S2 – VWAP Pullback + ADX (M1, long only) — DISABLED in v1.2 (no edge on USTEC)

| Element | Rule | Status |
|---|---|---|
| Opening range | High/low of M1 bars 08:30–09:00 CT | [CONFIRMED] |
| VWAP | Anchored **08:30 CT** (variant 00:00 CT) | [CONFIRMED] chart, variant [TEST] |
| 1. Arm | An M1 bar closing at or after 09:00 CT closes **above the opening-range high** | [CONFIRMED] whiteboard ("touch" in the chat; we use close) |
| 2. Touch | After arming, a bar's **low ≤ VWAP** (can be the same bar as the arm) | [CONFIRMED] |
| 3. Reclaim | A bar **closes above VWAP** (can be the touch bar) | [CONFIRMED] |
| 4. ADX | ADX > 20 **and** ADX ≤ previous bar's ADX. If 1–3 are met but ADX fails, keep checking each later bar, which must also close above VWAP | [CONFIRMED] / VWAP re-check [DEFAULT] |
| Entry | Market at the next bar's open | [CONFIRMED] |
| Entry cutoff | No new entries after 14:30 CT (as in S4) | [DEFAULT] |
| Trades per day | 1 (variant: 2, with a fresh touch required) | [DEFAULT] / [TEST] |
| TP | Highest high of the last 5 completed bars at signal. Mode A: fixed at entry [DEFAULT]. Mode B: recalculated every bar. If TP ≤ entry + min distance → skip the trade | [TEST] |
| SL | Lowest low of the last 20 completed bars at signal, fixed | [CONFIRMED] |
| Time exit | **14:55 CT** [DEFAULT] / **15:55 CT** | [TEST] (agreed) |

**Validation targets:** 576 trades (about 0.5/day) · 67.7% win · avg win 32.9 pts · avg loss 46.8 pts · avg trade **7.2 pts** · break-even 58.7% · worst single loss 278 pts · avg hold 44 min.

---

## 4. S3 – Overnight Bias ORB (M15, long and short)

| Element | Rule | Status |
|---|---|---|
| Overnight range | High/low **00:00–08:30 CT** [DEFAULT, matches chart]; variant 23:00–08:30 CT (whiteboard) | [TEST] |
| Bias | p = (open of the 08:30 CT bar − overnight low) ÷ (overnight high − overnight low). p > 2/3 → **long only**; p < 1/3 → **short only**; otherwise no trade. Exactly on a boundary → no trade | [CONFIRMED] |
| Opening range | High/low of the 08:30–08:45 CT bar | [CONFIRMED] |
| Signal | Any M15 bar close (from 09:00 CT) **beyond the opening range in the bias direction** with **ADX > 20** on that bar. Not only the first break | [CONFIRMED] ADX; "any bar" [DEFAULT] |
| Bias persistence | Never cancelled by later price action or an opposite break | [CONFIRMED] |
| Entry | Market at the next bar's open; **1 trade per day** | [CONFIRMED] |
| Entry cutoff | 14:00 CT (variant: none) | [DEFAULT] / [TEST] |
| SL / TP | SL = **0.40 × ADR15** (v1.2; source used 0.30); TP = **3 × SL** | [TESTED v1.2] |
| Time exit | 14:30 CT | [CONFIRMED] |

**Validation targets:** 434 trades (236 L / 198 S) · 53.7% win (L 56.8%, S 50.0%) · avg win 110.5 pts · avg loss 78.9 pts · avg trade **22.8 pts** · break-even 41.7% · worst loss 271 pts · worst losing streak $11,850 per NQ.
**Most robust to CFD costs** (−4% to −9% of the edge).

---

## 5. S4 – Golden Ticket: Drift VWAP Pullback (M15 trend, M5 trigger, long and short) — DISABLED in v1.2 (no edge on USTEC)

| Element | Rule | Status |
|---|---|---|
| VWAP | Calculated on **M15 bars**, anchored 08:30 CT (09:30 ET) | [CONFIRMED] |
| Trend check | At each M15 close. **Long:** close > VWAP · VWAP > VWAP one bar ago · close ≥ close 4 bars ago × 1.001 (+0.1% in 1 h). **Short:** mirror image (−0.1%). The state holds until the next M15 close | [CONFIRMED] |
| No-trade period | First hour 08:30–09:30 CT | [CONFIRMED] |
| Trigger | M5 bar close while the state is long and the bar is **red** (close < open) → buy. State short and **green** bar → sell. Distance to VWAP doesn't matter | [CONFIRMED] |
| After a trade | The next qualifying opposite-colour bar while the state still holds can trigger again | [DEFAULT] |
| Entry | Market at the next M5 bar's open | [CONFIRMED] |
| TP / SL | Long **+40 / −80 pts**; short **+50 / −80 pts**, fixed | [CONFIRMED] |
| Guards | 1 position at a time · max 4 trades/day · **max 2 losses/day** (variant: 2 *consecutive* losses) | [CONFIRMED] / [TEST] |
| Last entry / exit | No new trades after 14:30 CT; close all at 14:55 CT | [CONFIRMED] |

**Validation targets (from the interview, no full report):** win ~64% · avg win ~$866 (43 pts) · avg loss ~$1,300 (65 pts) · avg trade ≈ **4.3 pts** · break-even 60.0%.
**Most cost-sensitive of the four** (1–2 pt spread = −23% to −46% of the edge). The author says it's built for passing prop challenges, not for growing your own capital.

---

## 6. Test plan
1. Build all four as modules of one EA (shared time, VWAP, ADR and risk engine).
2. MT5 tester, "every tick based on real ticks", ICM USTEC, 2022 → present (or as far back as ICM tick data goes).
3. Check each strategy against its validation targets (trade count, win rate, average points per trade).
4. Run each [TEST] variant on its own. No parameter optimisation, to avoid overfitting.
5. Export trades → Monte Carlo on the combined portfolio → set risk % per strategy against the 5% static floor.
6. Run on a demo account (at least 4 weeks) before going live or using it on a prop account.

## 7. Open items
- Spec **approved** by user (v1.1: profit target 7%, 5% static floor on prop only).
- Prop: confirm any time limit; equity- vs balance-based floor (EA assumes equity).
- Live £1,000 account: maximum drawdown you'd tolerate; likely start with S3 only at 0.1 lot.
- Typical USTEC spread at 08:30–10:00 CT and 14:30–16:00 CT; stops level.
- How far back ICM real-tick history goes for USTEC.

---

## 8. Backtest results on USTEC (ICM, Jan 2022 – Sep 2026, history quality 10% real ticks)

All profit factors below include an extra **1 index point of cost per trade** (stress for slippage) on top of the tester's spread, unless stated.

### 8.1 Validation against the MultiCharts reports (baseline settings)
| | Trades (his / ours) | Win % (his / ours) | Avg trade pts (his, no costs / ours) | Verdict |
|---|---|---|---|---|
| S1 | 1,151 / 1,072 | 67.7 / 65.9 | 5.6 / 3.7 | ✓ reproduced |
| S2 | 576 / 582 | 67.7 / 72.0 | 7.2 / 0.2 | entries ✓, exits ✗ (TP geometry not reproducible) |
| S3 | 434 / 470 | 53.7 / 52.3 | 22.8 / 16.2 | ✓ reproduced (PF 1.40 = his 1.40) |
| S4 | ~4,000+ / 3,570 | ~64 / 62.5 | ~4.3 / 1.1 | ✓ reproduced, edge lost to spread |

### 8.2 Improvement tests (patterns found in 2022–24, checked on 2025–26)
| Strategy | Test | PF 22–24 | PF 25–26 | Decision |
|---|---|---|---|---|
| S1 | base | 1.07 | 1.22 | – |
| S1 | **stop after first loss** | 1.10 | 1.26 | **adopted** |
| S1 | + ADR-scaled exits | 1.14 | 1.23 | no clear gain → not adopted |
| S2 | PRETOUCH / SWING take profit | ~1.00 / ~1.04 overall | | no edge → disabled |
| S3 | base (SL 0.30) | 1.46 | 1.25 | – |
| S3 | exit 14:55 | 1.48 | 1.22 | no gain → keep 14:30 |
| S3 | session-based ADR | ≈ base | | no gain → keep broker D1 |
| S3 | SL 0.25 | 1.48 | 1.15 | worse |
| S3 | **SL 0.40** | 1.47 | 1.57 | **adopted** (best return per unit of risk) |
| S3 | SL 0.50 | 1.54 | 1.56 | higher PF but lower R per trade → not adopted |
| S4 | long only / + ADR exits | 1.05 / 1.02 overall | | no edge → disabled |

### 8.3 Final line-up: Monte Carlo (S1 + S3, S3 at 2× S1 risk, +1 pt cost stress)
**Prop (+7% target, 5% static floor, EA halts at −4.5%):**
| S1 / S3 risk per trade | Pass | Fail | Median days to pass |
|---|---|---|---|
| 0.25% / 0.50% | 73.7% | 3.8% | 134 |
| 0.35% / 0.70% | 82.6% | 9.9% | 94 |

**Own capital (5-day block bootstrap):**
| S1 / S3 risk per trade | Backtest CAGR | Median 1-yr return | Bad year (1 in 10) | P(losing year) | P(>20% DD within 5 yrs) |
|---|---|---|---|---|---|
| 0.5% / 1.0% | 19.7% | 18.8% | +3.9% | 4.9% | 1.3% |
| **0.6% / 1.2%** | 23.9% | 22.5% | +4.3% | 5.2% | 4.7% |
| 0.75% / 1.5% | 30.3% | 29.1% | +5.5% | 5.2% | 16.8% |

Plan on roughly half the backtest return live (data quality, slippage, edge decay).

---

## 9. Multi-market results (EA v1.20, Jan 2022 – Sep 2026)

Rules unchanged from USTEC; only session times (local exchange time, local DST) and range-scaled point values differ. Profit factors are in R with a cost stress of **1% of each trade's stop distance**.

| Market (preset) | S1 PF | S3 PF | S3 PF 22–24 / 25–26 | Daily-R correlation with USTEC S3 | Verdict |
|---|---|---|---|---|---|
| **USTEC** | 1.16 | **1.50** | 1.47 / 1.57 | – | **core** |
| **US500** | 1.10 | **1.28** | 1.32 / 1.18 (every year ≥ 1.04) | 0.69 | **backup / optional 25% split** |
| XAUUSD New York | 0.99 | 1.11 | 1.18 / 0.99 | −0.05 | watch-list (demo only) |
| JP225 (07:00–09:00 range) | 0.97 | 1.14 | 1.23 / 1.06; in drawdown since Jun 2026 | 0.00 | drop |
| JP225 (full overnight) | – | 0.96 | | | drop |
| DE40 | 0.93 | 0.91* | 0.99 / 0.87* | | drop |
| XAUUSD London | 0.83* | 0.95* | 0.99 / 0.84* | | drop |

\* These runs used a leftover S3 stop of 0.50 (see 9.3). They were clear fails at that setting, so they weren't re-run.

### 9.1 Portfolio effect (Monte Carlo, S1 + S3 on USTEC with S3 at 2× S1 risk, base risk 0.25% / 0.35%)
| Portfolio | Pass / fail at 0.25% | Pass / fail at 0.35% |
|---|---|---|
| USTEC S1 + S3 | 73.9% / 3.8% | 82.7% / 9.8% |
| + US500 S3 on top | 80.2% / 8.3% | 82.3% / 15.5% |
| USTEC S3 split 75/25 with US500 S3 | 71.5% / 3.7% | 82.6% / 8.8% |
| + XAUUSD S3 (1×) | 78.4% / 4.0% | 85.6% / 9.6% |

**What the multi-market tests show:**
- **The overnight-bias effect holds on US indices** (USTEC and US500), which supports it being real.
- **It does not carry over reliably to DAX, gold or Nikkei.** Gold and JP225 only look useful in the portfolio because they're uncorrelated; their own edges are too thin and uneven to trust.
- **For real diversification, the next step is a different strategy type built for those markets**, not the same rules.

### 9.2 Final line-up
| Chart | Strategies | Prop risk per trade | Own-capital risk per trade |
|---|---|---|---|
| USTEC (preset USTEC/custom) | S3 + S1 | S3 0.50%, S1 0.25% (faster: 0.70% / 0.35%) | S3 1.2%, S1 0.6% (on £1,000: 0.1 lot each) |
| US500 (optional, preset US500) | S3 only | take 25% of the total S3 risk from USTEC | same split |

### 9.3 Testing lessons
- **The MT5 Strategy Tester keeps the last-used inputs** for an EA, even after a recompile with new defaults. Reset the inputs before each new test series and check the key values. The EA's CSV makes it possible to infer the S3 stop actually used: on days when both strategies traded, take the ratio of S3's stop to S1's stop.
- **The tester's Symbol box decides the market traded**, not the chart that's open. Always check the `symbol` column in the trade log.
- **Gold is 100 oz per lot, and JP225 is about $0.0065 per point per lot.** Always use risk-% sizing. On JP225, raise "Hard cap on lots per trade" above 50 if you ever trade it.
