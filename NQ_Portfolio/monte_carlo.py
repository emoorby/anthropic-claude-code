#!/usr/bin/env python3
"""
Monte Carlo analysis for NQ_Portfolio_EA trade logs.

What it does
  1. Summary per strategy (to compare with the MultiCharts reports).
  2. Prop-challenge simulation: for a grid of risk-per-trade levels, the chance of
     reaching the profit target before the static floor, and how long it takes.
     Days are resampled in blocks (default 5 trading days) so losing streaks
     and same-day overlap between strategies are preserved.
  3. Benching yardsticks: per strategy, the distribution of maximum drawdown (in R)
     and where the current drawdown sits in it (75th percentile = bench signal).

Usage
  python monte_carlo.py NQPortfolio_trades.csv
  python monte_carlo.py a.csv b.csv --strategies S1,S3,S4 --risk 0.1,0.2,0.3
  python monte_carlo.py trades.csv --weights S3=1.5,S4=0.5 --floor 5 --target 7
  python monte_carlo.py trades.csv --cost 1.0     # deduct 1 extra point per trade

Notes
  * Risk is % of current balance per trade, as the EA does in RISK_PCT mode.
  * R = points / risk_points, so results do not depend on the lot size used in the backtest.
  * Intraday path is approximated by the order of trade closes; open-trade (floating)
    drawdown beyond the stop is not modelled. Lot rounding is not modelled (assumes a
    large enough account).
"""
import argparse

import numpy as np
import pandas as pd

TIME_FMT = "%Y.%m.%d %H:%M:%S"


def load_trades(paths, cost_pts=0.0):
    df = pd.concat([pd.read_csv(p) for p in paths], ignore_index=True)
    df.columns = [c.strip() for c in df.columns]
    df["open_time"] = pd.to_datetime(df["open_time"], format=TIME_FMT)
    df["close_time"] = pd.to_datetime(df["close_time"], format=TIME_FMT)
    df["day"] = df["close_time"].dt.normalize()
    df = df[df["risk_points"] > 0].copy()
    df["points"] = df["points"] - cost_pts      # extra cost stress (slippage etc.)
    df["R"] = df["points"] / df["risk_points"]
    return df.sort_values("close_time").reset_index(drop=True)


def max_consecutive(mask):
    best = cur = 0
    for m in mask:
        cur = cur + 1 if m else 0
        best = max(best, cur)
    return best


def max_drawdown(cum):
    peak = np.maximum.accumulate(np.concatenate([[0.0], cum]))[1:]
    return float((peak - cum).max()) if len(cum) else 0.0


def summarize(df):
    rows = []
    for s, g in df.groupby("strategy"):
        pts = g["points"].to_numpy()
        R = g["R"].to_numpy()
        win, loss = pts > 0, pts < 0
        gp, gl = pts[win].sum(), -pts[loss].sum()
        avg_w = pts[win].mean() if win.any() else 0.0
        avg_l = -pts[loss].mean() if loss.any() else 0.0
        rows.append({
            "strategy": s,
            "trades": len(g),
            "long/short": f"{(g['direction'] == 'long').sum()}/{(g['direction'] == 'short').sum()}",
            "win%": 100 * win.mean(),
            "avg_pts": pts.mean(),
            "avg_win_pts": avg_w,
            "avg_loss_pts": avg_l,
            "breakeven_win%": 100 * avg_l / (avg_w + avg_l) if (avg_w + avg_l) > 0 else np.nan,
            "profit_factor": gp / gl if gl > 0 else np.inf,
            "avg_R": R.mean(),
            "total_R": R.sum(),
            "max_dd_R": max_drawdown(np.cumsum(R)),
            "max_consec_losses": max_consecutive(loss),
            "profit_ccy": g["profit"].sum(),
        })
    return pd.DataFrame(rows)


def build_days(df, strategies):
    days = pd.bdate_range(df["day"].min(), df["day"].max())
    pos = {d: i for i, d in enumerate(days)}
    per_day = [[] for _ in days]
    for row in df[df["strategy"].isin(strategies)].itertuples():
        i = pos.get(row.day)
        if i is not None:
            per_day[i].append((row.strategy, row.R))
    return days, per_day


def day_arrays(per_day, risk_by_strat):
    n = len(per_day)
    ret, lo, hi = np.zeros(n), np.zeros(n), np.zeros(n)
    for i, trades in enumerate(per_day):
        c = mn = mx = 0.0
        for s, R in trades:
            c += risk_by_strat.get(s, 0.0) / 100.0 * R
            mn, mx = min(mn, c), max(mx, c)
        ret[i], lo[i], hi[i] = c, mn, mx
    return ret, lo, hi


def simulate(ret, lo, hi, floor_pct, buffer_pct, target_pct, sims, max_days, block, rng, chunk=2000):
    n = len(ret)
    block = max(1, min(block, n))
    stop_level = 1.0 - (floor_pct - buffer_pct) / 100.0
    target = 1.0 + target_pct / 100.0 if target_pct > 0 else np.inf
    big = max_days + 1
    passed = failed = 0
    days_to_pass = []
    done = 0
    while done < sims:
        m = min(chunk, sims - done)
        nblocks = int(np.ceil(max_days / block))
        starts = rng.integers(0, n - block + 1, size=(m, nblocks))
        idx = (starts[:, :, None] + np.arange(block)[None, None, :]).reshape(m, -1)[:, :max_days]
        r, l, h = ret[idx], lo[idx], hi[idx]
        eq_after = np.cumprod(1.0 + r, axis=1)
        eq_before = np.concatenate([np.ones((m, 1)), eq_after[:, :-1]], axis=1)
        fail = eq_before * (1.0 + l) <= stop_level
        win = eq_before * (1.0 + h) >= target
        ff = np.where(fail.any(axis=1), fail.argmax(axis=1), big)
        fw = np.where(win.any(axis=1), win.argmax(axis=1), big)
        p = fw < ff                      # same day: counted as a fail (conservative)
        f = (ff <= fw) & (ff < big)
        passed += int(p.sum())
        failed += int(f.sum())
        days_to_pass.extend((fw[p] + 1).tolist())
        done += m
    dtp = np.array(days_to_pass) if days_to_pass else np.array([np.nan])
    return passed / sims, failed / sims, 1 - (passed + failed) / sims, dtp


def bench_yardsticks(df, sims, rng):
    rows = []
    for s, g in df.groupby("strategy"):
        R = g["R"].to_numpy()
        n = len(R)
        if n < 10:
            continue
        samples = rng.choice(R, size=(sims, n), replace=True)
        cum = np.cumsum(samples, axis=1)
        peak = np.maximum.accumulate(np.concatenate([np.zeros((sims, 1)), cum], axis=1), axis=1)[:, 1:]
        dd = (peak - cum).max(axis=1)
        actual = np.cumsum(R)
        current_dd = float(np.maximum.accumulate(np.concatenate([[0.0], actual]))[-1] - actual[-1])
        rows.append({
            "strategy": s,
            "trades": n,
            "maxDD_R_p50": np.percentile(dd, 50),
            "maxDD_R_p75 (bench)": np.percentile(dd, 75),
            "maxDD_R_p95": np.percentile(dd, 95),
            "historical_maxDD_R": max_drawdown(actual),
            "current_DD_R": current_dd,
            "current_DD_percentile": 100 * (dd < current_dd).mean(),
        })
    return pd.DataFrame(rows)


def parse_weights(text):
    w = {}
    if text:
        for part in text.split(","):
            k, v = part.split("=")
            w[k.strip()] = float(v)
    return w


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+", help="trade log CSV file(s) exported by the EA")
    ap.add_argument("--strategies", default="S1,S2,S3,S4")
    ap.add_argument("--risk", default="0.1,0.15,0.2,0.25,0.3,0.4,0.5,0.75,1.0",
                    help="risk %% per trade levels to test")
    ap.add_argument("--weights", default="", help="per-strategy multipliers, e.g. S3=1.5,S4=0.5")
    ap.add_argument("--floor", type=float, default=5.0, help="static floor %% below initial balance")
    ap.add_argument("--buffer", type=float, default=0.5, help="EA halts this %% above the floor")
    ap.add_argument("--target", type=float, default=7.0, help="profit target %% (0 = none)")
    ap.add_argument("--sims", type=int, default=10000)
    ap.add_argument("--max-days", type=int, default=250, help="trading days per simulated challenge")
    ap.add_argument("--block", type=int, default=5, help="block length (days) for the bootstrap")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--cost", type=float, default=0.0,
                    help="extra cost in index points deducted from every trade (stress test)")
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    strategies = [s.strip() for s in a.strategies.split(",") if s.strip()]
    weights = parse_weights(a.weights)
    df = load_trades(a.csv, a.cost)
    df = df[df["strategy"].isin(strategies)]
    if df.empty:
        raise SystemExit("No trades for the selected strategies.")

    pd.set_option("display.width", 200)
    pd.set_option("display.float_format", lambda x: f"{x:,.2f}")

    print("\n=== Strategy summary (points are index points) ===")
    print(summarize(df).to_string(index=False))

    days, per_day = build_days(df, strategies)
    print(f"\nPeriod {days[0].date()} -> {days[-1].date()}  ({len(days)} weekdays)")

    print(f"\n=== Prop simulation: target +{a.target}% before floor -{a.floor}% "
          f"(EA stops at -{a.floor - a.buffer}%), {a.sims} runs, max {a.max_days} days, "
          f"block {a.block} days ===")
    rows = []
    for rk in [float(x) for x in a.risk.split(",")]:
        risk_by = {s: rk * weights.get(s, 1.0) for s in strategies}
        ret, lo, hi = day_arrays(per_day, risk_by)
        p, f, u, dtp = simulate(ret, lo, hi, a.floor, a.buffer, a.target, a.sims, a.max_days, a.block, rng)
        rows.append({
            "risk%/trade": rk,
            "P(pass)%": 100 * p,
            "P(fail)%": 100 * f,
            "P(unresolved)%": 100 * u,
            "days_to_pass_median": np.nanmedian(dtp),
            "days_to_pass_p90": np.nanpercentile(dtp, 90),
            "worst_hist_day%": 100 * lo.min(),
        })
    print(pd.DataFrame(rows).to_string(index=False))

    print("\n=== Benching yardsticks (bootstrap of each strategy's own trades, R units) ===")
    print(bench_yardsticks(df, min(a.sims, 5000), rng).to_string(index=False))


if __name__ == "__main__":
    main()
