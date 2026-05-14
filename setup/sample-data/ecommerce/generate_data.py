#!/usr/bin/env python3
"""
E-commerce Sample Data Generator

Produces two distinct datasets:
  generated_data/cassandra/*.csv   — hot / operational (loaded into Cassandra)
  generated_data/iceberg/*.parquet — historical / analytical / external
                                      (staged via hive_data → Iceberg)

Cassandra and Iceberg share customer_id and product_id pools so federated
joins resolve, but hold complementary, non-overlapping rows.

Demand signals (forecasting workshop)
-------------------------------------
Per-item `quantity` is scaled by a deterministic, per-category multiplier so
the forecasting workshop sees visibly non-flat history. The multiplier is
applied at order-build time, so all downstream tables derived from orders
(`orders_archive`, `order_items_archive`, `daily_sales_summary`,
`product_performance_weekly`) stay consistent.

multiplier(category, date) = trend(date) * seasonality(date) * promo(date)

  trend       (1 + r)^((date − anchor) / 7d), clamped to [0.6, 1.6].
              anchor = TODAY − 26 weeks, so the average across history sits
              near 1.0 and recent weeks reflect the growth/decline narrative.

  seasonality 1 + amp · sin(2π · week_of_year / 52 + φ), one sine wave per
              category, phased so the peak lands on the listed week-of-year.

  promo       1–2 randomly chosen weeks per category in the last 90 days
              get a one-week +30%–+80% bump; chosen via a dedicated seeded
              RNG so this does not perturb the rest of the generator's
              random stream.

Per-category encoded signals
  Electronics  +2.5%/wk,  amp 0.18, peak woy 47   (Black Friday / holiday)
  Clothing     +1.5%/wk,  amp 0.20, peak woy 47   (holiday apparel)
  Home         +0.5%/wk,  amp 0.10, peak woy 26   (summer DIY)
  Sports       +2.0%/wk,  amp 0.15, peak woy 26   (summer outdoor)
  Books        −1.0%/wk,  amp 0.08, peak woy 47   (gentle decline, holiday gifting)
  Beauty       +1.8%/wk,  amp 0.12, peak woy 47   (holiday gifting)
  Toys         +1.0%/wk,  amp 0.20, peak woy 49   (late-Q4 spike)
  Food         +0.8%/wk,  amp 0.06, peak woy 50   (holiday pantry)
  Automotive   −0.5%/wk,  amp 0.10, peak woy 26   (mild decline, summer DIY)
  Health       +2.8%/wk,  amp 0.07, peak woy  2   (New Year resolutions)

Promo weeks are listed by `_print_promo_calendar()` when the module is run.
"""
from __future__ import annotations

import csv
import math
import random
import sys
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _arrow_helpers import write_parquet  # type: ignore  # noqa: E402

# Sizing — tuned so each Iceberg INSERT batch fits under Presto's 1MB query-
# text limit and the total load completes in a few minutes. Dataset scale is
# pedagogical, not production; big enough to demo federation clearly.
CUSTOMERS_COUNT = 1000
PRODUCTS_COUNT = 200
ARCHIVE_ORDERS_COUNT = 3000
INFLIGHT_ORDERS_COUNT = 400
ACTIVE_CART_CUSTOMERS = 250
LIVE_SESSION_COUNT = 800
REVIEWS_RECENT_COUNT = 400

# Competitor-feed sampling (controls competitor_prices_weekly size).
COMPETITOR_SAMPLE_PRODUCTS = 50
COMPETITOR_WEEKS = 26

OUTPUT_DIR = Path(__file__).parent / "generated_data"
CASS_DIR = OUTPUT_DIR / "cassandra"
ICEBERG_DIR = OUTPUT_DIR / "iceberg"

# Pin "now" so regenerated data is deterministic run-to-run.
TODAY = date(2026, 4, 23)
NOW_TS = datetime(2026, 4, 23, 9, 0, 0)

CATEGORIES = {
    "Electronics": ["Smartphones", "Laptops", "Tablets", "Accessories", "Wearables"],
    "Clothing":    ["Mens", "Womens", "Kids", "Shoes", "Accessories"],
    "Home":        ["Furniture", "Decor", "Kitchen", "Bedding", "Tools"],
    "Sports":      ["Fitness", "Outdoor", "Team", "Water", "Winter"],
    "Books":       ["Fiction", "NonFiction", "Educational", "Childrens", "Comics"],
    "Beauty":      ["Skincare", "Makeup", "Haircare", "Fragrance", "Tools"],
    "Toys":        ["Action", "Dolls", "Educational", "Games", "Outdoor"],
    "Food":        ["Snacks", "Beverages", "Organic", "Gourmet", "Pantry"],
    "Automotive":  ["Parts", "Accessories", "Tools", "Care", "Electronics"],
    "Health":      ["Vitamins", "Supplements", "Medical", "Fitness", "Personal"],
}
BRANDS = ["TechPro", "StyleMax", "HomeComfort", "SportElite", "ReadWell",
          "BeautyGlow", "PlayTime", "FreshChoice", "AutoCare", "HealthPlus",
          "PremiumBrand", "ValueChoice", "LuxuryLine", "EcoFriendly", "SmartTech"]
COMPETITORS = ["MarketRival", "BudgetMart", "PremiumStore"]
FIRST_NAMES = ["James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael",
               "Linda", "William", "Elizabeth", "David", "Barbara", "Richard", "Susan",
               "Joseph", "Jessica", "Thomas", "Sarah", "Charles", "Karen"]
LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
              "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
              "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin"]
CITIES = [("New York", "NY"), ("Los Angeles", "CA"), ("Chicago", "IL"), ("Houston", "TX"),
          ("Phoenix", "AZ"), ("Philadelphia", "PA"), ("San Antonio", "TX"), ("San Diego", "CA"),
          ("Dallas", "TX"), ("San Jose", "CA"), ("Austin", "TX"), ("Seattle", "WA")]
PAYMENT_METHODS = ["credit_card", "debit_card", "paypal", "apple_pay", "google_pay", "gift_card"]
CHANNELS = ["email", "paid_search", "social", "display", "affiliate", "organic"]
DEVICE_TYPES = ["mobile", "desktop", "tablet"]
BROWSERS = ["Chrome", "Safari", "Firefox", "Edge"]
LOYALTY_TIERS = ["bronze", "silver", "gold", "platinum"]
LOYALTY_WEIGHTS = [0.50, 0.30, 0.15, 0.05]
TERMINAL_STATUSES = ["delivered", "returned", "cancelled"]
TERMINAL_WEIGHTS = [0.88, 0.07, 0.05]
INFLIGHT_STATUSES = ["pending", "processing", "shipped"]
INFLIGHT_WEIGHTS = [0.25, 0.35, 0.40]

random.seed(42)

# --- demand signal overlays (see module docstring) -----------------------

# (weekly_trend_rate, seasonality_amplitude, peak_week_of_year)
CATEGORY_SIGNALS = {
    "Electronics": (+0.025, 0.18, 47),
    "Clothing":    (+0.015, 0.20, 47),
    "Home":        (+0.005, 0.10, 26),
    "Sports":      (+0.020, 0.15, 26),
    "Books":       (-0.010, 0.08, 47),
    "Beauty":      (+0.018, 0.12, 47),
    "Toys":        (+0.010, 0.20, 49),
    "Food":        (+0.008, 0.06, 50),
    "Automotive":  (-0.005, 0.10, 26),
    "Health":      (+0.028, 0.07,  2),
}
TREND_ANCHOR = TODAY - timedelta(weeks=26)
TREND_CLAMP_LO, TREND_CLAMP_HI = 0.6, 1.6
QTY_MIN, QTY_MAX = 1, 12

# Promo windows: 1–2 random weeks per category in the last 90 days, each a
# +30%–+80% bump. A dedicated RNG keeps this off the global random stream
# so the rest of the dataset stays bit-identical to the no-promo case.
_signal_rng = random.Random(20260423)
_today_monday = TODAY - timedelta(days=TODAY.weekday())
_recent_mondays = [_today_monday - timedelta(weeks=w) for w in range(13)]
PROMO_WEEKS: dict[str, dict[date, float]] = {}
for _cat in CATEGORY_SIGNALS:
    _n = _signal_rng.choice([1, 1, 2])
    _picked = _signal_rng.sample(_recent_mondays, _n)
    PROMO_WEEKS[_cat] = {m: _signal_rng.uniform(0.30, 0.80) for m in _picked}

def _category_demand_multiplier(category: str, order_date: date) -> float:
    trend, amp, peak_woy = CATEGORY_SIGNALS[category]
    weeks_from_anchor = (order_date - TREND_ANCHOR).days / 7.0
    trend_mult = (1.0 + trend) ** weeks_from_anchor
    if trend_mult < TREND_CLAMP_LO: trend_mult = TREND_CLAMP_LO
    elif trend_mult > TREND_CLAMP_HI: trend_mult = TREND_CLAMP_HI
    woy = order_date.isocalendar()[1]
    phase = math.pi / 2 - 2 * math.pi * peak_woy / 52
    season_mult = 1.0 + amp * math.sin(2 * math.pi * woy / 52 + phase)
    monday = order_date - timedelta(days=order_date.weekday())
    promo_mult = 1.0 + PROMO_WEEKS.get(category, {}).get(monday, 0.0)
    return trend_mult * season_mult * promo_mult

def _print_promo_calendar():
    print("Encoded promo weeks (category → Monday: +bump):")
    for cat, weeks in PROMO_WEEKS.items():
        bits = ", ".join(f"{m.isoformat()}:+{int(b*100)}%" for m, b in sorted(weeks.items()))
        print(f"  {cat:<12} {bits}")

# --- helpers --------------------------------------------------------------

def write_csv(path: Path, header: list, rows: list):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)

def pick(pool, weights=None):
    return random.choices(pool, weights=weights, k=1)[0] if weights else random.choice(pool)

# --- pools ----------------------------------------------------------------

def generate_customers():
    rows = []
    for i in range(CUSTOMERS_COUNT):
        fn = pick(FIRST_NAMES); ln = pick(LAST_NAMES)
        city, state = pick(CITIES)
        created = TODAY - timedelta(days=random.randint(30, 730))
        rows.append({
            "customer_id": str(uuid.uuid4()),
            "email": f"{fn.lower()}.{ln.lower()}{i}@example.com",
            "first_name": fn, "last_name": ln,
            "phone": f"+1-{random.randint(200,999)}-{random.randint(100,999)}-{random.randint(1000,9999)}",
            "created_at": datetime.combine(created, datetime.min.time()) + timedelta(hours=random.randint(0,23)),
            "last_login": NOW_TS - timedelta(hours=random.randint(0, 24*90)),
            "account_status": "active" if random.random() < 0.97 else "suspended",
            "loyalty_tier": pick(LOYALTY_TIERS, LOYALTY_WEIGHTS),
            "shipping_city": city, "shipping_state": state, "shipping_country": "USA",
            "marketing_opt_in": random.random() < 0.7,
        })
    return rows

def generate_products():
    rows = []
    per_cat = PRODUCTS_COUNT // len(CATEGORIES)
    for cat, subs in CATEGORIES.items():
        for _ in range(per_cat):
            sub = pick(subs); brand = pick(BRANDS)
            price = round(random.uniform(5, 1500), 2)
            cost = round(price * random.uniform(0.40, 0.75), 2)
            created = TODAY - timedelta(days=random.randint(30, 720))
            rows.append({
                "product_id": str(uuid.uuid4()),
                "sku": f"{cat[:3].upper()}-{random.randint(10000,99999)}",
                "name": f"{brand} {sub} {pick(['Pro','Lite','Max','Classic','Edge','Prime'])} {random.randint(100,999)}",
                "category": cat, "subcategory": sub, "brand": brand,
                "price": Decimal(str(price)), "cost": Decimal(str(cost)), "currency": "USD",
                "stock_quantity": random.randint(0, 500),
                "reorder_level": random.randint(10, 50),
                "is_active": random.random() < 0.95,
                "created_at": datetime.combine(created, datetime.min.time()),
                "updated_at": NOW_TS - timedelta(hours=random.randint(0, 240)),
                "rating_avg": Decimal(str(round(random.uniform(3.2, 4.9), 2))),
                "rating_count": random.randint(0, 2000),
            })
    return rows

# --- order builder --------------------------------------------------------

def _make_order(customers, products, order_dt, status_pool, status_weights):
    cust = pick(customers)
    n_items = random.choices([1,2,3,4,5,6], weights=[0.30,0.25,0.20,0.15,0.07,0.03])[0]
    chosen = random.sample(products, n_items)
    items = []
    subtotal = Decimal("0")
    for seq, p in enumerate(chosen, 1):
        qty_base = random.randint(1, 4)
        mult = _category_demand_multiplier(p["category"], order_dt)
        qty = max(QTY_MIN, min(QTY_MAX, round(qty_base * mult)))
        unit = p["price"]
        disc = (unit * Decimal(str(round(random.uniform(0.05, 0.25), 2)))) if random.random() < 0.18 else Decimal("0")
        tax = (unit * qty - disc) * Decimal("0.08")
        line = unit * qty - disc + tax
        items.append({
            "item_sequence": seq, "product": p, "quantity": qty,
            "unit_price": unit, "discount_amount": disc.quantize(Decimal("0.01")),
            "tax_amount": tax.quantize(Decimal("0.01")),
            "line_total": line.quantize(Decimal("0.01")),
        })
        subtotal += unit * qty
    tax_total = sum((i["tax_amount"] for i in items), Decimal("0"))
    disc_total = sum((i["discount_amount"] for i in items), Decimal("0"))
    ship = Decimal(str(round(random.uniform(0, 25), 2)))
    total = (subtotal - disc_total + tax_total + ship).quantize(Decimal("0.01"))
    status = pick(status_pool, status_weights)
    order_ts = datetime.combine(order_dt, datetime.min.time()) + timedelta(
        hours=random.randint(0,23), minutes=random.randint(0,59))
    pay_status = {"delivered":"captured","shipped":"captured","processing":"captured",
                  "pending":"authorized","returned":"refunded","cancelled":"failed"}[status]
    return {
        "order_id": str(uuid.uuid4()),
        "customer_id": cust["customer_id"],
        "order_date": order_dt, "order_timestamp": order_ts,
        "order_status": status,
        "payment_method": pick(PAYMENT_METHODS), "payment_status": pay_status,
        "subtotal": subtotal.quantize(Decimal("0.01")),
        "tax_amount": tax_total.quantize(Decimal("0.01")),
        "shipping_cost": ship,
        "discount_amount": disc_total.quantize(Decimal("0.01")),
        "total_amount": total, "currency": "USD",
        "shipping_city": cust["shipping_city"],
        "shipping_state": cust["shipping_state"],
        "shipping_country": cust["shipping_country"],
        "tracking_number": f"TRK{random.randint(10**9, 10**10-1)}" if status in ("shipped","delivered") else None,
        "estimated_delivery_date": order_dt + timedelta(days=random.randint(2,10)),
        "delivered_at": order_ts + timedelta(days=random.randint(2,14)) if status == "delivered" else None,
        "returned_at": order_ts + timedelta(days=random.randint(10,45)) if status == "returned" else None,
        "created_at": order_ts,
        "updated_at": order_ts + timedelta(hours=random.randint(1,72)),
    }, items

def generate_archive_orders(customers, products):
    orders, items = [], []
    for _ in range(ARCHIVE_ORDERS_COUNT):
        order_dt = TODAY - timedelta(days=random.randint(31, 395))
        o, its = _make_order(customers, products, order_dt, TERMINAL_STATUSES, TERMINAL_WEIGHTS)
        for it in its:
            it["order_id"] = o["order_id"]; it["order_date"] = order_dt
        orders.append(o); items.extend(its)
    return orders, items

def generate_inflight_orders(customers, products):
    orders, items = [], []
    for _ in range(INFLIGHT_ORDERS_COUNT):
        order_dt = TODAY - timedelta(days=random.randint(0, 30))
        o, its = _make_order(customers, products, order_dt, INFLIGHT_STATUSES, INFLIGHT_WEIGHTS)
        for it in its:
            it["order_id"] = o["order_id"]; it["order_date"] = order_dt
        orders.append(o); items.extend(its)
    return orders, items

# --- derived analytical tables --------------------------------------------

def derive_daily_sales_summary(orders, items):
    by_id = {o["order_id"]: o for o in orders}
    bucket = defaultdict(lambda: {"order_ids": set(), "units": 0,
        "gross": Decimal("0"), "disc": Decimal("0"), "net": Decimal("0"),
        "ret_count": 0, "ret_amount": Decimal("0"), "customers": set()})
    for it in items:
        o = by_id[it["order_id"]]
        key = (o["order_date"], it["product"]["category"], o["shipping_country"], o["shipping_state"])
        b = bucket[key]
        b["order_ids"].add(o["order_id"])
        b["units"] += it["quantity"]
        b["gross"] += it["unit_price"] * it["quantity"]
        b["disc"] += it["discount_amount"]
        b["net"] += it["line_total"]
        b["customers"].add(o["customer_id"])
        if o["order_status"] == "returned":
            b["ret_count"] += 1; b["ret_amount"] += it["line_total"]
    rows = []
    for (dt, cat, country, state), b in bucket.items():
        rows.append({
            "summary_date": dt, "summary_year": dt.year, "summary_month": dt.month,
            "product_category": cat, "shipping_country": country, "shipping_state": state,
            "order_count": len(b["order_ids"]), "unit_count": b["units"],
            "gross_revenue": b["gross"].quantize(Decimal("0.01")),
            "discount_total": b["disc"].quantize(Decimal("0.01")),
            "net_revenue": b["net"].quantize(Decimal("0.01")),
            "return_count": b["ret_count"],
            "return_amount": b["ret_amount"].quantize(Decimal("0.01")),
            "unique_customers": len(b["customers"]),
        })
    return rows

def derive_product_performance_weekly(orders, items, products):
    by_id = {o["order_id"]: o for o in orders}
    cat_by_pid = {p["product_id"]: p["category"] for p in products}
    bucket = defaultdict(lambda: {"units": 0, "revenue": Decimal("0"), "returns": 0})
    for it in items:
        o = by_id[it["order_id"]]
        monday = o["order_date"] - timedelta(days=o["order_date"].weekday())
        key = (it["product"]["product_id"], monday)
        b = bucket[key]
        b["units"] += it["quantity"]
        b["revenue"] += it["unit_price"] * it["quantity"]
        if o["order_status"] == "returned":
            b["returns"] += it["quantity"]
    by_cat_week = defaultdict(list)
    rows = []
    for (pid, monday), b in bucket.items():
        cat = cat_by_pid[pid]
        avg_price = (b["revenue"] / b["units"]).quantize(Decimal("0.01")) if b["units"] else Decimal("0")
        return_rate = Decimal(str(round(b["returns"] / b["units"], 4))) if b["units"] else Decimal("0")
        rows.append({
            "product_id": pid, "product_category": cat,
            "week_start_date": monday, "week_year": monday.year,
            "week_of_year": monday.isocalendar()[1],
            "units_sold": b["units"],
            "gross_revenue": b["revenue"].quantize(Decimal("0.01")),
            "average_selling_price": avg_price, "return_rate": return_rate,
            "review_count": random.randint(0, max(1, b["units"] // 2)),
            "rating_average": Decimal(str(round(random.uniform(3.5, 4.8), 2))),
            "stock_start_of_week": random.randint(50, 500),
            "stock_end_of_week": random.randint(20, 450),
        })
        by_cat_week[(cat, monday)].append((b["units"], pid))
    rank_lookup = {}
    for key, lst in by_cat_week.items():
        lst.sort(reverse=True)
        for rank, (_u, pid) in enumerate(lst, 1):
            rank_lookup[(pid, key[1])] = rank
    for r in rows:
        r["velocity_rank"] = rank_lookup[(r["product_id"], r["week_start_date"])]
    return rows

def _month_list(n=12):
    y, m = TODAY.year, TODAY.month
    out = []
    for back in range(1, n + 1):
        mm = m - back; yy = y
        while mm <= 0: mm += 12; yy -= 1
        out.append((yy, mm))
    out.reverse()
    return out

def derive_customer_ltv_monthly(customers, archive_orders):
    by_cust = defaultdict(list)
    for o in archive_orders:
        if o["order_status"] == "delivered":
            by_cust[o["customer_id"]].append(o)
    months = _month_list(12)
    rows = []
    for cust in customers:
        cid = cust["customer_id"]
        orders = sorted(by_cust.get(cid, []), key=lambda o: o["order_date"])
        cum_orders = 0; cum_spend = Decimal("0")
        for (yy, mm) in months:
            month_start = date(yy, mm, 1)
            next_month = date(yy + (1 if mm == 12 else 0), 1 if mm == 12 else mm + 1, 1)
            in_month = [o for o in orders if month_start <= o["order_date"] < next_month]
            month_spend = sum((o["total_amount"] for o in in_month), Decimal("0"))
            cum_orders += len(in_month); cum_spend += month_spend
            snapshot_date = next_month - timedelta(days=1)
            rows.append({
                "customer_id": cid, "snapshot_year": yy, "snapshot_month": mm,
                "snapshot_date": snapshot_date,
                "ltv": cum_spend.quantize(Decimal("0.01")),
                "cumulative_orders": cum_orders,
                "orders_this_month": len(in_month),
                "spend_this_month": month_spend.quantize(Decimal("0.01")),
                "loyalty_tier": cust["loyalty_tier"],
                "is_active": any((snapshot_date - o["order_date"]).days <= 90 for o in orders),
            })
    return rows

def derive_cohort_retention(customers, archive_orders):
    cohort_of = {c["customer_id"]: (c["created_at"].date().year, c["created_at"].date().month) for c in customers}
    orders_by_cust_month = defaultdict(set)
    revenue_by_cust_month = defaultdict(lambda: Decimal("0"))
    for o in archive_orders:
        if o["order_status"] == "delivered":
            k = (o["order_date"].year, o["order_date"].month)
            orders_by_cust_month[o["customer_id"]].add(k)
            revenue_by_cust_month[(o["customer_id"], k)] += o["total_amount"]
    cohort_members = defaultdict(list)
    for cid, ck in cohort_of.items():
        cohort_members[ck].append(cid)
    rows = []
    for (cy, cm), members in sorted(cohort_members.items()):
        size = len(members)
        for offset in range(0, 12):
            yy = cy + (cm - 1 + offset) // 12
            mm = (cm - 1 + offset) % 12 + 1
            if date(yy, mm, 1) > TODAY: break
            target = (yy, mm)
            active = sum(1 for cid in members if target in orders_by_cust_month[cid])
            revenue = sum((revenue_by_cust_month[(cid, target)] for cid in members), Decimal("0"))
            retention = Decimal(str(round(active / size, 4))) if size else Decimal("0")
            avg_rev = (revenue / active).quantize(Decimal("0.01")) if active else Decimal("0")
            rows.append({
                "cohort_year": cy, "cohort_month": cm,
                "months_since_acquisition": offset,
                "cohort_size": size, "active_customers": active,
                "retention_rate": retention,
                "revenue_in_period": revenue.quantize(Decimal("0.01")),
                "avg_revenue_per_active": avg_rev,
            })
    return rows

def generate_marketing_attribution(archive_orders):
    rows = []
    for o in archive_orders:
        if o["order_status"] != "delivered" or random.random() > 0.40:
            continue
        channel = pick(CHANNELS, [0.22, 0.24, 0.20, 0.12, 0.08, 0.14])
        touches = random.randint(1, 5)
        val = o["total_amount"]
        attrib = (val * Decimal(str(round(random.uniform(0.40, 1.00), 2)))).quantize(Decimal("0.01")) \
                 if touches > 1 else val
        rows.append({
            "conversion_id": str(uuid.uuid4()),
            "customer_id": o["customer_id"], "order_id": o["order_id"],
            "conversion_timestamp": o["order_timestamp"],
            "conversion_year": o["order_timestamp"].year,
            "conversion_month": o["order_timestamp"].month,
            "campaign_id": f"camp-{random.randint(100,999)}",
            "campaign_name": f"{channel}_{o['order_timestamp'].year}Q{(o['order_timestamp'].month-1)//3+1}",
            "channel": channel, "touch_count": touches,
            "days_to_conversion": random.randint(0, 21),
            "conversion_value": val, "attributed_revenue": attrib,
        })
    return rows

def generate_competitor_prices(products):
    rows = []
    top = random.sample(products, min(COMPETITOR_SAMPLE_PRODUCTS, len(products)))
    for p in top:
        for wk in range(0, COMPETITOR_WEEKS):
            monday = TODAY - timedelta(days=TODAY.weekday() + 7 * wk)
            for comp in COMPETITORS:
                cp = p["price"] * Decimal(str(round(random.uniform(0.85, 1.20), 2)))
                rows.append({
                    "week_start_date": monday, "week_year": monday.year,
                    "our_product_id": p["product_id"], "our_sku": p["sku"],
                    "competitor_name": comp,
                    "competitor_sku": f"{comp[:3].upper()}-{random.randint(10000,99999)}",
                    "competitor_price": cp.quantize(Decimal("0.01")),
                    "currency": "USD", "in_stock": random.random() < 0.82,
                    "crawl_source": "partner_feed",
                    "crawl_timestamp": datetime.combine(monday, datetime.min.time()) + timedelta(hours=3),
                })
    return rows

# --- Cassandra-only tables ------------------------------------------------

def generate_active_carts(customers, products):
    rows = []
    for c in random.sample(customers, min(ACTIVE_CART_CUSTOMERS, len(customers))):
        for p in random.sample(products, random.randint(1, 4)):
            rows.append({
                "customer_id": c["customer_id"], "product_id": p["product_id"],
                "added_at": NOW_TS - timedelta(minutes=random.randint(1, 2880)),
                "quantity": random.randint(1, 3), "unit_price": p["price"],
            })
    return rows

def generate_live_sessions(customers):
    rows = []
    for _ in range(LIVE_SESSION_COUNT):
        c = pick(customers)
        start = NOW_TS - timedelta(minutes=random.randint(1, 1440))
        rows.append({
            "customer_id": c["customer_id"], "session_id": str(uuid.uuid4()),
            "session_start": start, "session_end": start + timedelta(minutes=random.randint(1, 45)),
            "page_views": random.randint(1, 40), "cart_additions": random.randint(0, 5),
            "products_viewed_count": random.randint(0, 25),
            "device_type": pick(DEVICE_TYPES), "browser": pick(BROWSERS),
            "referrer": pick(["google", "facebook", "direct", "email", "instagram"]),
        })
    return rows

def generate_inventory_ledger_recent(products):
    rows = []
    stock = {p["product_id"]: p["stock_quantity"] for p in products}
    for p in random.sample(products, min(150, len(products))):
        for _ in range(random.randint(3, 12)):
            dt = TODAY - timedelta(days=random.randint(0, 30))
            ttype = pick(["sale", "sale", "sale", "restock", "adjustment", "return"])
            qty = (-random.randint(1, 5) if ttype == "sale"
                   else random.randint(10, 100) if ttype == "restock"
                   else random.randint(1, 3) if ttype == "return"
                   else random.randint(-5, 5))
            stock[p["product_id"]] = max(0, stock[p["product_id"]] + qty)
            rows.append({
                "product_id": p["product_id"], "transaction_date": dt,
                "transaction_id": str(uuid.uuid1()),
                "transaction_type": ttype, "quantity_change": qty,
                "quantity_after": stock[p["product_id"]],
                "reference_order_id": str(uuid.uuid4()) if ttype == "sale" else None,
                "created_at": datetime.combine(dt, datetime.min.time()) + timedelta(hours=random.randint(0,23)),
            })
    return rows

def generate_reviews_recent(customers, products):
    rows = []
    for _ in range(REVIEWS_RECENT_COUNT):
        c = pick(customers); p = pick(products)
        dt = TODAY - timedelta(days=random.randint(0, 30))
        rating = random.choices([1,2,3,4,5], weights=[0.05,0.08,0.12,0.35,0.40])[0]
        rows.append({
            "product_id": p["product_id"], "review_date": dt,
            "review_id": str(uuid.uuid4()),
            "customer_id": c["customer_id"], "rating": rating,
            "title": pick(["Great product", "Not as expected", "Love it", "Okay", "Excellent", "Disappointed"]),
            "review_text": f"Review for {p['name']} — rating {rating}/5.",
            "verified_purchase": random.random() < 0.85,
            "created_at": datetime.combine(dt, datetime.min.time()) + timedelta(hours=random.randint(0,23)),
        })
    return rows

# --- writers --------------------------------------------------------------

def write_cassandra_csvs(customers, products, active_carts, inflight_orders, inflight_items,
                          live_sessions, inventory_recent, reviews_recent):
    write_csv(CASS_DIR / "customers.csv",
        ["customer_id","email","first_name","last_name","phone","created_at","last_login",
         "account_status","loyalty_tier","current_ltv","total_orders","shipping_city",
         "shipping_state","shipping_country","marketing_opt_in","updated_at"],
        [[c["customer_id"], c["email"], c["first_name"], c["last_name"], c["phone"],
          c["created_at"].isoformat(), c["last_login"].isoformat(),
          c["account_status"], c["loyalty_tier"],
          str(c.get("current_ltv", 0)), c.get("total_orders", 0),
          c["shipping_city"], c["shipping_state"], c["shipping_country"],
          c["marketing_opt_in"], NOW_TS.isoformat()] for c in customers])

    write_csv(CASS_DIR / "products.csv",
        ["product_id","sku","name","category","subcategory","brand","price","cost","currency",
         "stock_quantity","reorder_level","is_active","created_at","updated_at","rating_avg","rating_count"],
        [[p["product_id"], p["sku"], p["name"], p["category"], p["subcategory"], p["brand"],
          str(p["price"]), str(p["cost"]), p["currency"], p["stock_quantity"], p["reorder_level"],
          p["is_active"], p["created_at"].isoformat(), p["updated_at"].isoformat(),
          str(p["rating_avg"]), p["rating_count"]] for p in products])

    write_csv(CASS_DIR / "active_carts.csv",
        ["customer_id","product_id","added_at","quantity","unit_price"],
        [[r["customer_id"], r["product_id"], r["added_at"].isoformat(),
          r["quantity"], str(r["unit_price"])] for r in active_carts])

    write_csv(CASS_DIR / "orders_inflight.csv",
        ["customer_id","order_date","order_id","order_timestamp","order_status","payment_method",
         "payment_status","subtotal","tax_amount","shipping_cost","discount_amount","total_amount",
         "currency","shipping_city","shipping_state","shipping_country","tracking_number",
         "estimated_delivery_date","created_at","updated_at"],
        [[o["customer_id"], o["order_date"].isoformat(), o["order_id"], o["order_timestamp"].isoformat(),
          o["order_status"], o["payment_method"], o["payment_status"],
          str(o["subtotal"]), str(o["tax_amount"]), str(o["shipping_cost"]),
          str(o["discount_amount"]), str(o["total_amount"]), o["currency"],
          o["shipping_city"], o["shipping_state"], o["shipping_country"],
          o["tracking_number"] or "",
          o["estimated_delivery_date"].isoformat() if o["estimated_delivery_date"] else "",
          o["created_at"].isoformat(), o["updated_at"].isoformat()] for o in inflight_orders])

    write_csv(CASS_DIR / "order_items_inflight.csv",
        ["order_id","item_sequence","product_id","product_name","product_sku","quantity",
         "unit_price","discount_amount","tax_amount","line_total","currency"],
        [[it["order_id"], it["item_sequence"], it["product"]["product_id"],
          it["product"]["name"], it["product"]["sku"], it["quantity"],
          str(it["unit_price"]), str(it["discount_amount"]),
          str(it["tax_amount"]), str(it["line_total"]), "USD"] for it in inflight_items])

    write_csv(CASS_DIR / "live_sessions.csv",
        ["customer_id","session_id","session_start","session_end","page_views","cart_additions",
         "products_viewed_count","device_type","browser","referrer"],
        [[r["customer_id"], r["session_id"], r["session_start"].isoformat(),
          r["session_end"].isoformat(), r["page_views"], r["cart_additions"],
          r["products_viewed_count"], r["device_type"], r["browser"], r["referrer"]]
         for r in live_sessions])

    write_csv(CASS_DIR / "inventory_ledger_recent.csv",
        ["product_id","transaction_date","transaction_id","transaction_type","quantity_change",
         "quantity_after","reference_order_id","created_at"],
        [[r["product_id"], r["transaction_date"].isoformat(), r["transaction_id"],
          r["transaction_type"], r["quantity_change"], r["quantity_after"],
          r["reference_order_id"] or "", r["created_at"].isoformat()]
         for r in inventory_recent])

    write_csv(CASS_DIR / "reviews_recent.csv",
        ["product_id","review_date","review_id","customer_id","rating","title","review_text",
         "verified_purchase","created_at"],
        [[r["product_id"], r["review_date"].isoformat(), r["review_id"], r["customer_id"],
          r["rating"], r["title"], r["review_text"], r["verified_purchase"],
          r["created_at"].isoformat()] for r in reviews_recent])

def _flatten_order_items(archive_items):
    """Promote nested product fields onto each item dict so parquet serialization is flat."""
    out = []
    for it in archive_items:
        p = it["product"]
        out.append({
            "order_id": it["order_id"],
            "item_sequence": it["item_sequence"],
            "order_year": it["order_date"].year,
            "order_month": it["order_date"].month,
            "product_id": p["product_id"],
            "product_sku": p["sku"],
            "product_name": p["name"],
            "product_category": p["category"],
            "quantity": it["quantity"],
            "unit_price": it["unit_price"],
            "discount_amount": it["discount_amount"],
            "tax_amount": it["tax_amount"],
            "line_total": it["line_total"],
        })
    return out

def _enrich_orders(archive_orders, archive_items):
    """Attach order_year/order_month/item_count to each archive order for the parquet row."""
    counts = defaultdict(int)
    for it in archive_items: counts[it["order_id"]] += 1
    for o in archive_orders:
        o["order_year"] = o["order_date"].year
        o["order_month"] = o["order_date"].month
        o["item_count"] = counts[o["order_id"]]
    return archive_orders

def write_iceberg_parquet(archive_orders, archive_items, daily_summary, weekly_perf,
                          ltv_monthly, cohort, attribution, competitor_prices):
    archive_orders = _enrich_orders(archive_orders, archive_items)
    flat_items = _flatten_order_items(archive_items)

    write_parquet(ICEBERG_DIR / "orders_archive.parquet",
        [("order_id","str"),("customer_id","str"),("order_date","date"),
         ("order_year","int"),("order_month","int"),("order_timestamp","ts"),
         ("order_status","str"),("payment_method","str"),("payment_status","str"),
         ("subtotal","float"),("tax_amount","float"),("shipping_cost","float"),
         ("discount_amount","float"),("total_amount","float"),("currency","str"),
         ("shipping_city","str"),("shipping_state","str"),("shipping_country","str"),
         ("delivered_at","ts"),("returned_at","ts"),("item_count","int"),
         ("created_at","ts")],
        archive_orders)

    write_parquet(ICEBERG_DIR / "order_items_archive.parquet",
        [("order_id","str"),("item_sequence","int"),
         ("order_year","int"),("order_month","int"),
         ("product_id","str"),("product_sku","str"),("product_name","str"),
         ("product_category","str"),("quantity","int"),
         ("unit_price","float"),("discount_amount","float"),
         ("tax_amount","float"),("line_total","float")],
        flat_items)

    write_parquet(ICEBERG_DIR / "daily_sales_summary.parquet",
        [("summary_date","date"),("summary_year","int"),("summary_month","int"),
         ("product_category","str"),("shipping_country","str"),("shipping_state","str"),
         ("order_count","int"),("unit_count","int"),
         ("gross_revenue","float"),("discount_total","float"),("net_revenue","float"),
         ("return_count","int"),("return_amount","float"),("unique_customers","int")],
        daily_summary)

    write_parquet(ICEBERG_DIR / "customer_ltv_monthly.parquet",
        [("customer_id","str"),("snapshot_year","int"),("snapshot_month","int"),
         ("snapshot_date","date"),("ltv","float"),("cumulative_orders","int"),
         ("orders_this_month","int"),("spend_this_month","float"),
         ("loyalty_tier","str"),("is_active","bool")],
        ltv_monthly)

    write_parquet(ICEBERG_DIR / "product_performance_weekly.parquet",
        [("product_id","str"),("product_category","str"),
         ("week_start_date","date"),("week_year","int"),("week_of_year","int"),
         ("units_sold","int"),("gross_revenue","float"),
         ("average_selling_price","float"),("return_rate","float"),
         ("review_count","int"),("rating_average","float"),
         ("stock_start_of_week","int"),("stock_end_of_week","int"),
         ("velocity_rank","int")],
        weekly_perf)

    write_parquet(ICEBERG_DIR / "cohort_retention.parquet",
        [("cohort_year","int"),("cohort_month","int"),("months_since_acquisition","int"),
         ("cohort_size","int"),("active_customers","int"),
         ("retention_rate","float"),("revenue_in_period","float"),
         ("avg_revenue_per_active","float")],
        cohort)

    write_parquet(ICEBERG_DIR / "marketing_attribution.parquet",
        [("conversion_id","str"),("customer_id","str"),("order_id","str"),
         ("conversion_timestamp","ts"),("conversion_year","int"),("conversion_month","int"),
         ("campaign_id","str"),("campaign_name","str"),("channel","str"),
         ("touch_count","int"),("days_to_conversion","int"),
         ("conversion_value","float"),("attributed_revenue","float")],
        attribution)

    write_parquet(ICEBERG_DIR / "competitor_prices_weekly.parquet",
        [("week_start_date","date"),("week_year","int"),
         ("our_product_id","str"),("our_sku","str"),
         ("competitor_name","str"),("competitor_sku","str"),
         ("competitor_price","float"),("currency","str"),
         ("in_stock","bool"),("crawl_source","str"),("crawl_timestamp","ts")],
        competitor_prices)

# --- main -----------------------------------------------------------------

def main():
    print("Generating e-commerce sample data...")
    CASS_DIR.mkdir(parents=True, exist_ok=True)
    ICEBERG_DIR.mkdir(parents=True, exist_ok=True)

    print("  Customers...");           customers = generate_customers()
    print("  Products...");             products = generate_products()
    print("  Archive orders...");       archive_orders, archive_items = generate_archive_orders(customers, products)
    print("  Inflight orders...");      inflight_orders, inflight_items = generate_inflight_orders(customers, products)

    # Backfill current LTV / order count on customers from delivered archive orders.
    stats = defaultdict(lambda: {"n": 0, "spend": Decimal("0")})
    for o in archive_orders:
        if o["order_status"] == "delivered":
            stats[o["customer_id"]]["n"] += 1
            stats[o["customer_id"]]["spend"] += o["total_amount"]
    for c in customers:
        s = stats[c["customer_id"]]
        c["total_orders"] = s["n"]
        c["current_ltv"] = s["spend"].quantize(Decimal("0.01"))

    print("  Daily sales summary...");  daily_summary = derive_daily_sales_summary(archive_orders, archive_items)
    print("  Product performance...");  weekly_perf = derive_product_performance_weekly(archive_orders, archive_items, products)
    print("  Customer LTV monthly..."); ltv_monthly = derive_customer_ltv_monthly(customers, archive_orders)
    print("  Cohort retention...");     cohort = derive_cohort_retention(customers, archive_orders)
    print("  Marketing attribution..."); attribution = generate_marketing_attribution(archive_orders)
    print("  Competitor prices...");    competitor_prices = generate_competitor_prices(products)

    print("  Active carts...");         active_carts = generate_active_carts(customers, products)
    print("  Live sessions...");        live_sessions = generate_live_sessions(customers)
    print("  Inventory ledger...");     inventory_recent = generate_inventory_ledger_recent(products)
    print("  Reviews recent...");       reviews_recent = generate_reviews_recent(customers, products)

    print("Writing Cassandra CSVs...")
    write_cassandra_csvs(customers, products, active_carts, inflight_orders, inflight_items,
                          live_sessions, inventory_recent, reviews_recent)
    print("Writing Iceberg Parquet files...")
    write_iceberg_parquet(archive_orders, archive_items, daily_summary, weekly_perf,
                          ltv_monthly, cohort, attribution, competitor_prices)

    print()
    print("Done. Summary:")
    print(f"  Customers:              {len(customers):>7}")
    print(f"  Products:               {len(products):>7}")
    print(f"  Active carts (rows):    {len(active_carts):>7}")
    print(f"  In-flight orders:       {len(inflight_orders):>7}  (+{len(inflight_items)} items)")
    print(f"  Live sessions:          {len(live_sessions):>7}")
    print(f"  Inventory ledger:       {len(inventory_recent):>7}")
    print(f"  Reviews (recent):       {len(reviews_recent):>7}")
    print(f"  Archive orders:         {len(archive_orders):>7}  (+{len(archive_items)} items)")
    print(f"  Daily sales summary:    {len(daily_summary):>7}")
    print(f"  Weekly product perf:    {len(weekly_perf):>7}")
    print(f"  Customer LTV monthly:   {len(ltv_monthly):>7}")
    print(f"  Cohort retention:       {len(cohort):>7}")
    print(f"  Marketing attribution:  {len(attribution):>7}")
    print(f"  Competitor prices:      {len(competitor_prices):>7}")
    print()
    print(f"Cassandra CSVs  → {CASS_DIR}")
    print(f"Iceberg SQL     → {ICEBERG_DIR}")
    print()
    _print_promo_calendar()

if __name__ == "__main__":
    main()
