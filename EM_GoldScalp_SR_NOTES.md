# EM_GoldScalp_SR — notes

A rebuild of the **Ultimate Breakout System V7.4** "Breakout Support/Resistance" strategy,
set up the way `EM_ScalpH1_C.set` configures it (XAUUSD, H1 chart).
It has 30 inputs instead of about 200.

## Rules, worked out from the original EA's tester orders and Pepperstone M1 data

1 pip = 0.01 in price, so 300 pips = $3.00.

- **When it checks:** on the first tick of every new M5 bar, and only when no position is open (at most one trade at a time).
- **Swing level:** an H1 bar whose high is above the 20 bars before it and above every closed bar since, looking back up to 50 bars. Swing lows work the same way in reverse. A swing is no longer valid once price trades through it, including during the H1 bar that is still forming.
- **Which swing is used:** the **most recent** valid swing that is at least $20 (2000 pips) from the current bid.
- **Entry price:** a buy stop $2 *below* the swing high, or a sell stop $2 *above* the swing low (offset −200 pips).
- **Pending orders:** at most one per side. An existing order is replaced only when a *newer* swing qualifies. The new order is placed first, then the old one is deleted. Pending orders expire after 205 hours.
- **Exits:**
  - The SL ($3) and TP ($10) are attached to the pending order.
  - The trailing stop starts when the trade is $0.80 in profit, trails $0.80 behind price, and is checked on every tick.
  - The EA also keeps its own copy of the stop, based on the actual fill price. If price crosses it before the broker's stop does, the EA closes the trade at market.
- **NFP filter:** NFP is treated as 15:30 server time. From 50 minutes before until 30 minutes after, pending orders are deleted, open trades are closed and no new orders are placed.

**How well it matches:** 133 of 133 pending orders from July to October 2026 (OHLC report), with no extra or missing orders. All 176 cancellations in both reports are explained by replacement, NFP or the end of the test.

## NFP dates

- **Live chart:** the EA reads US Nonfarm Payrolls dates from the MQL5 calendar and caches them to `Common\Files\EM_NFP_Dates.csv`.
- **Strategy Tester:** it reads that cache. Attach the EA to any live XAUUSD chart once before backtesting. Note that MQL5 Cloud agents cannot see the Common folder; local agents can.
- **No cache:** it falls back to the first Friday of each month. That is wrong for dates such as 9 Jan 2026 and 2 Jul 2026.

## Removed from the original

- Licence and web addresses, info panel, auto-loader, backtest-speed setting, spread filter (it was off)
- Range Breakout and Volatility Breakout entries (not used: `Run_Strategy` = Support/Resistance), retest entry model
- Virtual stops (OFF in the set), Variable Values (0), Grid, Prop Firm settings, fake-breakout filters, trading hours
- Interest-rate and CPI filters, break-even, trailing TP, high/low trailing, time-based trailing, MagicTrail (all off)
- Lot-sizing modes other than fixed lots, and AutoGMT/WebRequest (replaced by the calendar cache)
