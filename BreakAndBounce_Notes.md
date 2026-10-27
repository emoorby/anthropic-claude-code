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
