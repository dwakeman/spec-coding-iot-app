-- ============================================================================
-- Financial Federation Queries
--
-- Cassandra: customers, accounts with live balances, in-flight transaction
--            authorizations, pending transfers, open fraud cases, last-30d
--            card activity, current card statuses.
-- Iceberg:   transactions_archive (>30d), account_statements_monthly,
--            fraud_training_labels, risk_assessment_history (quarterly),
--            portfolio_metrics_daily, regulatory_filings, market_data_daily
--            (external feed).
--
-- Prerequisites:
--   1. cassandra_catalog is registered in watsonx.data
--   2. ./setup/sample-data/load-iceberg-data.py has run for financial
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Query 1 — Real-time fraud context for a transaction authorizing NOW
--
-- For every transaction currently in the authorization queue (Cassandra),
-- pull the customer's historical spending baseline at this merchant category
-- (Iceberg transactions_archive) and their current quarterly risk score
-- (Iceberg risk_assessment_history). Lets a fraud engine score the
-- authorization using the customer's own behavior, not just rules.
-- ----------------------------------------------------------------------------
WITH customer_baseline AS (
    SELECT
        customer_id,
        merchant_category,
        AVG(amount) AS avg_amount,
        MAX(amount) AS max_amount,
        COUNT(*)    AS cnt
    FROM iceberg_data.financial.transactions_archive
    WHERE txn_date >= current_date - INTERVAL '180' DAY
      AND status = 'posted'
    GROUP BY customer_id, merchant_category
),
latest_risk AS (
    SELECT
        customer_id,
        risk_score,
        risk_tier,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY snapshot_date DESC
        ) AS rn
    FROM iceberg_data.financial.risk_assessment_history
)
SELECT
    t.account_id,
    t.transaction_id,
    t.initiated_at,
    t.amount             AS authorizing_amount,
    t.merchant_name,
    t.merchant_category,
    t.merchant_country,
    t.channel,
    ROUND(b.avg_amount, 2)  AS baseline_avg_amount,
    ROUND(b.max_amount, 2)  AS baseline_max_amount,
    b.cnt                AS baseline_n,
    ROUND(t.amount / NULLIF(b.avg_amount, 0), 2) AS ratio_vs_avg,
    r.risk_score,
    r.risk_tier,
    CASE
        WHEN r.risk_tier IN ('high', 'restricted')        THEN 'REVIEW'
        WHEN t.amount > b.avg_amount * 5 AND b.cnt > 3     THEN 'REVIEW'
        WHEN t.amount > b.max_amount                       THEN 'WATCH'
        ELSE 'OK'
    END AS auth_recommendation
FROM cassandra_catalog.financial.transactions_authorizing t
JOIN cassandra_catalog.financial.accounts a
  ON a.account_id = t.account_id
LEFT JOIN customer_baseline b
  ON CAST(a.customer_id AS VARCHAR) = b.customer_id
 AND b.merchant_category = t.merchant_category
LEFT JOIN latest_risk r
  ON CAST(a.customer_id AS VARCHAR) = r.customer_id
 AND r.rn = 1
WHERE t.auth_status = 'requesting'
ORDER BY t.initiated_at DESC
LIMIT 30;


-- ----------------------------------------------------------------------------
-- Query 2 — Fraud alert triage with similar-pattern history
--
-- Currently open fraud alerts (Cassandra) enriched with counts of similar
-- historical fraud cases from the training label set (Iceberg). Similar =
-- same customer's prior confirmed fraud, same alert type, and same merchant
-- category (via transactions_archive join). Helps analysts prioritize.
-- ----------------------------------------------------------------------------
WITH customer_prior_fraud AS (
    SELECT
        f.customer_id,
        COUNT(*)                                                AS lifetime_fraud_count,
        SUM(f.loss_amount)                                      AS lifetime_loss,
        SUM(f.recovered_amount)                                 AS lifetime_recovered
    FROM iceberg_data.financial.fraud_training_labels f
    WHERE f.is_fraud = true
    GROUP BY f.customer_id
)
SELECT
    a.severity,
    a.alert_type,
    a.raised_at,
    a.status                                AS case_status,
    a.assigned_to,
    ROUND(a.risk_score, 2)                  AS alert_risk_score,
    c.first_name || ' ' || c.last_name      AS customer_name,
    c.risk_tier                             AS current_risk_tier,
    cpf.lifetime_fraud_count,
    ROUND(cpf.lifetime_loss, 2)             AS lifetime_loss,
    ROUND(cpf.lifetime_recovered, 2)        AS lifetime_recovered
FROM cassandra_catalog.financial.fraud_alerts_open a
JOIN cassandra_catalog.financial.customers c
  ON c.customer_id = a.customer_id
LEFT JOIN customer_prior_fraud cpf
  ON cpf.customer_id = CAST(a.customer_id AS VARCHAR)
ORDER BY
    CASE a.severity
      WHEN 'critical' THEN 1 WHEN 'high' THEN 2
      WHEN 'medium'   THEN 3 ELSE 4 END,
    cpf.lifetime_fraud_count DESC NULLS LAST
LIMIT 25;


-- ----------------------------------------------------------------------------
-- Query 3 — Portfolio exposure: live balance vs. recent performance vs. market
--
-- For investment accounts: current balance (Cassandra) + last 30 days of
-- portfolio metrics (Iceberg) + a reference equity index from external
-- market data (Iceberg market_data_daily). Shows at a glance whose
-- portfolios are under-performing the market benchmark right now.
-- ----------------------------------------------------------------------------
WITH portfolio_last_30d AS (
    SELECT
        account_id,
        AVG(daily_return_pct)        AS avg_daily_return_30d,
        AVG(volatility_30d)          AS avg_vol_30d,
        MAX_BY(portfolio_value, metric_date)  AS last_portfolio_value,
        MAX(metric_date)             AS last_date
    FROM iceberg_data.financial.portfolio_metrics_daily
    WHERE metric_date >= current_date - INTERVAL '30' DAY
    GROUP BY account_id
),
benchmark_30d AS (
    SELECT
        AVG(((close_price - open_price) / open_price) * 100.0) AS bench_avg_daily_return_30d
    FROM iceberg_data.financial.market_data_daily
    WHERE ticker = 'AAPL'   -- stand-in for the benchmark; change to a market index if you add one
      AND quote_date >= current_date - INTERVAL '30' DAY
)
SELECT
    a.customer_id,
    a.account_id,
    a.current_balance             AS live_balance,
    ROUND(p.last_portfolio_value, 2)  AS last_closing_value,
    ROUND(p.avg_daily_return_30d, 4)  AS portfolio_avg_daily_return,
    ROUND(p.avg_vol_30d, 4)           AS portfolio_volatility,
    ROUND(b.bench_avg_daily_return_30d, 4) AS benchmark_avg_daily_return,
    ROUND(p.avg_daily_return_30d - b.bench_avg_daily_return_30d, 4)
                                   AS alpha_30d
FROM cassandra_catalog.financial.accounts a
JOIN portfolio_last_30d p
  ON p.account_id = CAST(a.account_id AS VARCHAR)
CROSS JOIN benchmark_30d b
WHERE a.account_type = 'investment'
  AND a.status = 'active'
ORDER BY (p.avg_daily_return_30d - b.bench_avg_daily_return_30d) ASC  -- worst underperformers first
LIMIT 25;


-- ----------------------------------------------------------------------------
-- Query 4 — Compliance watchlist: current activity vs. filing history
--
-- Customers with pending high-value transfers right now (Cassandra) cross-
-- referenced against their regulatory filing history (Iceberg). Anyone with
-- a pending wire >$10K AND a prior SAR in the last 12 months goes to the
-- top of the compliance queue.
-- ----------------------------------------------------------------------------
WITH pending_large AS (
    SELECT
        t.source_account_id,
        t.transfer_id,
        t.amount,
        t.transfer_type,
        t.destination_bank,
        t.status,
        a.customer_id
    FROM cassandra_catalog.financial.transfers_pending t
    JOIN cassandra_catalog.financial.accounts a
      ON a.account_id = t.source_account_id
    WHERE t.amount >= 10000
      AND t.status IN ('pending', 'processing', 'flagged')
),
prior_sars AS (
    SELECT
        customer_id,
        COUNT(*)                                 AS sar_count_12mo,
        MAX(filed_at)                            AS last_filing_at,
        MAX(trigger_reason)                      AS last_trigger
    FROM iceberg_data.financial.regulatory_filings
    WHERE filing_type = 'SAR'
      AND filed_at >= current_timestamp - INTERVAL '365' DAY
    GROUP BY customer_id
)
SELECT
    pl.customer_id,
    c.first_name || ' ' || c.last_name AS customer_name,
    c.risk_tier,
    pl.transfer_id,
    pl.amount,
    pl.transfer_type,
    pl.destination_bank,
    pl.status,
    ps.sar_count_12mo,
    ps.last_filing_at,
    ps.last_trigger
FROM pending_large pl
JOIN cassandra_catalog.financial.customers c
  ON c.customer_id = pl.customer_id
LEFT JOIN prior_sars ps
  ON ps.customer_id = CAST(pl.customer_id AS VARCHAR)
ORDER BY
    (CASE WHEN ps.sar_count_12mo > 0 THEN 0 ELSE 1 END),
    pl.amount DESC
LIMIT 25;
