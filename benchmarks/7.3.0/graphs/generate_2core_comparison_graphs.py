"""Generate 7.3.0 two-node-2-core comparison graphs — 3 scenarios x 2 metrics
(95th-percentile response time, throughput) over the 50-500 concurrency range
= 6 PNGs, saved as <scenario>/50_500_2core_lines.png and
<scenario>/50_500_2core_throughput.png next to this script.

The Two Node 2 Core series comes from the 2N2C basic result sheet (c6i.large,
2 vCPU per node). The four 4 Core series are the published 7.3.0 figures and
keep the colours/markers used by generate_graphs.py and gen_throughput_graphs.py
so these charts read against the existing ones.

Values are those of the primary bottleneck step marked with a paragraph symbol
in 7.3_performance_summary.md: complete flows/sec for multi-step flows,
requests/sec for single-step grants."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ── colour / style constants ────────────────────────────────────────────────
# The four 4 Core entries keep the colours and markers of the existing scripts;
# Two Node 2 Core is added in purple with a distinct marker.
CONFIGS = ["Two Node 2 Core", "Single Node 4 Core", "Two Node 4 Core",
           "Three Node 4 Core", "Four Node 4 Core"]
COLORS  = ["#9467bd", "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728"]
MARKERS = ["v", "o", "s", "^", "D"]
CU_LOW  = [50, 100, 150, 300, 500]

GRAPH_DIR = os.path.dirname(os.path.abspath(__file__))

FLOWS = "Complete Flows/sec"
REQS  = "Requests/sec"


def make_plot(scenario_dir, filename, data_by_config, ylabel):
    os.makedirs(scenario_dir, exist_ok=True)
    fig, ax = plt.subplots(figsize=(10, 6))

    for cfg, color, marker in zip(CONFIGS, COLORS, MARKERS):
        raw = data_by_config[cfg]
        xs, ys = [], []
        for cu, v in zip(CU_LOW, raw):
            if v is not None:
                xs.append(cu)
                ys.append(v)
        if xs:
            ax.plot(xs, ys, label=cfg, color=color, marker=marker,
                    linewidth=2, markersize=6)

    ax.set_xlabel("Concurrent Users", fontsize=12)
    ax.set_ylabel(ylabel, fontsize=12)
    ax.legend(fontsize=10, loc="upper left")
    ax.grid(True, linestyle="--", alpha=0.6)
    ax.set_xticks(CU_LOW)
    plt.tight_layout()
    out = os.path.join(scenario_dir, filename)
    plt.savefig(out, dpi=150)
    plt.close(fig)
    print(f"  saved -> {out}")


def gen(folder, unit, response_times, throughputs):
    """response_times / throughputs: dict cfg -> list[5] (CU_LOW order)"""
    d = os.path.join(GRAPH_DIR, folder)
    make_plot(d, "50_500_2core_lines.png", response_times,
              "95th Percentile of Response Time (ms)")
    make_plot(d, "50_500_2core_throughput.png", throughputs,
              f"Throughput ({unit})")


# ────────────────────────────────────────────────────────────────────────────
# 1. OIDC Auth Code Grant Redirect With Consent - Step 4: Consent Approval
# ────────────────────────────────────────────────────────────────────────────
gen("OIDC_Auth_Code_Grant_Redirect_With_Consent", FLOWS,
    {
        "Two Node 2 Core":    [12, 12, 12, 13, 14],
        "Single Node 4 Core": [11, 11, 11, 11, 13],
        "Two Node 4 Core":    [11, 11, 11, 11, 11],
        "Three Node 4 Core":  [14, 13, 13, 13, 15],
        "Four Node 4 Core":   [13, 12, 12, 12, 15],
    },
    {
        "Two Node 2 Core":    [6.19, 12.32, 18.56, 37.06, 61.77],
        "Single Node 4 Core": [6.20, 12.39, 18.59, 37.12, 61.79],
        "Two Node 4 Core":    [6.22, 12.43, 18.57, 37.10, 61.89],
        "Three Node 4 Core":  [6.14, 12.33, 18.50, 37.02, 61.63],
        "Four Node 4 Core":   [6.22, 12.40, 18.58, 37.15, 61.53],
    })

# ────────────────────────────────────────────────────────────────────────────
# 2. Client Credentials Grant Type - single /token request
# ────────────────────────────────────────────────────────────────────────────
gen("Client_Credentials_Grant_Type", REQS,
    {
        "Two Node 2 Core":    [176, 469, 751, 1679, 2495],
        "Single Node 4 Core": [ 74, 138, 203,  429,  783],
        "Two Node 4 Core":    [ 51, 194, 373,  819, 1295],
        "Three Node 4 Core":  [ 35, 118, 243,  575,  951],
        "Four Node 4 Core":   [ 25,  50, 126,  287,  385],
    },
    {
        "Two Node 2 Core":    [ 813.94,  754.67,  752.65,  710.08,  681.38],
        "Single Node 4 Core": [1084.13, 1056.18, 1023.38,  990.67,  970.82],
        "Two Node 4 Core":    [1750.07, 1744.60, 1896.92, 1739.69, 1868.69],
        "Three Node 4 Core":  [2538.89, 2627.19, 2398.75, 2638.63, 2553.60],
        "Four Node 4 Core":   [2856.20, 2927.64, 2949.31, 2981.62, 3014.67],
    })

# ────────────────────────────────────────────────────────────────────────────
# 3. OIDC Password Grant Type - single /token request
# ────────────────────────────────────────────────────────────────────────────
gen("OIDC_Password_Grant_Type", REQS,
    {
        "Two Node 2 Core":    [281, 675, 1039, 2207, 4079],
        "Single Node 4 Core": [157, 289,  455,  955, 1559],
        "Two Node 4 Core":    [177, 291,  421,  879, 1479],
        "Three Node 4 Core":  [182, 236,  297,  543, 1423],
        "Four Node 4 Core":   [183, 233,  303,  419, 1351],
    },
    {
        "Two Node 2 Core":    [377.51,  328.42,  327.70,  320.14,  293.44],
        "Single Node 4 Core": [457.94,  430.68,  400.10,  388.98,  401.99],
        "Two Node 4 Core":    [708.97,  752.24,  778.25,  772.03,  793.72],
        "Three Node 4 Core":  [858.93,  953.06, 1002.80, 1099.88, 1166.76],
        "Four Node 4 Core":   [934.63, 1043.80, 1089.76, 1232.87, 1551.69],
    })

print("\nAll 2 core comparison graphs generated.")
