# Olist Product Analytics: Funnel, Retention & Delivery-Experience Impact

**Dataset:** link: https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
100k real e-commerce orders, Sep 2016–Oct 2018 (Olist, Brazil) — 8 relational tables (orders, customers, order items, payments, reviews, products, sellers, category translation)
**Stack:** SQLite (SQL), Python (scipy) for inferential statistics

## What this project answers

1. **Where do orders drop off, and how fast do they move?** (order → approved → shipped → delivered funnel)
2. **Who are the customers worth retaining?** (RFM segmentation, cohort repeat-purchase rates)
3. **Does late delivery actually hurt the business, or does it just feel like it should?** (hypothesis testing)

## Data quality check (before trusting anything downstream)

8 orders (~0.01% of all "delivered" orders) are flagged `delivered` but have no `order_delivered_customer_date`. It's a small number, but every delivery-time and cohort query in this project still explicitly filters these out — otherwise they'd silently corrupt any query that computes delivery time or joins on that field.

## Part 1 — SQL: Funnel, cohorts, RFM (`analysis.sql`)

- **Order-to-delivery funnel**: conversion rate at each stage (purchase → approved → carrier → delivered)
- **Delivery time by state**: window-ranked (`RANK() OVER`) to surface the slowest regions
- **Monthly acquisition cohorts**: CTE-chained (`customer_orders → first_orders → repeat_flags`) to compute 90-day repeat-purchase rate per signup month
- **Time between orders**: `LAG()` window function over each customer's order sequence
- **RFM segmentation**: `NTILE(4)` on recency, frequency, monetary value → Champions / Loyal / At-Risk / Lost segments
- **Category performance**: revenue-ranked categories joined against average review score

Query results are saved as screenshots in [`sql outputs/`](sql%20outputs/), and `olist_product_analytics.sqbpro` is the DB Browser for SQLite project file with every query already run against the database — open it in [DB Browser for SQLite](https://sqlitebrowser.org/) to see all six analyses with their results in place, no re-running required.

## Part 2 — Statistics: does delivery timeliness change customer behavior? (`stats.ipynb`)

Cohorts built via SQL: each customer's **first order** classified as `on_time` or `late` (delivered after the estimated date). Two independent tests against that same split:

| Test | Outcome | Result |
|---|---|---|
| Two-proportion z-test | Repeat purchase within 180 days | **Not significant** (p=0.30). On-time 2.26% vs late 2.08% — a real but tiny gap. Power calculation shows ~99K customers per group would be needed to detect an effect this small at 80% power; the study (85.7K vs 7.6K) was underpowered for it. |
| Welch's t-test | Review score (1–5) | **Highly significant** (p≈0), large effect (Cohen's d=1.21). On-time avg 4.29★ vs late avg 2.57★. |

**Why report a null result at all?** Because the honest finding is more useful than a forced one: late delivery doesn't measurably change whether someone comes back, but it devastates how they rate the experience. Knowing which is true (and being able to show the power calculation behind the "not significant" call, rather than just eyeballing p>0.05) is the difference between running a test and understanding one.

**Caveat, stated rather than glossed over:** this is observational, not randomized. Delivery speed correlates with seller, region, and product category — any of which could independently affect review behavior. A randomized delivery-speed experiment (or an instrumental-variable design) would be needed to claim causation, not just association.

## Files

- `analysis.sql` — full SQL analysis (funnel, cohorts, RFM, category performance)
- `olist_product_analytics.sqbpro` — DB Browser for SQLite project file with the queries already executed against the database
- `stats.ipynb` — hypothesis testing notebook (z-test, t-test, power calculation)
- `olist_product_analytics.db` — SQLite database, ready to query directly
- `sql outputs/` — screenshots of each query and its result set
