# NQ Portfolio EA: build and test guide

Files:
| File | What it is |
|---|---|
| `NQ_Portfolio_EA.mq5` | The EA: S1 Vault Break, S2 VWAP Pullback + ADX, S3 Overnight Bias ORB, S4 Drift VWAP Pullback |
| `monte_carlo.py` | Reads the EA's trade log and simulates prop challenges plus benching yardsticks |
| `../EA_Strategy_Spec_v1.md` | The signed-off spec (v1.1) the code implements |

---

## Step 1: Compile
1. In MT5: **File → Open Data Folder → MQL5 → Experts**, and copy `NQ_Portfolio_EA.mq5` there.
2. Open it in MetaEditor and press **F7 (Compile)**.
3. Send me the full **Errors** tab, including warnings. The EA was written without access to a compiler, so expect a few fixes.

## Step 2: Research backtests (one strategy at a time first)

Strategy Tester settings:
| Setting | Value |
|---|---|
| Expert | NQ_Portfolio_EA |
| Symbol | USTEC |
| Timeframe | M1 (the chart timeframe doesn't affect the logic) |
| Modelling | **Every tick based on real ticks** |
| Dates | 2022.01.01 → latest (or the earliest date with real ticks) |
| Deposit | 100,000 (account currency) |
| Delays | Zero latency (we'll add delays later) |

Inputs for every research run:
- `InpProfile = PROFILE_RESEARCH` (no floor or target, so it trades the whole period)
- `InpSizing = SIZE_FIXED_LOTS`, with each strategy's `FixedLots = 1.0` (1 lot = $1 per point)
- Enable **only** the strategy you are testing
- Set `InpRunTag` so the run gets its own CSV (e.g. `S1_base`)

| Run tag | Enabled | Change from defaults |
|---|---|---|
| S1_base | S1 | none |
| S1_1030 | S1 | `InpS1_WindowStartCT = 1030` |
| S1_TR | S1 | `InpADRMode = ADR_SMA_OF_TR` |
| S1_2300 | S1 | `InpS1_AnchorCT = 2300` |
| S1_1loss | S1 | `InpS1_MaxLosses = 1` |
| S1_adr | S1 | `InpS1_ScaleWithADR = true` (RefADR 324) |
| S1_1loss_adr | S1 | both of the above |
| S1_sess | S1 | `InpADRUseSession = true` (daily range from 00:00–16:00 CT only) |
| S2_base | S2 | none |
| S2_vw0 | S2 | `InpS2_VWAPAnchorCT = 0` |
| S2_1555 | S2 | `InpS2_ExitCT = 1555` |
| S2_2tr | S2 | `InpS2_MaxTrades = 2` |
| S2_recalc | S2 | `InpS2_TPMode = S2TP_RECALC` |
| S3_base | S3 | none |
| S3_2300 | S3 | `InpS3_ONStartCT = 2300` |
| S3_1430 | S3 | `InpS3_CutoffCT = 1430` |
| S3_sess | S3 | `InpADRUseSession = true` |
| S2_pretouch | S2 | `InpS2_TPMode = S2TP_PRETOUCH` |
| S2_swing | S2 | `InpS2_TPMode = S2TP_SWING` |
| S4_base | S4 | none |
| S4_consec | S4 | `InpS4_LossRule = S4LOSS_CONSECUTIVE` |
| S4_long | S4 | `InpS4_AllowShort = false` |
| S4_long_adr | S4 | `InpS4_AllowShort = false`, `InpS4_ScaleWithADR = true` |
| S4_long_1loss | S4 | `InpS4_AllowShort = false`, `InpS4_MaxLosses = 1` |
| ALL | all four | none |

Each run writes to the **common** files folder (`%APPDATA%\MetaQuotes\Terminal\Common\Files`):
- `NQPortfolio_<tag>_trades.csv`: one row per trade (strategy, times, points, risk points, R, profit, exit reason)
- `NQPortfolio_<tag>_adr.csv`: the daily range used each day

**Send me:** the CSV files, plus a screenshot of each run's Backtest summary. Start with the four `_base` runs. We'll compare them with the MultiCharts figures before running the variants.

The journal prints every signal and every skipped trade (`SKIP: spread…`, `SKIP: stops too close…`). If a strategy trades much less than expected, search the journal for `SKIP`.

## Step 3: Monte Carlo
```
pip install numpy pandas
python monte_carlo.py NQPortfolio_ALL_trades.csv
python monte_carlo.py NQPortfolio_ALL_trades.csv --strategies S1,S3,S4 --risk 0.1,0.2,0.3
python monte_carlo.py NQPortfolio_ALL_trades.csv --weights S3=1.5,S4=0.5
```
It reports P(pass) and P(fail) for each risk level against the +7% target and the −5% static floor, plus the 75th-percentile drawdown yardstick used for benching.

## Step 4: Final line-up and live settings (v1.2)
The defaults are now the final line-up: **S3 (core) + S1 (support)**. S2 and S4 are off. S3 uses a 0.40 × ADR stop, and S1 stops for the day after its first loss.

**PROP**
- `Account profile` = PROFILE_PROP, `Position sizing mode` = SIZE_RISK_PCT
- Defaults: S1 0.25% and S3 0.50% per trade. Use 0.35% / 0.70% for faster passes with a higher chance of failing (see spec section 8.3)
- The EA halts at +7% (target) or at −4.5% (floor plus buffer). It refuses any trade that, if every open stop were hit, would breach the floor.

**LIVE (own capital)**
- `Account profile` = PROFILE_LIVE
- **"LIVE: halt if equity falls this % from its high"** = 20. The EA tracks your equity high (saved across restarts) and closes everything and halts if equity drops 20% below it. The pre-trade check stops any trade that could breach it.
- Suggested risk: S1 0.6% / S3 1.2% (spec section 8.3). On £1,000 the minimum lot decides for you: use `Position sizing mode` = SIZE_FIXED_LOTS with 0.1 lots on each (≈0.6% / ≈1.0% risk).
- To restart after a halt: set `Clear a previous halt on start` = true once. This also restarts the trailing high from current equity.

**Restarts:** the halt flag, initial balance and equity high are kept in MT5 global variables (F3). For a new prop challenge on the same login, set `Clear a previous halt on start` = true and set `Initial balance` to the new starting balance.

## Multi-market (v1.20)
Attach **one copy of the EA per market**, each on its own chart, and choose **"Market preset"** in the General group. The preset sets the market's session times in its own time zone, with its own daylight-saving dates. It also scales S1's exits, the spread filter and the minimum sizing distance to that market's daily range. The time inputs in the S1 and S3 groups are only used with the **USTEC / custom** setting.

| Preset | Time zone | S3 overnight range → open | S3 last entry / exit | S1 window (exit) | Magic offset |
|---|---|---|---|---|---|
| USTEC / custom | your inputs (default US Central) | 00:00 → 08:30 | 14:00 / 14:30 | 10:00–14:30 | 0 |
| US500, US30 | US Central | 00:00 → 08:30 | 14:00 / 14:30 | 10:00–14:30 | 100 / 200 |
| DE40 | Frankfurt | 00:00 → 09:00 | 16:30 / 17:00 | 10:30–17:00 | 300 |
| XAUUSD (New York) | US Central | 00:00 → 07:30 | 12:00 / 12:30 | 09:00–12:30 | 400 |
| XAUUSD (London) | London | 00:00 → 08:00 | 16:00 / 16:30 | 09:30–16:30 | 500 |
| JP225 (experimental) | Tokyo | 07:00 → 09:00 | 14:30 / 15:00 | 10:30–15:00 | 600 |
| JP225 (full overnight) | Tokyo | previous day 15:30 → 09:00 | 14:30 / 15:00 | 10:30–15:00 | 700 |

- **One floor for the whole account:** the floor, target and pre-trade risk checks count open positions on **all symbols**, and a halt on one chart halts every chart on the same login.
- **Holidays:** only the US calendar is built in, so it applies to US-time presets only.
- **S2 and S4** run only with the USTEC / custom setting.
- **JP225 is experimental:** the server day starts around 07:00 Tokyo time, so its "overnight" range only covers the reaction to the US session.

**Research runs** (same tester settings as before: RESEARCH profile, fixed 1.0 lot, 2022.01.01 → 2026.09.25). One run per market, S1 + S3 enabled:

| Tag | Symbol | Market preset |
|---|---|---|
| `DE40_base` | DE40 | DE40 |
| `XAU_ny` | XAUUSD | XAUUSD (New York) |
| `XAU_ldn` | XAUUSD | XAUUSD (London) |
| `US500_base` | US500 | US500 |
| `US30_base` | US30 | US30 |
| `JP225_base` | JP225 | JP225 |

The Monte Carlo script names each stream `strategy@symbol` when the files contain several markets. Use `--cost-risk-pct 1` as the cost stress (1% of each trade's stop distance), because a fixed `--cost 1` point means different things on gold and on indices:
```
python monte_carlo.py NQPortfolio_S1_1loss_trades.csv NQPortfolio_S3_sl040_trades.csv NQPortfolio_DE40_base_trades.csv --cost-risk-pct 1
```

## Safety inputs (added in review)
- `InpMinSizingPts = 10`: in risk-% mode, the lot size is calculated as if the stop were at least 10 points away. This stops S2's sometimes very tight 20-bar-low stop from producing an oversized position. It does not move the stop itself.
- `InpSessionEndBufMin = 5`: every open position is closed 5 minutes before the broker's last trading session of the day ends. This protects against Fridays and shortened sessions, where a 15:55 CT exit could otherwise be held over the weekend.

## Known limits
- VWAP uses **tick volume** (CFDs have no real volume), so it is an approximation of the futures VWAP.
- Times assume the broker changes clocks on **US dates**, so server time = CT + 8 h (`InpServerMinusCT`). Your check of the 16:30 volume spike confirmed this.
- US holidays and early-close days are skipped by a built-in calendar (`InpSkipHolidays`).
