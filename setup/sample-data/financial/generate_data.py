#!/usr/bin/env python3
"""
Financial Sample Data Generator

Cassandra holds customers, accounts with live balances, in-flight transaction
authorizations, pending transfers, open fraud cases, last-30d card activity,
and current card statuses. Iceberg holds archived transactions, monthly
statements, fraud training labels, quarterly risk snapshots, daily portfolio
metrics, regulatory filings, and an external market data feed.

Portfolio-analytics signals
---------------------------
Two narrative overlays so the analytics workshop sees real shape, not white
noise. (Fraud detection is intentionally out of scope here.)

  Market regime    `market_data_daily` is built as three regimes across the
                   last 120 days:
                     [120..60 days ago]  default drift  (~+0.04%/day)
                     [ 60..30 days ago]  drawdown       (~−0.50%/day, vol up)
                     [ 30.. 0 days ago]  recovery       (~+0.40%/day)
                   The drawdown/recovery windows are pinned inside the
                   60-day `portfolio_metrics_daily` horizon so portfolio
                   charts show both the dip and the rebound. Each
                   investment account has a beta in [0.6, 1.2] applied
                   to the market drift.

  Monthly txn      `transactions_archive` amounts are scaled by month —
  seasonality      Nov/Dec ~+50%, Jan ~−30%, summer ~−5%, mild bumps
                   elsewhere — so `account_statements_monthly` totals
                   reflect a holiday/post-holiday pattern instead of a
                   flat random per-month average. Txn counts unchanged.

The market regime windows and seasonality multipliers are documented as
constants below so workshop attendees can verify their queries pick them up.
"""
from __future__ import annotations

import csv
import random
import sys
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _arrow_helpers import write_parquet  # type: ignore  # noqa: E402

# Sizing — tuned for fast Iceberg ingest (each INSERT batch < 1MB query text).
CUSTOMERS_COUNT = 800
ACCOUNTS_PER_CUSTOMER_MIN = 1
ACCOUNTS_PER_CUSTOMER_MAX = 2

AUTHORIZING_COUNT = 150
PENDING_TRANSFERS_COUNT = 80
FRAUD_ALERTS_OPEN_COUNT = 35
CARD_TXN_RECENT_PER_CARD = 15

ARCHIVE_TXN_COUNT = 5000
STATEMENTS_MONTHS = 6
FRAUD_LABELS_COUNT = 250
RISK_QUARTERS = 4
PORTFOLIO_DAYS = 60
REG_FILINGS_COUNT = 100
MARKET_TICKERS = 20
MARKET_DAYS = 120


OUTPUT_DIR = Path(__file__).parent / "generated_data"
CASS_DIR = OUTPUT_DIR / "cassandra"
ICEBERG_DIR = OUTPUT_DIR / "iceberg"

TODAY = date(2026, 4, 23)
NOW_TS = datetime(2026, 4, 23, 9, 0, 0)

ACCOUNT_TYPES = ["checking", "savings", "credit", "investment"]
ACCOUNT_TYPE_WEIGHTS = [0.40, 0.30, 0.20, 0.10]
MERCHANT_CATEGORIES = [
    "grocery", "gas", "restaurant", "travel", "online_retail", "streaming",
    "utilities", "healthcare", "entertainment", "electronics", "clothing",
    "home_improvement", "subscription", "coffee_shop", "parking", "insurance"
]
MERCHANTS = {
    "grocery": ["FreshMart", "Kroger-Like", "Whole Foods Peer", "Trader Jack"],
    "gas": ["Shell-ish", "BP-ish", "Chevron Peer", "LocalGas"],
    "restaurant": ["Bistro 42", "The Table", "Pasta Palace", "Grill Yard"],
    "travel": ["Aero Airlines", "Rail Co", "HotelPoint", "Rental Cars Inc"],
    "online_retail": ["Zamazon", "BigOnline", "MarketWeb", "ShopNet"],
    "streaming": ["FlixBox", "MusicPlay", "StreamWave"],
    "utilities": ["PowerCo", "WaterBoard", "GasMunicipal"],
    "healthcare": ["MediCenter", "Pharmacy Plus", "Clinic Group"],
    "entertainment": ["CineMax-like", "Concerts Ltd", "ThemeLand"],
    "electronics": ["TechShack", "ByteStore", "GearUp"],
    "clothing": ["Apparel Co", "Denim Works", "SportStyle"],
    "home_improvement": ["HomeHub", "FixItDepot", "GardenPlus"],
    "subscription": ["Pro SaaS", "CloudBox", "SoftwareSub"],
    "coffee_shop": ["BeanScene", "Brew Corner", "Cafe Lane"],
    "parking": ["CityPark", "LotCo", "ParkSmart"],
    "insurance": ["Shield Ins", "Safe Mutual", "Auto Guard"],
}
CHANNELS = ["card", "online", "atm", "mobile"]
TRANSACTION_TYPES = ["purchase", "withdrawal", "transfer", "payment"]
TRANSACTION_WEIGHTS = [0.70, 0.08, 0.12, 0.10]
AUTH_STATUSES = ["approved", "approved", "approved", "approved", "declined"]
DECLINE_REASONS = ["insufficient_funds", "card_blocked", "fraud_hold", "network_error"]
CARD_NETWORKS = ["visa", "mastercard", "amex"]
CARD_NETWORK_WEIGHTS = [0.55, 0.35, 0.10]
CARD_TYPES = ["debit", "credit"]
FRAUD_TYPES = ["card_not_present", "account_takeover", "synthetic_id", "merchant_collusion"]
FRAUD_ALERT_TYPES = ["velocity", "geo_anomaly", "amount_anomaly", "card_not_present"]
ALERT_SEVERITIES = ["low", "medium", "high", "critical"]
ALERT_SEVERITY_WEIGHTS = [0.40, 0.30, 0.20, 0.10]
FILING_TYPES = ["SAR", "CTR", "OFAC", "314a", "FBAR"]
FILING_WEIGHTS = [0.45, 0.30, 0.08, 0.12, 0.05]
RISK_TIERS = ["low", "medium", "high", "restricted"]
RISK_TIER_WEIGHTS = [0.60, 0.28, 0.10, 0.02]
FIRST_NAMES = ["James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael",
               "Linda", "William", "Elizabeth", "David", "Barbara", "Richard", "Susan",
               "Joseph", "Jessica", "Thomas", "Sarah", "Charles", "Karen"]
LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
              "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
              "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin"]
CITIES = [("New York", "NY"), ("Los Angeles", "CA"), ("Chicago", "IL"), ("Houston", "TX"),
          ("Phoenix", "AZ"), ("Philadelphia", "PA"), ("Austin", "TX"), ("Seattle", "WA"),
          ("Boston", "MA"), ("Denver", "CO"), ("Atlanta", "GA"), ("Miami", "FL")]
TICKERS = {
    "equity": ["AAPL", "MSFT", "GOOGL", "AMZN", "NVDA", "META", "TSLA", "JPM", "V", "WMT",
               "PG", "JNJ", "XOM", "BA", "CAT", "DIS", "NFLX", "CRM", "ADBE", "ORCL"],
    "bond":   ["US10Y", "US30Y", "CORP-IG", "CORP-HY", "TIPS5"],
    "fx":     ["EUR/USD", "GBP/USD", "USD/JPY", "USD/CHF", "USD/CAD", "AUD/USD"],
    "commodity": ["GLD", "SLV", "WTI", "BRENT", "NATGAS"],
    "crypto": ["BTC", "ETH", "SOL", "USDC"],
}

random.seed(42)

# --- portfolio-analytics signal overlays (see module docstring) ----------

# Three regimes layered across the last 120 days. Each entry is
# (start_day_back, end_day_back, daily_drift_mean, daily_vol).
# Windows are inclusive on the upper bound, exclusive on the lower, so
# the boundary days fall into the older regime.
MARKET_REGIMES = [
    (60, 30, -0.0050, 0.025),   # drawdown — visible in portfolio (60d horizon)
    (30,  0, +0.0040, 0.018),   # recovery — most recent 30 days
]
MARKET_DEFAULT_DRIFT = 0.0004
MARKET_DEFAULT_VOL   = 0.015

def _market_regime(day_back: int) -> tuple[float, float]:
    """Return (daily_drift_mean, daily_vol) for a given day-back from TODAY."""
    for start, end, drift, vol in MARKET_REGIMES:
        if end < day_back <= start:
            return drift, vol
    return MARKET_DEFAULT_DRIFT, MARKET_DEFAULT_VOL

# Monthly transaction-amount seasonality. Multiplier applied to amount in
# transactions_archive so account_statements_monthly totals reflect a real
# pattern. Mean across 12 months is ~1.0 so total volume stays steady.
TXN_SEASONALITY = {
    1: 0.70, 2: 0.85, 3: 0.95, 4: 1.00, 5: 1.00, 6: 0.95,
    7: 0.95, 8: 1.00, 9: 1.00, 10: 1.05, 11: 1.40, 12: 1.55,
}

# Per-account portfolio sensitivity to the market regime. Picked by a
# dedicated RNG so we don't perturb the rest of the random stream.
_fin_signal_rng = random.Random(20260423)
PORTFOLIO_BETA: dict[str, float] = {}

def _portfolio_beta(account_id: str) -> float:
    if account_id not in PORTFOLIO_BETA:
        PORTFOLIO_BETA[account_id] = _fin_signal_rng.uniform(0.6, 1.2)
    return PORTFOLIO_BETA[account_id]

def _print_signal_summary():
    print("Encoded market regimes (day_back range → drift/vol):")
    for start, end, drift, vol in MARKET_REGIMES:
        print(f"  ({end:>3}..{start:>3}d ago]  drift={drift:+.4f}/day  vol={vol:.3f}")
    print(f"  default               drift={MARKET_DEFAULT_DRIFT:+.4f}/day  vol={MARKET_DEFAULT_VOL:.3f}")
    print("Encoded txn seasonality (month → amount multiplier):")
    months = " ".join(f"{m:>2}:{TXN_SEASONALITY[m]:.2f}" for m in range(1, 13))
    print(f"  {months}")

# --- helpers --------------------------------------------------------------
def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)

def pick(pool, weights=None):
    return random.choices(pool, weights=weights, k=1)[0] if weights else random.choice(pool)

def pick_merchant():
    cat = pick(MERCHANT_CATEGORIES)
    merchant = pick(MERCHANTS[cat])
    return merchant, cat

# --- pools ----------------------------------------------------------------
def generate_customers():
    rows = []
    for i in range(CUSTOMERS_COUNT):
        fn = pick(FIRST_NAMES); ln = pick(LAST_NAMES)
        city, state = pick(CITIES)
        dob = date(random.randint(1945, 2005), random.randint(1, 12), random.randint(1, 28))
        created = TODAY - timedelta(days=random.randint(60, 2500))
        rows.append({
            "customer_id": str(uuid.uuid4()),
            "email": f"{fn.lower()}.{ln.lower()}{i}@example.com",
            "first_name": fn, "last_name": ln,
            "phone": f"+1-{random.randint(200,999)}-{random.randint(100,999)}-{random.randint(1000,9999)}",
            "date_of_birth": dob,
            "ssn_last4": f"{random.randint(1000,9999)}",
            "created_at": datetime.combine(created, datetime.min.time()) + timedelta(hours=random.randint(0,23)),
            "account_status": "active" if random.random() < 0.96 else pick(["suspended", "closed"]),
            "risk_tier": pick(RISK_TIERS, RISK_TIER_WEIGHTS),
            "kyc_verified": random.random() < 0.97,
            "home_city": city, "home_state": state, "home_country": "USA",
            "updated_at": NOW_TS - timedelta(hours=random.randint(0, 24*30)),
        })
    return rows

def generate_accounts(customers):
    rows = []
    for c in customers:
        n = random.randint(ACCOUNTS_PER_CUSTOMER_MIN, ACCOUNTS_PER_CUSTOMER_MAX)
        types_chosen = random.sample(ACCOUNT_TYPES, min(n, len(ACCOUNT_TYPES)))
        for atype in types_chosen:
            opened = c["created_at"] + timedelta(days=random.randint(0, 90))
            balance = Decimal(str(round(random.uniform(50, 150000), 2)))
            holds = Decimal(str(round(random.uniform(0, float(balance) * 0.1), 2)))
            rows.append({
                "account_id": str(uuid.uuid4()),
                "customer_id": c["customer_id"],
                "account_type": atype,
                "account_number_masked": f"****{random.randint(1000,9999)}",
                "opened_at": opened,
                "status": "active" if c["account_status"] == "active" and random.random() < 0.98 else pick(["frozen", "closed"]),
                "current_balance": balance,
                "available_balance": (balance - holds).quantize(Decimal("0.01")),
                "credit_limit": Decimal(str(round(random.uniform(5000, 50000), 2))) if atype == "credit" else Decimal("0"),
                "currency": "USD",
                "updated_at": NOW_TS - timedelta(hours=random.randint(0, 72)),
            })
    return rows

def generate_cards(accounts):
    rows = []
    for a in accounts:
        if a["account_type"] not in ("checking", "credit"): continue
        if a["status"] != "active": continue
        n = 1 if random.random() < 0.8 else 2
        for _ in range(n):
            issued = a["opened_at"] + timedelta(days=random.randint(1, 30))
            expires = issued.date() + timedelta(days=365 * random.randint(3, 5))
            rows.append({
                "card_id": str(uuid.uuid4()),
                "account_id": a["account_id"],
                "customer_id": a["customer_id"],
                "card_number_last4": f"{random.randint(1000,9999)}",
                "card_type": "credit" if a["account_type"] == "credit" else "debit",
                "network": pick(CARD_NETWORKS, CARD_NETWORK_WEIGHTS),
                "status": pick(["active", "active", "active", "active", "active", "blocked", "frozen", "expired"]),
                "issued_at": issued,
                "expires_on": expires,
                "status_updated_at": NOW_TS - timedelta(days=random.randint(0, 365)),
            })
    return rows

# --- Cassandra hot tables -------------------------------------------------
def generate_transactions_authorizing(accounts):
    rows = []
    active_accounts = [a for a in accounts if a["status"] == "active"]
    for _ in range(AUTHORIZING_COUNT):
        a = pick(active_accounts)
        merchant, mcc = pick_merchant()
        rows.append({
            "account_id": a["account_id"],
            "transaction_id": str(uuid.uuid1()),
            "initiated_at": NOW_TS - timedelta(seconds=random.randint(1, 120)),
            "amount": Decimal(str(round(random.uniform(1, 2500), 2))),
            "currency": "USD",
            "transaction_type": pick(TRANSACTION_TYPES, TRANSACTION_WEIGHTS),
            "merchant_name": merchant, "merchant_category": mcc,
            "merchant_country": pick(["USA", "USA", "USA", "USA", "CAN", "MEX", "GBR"]),
            "channel": pick(CHANNELS, [0.50, 0.30, 0.08, 0.12]),
            "auth_status": pick(["requesting", "requesting", "approved", "declined"]),
            "auth_code": f"AUTH{random.randint(100000,999999)}",
            "decline_reason": pick(DECLINE_REASONS) if random.random() < 0.15 else None,
        })
    return rows

def generate_transfers_pending(accounts):
    rows = []
    for _ in range(PENDING_TRANSFERS_COUNT):
        src = pick([a for a in accounts if a["status"] == "active"])
        rows.append({
            "source_account_id": src["account_id"],
            "transfer_id": str(uuid.uuid4()),
            "initiated_at": NOW_TS - timedelta(hours=random.randint(1, 48)),
            "transfer_type": pick(["wire", "ach", "internal"], [0.15, 0.60, 0.25]),
            "destination_account": f"****{random.randint(1000,9999)}",
            "destination_bank": pick(["Chase-like", "BofA-like", "Wells-like", "International Bank", "Credit Union"]),
            "amount": Decimal(str(round(random.uniform(50, 50000), 2))),
            "currency": "USD",
            "status": pick(["pending", "processing", "flagged"], [0.55, 0.35, 0.10]),
            "scheduled_settlement": TODAY + timedelta(days=random.randint(0, 3)),
        })
    return rows

def generate_card_transactions_recent(cards, accounts):
    acct_by_id = {a["account_id"]: a for a in accounts}
    rows = []
    for card in cards:
        if card["status"] != "active": continue
        for _ in range(random.randint(CARD_TXN_RECENT_PER_CARD // 2, CARD_TXN_RECENT_PER_CARD)):
            dt = TODAY - timedelta(days=random.randint(0, 30))
            ts = datetime.combine(dt, datetime.min.time()) + timedelta(
                hours=random.randint(0, 23), minutes=random.randint(0, 59))
            merchant, mcc = pick_merchant()
            rows.append({
                "card_id": card["card_id"],
                "txn_date": dt,
                "transaction_id": str(uuid.uuid4()),
                "account_id": card["account_id"],
                "customer_id": card["customer_id"],
                "txn_timestamp": ts,
                "amount": Decimal(str(round(random.uniform(1, 800), 2))),
                "currency": "USD",
                "merchant_name": merchant, "merchant_category": mcc,
                "merchant_country": pick(["USA", "USA", "USA", "USA", "CAN", "MEX", "GBR"]),
                "posted": random.random() < 0.95,
            })
    return rows

def generate_fraud_alerts_open(customers, card_txns):
    rows = []
    # Pick some triggering transactions
    sample_txns = random.sample(card_txns, min(FRAUD_ALERTS_OPEN_COUNT * 2, len(card_txns))) if card_txns else []
    for i in range(FRAUD_ALERTS_OPEN_COUNT):
        trig = sample_txns[i] if i < len(sample_txns) else None
        cust_id = trig["customer_id"] if trig else pick(customers)["customer_id"]
        txn_id = trig["transaction_id"] if trig else str(uuid.uuid4())
        rows.append({
            "customer_id": cust_id,
            "alert_id": str(uuid.uuid4()),
            "raised_at": NOW_TS - timedelta(minutes=random.randint(10, 2880)),
            "severity": pick(ALERT_SEVERITIES, ALERT_SEVERITY_WEIGHTS),
            "alert_type": pick(FRAUD_ALERT_TYPES),
            "triggering_txn_id": txn_id,
            "risk_score": Decimal(str(round(random.uniform(50, 99), 2))),
            "status": pick(["open", "investigating", "escalated"], [0.60, 0.30, 0.10]),
            "assigned_to": pick(["fraud-ops-1", "fraud-ops-2", "fraud-ml", "analyst-5"]),
        })
    return rows

# --- Iceberg historical/analytical/external -------------------------------
def generate_transactions_archive(customers, accounts):
    rows = []
    active_accounts = [a for a in accounts if a["status"] == "active"]
    for _ in range(ARCHIVE_TXN_COUNT):
        a = pick(active_accounts)
        dt = TODAY - timedelta(days=random.randint(31, 720))
        ts = datetime.combine(dt, datetime.min.time()) + timedelta(
            hours=random.randint(0, 23), minutes=random.randint(0, 59))
        merchant, mcc = pick_merchant()
        base_amount = random.uniform(1, 5000)
        amount = Decimal(str(round(base_amount * TXN_SEASONALITY[dt.month], 2)))
        status = pick(["posted", "posted", "posted", "posted", "reversed", "disputed"])
        posted_at = ts + timedelta(hours=random.randint(1, 72)) if status == "posted" else None
        rows.append({
            "transaction_id": str(uuid.uuid4()),
            "account_id": a["account_id"],
            "customer_id": a["customer_id"],
            "txn_date": dt, "txn_year": dt.year, "txn_month": dt.month,
            "txn_timestamp": ts,
            "transaction_type": pick(TRANSACTION_TYPES, TRANSACTION_WEIGHTS),
            "amount": amount, "currency": "USD",
            "merchant_name": merchant, "merchant_category": mcc,
            "merchant_country": pick(["USA", "USA", "USA", "CAN", "MEX", "GBR", "DEU", "FRA"]),
            "channel": pick(CHANNELS, [0.45, 0.35, 0.08, 0.12]),
            "status": status, "posted_at": posted_at,
        })
    return rows

def derive_account_statements(accounts, archive_txns):
    by_acct_month = defaultdict(lambda: {"credits": Decimal("0"), "debits": Decimal("0"),
                                          "count": 0, "min": Decimal("0"), "max": Decimal("0")})
    for t in archive_txns:
        k = (t["account_id"], t["txn_year"], t["txn_month"])
        b = by_acct_month[k]
        b["count"] += 1
        if t["transaction_type"] in ("purchase", "withdrawal", "payment"):
            b["debits"] += t["amount"]
        else:
            b["credits"] += t["amount"]
    # Build statements for trailing 12 months
    months = []
    y, m = TODAY.year, TODAY.month
    for back in range(1, STATEMENTS_MONTHS + 1):
        mm = m - back; yy = y
        while mm <= 0: mm += 12; yy -= 1
        months.append((yy, mm))
    rows = []
    for a in accounts:
        balance = a["current_balance"] * Decimal(str(random.uniform(0.6, 1.0)))
        for (yy, mm) in sorted(months):
            b = by_acct_month.get((a["account_id"], yy, mm))
            opening = balance
            credits = b["credits"] if b else Decimal("0")
            debits = b["debits"] if b else Decimal("0")
            fees = (debits * Decimal("0.005")).quantize(Decimal("0.01"))
            interest = (opening * Decimal("0.0015") if a["account_type"] == "savings" else Decimal("0")).quantize(Decimal("0.01"))
            closing = (opening + credits - debits - fees + interest).quantize(Decimal("0.01"))
            period_start = date(yy, mm, 1)
            period_end = date(yy + (1 if mm == 12 else 0), 1 if mm == 12 else mm + 1, 1) - timedelta(days=1)
            rows.append({
                "statement_id": str(uuid.uuid4()),
                "account_id": a["account_id"], "customer_id": a["customer_id"],
                "statement_year": yy, "statement_month": mm,
                "period_start": period_start, "period_end": period_end,
                "opening_balance": opening.quantize(Decimal("0.01")),
                "closing_balance": closing,
                "total_credits": credits.quantize(Decimal("0.01")),
                "total_debits": debits.quantize(Decimal("0.01")),
                "transaction_count": b["count"] if b else 0,
                "fees_charged": fees,
                "interest_earned": interest,
                "minimum_balance": (opening * Decimal(str(random.uniform(0.3, 0.95)))).quantize(Decimal("0.01")),
            })
            balance = closing
    return rows

def generate_fraud_training_labels(archive_txns):
    rows = []
    sampled = random.sample(archive_txns, min(FRAUD_LABELS_COUNT, len(archive_txns)))
    for t in sampled:
        labeled_at = t["txn_timestamp"] + timedelta(days=random.randint(1, 60))
        is_fraud = random.random() < 0.30  # labeled set is enriched for fraud
        loss = t["amount"] * Decimal(str(round(random.uniform(0.3, 1.0), 2))) if is_fraud else Decimal("0")
        recovered = loss * Decimal(str(round(random.uniform(0.0, 0.6), 2))) if is_fraud else Decimal("0")
        rows.append({
            "label_id": str(uuid.uuid4()),
            "transaction_id": t["transaction_id"],
            "customer_id": t["customer_id"],
            "labeled_at": labeled_at, "label_year": labeled_at.year,
            "is_fraud": is_fraud,
            "fraud_type": pick(FRAUD_TYPES) if is_fraud else None,
            "confidence": Decimal(str(round(random.uniform(0.70, 0.99), 3))),
            "loss_amount": loss.quantize(Decimal("0.01")),
            "recovered_amount": recovered.quantize(Decimal("0.01")),
            "labeled_by": pick(["analyst", "rule_engine", "customer_dispute"]),
            "investigation_days": random.randint(1, 60),
        })
    return rows

def generate_risk_assessment_history(customers):
    # Last 6 quarters
    rows = []
    y, q = TODAY.year, (TODAY.month - 1) // 3 + 1
    quarters = []
    for back in range(0, RISK_QUARTERS):
        qq = q - back; yy = y
        while qq <= 0: qq += 4; yy -= 1
        quarters.append((yy, qq))
    for c in customers:
        for (yy, qq) in quarters:
            month_of_q = (qq - 1) * 3 + 3  # last month of quarter
            snapshot_date = date(yy, month_of_q, 28)
            score = round(random.uniform(20, 95), 2)
            tier = ("low" if score < 40 else "medium" if score < 70 else
                    "high" if score < 88 else "restricted")
            limit = round(random.uniform(5000, 100000), 2)
            util = round(random.uniform(0, 95), 2)
            rows.append({
                "customer_id": c["customer_id"],
                "snapshot_year": yy, "snapshot_quarter": qq,
                "snapshot_date": snapshot_date,
                "risk_score": Decimal(str(score)), "risk_tier": tier,
                "model_version": pick(["credit-v2.1", "credit-v2.3", "credit-v3.0"]),
                "pd_12mo": Decimal(str(round(random.uniform(0.0005, 0.15), 4))),
                "loss_given_default": Decimal(str(round(random.uniform(0.20, 0.80), 4))),
                "exposure_at_default": Decimal(str(round(random.uniform(1000, 100000), 2))),
                "credit_limit": Decimal(str(limit)),
                "utilization_pct": Decimal(str(util)),
            })
    return rows

def generate_portfolio_metrics(customers, accounts):
    # Only customers with an investment account get portfolio metrics
    inv_accts = [a for a in accounts if a["account_type"] == "investment" and a["status"] == "active"]
    rows = []
    cumulative = defaultdict(lambda: 0.0)
    for a in inv_accts:
        value = float(a["current_balance"]) * random.uniform(0.85, 1.15)
        for day_back in range(PORTFOLIO_DAYS, 0, -1):
            dt = TODAY - timedelta(days=day_back)
            # Track the market regime, scaled by the account's beta.
            mu, sigma = _market_regime(day_back)
            beta = _portfolio_beta(a["account_id"])
            daily_return = random.gauss(mu * beta, sigma * beta)
            prev = value
            value *= (1 + daily_return)
            daily_pnl = value - prev
            cumulative[a["account_id"]] = (cumulative[a["account_id"]] + 1) * (1 + daily_return) - 1 \
                                           if cumulative[a["account_id"]] else daily_return
            rows.append({
                "customer_id": a["customer_id"],
                "account_id": a["account_id"],
                "metric_date": dt, "metric_year": dt.year, "metric_month": dt.month,
                "portfolio_value": Decimal(str(round(value, 2))),
                "daily_pnl": Decimal(str(round(daily_pnl, 2))),
                "daily_return_pct": Decimal(str(round(daily_return * 100, 5))),
                "cumulative_return_pct": Decimal(str(round(cumulative[a["account_id"]] * 100, 5))),
                "volatility_30d": Decimal(str(round(random.uniform(0.5, 3.5), 5))),
                "sharpe_ratio": Decimal(str(round(random.uniform(-0.5, 2.5), 3))),
                "asset_class_mix": pick(["60/30/10", "70/20/10", "80/15/5", "50/40/10", "40/50/10"]),
            })
    return rows

def generate_regulatory_filings(customers):
    rows = []
    for _ in range(REG_FILINGS_COUNT):
        c = pick(customers)
        filed_at = NOW_TS - timedelta(days=random.randint(10, 1000),
                                      hours=random.randint(0, 23))
        rows.append({
            "filing_id": str(uuid.uuid4()),
            "customer_id": c["customer_id"],
            "filed_at": filed_at,
            "filing_year": filed_at.year, "filing_month": filed_at.month,
            "filing_type": pick(FILING_TYPES, FILING_WEIGHTS),
            "regulator": pick(["FinCEN", "OCC", "OFAC", "FDIC", "SEC"]),
            "amount_reported": Decimal(str(round(random.uniform(10000, 500000), 2))),
            "status": pick(["filed", "acknowledged", "amended", "closed"], [0.20, 0.45, 0.10, 0.25]),
            "trigger_reason": pick(["large_cash_deposit", "suspicious_pattern", "sanctions_match",
                                     "structuring", "unusual_beneficiary", "kyc_discrepancy"]),
        })
    return rows

def generate_market_data():
    rows = []
    chosen = []
    # Spread across asset classes
    for cls, tkrs in TICKERS.items():
        chosen.extend([(cls, t) for t in tkrs[:MARKET_TICKERS // len(TICKERS) + 2]])
    chosen = chosen[:MARKET_TICKERS]
    for (cls, ticker) in chosen:
        price = random.uniform(20, 500) if cls == "equity" else random.uniform(0.5, 2000)
        for day_back in range(MARKET_DAYS, 0, -1):
            dt = TODAY - timedelta(days=day_back)
            # weekdays only for equities/bonds
            if cls in ("equity", "bond") and dt.weekday() >= 5:
                continue
            mu, sigma = _market_regime(day_back)
            drift = random.gauss(mu, sigma)
            open_p = price
            close_p = open_p * (1 + drift)
            high = max(open_p, close_p) * (1 + random.uniform(0, 0.015))
            low = min(open_p, close_p) * (1 - random.uniform(0, 0.015))
            volume = random.randint(100000, 20000000) if cls == "equity" else random.randint(1000, 500000)
            rows.append({
                "ticker": ticker, "asset_class": cls,
                "quote_date": dt, "quote_year": dt.year,
                "open_price": Decimal(str(round(open_p, 4))),
                "high_price": Decimal(str(round(high, 4))),
                "low_price": Decimal(str(round(low, 4))),
                "close_price": Decimal(str(round(close_p, 4))),
                "volume": volume,
                "currency": "USD",
                "source": "market_vendor_x",
            })
            price = close_p
    return rows

# --- writers --------------------------------------------------------------
def write_cassandra_csvs(customers, accounts, cards, auth_txns, transfers_pending,
                          card_txns_recent, fraud_alerts):
    write_csv(CASS_DIR / "customers.csv",
        ["customer_id","email","first_name","last_name","phone","date_of_birth","ssn_last4",
         "created_at","account_status","risk_tier","kyc_verified","home_city","home_state",
         "home_country","updated_at"],
        [[c["customer_id"], c["email"], c["first_name"], c["last_name"], c["phone"],
          c["date_of_birth"].isoformat(), c["ssn_last4"], c["created_at"].isoformat(),
          c["account_status"], c["risk_tier"], c["kyc_verified"], c["home_city"],
          c["home_state"], c["home_country"], c["updated_at"].isoformat()]
         for c in customers])

    write_csv(CASS_DIR / "accounts.csv",
        ["account_id","customer_id","account_type","account_number_masked","opened_at","status",
         "current_balance","available_balance","credit_limit","currency","updated_at"],
        [[a["account_id"], a["customer_id"], a["account_type"], a["account_number_masked"],
          a["opened_at"].isoformat(), a["status"], str(a["current_balance"]),
          str(a["available_balance"]), str(a["credit_limit"]), a["currency"],
          a["updated_at"].isoformat()] for a in accounts])

    write_csv(CASS_DIR / "card_status_current.csv",
        ["card_id","account_id","customer_id","card_number_last4","card_type","network","status",
         "issued_at","expires_on","status_updated_at"],
        [[c["card_id"], c["account_id"], c["customer_id"], c["card_number_last4"],
          c["card_type"], c["network"], c["status"], c["issued_at"].isoformat(),
          c["expires_on"].isoformat(), c["status_updated_at"].isoformat()] for c in cards])

    write_csv(CASS_DIR / "transactions_authorizing.csv",
        ["account_id","transaction_id","initiated_at","amount","currency","transaction_type",
         "merchant_name","merchant_category","merchant_country","channel","auth_status",
         "auth_code","decline_reason"],
        [[r["account_id"], r["transaction_id"], r["initiated_at"].isoformat(),
          str(r["amount"]), r["currency"], r["transaction_type"], r["merchant_name"],
          r["merchant_category"], r["merchant_country"], r["channel"], r["auth_status"],
          r["auth_code"], r["decline_reason"] or ""] for r in auth_txns])

    write_csv(CASS_DIR / "transfers_pending.csv",
        ["source_account_id","transfer_id","initiated_at","transfer_type","destination_account",
         "destination_bank","amount","currency","status","scheduled_settlement"],
        [[r["source_account_id"], r["transfer_id"], r["initiated_at"].isoformat(),
          r["transfer_type"], r["destination_account"], r["destination_bank"],
          str(r["amount"]), r["currency"], r["status"],
          r["scheduled_settlement"].isoformat()] for r in transfers_pending])

    write_csv(CASS_DIR / "card_transactions_recent.csv",
        ["card_id","txn_date","transaction_id","account_id","customer_id","txn_timestamp",
         "amount","currency","merchant_name","merchant_category","merchant_country","posted"],
        [[r["card_id"], r["txn_date"].isoformat(), r["transaction_id"], r["account_id"],
          r["customer_id"], r["txn_timestamp"].isoformat(), str(r["amount"]), r["currency"],
          r["merchant_name"], r["merchant_category"], r["merchant_country"], r["posted"]]
         for r in card_txns_recent])

    write_csv(CASS_DIR / "fraud_alerts_open.csv",
        ["customer_id","alert_id","raised_at","severity","alert_type","triggering_txn_id",
         "risk_score","status","assigned_to"],
        [[r["customer_id"], r["alert_id"], r["raised_at"].isoformat(), r["severity"],
          r["alert_type"], r["triggering_txn_id"], str(r["risk_score"]),
          r["status"], r["assigned_to"]] for r in fraud_alerts])

def write_iceberg_parquet(archive_txns, statements, fraud_labels, risk_hist, portfolio, filings, market):
    write_parquet(ICEBERG_DIR / "transactions_archive.parquet",
        [("transaction_id","str"),("account_id","str"),("customer_id","str"),
         ("txn_date","date"),("txn_year","int"),("txn_month","int"),
         ("txn_timestamp","ts"),("transaction_type","str"),
         ("amount","float"),("currency","str"),
         ("merchant_name","str"),("merchant_category","str"),
         ("merchant_country","str"),("channel","str"),
         ("status","str"),("posted_at","ts")],
        archive_txns)

    write_parquet(ICEBERG_DIR / "account_statements_monthly.parquet",
        [("statement_id","str"),("account_id","str"),("customer_id","str"),
         ("statement_year","int"),("statement_month","int"),
         ("period_start","date"),("period_end","date"),
         ("opening_balance","float"),("closing_balance","float"),
         ("total_credits","float"),("total_debits","float"),
         ("transaction_count","int"),("fees_charged","float"),
         ("interest_earned","float"),("minimum_balance","float")],
        statements)

    write_parquet(ICEBERG_DIR / "fraud_training_labels.parquet",
        [("label_id","str"),("transaction_id","str"),("customer_id","str"),
         ("labeled_at","ts"),("label_year","int"),("is_fraud","bool"),
         ("fraud_type","str"),("confidence","float"),
         ("loss_amount","float"),("recovered_amount","float"),
         ("labeled_by","str"),("investigation_days","int")],
        fraud_labels)

    write_parquet(ICEBERG_DIR / "risk_assessment_history.parquet",
        [("customer_id","str"),("snapshot_year","int"),("snapshot_quarter","int"),
         ("snapshot_date","date"),("risk_score","float"),("risk_tier","str"),
         ("model_version","str"),("pd_12mo","float"),
         ("loss_given_default","float"),("exposure_at_default","float"),
         ("credit_limit","float"),("utilization_pct","float")],
        risk_hist)

    write_parquet(ICEBERG_DIR / "portfolio_metrics_daily.parquet",
        [("customer_id","str"),("account_id","str"),
         ("metric_date","date"),("metric_year","int"),("metric_month","int"),
         ("portfolio_value","float"),("daily_pnl","float"),
         ("daily_return_pct","float"),("cumulative_return_pct","float"),
         ("volatility_30d","float"),("sharpe_ratio","float"),
         ("asset_class_mix","str")],
        portfolio)

    write_parquet(ICEBERG_DIR / "regulatory_filings.parquet",
        [("filing_id","str"),("customer_id","str"),("filed_at","ts"),
         ("filing_year","int"),("filing_month","int"),
         ("filing_type","str"),("regulator","str"),
         ("amount_reported","float"),("status","str"),("trigger_reason","str")],
        filings)

    write_parquet(ICEBERG_DIR / "market_data_daily.parquet",
        [("ticker","str"),("asset_class","str"),
         ("quote_date","date"),("quote_year","int"),
         ("open_price","float"),("high_price","float"),
         ("low_price","float"),("close_price","float"),
         ("volume","int"),("currency","str"),("source","str")],
        market)

# --- main -----------------------------------------------------------------
def main():
    print("Generating financial sample data...")
    CASS_DIR.mkdir(parents=True, exist_ok=True)
    ICEBERG_DIR.mkdir(parents=True, exist_ok=True)

    print("  Customers...");             customers = generate_customers()
    print("  Accounts...");               accounts = generate_accounts(customers)
    print("  Cards...");                  cards = generate_cards(accounts)
    print("  Transactions authorizing..."); auth_txns = generate_transactions_authorizing(accounts)
    print("  Transfers pending...");      transfers_pending = generate_transfers_pending(accounts)
    print("  Card txns recent (30d)...");  card_txns_recent = generate_card_transactions_recent(cards, accounts)
    print("  Fraud alerts open...");      fraud_alerts = generate_fraud_alerts_open(customers, card_txns_recent)

    print("  Transactions archive...");   archive_txns = generate_transactions_archive(customers, accounts)
    print("  Account statements...");     statements = derive_account_statements(accounts, archive_txns)
    print("  Fraud training labels...");  fraud_labels = generate_fraud_training_labels(archive_txns)
    print("  Risk assessment history..."); risk_hist = generate_risk_assessment_history(customers)
    print("  Portfolio metrics daily..."); portfolio = generate_portfolio_metrics(customers, accounts)
    print("  Regulatory filings...");     filings = generate_regulatory_filings(customers)
    print("  Market data daily...");      market = generate_market_data()

    print("Writing Cassandra CSVs...")
    write_cassandra_csvs(customers, accounts, cards, auth_txns, transfers_pending,
                          card_txns_recent, fraud_alerts)
    print("Writing Iceberg Parquet files...")
    write_iceberg_parquet(archive_txns, statements, fraud_labels, risk_hist, portfolio, filings, market)

    print()
    print("Done. Summary:")
    print(f"  Customers:                {len(customers):>7}")
    print(f"  Accounts:                 {len(accounts):>7}")
    print(f"  Cards:                    {len(cards):>7}")
    print(f"  Txns authorizing:         {len(auth_txns):>7}")
    print(f"  Transfers pending:        {len(transfers_pending):>7}")
    print(f"  Card txns (30d):          {len(card_txns_recent):>7}")
    print(f"  Fraud alerts open:        {len(fraud_alerts):>7}")
    print(f"  Transactions archive:     {len(archive_txns):>7}")
    print(f"  Account statements:       {len(statements):>7}")
    print(f"  Fraud training labels:    {len(fraud_labels):>7}")
    print(f"  Risk assessment hist:     {len(risk_hist):>7}")
    print(f"  Portfolio metrics:        {len(portfolio):>7}")
    print(f"  Regulatory filings:       {len(filings):>7}")
    print(f"  Market data daily:        {len(market):>7}")
    print()
    print(f"Cassandra CSVs  → {CASS_DIR}")
    print(f"Iceberg SQL     → {ICEBERG_DIR}")
    print()
    _print_signal_summary()

if __name__ == "__main__":
    main()
