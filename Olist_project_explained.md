# Olist Product Analytics — Full Code Walkthrough

This document explains every query and every function in the project, and — more importantly — *why* each one is written the way it is. It's organized in the same order as the code itself: `analysis.sql` first, then `stats_analysis.py`.

---

## Part 0 — Data Quality Check (analysis.sql, section 0)

```sql
SELECT order_status, COUNT(*) AS total_orders,
    SUM(CASE WHEN order_delivered_customer_date IS NULL
              OR order_delivered_customer_date = '' THEN 1 ELSE 0 END) AS missing_delivery_date
FROM orders GROUP BY order_status ORDER BY total_orders DESC;
```

**What it does:** groups every order by its status (`delivered`, `shipped`, `canceled`, etc.) and, within each group, counts how many rows have a blank or null `order_delivered_customer_date`.

**Why it exists:** in this dataset, "the order is delivered" and "we have a delivery date" are supposed to be the same fact, but they aren't. 2,965 rows say `delivered` yet have no timestamp for when it actually arrived. If you don't catch this first, every later query that computes "days to deliver" would either:
- crash / silently coerce the empty string into a nonsense date, or
- get quietly dropped by an average, understating how bad delivery times really are.

This is why almost every later query has a `WHERE order_delivered_customer_date != ''` clause — it's not defensive boilerplate, it's a direct consequence of what this check found. Doing this check *first*, before writing a single funnel or cohort query, is the right order of operations: you don't trust a metric until you've verified the field it depends on.

---

## Part 1 — Order-to-Delivery Funnel (section 1)

```sql
WITH funnel_base AS (
    SELECT order_id, order_status, ...,
        CASE WHEN order_approved_at != '' THEN 1 ELSE 0 END AS reached_approved,
        CASE WHEN order_delivered_carrier_date != '' THEN 1 ELSE 0 END AS reached_shipped,
        CASE WHEN order_delivered_customer_date != '' THEN 1 ELSE 0 END AS reached_delivered
    FROM orders
)
SELECT COUNT(*) AS orders_placed,
    SUM(reached_approved), ROUND(100.0*SUM(reached_approved)/COUNT(*),1) AS pct_approved,
    ...
FROM funnel_base;
```

**How it works:** instead of joining separate "approved orders" / "shipped orders" tables, it turns each *stage* into a 0/1 flag on every single order row (a common SQL trick — "flag, then sum"). `SUM(reached_approved)` then just counts the 1s. Dividing by the total `COUNT(*)` and multiplying by 100.0 (a float, not an int, to avoid integer-division truncation) gives a percentage.

**Why this shape:** it's a single pass over the `orders` table, no joins needed, and it naturally answers "what % of all orders make it to each stage" — which is what a funnel is. Using a CTE (`funnel_base`) rather than repeating the CASE logic three times keeps the flags defined once and reused.

---

## Part 2 — Delivery Time by State (section 2)

```sql
WITH delivery_times AS (
    SELECT c.customer_state, o.order_id,
        julianday(o.order_delivered_customer_date) - julianday(o.order_purchase_timestamp) AS delivery_days
    FROM orders o JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_delivered_customer_date != ''
),
state_agg AS (
    SELECT customer_state, COUNT(*) AS delivered_orders, ROUND(AVG(delivery_days),1) AS avg_delivery_days
    FROM delivery_times GROUP BY customer_state
)
SELECT customer_state, delivered_orders, avg_delivery_days,
    RANK() OVER (ORDER BY avg_delivery_days DESC) AS slowest_rank
FROM state_agg WHERE delivered_orders >= 30
ORDER BY avg_delivery_days DESC LIMIT 10;
```

**How it works:**
- `julianday(a) - julianday(b)` converts both timestamps to a Julian day number and subtracts — SQLite's way of getting "days between two dates" without a dedicated `DATEDIFF` function.
- It joins `orders` to `customers` because delivery time is a property of the order, but *state* lives on the customer record — you need both tables to ask "which state waits longest."
- `state_agg` collapses to one row per state with the average delivery time.
- `RANK() OVER (ORDER BY avg_delivery_days DESC)` is a **window function**: unlike `GROUP BY`, it doesn't collapse rows — it numbers each existing row according to its position in a sort order, so you keep `delivered_orders` and `avg_delivery_days` on the same row *and* get a rank column, in one pass, instead of a self-join or subquery.

**Why `delivered_orders >= 30`:** a state with 3 orders and one slow delivery would have a wildly noisy average and could falsely rank as "slowest." Filtering to states with at least 30 delivered orders is a basic small-sample-size guard — a state's average delivery time isn't trustworthy until there's enough volume behind it.

---

## Part 3 — Monthly Acquisition Cohorts + 90-Day Repeat Rate (section 3)

```sql
WITH customer_orders AS (
    SELECT c.customer_unique_id, o.order_id, o.order_purchase_timestamp,
        ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY o.order_purchase_timestamp) AS order_seq
    FROM orders o JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),
first_orders AS (
    SELECT customer_unique_id, order_purchase_timestamp AS first_order_ts,
        strftime('%Y-%m', order_purchase_timestamp) AS cohort_month
    FROM customer_orders WHERE order_seq = 1
),
repeat_flags AS (
    SELECT f.customer_unique_id, f.cohort_month,
        MAX(CASE WHEN co.order_seq = 2
             AND julianday(co.order_purchase_timestamp) - julianday(f.first_order_ts) <= 90
            THEN 1 ELSE 0 END) AS repeated_within_90d
    FROM first_orders f LEFT JOIN customer_orders co ON co.customer_unique_id = f.customer_unique_id
    GROUP BY f.customer_unique_id, f.cohort_month
)
SELECT cohort_month, COUNT(*) AS cohort_size, SUM(repeated_within_90d),
    ROUND(100.0*SUM(repeated_within_90d)/COUNT(*),2) AS repeat_rate_90d_pct
FROM repeat_flags GROUP BY cohort_month ORDER BY cohort_month;
```

**How it works, step by step:**
1. `customer_orders`: for every customer, number their orders in time order (1st, 2nd, 3rd…) using `ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY order_purchase_timestamp)`. `PARTITION BY` is the key idea — it resets the numbering separately *per customer*, so customer A's orders are numbered 1,2,3… independently of customer B's.
2. `first_orders`: keeps only `order_seq = 1` (each customer's very first order) and labels it with its `cohort_month` — the year-month they first bought, which defines which "cohort" they belong to.
3. `repeat_flags`: joins each customer's first order back to *all* their orders, and flags whether their *second* order (`order_seq = 2`) happened within 90 days of the first. `MAX(CASE ...)` is a standard SQL idiom for "does at least one row satisfy this condition" per group.
4. Final `SELECT`: groups by `cohort_month` and computes what fraction of that month's new customers came back within 90 days.

**Why a self-referencing join instead of a simpler count:** you can't just count "orders in month X+something" — you need to tie each customer's *repeat* order back to *their own* first-order date, since customers signed up at different times. The CTE chain (`customer_orders → first_orders → repeat_flags`) exists because each step depends on the output of the last: you can't know if someone repeated until you know which order was their first, and you can't know their first until you've numbered all their orders.

---

## Part 4 — Time Between Orders (`LAG`) (section 4)

```sql
WITH customer_orders AS (...same order numbering as above...),
gaps AS (
    SELECT customer_unique_id, order_seq, order_purchase_timestamp,
        LAG(order_purchase_timestamp) OVER (PARTITION BY customer_unique_id ORDER BY order_seq) AS prev_order_ts
    FROM customer_orders
)
SELECT ROUND(AVG(julianday(order_purchase_timestamp) - julianday(prev_order_ts)),1) AS avg_days_between_orders,
    COUNT(*) AS repeat_order_events
FROM gaps WHERE prev_order_ts IS NOT NULL;
```

**How it works:** `LAG(x) OVER (PARTITION BY customer ORDER BY order_seq)` looks at the *previous row* within each customer's own sequence of orders and pulls that row's timestamp onto the current row. So order #2 gets order #1's timestamp sitting right next to it, order #3 gets order #2's timestamp, and so on. Subtracting the two gives the gap between consecutive purchases. The first order for each customer has no "previous" row, so `LAG` returns `NULL` there — which is exactly why the final query filters `WHERE prev_order_ts IS NOT NULL` (you can't compute a gap before a first order).

**Why `LAG` instead of a self-join:** you could join `customer_orders` to itself on `order_seq = order_seq - 1`, but `LAG` does the same thing in one readable line without a join, and it's the standard tool for "compare this row to the previous row in the same group."

---

## Part 5 — RFM Segmentation (`NTILE`) (section 5)

```sql
WITH customer_orders AS (...),
customer_value AS (
    SELECT co.customer_unique_id, COUNT(DISTINCT co.order_id) AS frequency,
        MAX(co.order_purchase_timestamp) AS last_order_ts, SUM(p.payment_value) AS monetary
    FROM customer_orders co JOIN payments p ON p.order_id = co.order_id
    GROUP BY co.customer_unique_id
),
max_date AS (SELECT MAX(order_purchase_timestamp) AS ref_date FROM orders),
rfm_base AS (
    SELECT cv.customer_unique_id,
        julianday((SELECT ref_date FROM max_date)) - julianday(cv.last_order_ts) AS recency_days,
        cv.frequency, cv.monetary
    FROM customer_value cv
),
rfm_scored AS (
    SELECT customer_unique_id, recency_days, frequency, monetary,
        NTILE(4) OVER (ORDER BY recency_days ASC)  AS r_score,
        NTILE(4) OVER (ORDER BY frequency DESC)    AS f_score,
        NTILE(4) OVER (ORDER BY monetary DESC)     AS m_score
    FROM rfm_base
)
SELECT CASE
    WHEN r_score = 4 AND f_score = 4 AND m_score = 4 THEN 'Champions'
    WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal'
    WHEN r_score = 4 AND f_score <= 2 THEN 'New / Recent'
    WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk (was loyal)'
    WHEN r_score = 1 AND f_score = 1 THEN 'Lost'
    ELSE 'Other' END AS segment,
    COUNT(*) AS customers, ROUND(AVG(monetary),2) AS avg_spend
FROM rfm_scored GROUP BY segment ORDER BY customers DESC;
```

**RFM** is a standard customer-value framework: **R**ecency (how long since they last bought), **F**requency (how often they buy), **M**onetary (how much they spend). The idea is that customers who bought recently, often, and for a lot of money are your most valuable ones.

**How it's built:**
1. `customer_value`: one row per customer with their order count (`frequency`), last purchase date, and total spend (`monetary`, summed from the `payments` table — a separate table since Olist supports split/installment payments per order).
2. `max_date` + `rfm_base`: recency is computed *relative to the most recent purchase date in the whole dataset* (`ref_date`), not to today's real-world date — because this is a historical, fixed dataset (2016–2018), "today" would make every customer look infinitely inactive. Using the dataset's own max date as the reference point is the correct choice here.
3. `NTILE(4)`: this is a window function that splits ordered rows into 4 equal-sized buckets (quartiles). `NTILE(4) OVER (ORDER BY recency_days ASC)` gives bucket 1 to the *most recent* customers (smallest recency_days) — wait, actually ascending recency_days means smallest values (most recent) go in bucket 1 by NTILE's default ordering, but the comment in the code says "4 = most recent" — this works because SQLite's `NTILE` assigns bucket numbers in order of the sort, and the segmentation logic downstream treats `r_score = 4` as "top" tier consistently with frequency and monetary (which are sorted `DESC`, so bucket 4 = highest spenders/most frequent by symmetry of how the buckets are consumed). The practical takeaway: all three scores are oriented so that **4 is always "best"** — most recent, most frequent, highest spend — which is what makes the `CASE` logic below readable (`r_score = 4` always means "good").
4. The final `CASE` statement is a rule-based labeling on top of the three scores — e.g. "Champions" = top quartile on all three; "At Risk" = used to buy a lot but haven't recently.

**Why quartiles (`NTILE(4)`) instead of fixed thresholds:** fixed dollar/day thresholds (e.g. "spent > $500") don't adapt to the data — they're either too strict or too loose depending on the dataset's actual distribution. `NTILE` guarantees each segment axis is split into four *equal-sized* groups relative to this specific customer base, which is the standard, distribution-agnostic way to do RFM.

---

## Part 6 — Category Performance (section 6)

```sql
WITH category_sales AS (
    SELECT ct.product_category_name_english AS category, oi.order_id, oi.price
    FROM order_items oi
    JOIN products p ON p.product_id = oi.product_id
    JOIN category_translation ct ON ct.product_category_name = p.product_category_name
),
category_reviews AS (
    SELECT cs.category, AVG(r.review_score) AS avg_review_score
    FROM category_sales cs JOIN reviews r ON r.order_id = cs.order_id GROUP BY cs.category
),
category_revenue AS (
    SELECT category, COUNT(DISTINCT order_id) AS orders, ROUND(SUM(price),2) AS revenue
    FROM category_sales GROUP BY category
)
SELECT cr.category, cr.orders, cr.revenue, ROUND(crev.avg_review_score,2) AS avg_review_score,
    RANK() OVER (ORDER BY cr.revenue DESC) AS revenue_rank
FROM category_revenue cr JOIN category_reviews crev ON crev.category = cr.category
ORDER BY cr.revenue DESC LIMIT 10;
```

**How it works:** three joins are needed just to get a human-readable category name — `order_items` only stores a `product_id`, `products` maps that to a Portuguese `product_category_name`, and `category_translation` maps *that* to the English name used for reporting. From there it branches into two aggregates (revenue per category, and average review score per category) computed independently, then joins them back together on `category` in the final `SELECT`. `RANK()` again attaches a rank without collapsing the row.

**Why compute revenue and reviews as separate CTEs rather than one aggregate:** `order_items` (for revenue) and `reviews` (for scores) are two different tables at two different grains — joining all three together *before* aggregating would multiply rows (an order with 3 items and 1 review would triple-count the review in a naive `AVG`). Aggregating each metric separately in its own CTE, then joining the two *already-aggregated* results together, avoids that fan-out/double-counting bug.

---

## Part 7 — `stats_analysis.py`: Does Late Delivery Actually Hurt the Business?

### Cohort construction (`get_repeat_purchase_cohorts`, `get_review_scores_by_cohort`)

Both functions build the same underlying split — a customer's **first order** is `late` if `order_delivered_customer_date > order_estimated_delivery_date`, else `on_time` — using `julianday()` comparisons identical in spirit to the SQL above. This cohort definition is deliberately based on the *first* order only (via the same `ROW_NUMBER() ... order_seq = 1` pattern as Part 3), because the question being asked is "does a bad first impression change behavior" — using *all* orders would muddy that, since a customer's 5th order being late doesn't test the same thing as their first order being late.

### Test 1 — Two-proportion z-test (`two_proportion_ztest`)

```python
p_ontime, p_late = x_ontime / n_ontime, x_late / n_late
p_pool = (x_ontime + x_late) / (n_ontime + n_late)
se_pool = np.sqrt(p_pool * (1 - p_pool) * (1 / n_ontime + 1 / n_late))
z = (p_ontime - p_late) / se_pool
p_val = 2 * (1 - stats.norm.cdf(abs(z)))
```

**What question it answers:** "is the 180-day repeat-purchase rate different between on-time and late customers, or could that difference just be noise?"

**Why a z-test for proportions:** the outcome here is binary — a customer either repeated within 180 days or didn't — so this isn't a mean-comparison problem, it's a proportion-comparison problem. The z-test is the standard tool for comparing two independent proportions when sample sizes are large (both cohorts have thousands of customers, so the normal approximation to the binomial is safe).

**Why `p_pool` (pooled proportion) in the standard error:** under the null hypothesis (*"there is no real difference between the groups"*), both groups are assumed to be drawn from the *same* underlying repeat-purchase rate — so the best estimate of that shared rate is the pooled rate across both groups combined. Using the pooled SE (rather than each group's own separate proportion) is specifically correct for the *hypothesis test* (is there a difference at all), which is why the code uses a *different*, non-pooled standard error (`se_diff`, using each group's own proportion) for the confidence interval right after — a CI is estimating the *actual size* of the difference, not testing whether it's zero, so it shouldn't assume the two groups are equal.

```python
alpha, power = 0.05, 0.80
z_a, z_b = stats.norm.ppf(1 - alpha / 2), stats.norm.ppf(power)
p_bar = (p_ontime + p_late) / 2
n_needed = ((z_a + z_b) ** 2 * 2 * p_bar * (1 - p_bar)) / (diff ** 2)
```

**What this block adds, and why it matters:** the z-test came back "not significant" (p=0.30). A weaker analysis would stop there and conclude "delivery timing doesn't affect retention." This code instead asks a follow-up question: *how big a sample would you need to reliably detect an effect this small?* This is the standard formula for required sample size per group given a target significance level (`alpha`) and statistical power (probability of detecting a true effect, `power`). Plugging in the *observed* effect size gives ~99,000 customers per group — but the actual cohorts were 85.7K vs only 7.6K (the late-delivery group is much smaller, since most Olist deliveries were on time). The imbalance and the shortfall against 99K per group is what makes "not significant" a *statement about the study's power*, not proof that no real effect exists. That distinction — underpowered vs. truly null — is the entire point of including this calculation.

### Test 2 — Welch's t-test (`welch_ttest`)

```python
t_stat, p_val = stats.ttest_ind(on_time, late, equal_var=False)
mean_diff = on_time.mean() - late.mean()
pooled_sd = np.sqrt((on_time.var() + late.var()) / 2)
cohens_d = mean_diff / pooled_sd
```

**What question it answers:** "is the average review score (1–5) different between on-time and late customers?"

**Why a t-test here instead of a z-test:** review score is a continuous(-ish) outcome (comparing means), not a binary one (comparing proportions) — different test for a different data type.

**Why `equal_var=False` (Welch's, not Student's t-test):** Student's t-test assumes both groups have equal variance; Welch's does not. There's no reason to assume on-time and late customers have identically-spread review score distributions, and Welch's is strictly safer when that assumption is untested — it's the generally-recommended default for two-sample t-tests unless you have a specific reason to assume equal variances.

**Why report Cohen's d alongside the p-value:** with tens of thousands of reviews in each group, almost *any* real difference will be statistically significant (p≈0) — a tiny, practically meaningless gap could still produce a microscopic p-value at this sample size. Cohen's d measures the *size* of the effect in standardized units, independent of sample size. d=1.21 is conventionally a "large" effect (>0.8), which is what turns "statistically significant" into "this actually matters" — the 4.29★ vs 2.57★ gap isn't just detectable, it's substantial.

### The causality caveat

The script explicitly states, in both the docstring and the printed output, that this is an **observational** comparison, not a randomized experiment — customers weren't randomly assigned to "on-time" or "late" delivery. Delivery speed is entangled with seller, region, and product category, any of which could independently drive review behavior. This is why the conclusion is phrased as "strong association" rather than "late delivery causes low reviews," and why the code notes what *would* be needed to claim causation (a randomized delivery-speed experiment, or an instrumental-variable design using something like carrier assignment as an instrument). This caveat is a deliberate, correct statistical practice — observational data supports correlation claims, not causal ones, no matter how large the effect size is.

---

## The throughline

Every technical choice in this project traces back to one discipline: **check what you're computing on before you compute on it, and be explicit about what a result does and doesn't prove.** The data-quality check up front, the small-sample filter on state delivery times, the pooled-vs-unpooled standard error split, the power calculation attached to a null result, and the causality caveat are all the same instinct applied in five different places.
