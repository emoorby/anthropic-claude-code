# NasdaqFairPrice EA (MQL5)

An Expert Adviser for the Nasdaq 100 CFD (IC Markets `USTEC`, Vantage `NAS100`) on M1, built from the "fair pricing theory" New York open strategy.

> Not yet compiled or backtested. Compile in MetaEditor and fix anything it reports before running it.

## Files

| File | Where it goes |
|---|---|
| `NasdaqFairPrice.mq5` | `MQL5\Experts\` in your MT5 data folder. Compile in MetaEditor. |
| `NasdaqFairPrice_NewsExport.mq5` | `MQL5\Scripts\`. Run it once to fill the news CSV (see below). |
| `NasdaqFairPrice_news.csv` | Template only. The export script writes the real file to `Terminal\Common\Files\`, the shared folder the Strategy Tester can read. |

The trade log is written to `Terminal\Common\Files\NasdaqFairPrice_log_<symbol>.csv`.

## The strategy as coded

All times are **New York time**. All distances are **index points** (1.0 = one Nasdaq point), not MT5 `_Point`.

1. **Fair price** = open of the M1 candle at `InpFairPriceTime` (default 09:30). Set it earlier, e.g. 08:30 or 09:00, to anchor fair price to the pre-market price on every day. This only changes the level: reversion trading still starts at 09:35 on normal days, and the 09:30 continuation is unchanged. On news days the news release price takes priority.
2. **Continuation (09:30 candle only).** When the 09:30 candle closes, enter in its colour.
   - Body ≤ 25 pts: SL 25 / TP 38.
   - Body > 25 pts: SL 50 / TP 76.
3. **Reversion (09:35–11:00).** Only toward fair price: shorts while the last close is above it, longs while below. The direction flips if price crosses fair price. A signal is either:
   - **Displacement**: candle toward fair price whose body is larger than the previous candle's body. It must also meet a minimum body size and a minimum body/range ratio, which rejects "all four directions" candles. Optional extras:
     - It must close beyond the previous candle's wick.
     - Up to N same-colour candles can be combined against one opposing candle (off by default).
   - **Break of structure**: candle toward fair price that **closes** beyond an unbroken swing low or high. A swing point is a fractal with `InpSwingStrength` bars each side.
4. Each reversion trade uses SL 25 / TP 38, set from the actual fill price.
5. Reversion trades are skipped when the distance to fair price is less than the TP.
6. **Layering:** a second position in the same direction is allowed only on a break of structure, up to the open-position cap.
7. From 11:00, no new entries. Open trades run to their SL or TP unless *Close open trades at session end* is on.

### News mode (CSV)

If the CSV has an event between `InpNewsModeEarliest` (08:00) and 09:30 on a day, e.g. CPI at 08:30:
- Fair price = the price at the release (the open of the 08:30 candle).
- Reversion trading starts at the release, using the same rules.
- After 09:30 the pre-news fair price is kept (`InpNewsKeepFairPrice`).
- The 09:30 continuation is taken only if it points toward that fair price (`InpNewsContMode`).

Events at or after 09:30 do nothing unless `InpNewsBlackout` is on. Then entries are blocked for a few minutes either side of the event.

**Filling the CSV:**
1. Compile `NasdaqFairPrice_NewsExport.mq5`.
2. In a live or demo terminal (not the tester), drag it onto any chart and set the date range.
3. It reads MT5's built-in economic calendar and writes `Common\Files\NasdaqFairPrice_news.csv`:
   - high-impact USD events only;
   - converted to New York time;
   - events at the same time merged into one line;
   - past events with no actual value (e.g. the cancelled October 2025 CPI) skipped.
4. The Experts tab lists every event name it included. Use the *Exclude* input to drop any you don't want, e.g. `Jobless Claims`. Weekly claims would otherwise make every Thursday a news day.
5. Re-run it every month or so to add upcoming events for live trading.

CSV format: `date,time,label`, e.g. `2026-03-11,08:30,CPI`. Times are in New York time. Lines starting with `#` are ignored.

## Defaults and why

| Setting | Default | Reason |
|---|---|---|
| Risk per trade | 0.5% of balance | Your choice |
| Max trades per day | 5 | 5 full losses = 2.5%, inside a typical 5% daily limit |
| Max open positions | 3 | Allows layering; worst case 1.5% at risk at once |
| Setups | Displacement and BOS | Your choice (his prop-firm approach) |
| Close beyond wick | Off | He takes trades both with and without it |
| Combine candles | 1 (off) | Discretionary in the video; test 2–3 separately |
| Daily loss guard | 3% (equity) | Placeholder until prop-firm rules are confirmed |
| Max drawdown guard | Off | Placeholder until prop-firm rules are confirmed |
| Max spread | 3 pts | Skips entries when spreads blow out at the open or on news |

## Broker time

`Server = New York + 7h` is correct for brokers whose server runs GMT+2 in winter and GMT+3 in US summer, which is the usual setup at IC Markets and Vantage. When the EA starts, it prints the server time of today's 09:30 NY candle. **Check that this matches your chart** (it should be 16:30 server time). Otherwise switch the time model.

## Trend-day protection

On trend days price never returns to fair price, and fading it loses trade after trade. In the first backtest (Sep–Oct 2026) this produced a 20-loss streak and several days with no wins. There are two options, which can be used separately or together:

**A. Direction stop** (`InpDirStopLosses`, default 1). After N losing trades in one direction today, the EA takes no more trades in that direction. The other direction is still allowed if price crosses fair price. 0 turns it off.

**B. Fair price reset** (`InpUseFPReset`, default off). This is the transcript's rule: when price moves away, consolidates, then breaks further away, the old fair price is no longer fair. A reset happens when all of these are true:
- the last `InpConsolBars` (10) candles sit in a range of `InpConsolMaxRange` (25 pts) or less;
- that range is entirely on one side of fair price and at least `InpResetMinDist` (38 pts) from it;
- a candle then closes out of the range, further away from fair price.

Fair price then moves to the middle of that range, at most `InpMaxFPResets` times a day. Each move is logged as `FP_RESET` and drawn as a new line.

With both on, `InpDirStopResetOnFP` clears the direction stops when fair price moves, because the old losses were against the old level.

Test these four runs over the same period and compare:

| Run | `InpDirStopLosses` | `InpUseFPReset` |
|---|---|---|
| Baseline | 0 | false |
| A | 1 (then try 2) | false |
| B | 0 | true |
| A + B | 1 | true |

The settings for B (10 bars, 25 pts) are first guesses. Optimise them only on part of your data, then check the result on a period they were not tuned on.

## Backtesting

- Model: **Every tick based on real ticks**, on the broker you will trade.
- Commission: set `InpCommissionPerLot` if your account charges it on indices, so sizing includes it.
- Use the log CSV to compare signal types (`CONT`, `DISP`, `BOS`, `BOS+DISP`) and skip reasons.
- US market holidays and half days are not filtered. Add them to a later version if they hurt results.

## Not implemented (by design for v1)

- Discretionary trades: Trump tweets, "pick a different account for this many points", copy trading.
- Breakeven moves, apart from the optional *close continuation on opposite BOS*.
- Firm-specific prop rules (consistency, minimum hold time, trailing drawdown). To be added once the firm is chosen.
