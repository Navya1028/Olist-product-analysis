# Olist Product Analytics: Funnel, Retention & Delivery-Experience Impact

**Dataset:** 99,441 real e-commerce orders, Sep 2016–Oct 2018 (Olist, Brazil) — 8 relational tables (orders, customers, order items, payments, reviews, products, sellers, category translation)
**Stack:** SQLite (SQL), Python (scipy) for inferential statistics

## What this project answers

1. **Where do orders drop off, and how fast do they move?** (order → approved → shipped → delivered funnel)
2. **Who are the customers worth retaining?** (RFM segmentation, cohort repeat-purchase rates)
3. **Does late delivery actually hurt the business, or does it just feel like it should?** (hypothesis testing)

## Data quality check (before trusting anything downstream)

2,965 orders (~3% of all "delivered" orders) are flagged `delivered` but have no `order_delivered_customer_date`. Every delivery-time and cohort query in this project explicitly filters these out — otherwise they'd silently inflate or corrupt every downstream funnel and delivery-time metric.

## Part 1 — SQL: Funnel, cohorts, RFM (`analysis.sql`)

- **Order-to-delivery funnel**: conversion rate at each stage (purchase → approved → carrier → delivered)
- **Delivery time by state**: window-ranked (`RANK() OVER`) to surface the slowest regions
- **Monthly acquisition cohorts**: CTE-chained (`customer_orders → first_orders → repeat_flags`) to compute 90-day repeat-purchase rate per signup month
- **Time between orders**: `LAG()` window function over each customer's order sequence
- **RFM segmentation**: `NTILE(4)` on recency, frequency, monetary value → Champions / Loyal / At-Risk / Lost segments
- **Category performance**: revenue-ranked categories joined against average review score

## Part 2 — Statistics: does delivery timeliness change customer behavior? (`stats_analysis.py`)

Cohorts built via SQL: each customer's **first order** classified as `on_time` or `late` (delivered after the estimated date). Two independent tests against that same split:

| Test | Outcome | Result |
|---|---|---|
| Two-proportion z-test | Repeat purchase within 180 days | **Not significant** (p=0.30). On-time 2.26% vs late 2.08% — a real but tiny gap. Power calculation shows ~99K customers per group would be needed to detect an effect this small at 80% power; the study (85.7K vs 7.6K) was underpowered for it. |
| Welch's t-test | Review score (1–5) | **Highly significant** (p≈0), large effect (Cohen's d=1.21). On-time avg 4.29★ vs late avg 2.57★. |

**Why report a null result at all?** Because the honest finding is more useful than a forced one: late delivery doesn't measurably change whether someone comes back, but it devastates how they rate the experience. Knowing which is true (and being able to show the power calculation behind the "not significant" call, rather than just eyeballing p>0.05) is the difference between running a test and understanding one.

**Caveat, stated rather than glossed over:** this is observational, not randomized. Delivery speed correlates with seller, region, and product category — any of which could independently affect review behavior. A randomized delivery-speed experiment (or an instrumental-variable design) would be needed to claim causation, not just association.

## Files

- `analysis.sql` — full SQL analysis (funnel, cohorts, RFM, category performance)
- `stats_analysis.py` — hypothesis testing module (z-test, t-test, power calculation)
- `olist_product_analytics.db` — SQLite database, ready to query directly
"# Olist-product-analysis" 
