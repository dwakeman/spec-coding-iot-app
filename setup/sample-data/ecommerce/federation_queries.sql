-- ============================================================================
-- E-commerce Federation Queries
--
-- Each of these queries needs BOTH catalogs — cassandra_catalog for live
-- operational state and iceberg_data for historical/analytical/external data.
-- That's the point: a single question answered across heterogeneous sources,
-- no ETL in the middle.
--
-- Prerequisites:
--   1. Cassandra is registered in watsonx.data as catalog "cassandra_catalog"
--   2. Iceberg data has been loaded (./setup/sample-data/load-iceberg-data.sh)
--   3. Cassandra data has been loaded (via the workshop installer or the
--      load-data-with-venv.sh script)
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Query 1 — Personalize carts being filled right now
--
-- For every customer currently filling a cart (Cassandra),
-- pull their 12-month LTV trajectory and preferred category
-- from the Iceberg archive, so we can show a relevant promotion.
-- ----------------------------------------------------------------------------
WITH current_carts AS (
    SELECT
        customer_id,
        COUNT(*)          AS items_in_cart,
        SUM(quantity * unit_price) AS cart_value
    FROM cassandra_catalog.ecommerce.active_carts
    GROUP BY customer_id
),
customer_latest_ltv AS (
    SELECT
        customer_id,
        ltv,
        loyalty_tier,
        cumulative_orders,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY snapshot_date DESC) AS rn
    FROM iceberg_data.ecommerce.customer_ltv_monthly
),
top_category_per_customer AS (
    SELECT
        oi.order_id,
        oa.customer_id,
        oi.product_category,
        SUM(oi.line_total) AS revenue_in_cat,
        ROW_NUMBER() OVER (
            PARTITION BY oa.customer_id
            ORDER BY SUM(oi.line_total) DESC
        ) AS rn
    FROM iceberg_data.ecommerce.order_items_archive oi
    JOIN iceberg_data.ecommerce.orders_archive oa USING (order_id)
    GROUP BY oi.order_id, oa.customer_id, oi.product_category
)
SELECT
    c.customer_id,
    cc.items_in_cart,
    cc.cart_value,
    ltv.ltv                  AS historical_ltv,
    ltv.loyalty_tier,
    ltv.cumulative_orders,
    tc.product_category      AS top_preferred_category
FROM current_carts cc
JOIN cassandra_catalog.ecommerce.customers c
  ON c.customer_id = cc.customer_id
LEFT JOIN customer_latest_ltv ltv
  ON ltv.customer_id = cc.customer_id AND ltv.rn = 1
LEFT JOIN top_category_per_customer tc
  ON tc.customer_id = cc.customer_id AND tc.rn = 1
ORDER BY cc.cart_value DESC
LIMIT 25;


-- ----------------------------------------------------------------------------
-- Query 2 — Competitive price audit
--
-- Which products in our live catalog are currently priced ≥10% above
-- the average competitor price from last week's external feed?
-- Classic "our Cassandra price vs their Iceberg feed" question.
-- ----------------------------------------------------------------------------
WITH latest_competitor_week AS (
    SELECT MAX(week_start_date) AS week_start_date
    FROM iceberg_data.ecommerce.competitor_prices_weekly
),
avg_competitor AS (
    SELECT
        cp.our_product_id,
        AVG(cp.competitor_price) AS avg_competitor_price,
        COUNT(*)                 AS competitor_quotes
    FROM iceberg_data.ecommerce.competitor_prices_weekly cp
    JOIN latest_competitor_week w ON cp.week_start_date = w.week_start_date
    GROUP BY cp.our_product_id
)
SELECT
    p.name                     AS product,
    p.category,
    p.brand,
    p.price                    AS our_price,
    ac.avg_competitor_price,
    ROUND(100 * (p.price - ac.avg_competitor_price) / ac.avg_competitor_price, 2)
                                AS pct_above_market,
    ac.competitor_quotes,
    p.stock_quantity
FROM cassandra_catalog.ecommerce.products p
JOIN avg_competitor ac
  ON CAST(p.product_id AS VARCHAR) = ac.our_product_id
WHERE p.is_active = true
  AND p.price > ac.avg_competitor_price * 1.10
ORDER BY pct_above_market DESC
LIMIT 30;


-- ----------------------------------------------------------------------------
-- Query 3 — In-flight order risk (return-rate check)
--
-- For each order currently in fulfillment (Cassandra), compute the customer's
-- historical return rate from Iceberg. Flag high-return customers so ops
-- can prioritize a quality check before shipping.
-- ----------------------------------------------------------------------------
WITH customer_return_rate AS (
    SELECT
        customer_id,
        COUNT(*)                                            AS lifetime_orders,
        SUM(CASE WHEN order_status = 'returned' THEN 1 ELSE 0 END)
                                                            AS lifetime_returns,
        CAST(SUM(CASE WHEN order_status = 'returned' THEN 1 ELSE 0 END) AS DOUBLE)
          / NULLIF(COUNT(*), 0)                             AS return_rate
    FROM iceberg_data.ecommerce.orders_archive
    GROUP BY customer_id
)
SELECT
    oi.order_id,
    oi.customer_id,
    oi.order_date,
    oi.order_status,
    oi.total_amount,
    crr.lifetime_orders,
    crr.lifetime_returns,
    ROUND(crr.return_rate, 3)                              AS return_rate,
    CASE
        WHEN crr.return_rate >= 0.15 THEN 'HIGH'
        WHEN crr.return_rate >= 0.08 THEN 'MEDIUM'
        ELSE 'LOW'
    END                                                     AS risk_flag
FROM cassandra_catalog.ecommerce.orders_inflight oi
LEFT JOIN customer_return_rate crr
  ON CAST(oi.customer_id AS VARCHAR) = crr.customer_id
WHERE oi.order_status IN ('processing', 'shipped')
ORDER BY crr.return_rate DESC NULLS LAST, oi.total_amount DESC
LIMIT 30;


-- ----------------------------------------------------------------------------
-- Query 4 — Session-level conversion potential
--
-- Match currently-active browsing sessions (Cassandra) to the customer's
-- acquisition cohort (Iceberg). High-retention cohort + long session =
-- priority target for a nudge/chat invite.
-- ----------------------------------------------------------------------------
WITH customer_cohort AS (
    SELECT
        customer_id,
        YEAR(created_at)  AS cohort_year,
        MONTH(created_at) AS cohort_month
    FROM cassandra_catalog.ecommerce.customers
),
latest_retention AS (
    -- Most recent retention point per cohort (the "mature" observation)
    SELECT
        cohort_year, cohort_month,
        MAX(months_since_acquisition) AS latest_offset,
        MAX_BY(retention_rate, months_since_acquisition) AS latest_retention_rate
    FROM iceberg_data.ecommerce.cohort_retention
    GROUP BY cohort_year, cohort_month
)
SELECT
    ls.customer_id,
    ls.session_start,
    ls.page_views,
    ls.cart_additions,
    ls.device_type,
    cc.cohort_year,
    cc.cohort_month,
    ROUND(lr.latest_retention_rate, 4) AS cohort_retention
FROM cassandra_catalog.ecommerce.live_sessions ls
JOIN customer_cohort cc
  ON cc.customer_id = ls.customer_id
LEFT JOIN latest_retention lr
  ON lr.cohort_year = cc.cohort_year AND lr.cohort_month = cc.cohort_month
WHERE lr.latest_retention_rate > 0.25   -- high-retention cohort only
  AND ls.page_views > 5
ORDER BY lr.latest_retention_rate DESC, ls.page_views DESC
LIMIT 25;
