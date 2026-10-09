"""Generate 7.3.0 two-node-2-core comparison graphs — 9 scenarios x 2 metrics
(95th-percentile response time, throughput) over the 50-500 concurrency range
= 18 PNGs, saved as <scenario>/50_500_2core_lines.png and
<scenario>/50_500_2core_throughput.png next to this script.

The Two Node 2 Core series is the best measurement per scenario x concurrency
across the three 2N2C result sheets ("full 24_09", "basic 50 23_09", "basic"),
selected on lowest 95th percentile of the bottleneck step. The four 4 Core
series are the published 7.3.0 figures and keep the colours/markers used by
generate_graphs.py and gen_throughput_graphs.py so these charts read against
the existing ones.

Values are those of the primary bottleneck step marked with a diamond in
7.3_performance_summary_2core.md: complete flows/sec for multi-step flows,
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

# A chart where the configurations differ by more than this multiple *at the same
# concurrency* is drawn on a log y-axis — otherwise the four 4 Core series
# collapse into one flat band against a single 2 Core spike. The test is
# deliberately per-concurrency: a series that simply climbs with the x sweep
# (think-time-bound throughput) must stay linear, or a straight line is drawn as
# a false saturation curve.
LOG_RATIO = 8.0


def spread(data_by_config):
    """Largest max/min ratio across configurations at a single concurrency."""
    worst = 1.0
    for i in range(len(CU_LOW)):
        col = [raw[i] for raw in data_by_config.values() if raw[i] is not None]
        if len(col) > 1 and min(col) > 0:
            worst = max(worst, max(col) / min(col))
    return worst


def make_plot(scenario_dir, filename, data_by_config, ylabel):
    os.makedirs(scenario_dir, exist_ok=True)
    fig, ax = plt.subplots(figsize=(10, 6))

    use_log = spread(data_by_config) > LOG_RATIO

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
    if use_log:
        ax.set_yscale("log")
        ax.set_ylabel(f"{ylabel} — log scale", fontsize=12)
        # Label the 1-2-3-5 decade steps as plain numbers, so values stay
        # readable instead of leaving a single labelled decade tick.
        ax.yaxis.set_minor_locator(
            matplotlib.ticker.LogLocator(subs=(2.0, 3.0, 5.0)))
        for axis_fmt in (ax.yaxis.set_major_formatter,
                         ax.yaxis.set_minor_formatter):
            axis_fmt(matplotlib.ticker.ScalarFormatter())
        ax.tick_params(axis="y", which="minor", labelsize=9)
    else:
        ax.set_ylabel(ylabel, fontsize=12)
    ax.legend(fontsize=10, loc="best", framealpha=0.9)
    ax.grid(True, linestyle="--", alpha=0.6, which="both")
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
        "Two Node 2 Core":    [6.20, 12.32, 18.56, 37.06, 61.77],
        "Single Node 4 Core": [6.20, 12.39, 18.59, 37.12, 61.79],
        "Two Node 4 Core":    [6.22, 12.43, 18.57, 37.10, 61.89],
        "Three Node 4 Core":  [6.14, 12.33, 18.50, 37.02, 61.63],
        "Four Node 4 Core":   [6.22, 12.40, 18.58, 37.15, 61.53],
    })

# ────────────────────────────────────────────────────────────────────────────
# 2. OIDC Auth Code Grant Redirect Without Consent - Step 2: Login
# ────────────────────────────────────────────────────────────────────────────
gen("OIDC_Auth_Code_Grant_Redirect_Without_Consent", FLOWS,
    {
        "Two Node 2 Core":    [33, 50, 44, 46, 437],
        "Single Node 4 Core": [33, 33, 27, 28,  35],
        "Two Node 4 Core":    [33, 33, 26, 26,  31],
        "Three Node 4 Core":  [38, 38, 32, 32,  42],
        "Four Node 4 Core":   [37, 36, 30, 29,  42],
    },
    {
        "Two Node 2 Core":    [8.20, 16.43, 24.64, 49.18, 80.48],
        "Single Node 4 Core": [8.27, 16.44, 24.68, 49.50, 82.38],
        "Two Node 4 Core":    [8.26, 16.48, 24.63, 49.52, 82.57],
        "Three Node 4 Core":  [8.17, 16.40, 24.65, 49.43, 82.15],
        "Four Node 4 Core":   [8.20, 16.46, 24.75, 49.52, 82.20],
    })

# ────────────────────────────────────────────────────────────────────────────
# 3. ... Without Consent Retrieving User Attributes - Step 2: Login
# ────────────────────────────────────────────────────────────────────────────
gen("OIDC_Auth_Code_Grant_Redirect_Without_Consent_Retrieve_User_Attributes", FLOWS,
    {
        "Two Node 2 Core":    [35, 44, 44, 46, 435],
        "Single Node 4 Core": [28, 27, 27, 28,  30],
        "Two Node 4 Core":    [28, 26, 26, 26,  26],
        "Three Node 4 Core":  [34, 33, 32, 32,  37],
        "Four Node 4 Core":   [33, 30, 30, 29,  39],
    },
    {
        "Two Node 2 Core":    [8.18, 16.43, 24.63, 49.18, 80.30],
        "Single Node 4 Core": [8.23, 16.47, 24.68, 49.41, 82.29],
        "Two Node 4 Core":    [8.26, 16.41, 24.60, 49.55, 82.28],
        "Three Node 4 Core":  [8.20, 16.40, 24.70, 49.59, 82.16],
        "Four Node 4 Core":   [8.23, 16.51, 24.86, 49.30, 81.98],
    })

# ────────────────────────────────────────────────────────────────────────────
# 4. ... Without Consent Retrieving User Attributes, Groups and Roles - Step 2
# ────────────────────────────────────────────────────────────────────────────
gen("OIDC_Auth_Code_Grant_Redirect_Without_Consent_Retrieve_User_Attributes_Groups_and_Roles", FLOWS,
    {
        "Two Node 2 Core":    [35, 45, 43, 46, 409],
        "Single Node 4 Core": [28, 28, 27, 28,  29],
        "Two Node 4 Core":    [27, 27, 26, 26,  27],
        "Three Node 4 Core":  [34, 33, 32, 32,  35],
        "Four Node 4 Core":   [33, 32, 30, 29,  38],
    },
    {
        "Two Node 2 Core":    [8.19, 16.43, 24.67, 49.23, 79.98],
        "Single Node 4 Core": [8.27, 16.46, 24.79, 49.57, 82.40],
        "Two Node 4 Core":    [8.23, 16.52, 24.76, 49.53, 82.45],
        "Three Node 4 Core":  [8.26, 16.46, 24.68, 49.45, 82.13],
        "Four Node 4 Core":   [8.19, 16.51, 24.72, 49.48, 82.07],
    })

# ────────────────────────────────────────────────────────────────────────────
# 5. SAML2 SSO Redirect Binding - Step 2: Identity Provider Login
# ────────────────────────────────────────────────────────────────────────────
gen("SAML2_SSO_Redirect_Binding", FLOWS,
    {
        "Two Node 2 Core":    [34, 42, 41, 41, 45],
        "Single Node 4 Core": [32, 31, 31, 31, 32],
        "Two Node 4 Core":    [32, 32, 31, 31, 31],
        "Three Node 4 Core":  [41, 39, 39, 38, 48],
        "Four Node 4 Core":   [37, 34, 34, 33, 47],
    },
    {
        "Two Node 2 Core":    [8.26, 16.59, 24.72, 49.48, 82.58],
        "Single Node 4 Core": [8.21, 16.46, 24.87, 49.58, 82.31],
        "Two Node 4 Core":    [8.31, 16.55, 24.86, 49.79, 82.27],
        "Three Node 4 Core":  [8.31, 16.47, 24.77, 49.77, 82.43],
        "Four Node 4 Core":   [8.25, 16.56, 24.79, 49.54, 82.22],
    })

# ────────────────────────────────────────────────────────────────────────────
# 6. App Native Authentication - Step 2: Credential Submission
# ────────────────────────────────────────────────────────────────────────────
gen("App_Native_Authentication", FLOWS,
    {
        "Two Node 2 Core":    [43, 58, 57, 61, 465],
        "Single Node 4 Core": [38, 37, 37, 38,  41],
        "Two Node 4 Core":    [38, 37, 37, 36,  36],
        "Three Node 4 Core":  [46, 45, 44, 44,  53],
        "Four Node 4 Core":   [44, 42, 41, 40,  47],
    },
    {
        "Two Node 2 Core":    [8.33, 16.42, 24.55, 49.12, 80.19],
        "Single Node 4 Core": [8.28, 16.48, 24.70, 49.51, 82.43],
        "Two Node 4 Core":    [8.30, 16.54, 24.66, 49.47, 82.40],
        "Three Node 4 Core":  [8.21, 16.39, 24.73, 49.41, 82.05],
        "Four Node 4 Core":   [8.29, 16.45, 24.61, 49.40, 82.29],
    })

# ────────────────────────────────────────────────────────────────────────────
# 7. Token Exchange Grant Type - single /token request
# ────────────────────────────────────────────────────────────────────────────
gen("Token_Exchange_Grant", REQS,
    {
        "Two Node 2 Core":    [277, 755, 1175, 2415, 4127],
        "Single Node 4 Core": [153, 329,  511, 1063, 1759],
        "Two Node 4 Core":    [191, 275,  381,  811, 1615],
        "Three Node 4 Core":  [173, 293,  381,  699, 1591],
        "Four Node 4 Core":   [174, 257,  307,  489, 1423],
    },
    {
        "Two Node 2 Core":    [458.58, 367.84, 354.06,  344.86,  335.51],
        "Single Node 4 Core": [492.38, 475.99, 468.43,  454.03,  454.53],
        "Two Node 4 Core":    [714.29, 768.87, 819.55,  846.67,  888.77],
        "Three Node 4 Core":  [825.92, 911.09, 961.73, 1059.51, 1090.21],
        "Four Node 4 Core":   [853.73, 897.57, 1019.76, 1171.01, 1479.01],
    })

# ────────────────────────────────────────────────────────────────────────────
# 8. Client Credentials Grant Type - single /token request
# ────────────────────────────────────────────────────────────────────────────
gen("Client_Credentials_Grant_Type", REQS,
    {
        "Two Node 2 Core":    [147, 469, 751, 1679, 2495],
        "Single Node 4 Core": [ 74, 138, 203,  429,  783],
        "Two Node 4 Core":    [ 51, 194, 373,  819, 1295],
        "Three Node 4 Core":  [ 35, 118, 243,  575,  951],
        "Four Node 4 Core":   [ 25,  50, 126,  287,  385],
    },
    {
        "Two Node 2 Core":    [ 905.66,  754.67,  752.65,  710.08,  681.38],
        "Single Node 4 Core": [1084.13, 1056.18, 1023.38,  990.67,  970.82],
        "Two Node 4 Core":    [1750.07, 1744.60, 1896.92, 1739.69, 1868.69],
        "Three Node 4 Core":  [2538.89, 2627.19, 2398.75, 2638.63, 2553.60],
        "Four Node 4 Core":   [2856.20, 2927.64, 2949.31, 2981.62, 3014.67],
    })

# ────────────────────────────────────────────────────────────────────────────
# 9. OIDC Password Grant Type - single /token request
# ────────────────────────────────────────────────────────────────────────────
gen("OIDC_Password_Grant_Type", REQS,
    {
        "Two Node 2 Core":    [245, 675, 1039, 2207, 4079],
        "Single Node 4 Core": [157, 289,  455,  955, 1559],
        "Two Node 4 Core":    [177, 291,  421,  879, 1479],
        "Three Node 4 Core":  [182, 236,  297,  543, 1423],
        "Four Node 4 Core":   [183, 233,  303,  419, 1351],
    },
    {
        "Two Node 2 Core":    [416.41,  328.42,  327.70,  320.14,  293.44],
        "Single Node 4 Core": [457.94,  430.68,  400.10,  388.98,  401.99],
        "Two Node 4 Core":    [708.97,  752.24,  778.25,  772.03,  793.72],
        "Three Node 4 Core":  [858.93,  953.06, 1002.80, 1099.88, 1166.76],
        "Four Node 4 Core":   [934.63, 1043.80, 1089.76, 1232.87, 1551.69],
    })

print("\nAll 2 core comparison graphs generated.")
