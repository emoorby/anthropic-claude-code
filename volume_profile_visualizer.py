"""
Volume Profile Visualizer
Reads CSV exports from OrderFlow_VWAP_EA and plots daily volume profiles
with Price on Y-axis and Volume on X-axis.

Usage:
    python volume_profile_visualizer.py [csv_folder]

Default folder: looks in MT5 common data folder under OrderFlow/
"""

import sys
import os
import glob
import re
from pathlib import Path

try:
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
    HAS_PLOTLY = True
except ImportError:
    HAS_PLOTLY = False

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.ticker import MaxNLocator
import numpy as np


NODE_COLORS = {
    'POC':    {'plotly': '#FFD700', 'mpl': '#FFD700'},
    'HVN':    {'plotly': '#1E90FF', 'mpl': '#1E90FF'},
    'LVN':    {'plotly': '#FF4500', 'mpl': '#FF4500'},
    'VA':     {'plotly': '#708090', 'mpl': '#708090'},
    'Normal': {'plotly': '#A9A9A9', 'mpl': '#A9A9A9'},
}


def find_csv_folder():
    """Try to locate the MT5 common data folder."""
    candidates = []

    if sys.platform == 'win32':
        appdata = os.environ.get('APPDATA', '')
        if appdata:
            base = Path(appdata) / 'MetaQuotes' / 'Terminal' / 'Common' / 'Files' / 'OrderFlow'
            candidates.append(base)

    candidates.append(Path('.') / 'OrderFlow')
    candidates.append(Path('.'))

    for c in candidates:
        if c.exists():
            csvs = list(c.glob('*_profile.csv'))
            if csvs:
                return str(c)

    return '.'


def parse_profile_csv(filepath):
    """Parse a volume profile CSV exported by the EA."""
    metadata = {}
    levels = []

    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if line.startswith('# '):
                match = re.match(r'#\s*(\w+):\s*(.+)', line)
                if match:
                    metadata[match.group(1)] = match.group(2).strip()
                continue

            if line.startswith('PriceLevel'):
                continue

            parts = line.split(',')
            if len(parts) >= 7:
                try:
                    levels.append({
                        'price':      float(parts[0]),
                        'total_vol':  float(parts[1]),
                        'buy_vol':    float(parts[2]),
                        'sell_vol':   float(parts[3]),
                        'delta':      float(parts[4]),
                        'smoothed':   float(parts[5]),
                        'node_type':  parts[6].strip(),
                    })
                except ValueError:
                    continue

    return metadata, levels


def load_all_profiles(folder):
    """Load all profile CSVs from folder, sorted by date."""
    pattern = os.path.join(folder, '*_profile.csv')
    files = sorted(glob.glob(pattern))

    profiles = []
    for f in files:
        if '_LIVE_' in f:
            continue
        meta, levels = parse_profile_csv(f)
        if levels:
            profiles.append({'file': f, 'meta': meta, 'levels': levels})

    return profiles


def plot_profiles_matplotlib(profiles, output_path='volume_profiles.png'):
    """Plot volume profiles using matplotlib. Price on Y, Volume on X."""
    n = len(profiles)
    if n == 0:
        print("No profiles to plot.")
        return

    cols = min(n, 3)
    rows = (n + cols - 1) // cols

    fig, axes = plt.subplots(rows, cols, figsize=(7 * cols, 10 * rows),
                              squeeze=False)
    fig.suptitle('Daily Volume Profiles', fontsize=16, fontweight='bold', y=0.98)

    for idx, profile in enumerate(profiles):
        row = idx // cols
        col = idx % cols
        ax = axes[row][col]

        meta = profile['meta']
        levels = profile['levels']

        prices    = [l['price'] for l in levels]
        volumes   = [l['total_vol'] for l in levels]
        buy_vols  = [l['buy_vol'] for l in levels]
        sell_vols = [l['sell_vol'] for l in levels]
        types     = [l['node_type'] for l in levels]

        bar_colors = [NODE_COLORS.get(t, NODE_COLORS['Normal'])['mpl'] for t in types]

        price_step = prices[1] - prices[0] if len(prices) > 1 else 1.0

        ax.barh(prices, volumes, height=price_step * 0.85,
                color=bar_colors, alpha=0.8, edgecolor='none')

        poc_price = float(meta.get('POC', 0))
        vah_price = float(meta.get('VAH', 0))
        val_price = float(meta.get('VAL', 0))
        vwap_val  = float(meta.get('VWAP', 0))

        if poc_price > 0:
            ax.axhline(y=poc_price, color='#FFD700', linewidth=2,
                       linestyle='-', label=f'POC {poc_price:.1f}')
        if vah_price > 0:
            ax.axhline(y=vah_price, color='#708090', linewidth=1,
                       linestyle='--', label=f'VAH {vah_price:.1f}')
        if val_price > 0:
            ax.axhline(y=val_price, color='#708090', linewidth=1,
                       linestyle='--', label=f'VAL {val_price:.1f}')
        if vwap_val > 0:
            ax.axhline(y=vwap_val, color='#FF00FF', linewidth=1.5,
                       linestyle='-.', label=f'VWAP {vwap_val:.1f}')

        date_str = meta.get('Date', os.path.basename(profile['file']))
        total_delta = meta.get('TotalDelta', '0')

        delta_val = float(total_delta)
        delta_label = f"Delta: +{delta_val:.0f}" if delta_val >= 0 else f"Delta: {delta_val:.0f}"
        delta_color = '#00AA00' if delta_val >= 0 else '#CC0000'

        ax.set_title(f"{date_str}  ({delta_label})", fontsize=12, fontweight='bold',
                     color=delta_color if abs(delta_val) > 0 else 'black')
        ax.set_xlabel('Volume', fontsize=10)
        ax.set_ylabel('Price', fontsize=10)
        ax.yaxis.set_major_locator(MaxNLocator(nbins=20))
        ax.grid(axis='y', alpha=0.3, linestyle=':')
        ax.legend(loc='upper right', fontsize=8, framealpha=0.7)

        ax.spines['top'].set_visible(False)
        ax.spines['right'].set_visible(False)

    for idx in range(n, rows * cols):
        row = idx // cols
        col = idx % cols
        axes[row][col].set_visible(False)

    legend_patches = [
        mpatches.Patch(color=NODE_COLORS['POC']['mpl'], label='POC'),
        mpatches.Patch(color=NODE_COLORS['HVN']['mpl'], label='HVN'),
        mpatches.Patch(color=NODE_COLORS['LVN']['mpl'], label='LVN'),
        mpatches.Patch(color=NODE_COLORS['VA']['mpl'],  label='Value Area'),
        mpatches.Patch(color=NODE_COLORS['Normal']['mpl'], label='Normal'),
    ]
    fig.legend(handles=legend_patches, loc='lower center', ncol=5,
               fontsize=10, framealpha=0.9, bbox_to_anchor=(0.5, 0.01))

    plt.tight_layout(rect=[0, 0.04, 1, 0.96])
    plt.savefig(output_path, dpi=150, bbox_inches='tight',
                facecolor='white', edgecolor='none')
    plt.close()
    print(f"Saved matplotlib chart: {output_path}")


def plot_profiles_plotly(profiles, output_path='volume_profiles.html'):
    """Plot volume profiles using plotly. Price on Y, Volume on X."""
    n = len(profiles)
    if n == 0:
        print("No profiles to plot.")
        return

    cols = min(n, 3)
    rows = (n + cols - 1) // cols

    subtitles = []
    for p in profiles:
        date = p['meta'].get('Date', '?')
        delta = float(p['meta'].get('TotalDelta', 0))
        sign = '+' if delta >= 0 else ''
        subtitles.append(f"{date} (Delta: {sign}{delta:.0f})")

    while len(subtitles) < rows * cols:
        subtitles.append('')

    fig = make_subplots(rows=rows, cols=cols, subplot_titles=subtitles,
                        horizontal_spacing=0.08, vertical_spacing=0.06)

    for idx, profile in enumerate(profiles):
        r = idx // cols + 1
        c = idx % cols + 1

        meta = profile['meta']
        levels = profile['levels']

        prices   = [l['price'] for l in levels]
        volumes  = [l['total_vol'] for l in levels]
        buy_vols = [l['buy_vol'] for l in levels]
        sell_vols= [l['sell_vol'] for l in levels]
        types    = [l['node_type'] for l in levels]
        deltas   = [l['delta'] for l in levels]

        bar_colors = [NODE_COLORS.get(t, NODE_COLORS['Normal'])['plotly']
                      for t in types]

        hover_text = [
            f"Price: {p:.1f}<br>Vol: {v:.0f}<br>Buy: {b:.0f} | Sell: {s:.0f}"
            f"<br>Delta: {d:+.0f}<br>Type: {t}"
            for p, v, b, s, d, t in zip(prices, volumes, buy_vols, sell_vols,
                                        deltas, types)
        ]

        price_step = prices[1] - prices[0] if len(prices) > 1 else 1.0

        fig.add_trace(
            go.Bar(
                x=volumes,
                y=prices,
                orientation='h',
                marker=dict(color=bar_colors, line=dict(width=0)),
                width=price_step * 0.85,
                hovertext=hover_text,
                hoverinfo='text',
                showlegend=False,
            ),
            row=r, col=c
        )

        poc_price = float(meta.get('POC', 0))
        vah_price = float(meta.get('VAH', 0))
        val_price = float(meta.get('VAL', 0))
        vwap_val  = float(meta.get('VWAP', 0))

        max_vol = max(volumes) if volumes else 1

        if poc_price > 0:
            fig.add_shape(type='line', y0=poc_price, y1=poc_price,
                          x0=0, x1=max_vol,
                          line=dict(color='#FFD700', width=2, dash='solid'),
                          row=r, col=c)
        if vah_price > 0:
            fig.add_shape(type='line', y0=vah_price, y1=vah_price,
                          x0=0, x1=max_vol,
                          line=dict(color='#708090', width=1, dash='dash'),
                          row=r, col=c)
        if val_price > 0:
            fig.add_shape(type='line', y0=val_price, y1=val_price,
                          x0=0, x1=max_vol,
                          line=dict(color='#708090', width=1, dash='dash'),
                          row=r, col=c)
        if vwap_val > 0:
            fig.add_shape(type='line', y0=vwap_val, y1=vwap_val,
                          x0=0, x1=max_vol,
                          line=dict(color='#FF00FF', width=1.5, dash='dashdot'),
                          row=r, col=c)

        fig.update_xaxes(title_text='Volume', row=r, col=c)
        fig.update_yaxes(title_text='Price', row=r, col=c)

    fig.update_layout(
        title=dict(text='Daily Volume Profiles (Order Flow Analysis)',
                   font=dict(size=18)),
        height=500 * rows,
        width=450 * cols,
        template='plotly_dark',
        showlegend=False,
    )

    fig.write_html(output_path)
    print(f"Saved interactive plotly chart: {output_path}")


def plot_delta_comparison(profiles, output_path=None):
    """Plot a delta comparison across days for bias assessment."""
    if len(profiles) < 2:
        return

    dates = []
    deltas = []
    poc_prices = []

    for p in profiles:
        dates.append(p['meta'].get('Date', '?'))
        deltas.append(float(p['meta'].get('TotalDelta', 0)))
        poc_prices.append(float(p['meta'].get('POC', 0)))

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    fig.suptitle('Daily Bias Analysis', fontsize=14, fontweight='bold')

    colors = ['#00AA00' if d >= 0 else '#CC0000' for d in deltas]
    ax1.bar(dates, deltas, color=colors, alpha=0.8)
    ax1.set_ylabel('Session Delta')
    ax1.axhline(y=0, color='white', linewidth=0.5, alpha=0.5)
    ax1.set_title('Cumulative Delta by Day')
    for i, d in enumerate(deltas):
        sign = '+' if d >= 0 else ''
        ax1.text(i, d, f'{sign}{d:.0f}', ha='center',
                 va='bottom' if d >= 0 else 'top', fontsize=9, fontweight='bold')

    ax2.plot(dates, poc_prices, 'o-', color='#FFD700', linewidth=2,
             markersize=8, label='POC')
    ax2.set_ylabel('Price')
    ax2.set_title('POC Migration (Value Shift)')
    ax2.legend()
    ax2.grid(alpha=0.3)

    plt.xticks(rotation=45)
    plt.tight_layout()

    out = output_path or 'daily_bias.png'
    plt.savefig(out, dpi=150, bbox_inches='tight', facecolor='white')
    plt.close()
    print(f"Saved bias chart: {out}")


def print_summary(profiles):
    """Print a text summary of all profiles for quick reference."""
    print("\n" + "=" * 70)
    print("VOLUME PROFILE SUMMARY")
    print("=" * 70)

    for p in profiles:
        m = p['meta']
        delta = float(m.get('TotalDelta', 0))
        bias = "BULLISH" if delta > 0 else ("BEARISH" if delta < 0 else "NEUTRAL")
        sign = '+' if delta >= 0 else ''

        print(f"\n  Date: {m.get('Date', '?')}")
        print(f"  POC:  {m.get('POC', '?')}  |  VAH: {m.get('VAH', '?')}  |  VAL: {m.get('VAL', '?')}")
        print(f"  VWAP: {m.get('VWAP', '?')}  |  Delta: {sign}{delta:.0f}  |  Bias: {bias}")

        hvns = [l for l in p['levels'] if l['node_type'] == 'HVN']
        lvns = [l for l in p['levels'] if l['node_type'] == 'LVN']
        if hvns:
            hvn_str = ', '.join(f"{l['price']:.1f}" for l in hvns)
            print(f"  HVNs: {hvn_str}")
        if lvns:
            lvn_str = ', '.join(f"{l['price']:.1f}" for l in lvns)
            print(f"  LVNs: {lvn_str}")

    print("\n" + "=" * 70)

    if len(profiles) >= 2:
        last_poc = float(profiles[-1]['meta'].get('POC', 0))
        prev_poc = float(profiles[-2]['meta'].get('POC', 0))
        if last_poc > prev_poc:
            print("  POC MIGRATION: UPWARD (value accepting higher)")
        elif last_poc < prev_poc:
            print("  POC MIGRATION: DOWNWARD (value accepting lower)")
        else:
            print("  POC MIGRATION: FLAT (balanced)")

        last_delta = float(profiles[-1]['meta'].get('TotalDelta', 0))
        if last_delta > 0 and last_poc > prev_poc:
            print("  DAILY BIAS SUGGESTION: LONG (rising POC + positive delta)")
        elif last_delta < 0 and last_poc < prev_poc:
            print("  DAILY BIAS SUGGESTION: SHORT (falling POC + negative delta)")
        else:
            print("  DAILY BIAS SUGGESTION: MIXED (conflicting signals)")

    print("=" * 70 + "\n")


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else find_csv_folder()
    print(f"Loading profiles from: {folder}")

    profiles = load_all_profiles(folder)

    if not profiles:
        print("No profile CSVs found. Make sure the EA has exported data.")
        print(f"Looked in: {folder}")
        print("Expected files matching: *_profile.csv")
        return

    print(f"Found {len(profiles)} daily profiles")

    print_summary(profiles)

    plot_profiles_matplotlib(profiles, 'volume_profiles.png')

    if HAS_PLOTLY:
        plot_profiles_plotly(profiles, 'volume_profiles.html')
    else:
        print("Install plotly for interactive charts: pip install plotly")

    if len(profiles) >= 2:
        plot_delta_comparison(profiles, 'daily_bias.png')

    print("\nDone. Files generated:")
    print("  - volume_profiles.png  (static chart)")
    if HAS_PLOTLY:
        print("  - volume_profiles.html (interactive chart)")
    if len(profiles) >= 2:
        print("  - daily_bias.png       (bias analysis)")


if __name__ == '__main__':
    main()
