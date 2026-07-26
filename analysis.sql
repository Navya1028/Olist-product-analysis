/* ============================================================================
   OLIST E-COMMERCE — PRODUCT FUNNEL & CUSTOMER RETENTION ANALYSIS
   Dataset: 99,441 real orders, Sep 2016 - Oct 2018 (Olist, Brazil)
   Engine: SQLite3
   ============================================================================ */


/* ----------------------------------------------------------------------------
   0. DATA QUALITY CHECK
   Before trusting the funnel, verify the delivery-status field is reliable.
   ---------------------------------------------------------------------------- */
SELECT
    order_status,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN order_delivered_customer_date IS NULL
              OR order_delivered_customer_date = '' THEN 1 ELSE 0 END) AS missing_delivery_date
FROM orders
GROUP BY order_status
ORDER BY total_orders DESC;
-- Finding: 2,965 orders are flagged "delivered" but have no delivered_customer_date
-- (~3% of all "delivered" orders). Any delivery-time metric must exclude these,
-- or it silently drops real cycle-time signal. Flagged in every funnel query below
-- via `order_delivered_customer_date != ''`.


/* ----------------------------------------------------------------------------
   1. ORDER-TO-DELIVERY FUNNEL
   Stage-by-stage conversion + median time spent at each stage.
   ---------------------------------------------------------------------------- */
WITH funnel_base AS (
    SELECT
        order_id,
        order_status,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date,
        CASE WHEN order_approved_at != '' THEN 1 ELSE 0 END AS reached_approved,
        CASE WHEN order_delivered_carrier_date != '' THEN 1 ELSE 0 END AS reached_shipped,
        CASE WHEN order_delivered_customer_date != '' THEN 1 ELSE 0 END AS reached_delivered
    FROM orders
)
SELECT
    COUNT(*) AS orders_placed,
    SUM(reached_approved) AS reached_approved,
    ROUND(100.0 * SUM(reached_approved) / COUNT(*), 1) AS pct_approved,
    SUM(reached_shipped) AS reached_shipped,
    ROUND(100.0 * SUM(reached_shipped) / COUNT(*), 1) AS pct_shipped,
    SUM(reached_delivered) AS reached_delivered,
    ROUND(100.0 * SUM(reached_delivered) / COUNT(*), 1) AS pct_delivered
FROM funnel_base;


/* ----------------------------------------------------------------------------
   2. DELIVERY TIME BY STATE (operational drill-down)
   Window function: rank states by average delivery time to spot outliers.
   ---------------------------------------------------------------------------- */
WITH delivery_times AS (
    SELECT
        c.customer_state,
        o.order_id,
        julianday(o.order_delivered_customer_date) - julianday(o.order_purchase_timestamp) AS delivery_days
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_delivered_customer_date != ''
),
state_agg AS (
    SELECT
        customer_state,
        COUNT(*) AS delivered_orders,
        ROUND(AVG(delivery_days), 1) AS avg_delivery_days
    FROM delivery_times
    GROUP BY customer_state
)
SELECT
    customer_state,
    delivered_orders,
    avg_delivery_days,
    RANK() OVER (ORDER BY avg_delivery_days DESC) AS slowest_rank
FROM state_agg
WHERE delivered_orders >= 30
ORDER BY avg_delivery_days DESC
LIMIT 10;


/* ----------------------------------------------------------------------------
   3. MONTHLY ACQUISITION COHORTS + REPEAT-PURCHASE RETENTION
   Classic cohort table: for each signup month, what % of customers placed
   a 2nd order within 90 days?
   ---------------------------------------------------------------------------- */
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY c.customer_unique_id
            ORDER BY o.order_purchase_timestamp
        ) AS order_seq
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),
first_orders AS (
    SELECT
        customer_unique_id,
        order_purchase_timestamp AS first_order_ts,
        strftime('%Y-%m', order_purchase_timestamp) AS cohort_month
    FROM customer_orders
    WHERE order_seq = 1
),
repeat_flags AS (
    SELECT
        f.customer_unique_id,
        f.cohort_month,
        MAX(CASE
            WHEN co.order_seq = 2
             AND julianday(co.order_purchase_timestamp) - julianday(f.first_order_ts) <= 90
            THEN 1 ELSE 0 END) AS repeated_within_90d
    FROM first_orders f
    LEFT JOIN customer_orders co
        ON co.customer_unique_id = f.customer_unique_id
    GROUP BY f.customer_unique_id, f.cohort_month
)
SELECT
    cohort_month,
    COUNT(*) AS cohort_size,
    SUM(repeated_within_90d) AS repeat_customers_90d,
    ROUND(100.0 * SUM(repeated_within_90d) / COUNT(*), 2) AS repeat_rate_90d_pct
FROM repeat_flags
GROUP BY cohort_month
ORDER BY cohort_month;


/* ----------------------------------------------------------------------------
   4. TIME BETWEEN ORDERS FOR REPEAT CUSTOMERS (LAG window function)
   ---------------------------------------------------------------------------- */
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY c.customer_unique_id
            ORDER BY o.order_purchase_timestamp
        ) AS order_seq
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),
gaps AS (
    SELECT
        customer_unique_id,
        order_seq,
        order_purchase_timestamp,
        LAG(order_purchase_timestamp) OVER (
            PARTITION BY customer_unique_id ORDER BY order_seq
        ) AS prev_order_ts
    FROM customer_orders
)
SELECT
    ROUND(AVG(julianday(order_purchase_timestamp) - julianday(prev_order_ts)), 1) AS avg_days_between_orders,
    COUNT(*) AS repeat_order_events
FROM gaps
WHERE prev_order_ts IS NOT NULL;


/* ----------------------------------------------------------------------------
   5. RFM CUSTOMER SEGMENTATION (NTILE window function)
   Recency = days since last order (from dataset max date)
   Frequency = number of orders
   Monetary = total payment value
   ---------------------------------------------------------------------------- */
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),
customer_value AS (
    SELECT
        co.customer_unique_id,
        COUNT(DISTINCT co.order_id) AS frequency,
        MAX(co.order_purchase_timestamp) AS last_order_ts,
        SUM(p.payment_value) AS monetary
    FROM customer_orders co
    JOIN payments p ON p.order_id = co.order_id
    GROUP BY co.customer_unique_id
),
max_date AS (SELECT MAX(order_purchase_timestamp) AS ref_date FROM orders),
rfm_base AS (
    SELECT
        cv.customer_unique_id,
        julianday((SELECT ref_date FROM max_date)) - julianday(cv.last_order_ts) AS recency_days,
        cv.frequency,
        cv.monetary
    FROM customer_value cv
),
rfm_scored AS (
    SELECT
        customer_unique_id,
        recency_days,
        frequency,
        monetary,
        NTILE(4) OVER (ORDER BY recency_days ASC)  AS r_score,   -- 4 = most recent
        NTILE(4) OVER (ORDER BY frequency DESC)    AS f_score,   -- 4 = most frequent
        NTILE(4) OVER (ORDER BY monetary DESC)     AS m_score    -- 4 = highest spend
    FROM rfm_base
)
SELECT
    CASE
        WHEN r_score = 4 AND f_score = 4 AND m_score = 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal'
        WHEN r_score = 4 AND f_score <= 2 THEN 'New / Recent'
        WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk (was loyal)'
        WHEN r_score = 1 AND f_score = 1 THEN 'Lost'
        ELSE 'Other'
    END AS segment,
    COUNT(*) AS customers,
    ROUND(AVG(monetary), 2) AS avg_spend
FROM rfm_scored
GROUP BY segment
ORDER BY customers DESC;


/* ----------------------------------------------------------------------------
   6. PRODUCT CATEGORY PERFORMANCE — DEMAND + SATISFACTION
   Window function: rank categories by revenue, surface review score alongside.
   ---------------------------------------------------------------------------- */
WITH category_sales AS (
    SELECT
        ct.product_category_name_english AS category,
        oi.order_id,
        oi.price
    FROM order_items oi
    JOIN products p ON p.product_id = oi.product_id
    JOIN category_translation ct ON ct.product_category_name = p.product_category_name
),
category_reviews AS (
    SELECT
        cs.category,
        AVG(r.review_score) AS avg_review_score
    FROM category_sales cs
    JOIN reviews r ON r.order_id = cs.order_id
    GROUP BY cs.category
),
category_revenue AS (
    SELECT
        category,
        COUNT(DISTINCT order_id) AS orders,
        ROUND(SUM(price), 2) AS revenue
    FROM category_sales
    GROUP BY category
)
SELECT
    cr.category,
    cr.orders,
    cr.revenue,
    ROUND(crev.avg_review_score, 2) AS avg_review_score,
    RANK() OVER (ORDER BY cr.revenue DESC) AS revenue_rank
FROM category_revenue cr
JOIN category_reviews crev ON crev.category = cr.category
ORDER BY cr.revenue DESC
LIMIT 10;
