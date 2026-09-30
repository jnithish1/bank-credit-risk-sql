"""
make_charts.py - renders the README charts from the CSVs in results/.
Run after scripts/run_analysis.sh:   python scripts/make_charts.py
"""
from pathlib import Path
import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = Path(__file__).resolve().parents[1]
RES, OUT = ROOT / "results", ROOT / "docs" / "images"
OUT.mkdir(parents=True, exist_ok=True)

# Palette: validated categorical slots 1-2 + neutral inks
BLUE, ORANGE = "#2a78d6", "#eb6834"
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10.5,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.titlelocation": "left",
    "xtick.color": INK2, "ytick.color": INK2, "axes.spines.top": False,
    "axes.spines.right": False, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE, "savefig.dpi": 160,
})


def read(name):
    with open(RES / f"{name}.csv", newline="") as f:
        return list(csv.DictReader(f))


def headline(fig, title, subtitle):
    fig.text(0.012, 0.955, title, color=INK, fontsize=13, fontweight="bold", ha="left", va="top")
    fig.text(0.012, 0.885, subtitle, color=INK2, fontsize=9.5, ha="left", va="top")


def finish(ax, fig, fname, subtitle, grid_axis="y"):
    ax.grid(axis=grid_axis, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    headline(fig, ax.get_title(loc="left"), subtitle)
    ax.set_title("", loc="left")
    fig.tight_layout(rect=(0, 0, 1, 0.84))
    fig.savefig(OUT / fname)
    plt.close(fig)


# 1. Default rate by loan amount with 95% CI --------------------------------
rows = [r for r in read("q02_default_drivers") if r["dimension"] == "Loan amount"]
labels = [r["segment"].split(". ", 1)[1] for r in rows]
rate = [float(r["default_rate_pct"]) for r in rows]
lo = [rate[i] - float(r["ci95_low_pct"]) for i, r in enumerate(rows)]
hi = [float(r["ci95_high_pct"]) - rate[i] for i, r in enumerate(rows)]
portfolio = float(read("q02_default_drivers")[0]["default_rate_pct"])
fig, ax = plt.subplots(figsize=(8, 4.4))
ax.bar(labels, rate, color=BLUE, width=0.55, zorder=2)
ax.errorbar(labels, rate, yerr=[lo, hi], fmt="none", ecolor=INK2, elinewidth=1.2, capsize=4, zorder=3)
ax.axhline(portfolio, color=INK2, linestyle="--", linewidth=1)
ax.text(-0.45, portfolio + 0.8, f"portfolio average {portfolio:.1f}%", color=INK2, ha="left", fontsize=9)
for i, v in enumerate(rate):
    ax.text(i, 1, f"{v:.1f}%", ha="center", color="white", fontsize=9.5, fontweight="bold")
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.0f}%"))
ax.set_xlabel("Loan amount (CZK)")
ax.set_title("Default rate rises with loan size")
finish(ax, fig, "default_rate_by_amount.png", "Share of loans defaulted, with 95% Wilson confidence interval  (n = 682 loans)")

# 2. Pre-loan warning signs: defaulted vs repaid ------------------------------
rows = {r["metric"]: r for r in read("q03_pre_loan_behaviour")}
metrics = ["% overdrawn in prior 3 months", "% charged penalty interest, prior 3m", "% with balance < 5x instalment"]
nice = ["Overdrawn in the\n3 months before", "Charged penalty\ninterest", "Balance under 5x\nthe instalment"]
bad = [float(rows[m]["defaulted"]) for m in metrics]
good = [float(rows[m]["repaying_or_repaid"]) for m in metrics]
x = range(len(metrics))
w = 0.36
fig, ax = plt.subplots(figsize=(8, 4.4))
ax.bar([i - w / 2 - 0.01 for i in x], bad, w, color=ORANGE, label="Later defaulted", zorder=2)
ax.bar([i + w / 2 + 0.01 for i in x], good, w, color=BLUE, label="Repaid / repaying", zorder=2)
for i in x:
    ax.text(i - w / 2 - 0.01, bad[i] + 1, f"{bad[i]:.0f}%", ha="center", color=INK, fontsize=9.5)
    ax.text(i + w / 2 + 0.01, good[i] + 1, f"{good[i]:.1f}%", ha="center", color=INK, fontsize=9.5)
ax.set_xticks(list(x), nice)
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.0f}%"))
ax.legend(frameon=False, loc="upper left")
ax.set_ylim(0, 58)
ax.set_title("Bad borrowers were visible before approval")
finish(ax, fig, "pre_loan_warning_signs.png", "Share of borrowers showing each sign in the 90 days before the loan was granted")

# 3. Signal strength (Information Value) --------------------------------------
rows = read("q04_risk_signal_strength")[::-1]
fig, ax = plt.subplots(figsize=(8, 4.8))
names = [r["feature"].replace("_", " ") for r in rows]
iv = [float(r["information_value"]) for r in rows]
ax.barh(names, iv, color=BLUE, height=0.6, zorder=2)
for i, v in enumerate(iv):
    ax.text(v + 0.015, i, f"{v:.2f}", va="center", color=INK, fontsize=9)
ax.axvline(0.3, color=INK2, linestyle="--", linewidth=1)
ax.text(0.31, len(iv) - 0.6, "strong threshold (IV 0.3)", color=INK2, fontsize=8.5)
ax.set_ylim(-0.6, len(iv) - 0.2)
ax.set_xlabel("Information Value")
ax.set_title("Liquidity signals beat income and loan size")
finish(ax, fig, "risk_signal_strength.png",
       "Predictive power of each pre-loan signal for default (Information Value)", grid_axis="x")

# 4. Deposit trend -------------------------------------------------------------
rows = read("q09_deposit_trend")
months = [r["month_start"] for r in rows]
dep = [float(r["deposits_czk_m"]) for r in rows]
avg3 = [float(r["deposits_3m_avg_czk_m"]) for r in rows]
fig, ax = plt.subplots(figsize=(9, 4.2))
ax.plot(range(len(months)), dep, color=BLUE, linewidth=2, label="Month-end deposits")
ax.plot(range(len(months)), avg3, color=INK2, linewidth=1.2, linestyle="--", label="3-month average")
ticks = [i for i, m in enumerate(months) if m.endswith("-01-01")]
ax.set_xticks(ticks, [months[i][:4] for i in ticks])
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.0f}M"))
ax.set_ylabel("CZK")
ax.legend(frameon=False, loc="upper left")
ax.annotate("Deposits dip every January", xy=(60, dep[60]), xytext=(71, 45), ha="right",
            color=INK2, fontsize=9, arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
ax.set_title("Deposits grew to CZK 197M by end of 1998")
finish(ax, fig, "deposit_trend.png", "Total month-end balances across all accounts, 1993-1998")

print("Charts written to", OUT)
