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

## Step 4: Prop / live settings (after testing)
**PROP**
- `InpProfile = PROFILE_PROP`, `InpSizing = SIZE_RISK_PCT`
- Risk % per strategy taken from the Monte Carlo
- The EA halts at +7% (target) or at −4.5% (floor plus buffer). It also refuses any trade that, if every open stop were hit, would breach the floor.

**LIVE (£1,000)**
- `InpProfile = PROFILE_LIVE`, S3 only, `InpSizing = SIZE_FIXED_LOTS`, `InpS3_FixedLots = 0.1`
- Floor at 20% (`InpLiveFloorPct`)

**Restarts:** the halt flag and initial balance are kept in MT5 global variables (F3). For a new challenge on the same login, set `InpResetHalt = true` and set `InpInitialBalance` to the new starting balance.

## Safety inputs (added in review)
- `InpMinSizingPts = 10`: in risk-% mode, the lot size is calculated as if the stop were at least 10 points away. This stops S2's sometimes very tight 20-bar-low stop from producing an oversized position. It does not move the stop itself.
- `InpSessionEndBufMin = 5`: every open position is closed 5 minutes before the broker's last trading session of the day ends. This protects against Fridays and shortened sessions, where a 15:55 CT exit could otherwise be held over the weekend.

## Known limits
- VWAP uses **tick volume** (CFDs have no real volume), so it is an approximation of the futures VWAP.
- Times assume the broker changes clocks on **US dates**, so server time = CT + 8 h (`InpServerMinusCT`). Your check of the 16:30 volume spike confirmed this.
- US holidays and early-close days are skipped by a built-in calendar (`InpSkipHolidays`).
