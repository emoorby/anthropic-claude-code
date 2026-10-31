# Break & Bounce – review notes for `BreakAndBounce_EA.mq5`

## 1. Rules in the video that the ProRealTime code does not cover (or gets wrong)

| # | Video rule | What the PRT code does | How the EA handles it |
|---|-----------|------------------------|-----------------------|
| 1 | The breakout needs a **closed** 15m candle beyond the level ("we don't just settle for price moving above the level for a minute") | `TIMEFRAME(15 minutes)` without `UpdateOnClose` reads the 15m bar that is still forming, so a 5-minute poke above the level counts | Only closed `InpBreakTF` bars are checked |
| 2 | The breakout must happen **within the first 2.5 h** ("sometimes the breakout happens, but not within the first 2½ hours") | `dir` is set at any time, including pre-market or overnight | Only bars from the open are scanned; `InpBreakoutInWindow` |
| 3 | One setup per day, based on yesterday's box | `dir` is **never reset**, so yesterday's breakout direction carries into today. An opposite breakout flips it. Can re-enter after a stop-out | Daily reset; `InpAllowFlip`; `InpMaxTradesPerDay` |
| 4 | Retest comes **after** the breakout | No ordering. The retest can be the breakout bar itself | Signal bars must open after the breakout candle has closed |
| 5 | Hammer "**must come after a clear red negative movement**". The video rejects a hammer that lacks one | Not coded | `InpPriorMoveBars`: net counter-move over N bars, and the hammer marks the extreme |
| 6 | Hammer entry = **break of the hammer** (buy stop above its high), SL at the hammer low | Market order at the next bar open, with SL = level − 0.2×candle range | `InpHammerEntry` = `HAM_BREAK` (video) or `HAM_AT_CLOSE` (live demo/PRT), `InpHamBreakBars` |
| 7 | Engulfing is defined by **high/low** (high > prev high, low < prev low). The entry is placed **at the high of the previous red candle, without waiting for the close** | Requires `Open < Low[1]` and `Close > High[1]`, which almost never happens on a retest because the open ≈ the previous close. Enters only after the close | `InpEngulfMode`: `ENG_INTRABAR` (video), `ENG_ON_CLOSE`, `ENG_PRT_STRICT` |
| 8 | The engulfed candle is the previous **red** candle (green for shorts) | Not checked | `InpEngPrevOpposite` |
| 9 | Stop "slightly below the low of the hammer/engulfing candle". In the live demo it was "a bit under the level" | Level − 0.2×signal-candle range | `InpSLMode`: candle / level / PRT, `InpSLBuffer` |
| 10 | Target 3R in example 1 and **2R** in the live trade | Fixed 3R, measured from the signal close, but the fill happens at the next open, so the real R:R differs | `InpRR`, measured from the actual entry price |
| 11 | Signal "**at / around** the level" | Requires `Low <= level` exactly, with no tolerance and no limit on how deep price goes back into the range | `InpRetestTol`, `InpMaxPenetration`, `InpRequireCloseBeyond` |
| 12 | Close the trade at the **market close** | 22:00 hard-coded | `InpExitHour/Min`; also closes positions left over from a previous day |
| 13 | Range = yesterday's **daily** high/low on a stock (cash session) | `DHigh(1)` on a CFD includes overnight/pre-market | `InpRangeSource` = D1 or custom session, `InpSkipSundayBar` |
| 14 | — | `ranged × 0.2` uses a Unicode `×`, so the PRT code does not compile as given | n/a |

## 2. Other considerations for making it work

1. **Time zones and DST.** All EA times are broker server time. US and EU daylight-saving changes fall on different dates, so the US open moves by an hour on server time for about 3 weeks a year. Check those weeks, or switch the times per season.
2. **Instrument.** The video trades single stocks in the cash session (Netflix). On index CFDs the D1 bar includes overnight trading, which changes the levels. Try `RANGE_SESSION` set to the cash hours.
3. **Sample size.** The video says the setup appears only 2–3× per month per stock. One symbol gives about 30 trades a year, which is too few to optimise on. Run it on a basket (MT5 multi-symbol tests, or one chart per symbol with the same magic). Set `InpMinTradesOpt` so the optimiser ignores thin results.
4. **The video's statistics are inconsistent.** It claims a 70% win rate with PF 1.6. With 2–3R targets, a 70% win rate would give a PF of about 4.6–7. So the author's live algo must use smaller effective targets, scratch trades, slippage or EOD exits. Treat their numbers loosely. Test `InpRR` from 1.0 to 3.0 and `InpBreakevenR`.
5. **Gaps.** If the session opens beyond the range, the first 15m candle is a "breakout" with no real break. Both video examples opened inside the range. Test `InpSkipGapOutside = true`.
6. **Volatility regime.** A very narrow previous day leaves levels that get blown through, and a huge day leaves levels that are never reached. Use `InpMinRangeATR` / `InpMaxRangeATR`.
7. **Units.** Distances default to % of the previous-day range (`UNITS_RANGE_PCT`), so one parameter set carries across symbols with different prices. Switch to points if you prefer.
8. **Costs.** The first 30 minutes after the open has the widest spreads and the most slippage, and stops are tight. Use `InpMaxSpreadPts`, include commission in tests, and test with "Every tick based on real ticks". The intrabar engulfing entry and the hammer-break entry are tick-sensitive.
9. **Stops too tight.** A hammer SL can be just a few ticks. `InpMinSL` widens it, and `InpMaxSL` skips trades whose stop is too wide.
10. **Event risk.** For stocks, avoid earnings days. For indices, avoid CPI/NFP/FOMC (there is no news filter, so add one or skip those days manually).
11. **Robustness.** Walk-forward / out-of-sample test. Optimise a few parameters (`InpRR`, `InpRetestTol`, `InpPriorMoveBars`, `InpSLMode`, `InpEntryWindowMins`, `InpEngulfMode`) rather than all of them.

## 3. Suggested optimisation ranges

| Input | Range |
|------|-------|
| InpRR | 1.0 – 3.0 step 0.5 |
| InpEntryWindowMins | 90 – 210 step 30 |
| InpRetestTol (% range) | 0 – 15 step 2.5 |
| InpMaxPenetration (% range) | 10 – 50 step 10 |
| InpPriorMoveBars | 0 – 5 |
| InpHamWickBody | 1.5 – 3.0 step 0.5 |
| InpSLMode / InpHammerEntry / InpEngulfMode | all |
| InpSLBuffer (% range) | 0 – 5 step 1 |
| InpBreakevenR | 0, 1.0, 1.5 |
| InpMinRangeATR / InpMaxRangeATR | 0–0.6 / 0, 1.5–2.5 |

---

# v2: basket testing, gap opens, news & earnings

## 4. Testing a basket efficiently

**Stage 1: screen symbols (no code needed).** Put the candidate stocks in Market Watch. In the Strategy Tester, set *Optimization* to **"All symbols selected in Market Watch"** and run with fixed default settings. Each symbol is tested separately, in parallel across all CPU cores, and you get one results row per symbol. Use this to drop symbols with no edge, poor data or high costs.

**Stage 2: optimise the basket as one portfolio.** Put the surviving symbols in `InpSymbols` (e.g. `NFLX,AAPL,MSFT,NVDA,AMZN`). One tester pass then trades all of them, and every optimisation pass is scored on the combined result (`OnTester` = PF × √trades). This is the efficient way to find settings that work across the basket instead of overfitting one symbol. Put the EA on a chart of the most liquid basket member. A 1-second timer covers the other symbols.

**Stage 3: walk-forward and review.** Optimise on, say, 2019–2022 and check 2023–now with the same settings. After a single (non-optimisation) run, the journal and `BB_symbol_stats.csv` list trades, win rate, net and PF **per symbol**. In the tester this file is written to the agent's `MQL5\Files` folder. Remove the members that don't contribute.

Speed tips:
- Optimise roughly in "1 minute OHLC" mode, then confirm the best sets with "Every tick based on real ticks". The intrabar entries need ticks.
- Use the genetic optimiser.
- Use all local agents, plus the MQL5 Cloud Network if you want.
- Optimise a handful of inputs at a time.

Basket limits: `InpMaxTradesDayTotal` and `InpMaxOpenTotal` cap correlated exposure, for example when 10 tech stocks all break out on the same day.

## 5. Gap opens

| Input | Effect |
|------|--------|
| `InpGapMode = GAP_ALLOW` | Original rules: the first 15m close beyond the range counts, even when the market opened there |
| `GAP_SKIP` | No trading when the session opens outside yesterday's range |
| `GAP_REBREAK` (default) | If the open is outside the range, price must first **close back inside** (15m), and then make a fresh breakout close. This filters out "breakouts" that are really just the gap |
| `InpMaxGapATR` | Skips the day when \|open − previous close\| > x × daily ATR. Catches news/earnings shocks even without an earnings file |

## 6. News & earnings

* **Economic news.** Live, the EA reads MT5's built-in economic calendar. In the tester the calendar API is unavailable, so first run the script **`BB_ExportCalendar.mq5`** on your broker's terminal. It writes `MQL5\Files\BB_news.csv`, and `#property tester_file` sends that file to the tester agents.
  * `NEWS_BLOCK`: no entries `InpNewsBeforeMins`/`InpNewsAfterMins` around an event.
  * `NEWS_SKIP_DAY`: skips the day if an event falls between `InpNewsPreOpenMins` before the open and the end of the entry window. This catches 8:30 ET CPI/NFP, which gap the open.
  * `InpNewsFlattenMins`: closes open trades before an event (e.g. FOMC at 14:00 ET).
* **Earnings.** These are not in the MT5 calendar. Fill `BB_earnings.csv` (`ticker,date,BMO|AMC`) and copy it to `MQL5\Files`. Sources: Nasdaq/Yahoo earnings calendars, or APIs such as Financial Modeling Prep / Alpha Vantage `EARNINGS_CALENDAR`. With `InpUseEarnings = true`, the EA skips the day the results hit the open: same day for BMO, the next session for AMC, and both if the timing is unknown. Tickers are matched loosely: `#AAPL`, `AAPL.US` and `AAPL_CFD` all match `AAPL`.
* Both `BB_news.csv` and `BB_earnings.csv` must exist in `MQL5\Files` before testing, even if they are only a header line. Otherwise the tester can complain about the missing `tester_file`.

## 7. What makes a stock suitable (narrowing the basket)

The edge depends on the previous day's high/low being a level where **institutional orders sit**, and on the price having **enough intraday movement** to reach 2–3R within a couple of hours. Look for:

1. **Liquidity / institutional ownership.** Large caps with high dollar volume (roughly > $100M/day; the most traded names are > $1B). Thin stocks don't respect levels, and their spreads eat a tight stop.
2. **Cost relative to movement.** Spread + commission as a fraction of the typical stop. Aim for < 5–10% of a typical stop (≈ 10–20% of the previous-day range). Most CFD stock spreads at the open fail this for low-priced names.
3. **Intraday volatility.** An average daily range of roughly 2–5% of price. Below that, 2–3R isn't reached before the close. Far above that, it's meme/news behaviour that ignores levels.
4. **Clean intraday trend behaviour.** Names that tend to continue after a level break (momentum large caps such as NFLX, NVDA, META, AMZN, TSLA, AMD, and liquid index proxies) rather than choppy, mean-reverting defensives (utilities, staples). Measure this directly: for each symbol, the % of days where a breakout of PDH/PDL within 2.5 h was followed by a retest that held. Stage 1 screening gives this.
5. **Opens inside the prior range often.** Stocks that frequently gap far outside yesterday's range give few valid setups (see gap rules). Check the gap distribution.
6. **Price above ~$20–30** to avoid tick-size and spread distortions.
7. **Diversification.** Pick across sectors, and cap concurrent trades. Ten semiconductor names are effectively one trade.
8. **Data quality at your broker.** Many brokers keep only 1–3 years of tick history for stock CFDs. Check the session times and how dividends and splits are handled. A basket you can't backtest properly is a basket you can't trust.
9. **Market regime.** Breakout-retest strategies do best in trending, moderately volatile markets. Consider an index-level filter (e.g. only trade when the index's opening range is outside its previous day's range, or VIX within a band).
10. **Possible extra filter: relative volume.** Stocks "in play" (first 15m volume ≫ average) follow through better. MT5 stock CFDs often only provide tick volume, so check what your broker supplies before relying on it.

---

# v2.1: data robustness, diagnostics, symbol selector

Why: a PC vs VPS comparison of two "All symbols in Market Watch" runs showed the same ticker giving very different results. The EA, the inputs and the tester engine were consistent, so the cause was **different or incomplete history on each machine**. Many runs also produced no trades and never said why.

## EA changes (`BreakAndBounce_EA.mq5` v2.10)
* **No more silently lost days.** If the D1/M5/ATR data isn't ready when a day starts, the EA retries once a minute until the entry window closes. Before, it skipped the whole day.
* **`InpMaxRangeAgeDays` (5).** If the "previous day" bar is older than this, there's a hole in the history. The day is skipped and counted as `stale_range`, instead of trading off weeks-old levels.
* **Weekdays with no ticks at all** are counted as `no_data`, including from the test start. Patchy stock history becomes visible.
* **Diagnostics for every symbol:** days, no_data, stale_range, range_filter, gap_skip, news_skip, earnings_skip, breakouts, setups, entries, and why entries were refused (spread, news, lots, max SL, basket caps, broker rejection plus the last retcode). Each symbol also gets a one-word **verdict**: `traded`, `NO_DATA`, `TRADE_REJECTED`, `LOT_TOO_BIG`, `no_breakouts`, `no_setups`, `filtered`.
  * Single test → `Terminal\Common\Files\BB_symbol_stats.csv` (and the journal).
  * Optimisation, including Market Watch mode → **`Terminal\Common\Files\BB_optim_diag.csv`**, one row per pass and symbol, collected via tester frames.
  * Find it via *File → Open Data Folder*, go up one level, then `Common\Files`.
* A warning is printed at start if a symbol's trade mode isn't FULL (e.g. close-only).
* `InpSymbolsFromFile` reads the basket from `MQL5\Files\BB_symbols.txt`, which the selector script writes. Long lists don't fit in a string input.

## `BB_SymbolSelector.mq5` (script)
1. Picks every server symbol ending in `.NYSE` / `.NAS` (configurable) and drops names containing `-24`.
2. Forces the history download and keeps only symbols whose data covers the test period:
   * the first bar is within `InpEdgeDays` of the start and the last bar within that of the end (drops delisted symbols);
   * there are ≥ `InpMinCoverPct` daily bars compared with the best symbol (drops patchy history);
   * M1 bars exist at the start, and real ticks on the first and last day.
3. Optional filters: FULL trade mode only, minimum price, ADR % band, top-N by average traded value. Real volume is used where the broker supplies it, otherwise tick volume as a proxy.
4. Shows the passing symbols in Market Watch and hides the rest. Then writes `MQL5\Files\BB_symbol_check.csv` (every symbol and its pass/fail reason) and `BB_symbols.txt`.

It can take a while for ~1,500 candidates, because each one's history is downloaded; progress shows in the chart corner. Save the result as a Market Watch set (right-click → Sets → Save as) so you don't have to run it every time.

## Testing checklist
1. Same machine, same dates, same `.set` file, same modelling ("Every tick based on real ticks" for final checks).
2. Run `BB_SymbolSelector` first, with the **same dates** as the test.
3. If a ticker still differs between machines, delete that machine's `Tester\Agent-*\bases\<server>\history\<symbol>` and `ticks\<symbol>` folders and re-run. They are rebuilt from the terminal's data.
4. After a Market Watch optimisation, sort `BB_optim_diag.csv` by verdict. `NO_DATA` / `TRADE_REJECTED` rows are data or broker problems, not strategy results.
5. Watch free disk space: each agent keeps its own copy of the tick history. Fewer agents means less disk.

---

# v2.2: strategy-improvement features and staged optimisation

## New EA features (v2.20)
| Input | What it does |
|---|---|
| `InpTrendMode` | `TREND_MA`: only breakouts in the direction of the symbol's daily close vs its `InpTrendMAPeriod`-day MA. `TREND_INDEX`: only breakouts in the direction the index (`InpTrendIndex`, e.g. US500) is trading vs its previous daily close, at the moment of the breakout. `TREND_BOTH`: both must agree. Breakouts against the trend are skipped (diagnostic `trend_skip`), and a later breakout the other way can still trade. The index symbol must be in Market Watch. |
| `InpMaxHoldMins` | Closes a trade after x minutes. The video says trades normally last 1–2 h. |
| `InpPartialR` / `InpPartialPct` | At x R, closes that % of the position and moves the stop to entry. If the lot is too small to split, it only moves the stop. |
| Results per pattern/direction | The stats files now have `hammer_long / hammer_short / engulf_long / engulf_short` columns (trades, win %, net, PF), plus a **TOTAL** row for basket runs. `trades` now counts positions, so a partial close counts as one trade. |

## The .set files (`sets/` folder)
Copy them to `MQL5\Profiles\Tester\`. In the Strategy Tester's *Inputs* tab, right-click → **Load**. All of them use the basket from `BB_symbols.txt` (`InpSymbolsFromFile = true`). For the custom score (*Custom max* criterion), a result needs at least 300 trades.

| File | Type | What to look at |
|---|---|---|
| `BB_Stage1a_Baseline.set` | Single test, Jan–Jun | TOTAL row and the four pattern/direction columns in `BB_symbol_stats.csv`. Which part is losing? |
| `BB_Stage1b_RR1.set` | Single test, Jan–Jun, 1R target | Win rate well below 50% means the entry has no edge. Around 50% or more means work on exits |
| `BB_Stage2_StopTarget.set` | Genetic, 3,600 combos | Stop mode/buffer/minimum, RR, breakeven, partial, time exit |
| `BB_Stage3_Entry.set` | Genetic, ~124k combos | Hammer/engulfing entry modes, prior move, retest tolerance/penetration, breakout buffer, entry window, gap mode, **trend filter** |
| `BB_Stage4_DayFilters.set` | Full search, 36 combos | Previous-range/ATR and gap/ATR filters |

Procedure:
1. Optimise on **Jan–Jun** with *1 minute OHLC*, genetic, *Custom max*.
2. Look for an area of good results, not the single best pass. Pick values that are good across their neighbours.
3. Re-run the top 3–5 sets on **Jul–Oct** with *Every tick based on real ticks*, **without changing anything**.
4. Carry the winners forward. Stages 3 and 4 say at the top which values to set first.
5. Success means PF ≥ 1.2 in-sample, ≥ 1.1 out-of-sample, on 300+ trades. At 2R the strategy needs a win rate above about 36% after costs.

## v2.3: R-multiples and fixed-risk sizing
* **`InpRiskBase`**: `RISK_EQUITY` sizes from current equity (compounds; use for live). `RISK_START_BALANCE` risks the same $ amount on every trade (use for tests, so a drawdown doesn't shrink later trades). All `.set` files now use the starting balance.
* **R-multiples.** Each trade's money at risk is recorded at entry, and every result is also reported as profit ÷ initial risk.
  * New columns `sum_R` and `exp_R` (expectancy = average R per trade), plus `<pattern>_expR` for each of the four buckets.
  * R doesn't depend on deposit, lot rounding or broker lot caps.
  * `exp_R > 0` after costs is the real test of the edge. Roughly, +0.10R per trade on 300+ trades is worth pursuing.

## Findings to date (Jan–Oct 2026, 54 large-cap US stock CFDs, IC Markets)
| Test | Result |
|---|---|
| 1R target, normal / wide stop | 43.7% / 47.7% wins: a coin flip or worse |
| Stage 2 (141 exit combinations) | Best −0.03R; only the minimum-stop width mattered (costs), nothing positive |
| Stage 2b (stops 45–85%) | Flat at about −0.03R |
| In-sample shorts (Jan–Jun) | +0.08R |
| **Out-of-sample Jul–Oct** | **−0.18R overall; shorts −0.25R, longs −0.14R** |

Conclusion: the rules as specified show no edge. The full Stage 3 and Stage 4 optimisations were stopped to avoid fitting noise. Two final fixed tests remain:
`BB_Final_TrendFilter_JanOct.set` and `BB_Final_Indices_2023.set`. If neither reaches +0.10R across the whole period, drop the strategy in this form.
