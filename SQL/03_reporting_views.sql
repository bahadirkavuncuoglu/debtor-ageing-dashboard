/* ============================================================
   03 - REPORTING VIEWS (GBP reporting)
   Database: debtor_ageing (PostgreSQL)

   As-at date: 2026-09-30 (fixed).
   Reporting currency: GBP. EUR converted with ECB reference
   rates (series EXR.D.GBP.EUR.SP00.A), held monthly in fx_rates:
     - balances  -> closing rate at the reporting date (IAS 21)
     - sales     -> average rate of the month invoiced

   Requires tables: customers, invoices, payments, fx_rates.
   Views:
     1. v_invoice_outstanding        one row per invoice (Power BI fact table)
     2. v_aged_debt_summary          control total by bucket and currency
     3. v_collections_worklist       one row per customer and currency
     4. v_dso_monthly                simple, countback and best possible DSO
     5. v_customer_payment_behaviour how late each customer actually pays
   Create in this order - later views read from earlier ones.
   ============================================================ */


/* ------------------------------------------------------------
   1. INVOICE-LEVEL OUTSTANDING + AGEING (+ GBP columns)
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_invoice_outstanding AS
WITH paid AS (
    SELECT invoice_id,
           SUM(payment_amount) AS amount_paid
    FROM payments
    WHERE payment_date <= DATE '2026-09-30'
    GROUP BY invoice_id
),
closing AS (
    SELECT eur_gbp_close
    FROM fx_rates
    WHERE rate_month = DATE '2026-09-01'
)
SELECT i.invoice_id,
       i.customer_id,
       i.invoice_date,
       i.due_date,
       i.currency,
       i.invoice_amount,
       COALESCE(p.amount_paid, 0)                         AS amount_paid,
       i.invoice_amount - COALESCE(p.amount_paid, 0)      AS outstanding_amount,
       DATE '2026-09-30' - i.due_date                     AS days_overdue,
       CASE
           WHEN i.due_date IS NULL                                  THEN 'CHECK: missing due date'
           WHEN (DATE '2026-09-30' - i.due_date) <= 0               THEN 'Not due'
           WHEN (DATE '2026-09-30' - i.due_date) BETWEEN 1  AND 30  THEN '1-30'
           WHEN (DATE '2026-09-30' - i.due_date) BETWEEN 31 AND 60  THEN '31-60'
           WHEN (DATE '2026-09-30' - i.due_date) BETWEEN 61 AND 90  THEN '61-90'
           ELSE '90+'
       END AS ageing_bucket,
       CASE
           WHEN i.due_date IS NULL                                  THEN 6
           WHEN (DATE '2026-09-30' - i.due_date) <= 0               THEN 1
           WHEN (DATE '2026-09-30' - i.due_date) BETWEEN 1  AND 30  THEN 2
           WHEN (DATE '2026-09-30' - i.due_date) BETWEEN 31 AND 60  THEN 3
           WHEN (DATE '2026-09-30' - i.due_date) BETWEEN 61 AND 90  THEN 4
           ELSE 5
       END AS bucket_order,
       CASE WHEN i.currency = 'EUR' THEN fx.eur_gbp_avg  ELSE 1 END     AS fx_rate_invoice,
       CASE WHEN i.currency = 'EUR' THEN c.eur_gbp_close ELSE 1 END     AS fx_rate_closing,
       ROUND(i.invoice_amount
             * CASE WHEN i.currency = 'EUR' THEN fx.eur_gbp_avg ELSE 1 END, 2)   AS invoice_amount_gbp,
       ROUND((i.invoice_amount - COALESCE(p.amount_paid, 0))
             * CASE WHEN i.currency = 'EUR' THEN c.eur_gbp_close ELSE 1 END, 2)  AS outstanding_gbp
FROM invoices i
LEFT JOIN paid p      ON p.invoice_id = i.invoice_id
LEFT JOIN fx_rates fx ON fx.rate_month = DATE_TRUNC('month', i.invoice_date)::date
CROSS JOIN closing c
WHERE i.invoice_date <= DATE '2026-09-30';


/* ------------------------------------------------------------
   2. AGED DEBT SUMMARY (control total, original currency)
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_aged_debt_summary AS
SELECT ageing_bucket,
       bucket_order,
       currency,
       COUNT(*)                  AS num_invoices,
       SUM(outstanding_amount)   AS total_outstanding
FROM v_invoice_outstanding
WHERE outstanding_amount > 0
GROUP BY ageing_bucket, bucket_order, currency;


/* ------------------------------------------------------------
   3. COLLECTIONS WORKLIST (original currency)
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_collections_worklist AS
SELECT c.customer_id,
       c.customer_name,
       c.country,
       o.currency,
       SUM(CASE WHEN o.ageing_bucket = 'Not due' THEN o.outstanding_amount ELSE 0 END) AS not_due,
       SUM(CASE WHEN o.ageing_bucket = '1-30'    THEN o.outstanding_amount ELSE 0 END) AS bucket_1_30,
       SUM(CASE WHEN o.ageing_bucket = '31-60'   THEN o.outstanding_amount ELSE 0 END) AS bucket_31_60,
       SUM(CASE WHEN o.ageing_bucket = '61-90'   THEN o.outstanding_amount ELSE 0 END) AS bucket_61_90,
       SUM(CASE WHEN o.ageing_bucket = '90+'     THEN o.outstanding_amount ELSE 0 END) AS bucket_90_plus,
       SUM(o.outstanding_amount)                                                      AS total_outstanding
FROM v_invoice_outstanding o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.outstanding_amount > 0
GROUP BY c.customer_id, c.customer_name, c.country, o.currency;


/* ------------------------------------------------------------
   4. MONTHLY DSO - ALL CURRENCIES, IN GBP
   Sales at the invoice month's average rate.
   Balances at each month end's closing rate.
   Oct-Dec 2024 excluded from output: ledger ramp-up.
   An invoice due ON the month end is not yet overdue (>=).
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_dso_monthly AS
WITH months AS (
    SELECT d::date AS month_start,
           (d + INTERVAL '1 month' - INTERVAL '1 day')::date AS month_end,
           EXTRACT(DAY FROM (d + INTERVAL '1 month' - INTERVAL '1 day')) AS days_in_month,
           f.eur_gbp_close
    FROM generate_series(DATE '2024-10-01', DATE '2026-09-01', INTERVAL '1 month') AS d
    JOIN fx_rates f ON f.rate_month = d::date
),
monthly_sales AS (
    SELECT DATE_TRUNC('month', i.invoice_date)::date AS month_start,
           SUM(i.invoice_amount
               * CASE WHEN i.currency = 'EUR' THEN f.eur_gbp_avg ELSE 1 END) AS credit_sales
    FROM invoices i
    JOIN fx_rates f ON f.rate_month = DATE_TRUNC('month', i.invoice_date)::date
    GROUP BY 1
),
cum_invoiced AS (
    SELECT m.month_start,
           COALESCE(SUM(i.invoice_amount
               * CASE WHEN i.currency = 'EUR' THEN m.eur_gbp_close ELSE 1 END), 0) AS invoiced_to_date
    FROM months m
    LEFT JOIN invoices i ON i.invoice_date <= m.month_end
    GROUP BY m.month_start
),
cum_paid AS (
    SELECT m.month_start,
           COALESCE(SUM(p.payment_amount
               * CASE WHEN p.currency = 'EUR' THEN m.eur_gbp_close ELSE 1 END), 0) AS paid_to_date
    FROM months m
    LEFT JOIN payments p ON p.payment_date <= m.month_end
    GROUP BY m.month_start
),
not_due_invoiced AS (
    SELECT m.month_start,
           COALESCE(SUM(i.invoice_amount
               * CASE WHEN i.currency = 'EUR' THEN m.eur_gbp_close ELSE 1 END), 0) AS not_due_invoiced
    FROM months m
    LEFT JOIN invoices i
           ON i.invoice_date <= m.month_end
          AND i.due_date     >= m.month_end
    GROUP BY m.month_start
),
not_due_paid AS (
    SELECT m.month_start,
           COALESCE(SUM(p.payment_amount
               * CASE WHEN i.currency = 'EUR' THEN m.eur_gbp_close ELSE 1 END), 0) AS not_due_paid
    FROM months m
    LEFT JOIN invoices i
           ON i.invoice_date <= m.month_end
          AND i.due_date     >= m.month_end
    LEFT JOIN payments p
           ON p.invoice_id = i.invoice_id
          AND p.payment_date <= m.month_end
    GROUP BY m.month_start
),
dso_calc AS (
    SELECT m.month_start,
           m.month_end,
           m.days_in_month,
           COALESCE(s.credit_sales, 0)                    AS credit_sales,
           ci.invoiced_to_date - cp.paid_to_date          AS closing_receivables,
           ndi.not_due_invoiced - ndp.not_due_paid        AS current_receivables,
           ROUND((ci.invoiced_to_date - cp.paid_to_date)
                 / NULLIF(s.credit_sales, 0) * m.days_in_month, 1) AS simple_dso,
           ROUND((ndi.not_due_invoiced - ndp.not_due_paid)
                 / NULLIF(s.credit_sales, 0) * m.days_in_month, 1) AS best_possible_dso
    FROM months m
    LEFT JOIN monthly_sales s      ON s.month_start   = m.month_start
    LEFT JOIN cum_invoiced ci      ON ci.month_start  = m.month_start
    LEFT JOIN cum_paid cp          ON cp.month_start  = m.month_start
    LEFT JOIN not_due_invoiced ndi ON ndi.month_start = m.month_start
    LEFT JOIN not_due_paid ndp     ON ndp.month_start = m.month_start
),
pairs AS (
    SELECT r.month_start AS reporting_month,
           h.month_start AS sales_month,
           h.days_in_month,
           COALESCE(s.credit_sales, 0) AS credit_sales
    FROM months r
    JOIN months h ON h.month_start <= r.month_start
    LEFT JOIN monthly_sales s ON s.month_start = h.month_start
),
running AS (
    SELECT p.*,
           SUM(credit_sales) OVER (PARTITION BY reporting_month
                                   ORDER BY sales_month DESC) AS cum_sales_back
    FROM pairs p
),
contrib AS (
    SELECT r.reporting_month,
           r.sales_month,
           CASE
               WHEN r.cum_sales_back <= b.closing_receivables
                   THEN r.days_in_month
               WHEN r.cum_sales_back - r.credit_sales < b.closing_receivables
                   THEN (b.closing_receivables - (r.cum_sales_back - r.credit_sales))
                        / r.credit_sales * r.days_in_month
               ELSE 0
           END AS days_counted
    FROM running r
    JOIN dso_calc b ON b.month_start = r.reporting_month
),
countback AS (
    SELECT reporting_month AS month_start,
           ROUND(SUM(days_counted), 1) AS countback_dso
    FROM contrib
    GROUP BY reporting_month
)
SELECT d.month_start,
       d.month_end,
       d.credit_sales,
       d.closing_receivables,
       d.current_receivables,
       d.closing_receivables - d.current_receivables          AS overdue_receivables,
       ROUND((d.closing_receivables - d.current_receivables)
             / NULLIF(d.closing_receivables, 0) * 100, 1)     AS overdue_pct,
       d.simple_dso,
       c.countback_dso,
       d.best_possible_dso,
       d.simple_dso - d.best_possible_dso                     AS days_late
FROM dso_calc d
JOIN countback c ON c.month_start = d.month_start
WHERE d.month_start >= DATE '2025-01-01';


/* ------------------------------------------------------------
   5. CUSTOMER PAYMENT BEHAVIOUR
   Fully settled invoices only; final payment date vs due date.
   Weighted by invoice value in GBP. Customers with few settled
   invoices should be filtered in reporting (min. 5 used).
   ------------------------------------------------------------ */
CREATE OR REPLACE VIEW v_customer_payment_behaviour AS
WITH settled AS (
    SELECT o.invoice_id,
           o.customer_id,
           o.due_date,
           o.invoice_amount_gbp,
           MAX(p.payment_date) AS final_payment_date
    FROM v_invoice_outstanding o
    JOIN payments p
      ON p.invoice_id = o.invoice_id
     AND p.payment_date <= DATE '2026-09-30'
    WHERE o.outstanding_amount = 0
    GROUP BY o.invoice_id, o.customer_id, o.due_date, o.invoice_amount_gbp
)
SELECT customer_id,
       COUNT(*) AS invoices_settled,
       ROUND(SUM((final_payment_date - due_date) * invoice_amount_gbp)
             / NULLIF(SUM(invoice_amount_gbp), 0), 1)          AS avg_days_late_weighted,
       ROUND(AVG(final_payment_date - due_date), 1)            AS avg_days_late,
       ROUND(100.0 * SUM(CASE WHEN final_payment_date > due_date THEN 1 ELSE 0 END)
             / COUNT(*), 1)                                    AS pct_paid_late
FROM settled
GROUP BY customer_id;
