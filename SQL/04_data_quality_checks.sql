/* ============================================================
   04 - DATA QUALITY AND RECONCILIATION CHECKS
   Run after loading data and after any change to the views.
   Each check states the expected result.
   ============================================================ */

/* ---------- A. Row counts ---------- */
SELECT 'customers' AS tbl, COUNT(*) FROM customers   -- 300
UNION ALL SELECT 'invoices', COUNT(*) FROM invoices  -- 7,010
UNION ALL SELECT 'payments', COUNT(*) FROM payments; -- 7,029

/* ---------- B. Records that don't belong ----------
   Caught a real issue: hand-typed test invoices had been
   re-inserted into the dataset by a learning script.
   Expected: 0 and 0 */
SELECT 'invoices outside generated ID range' AS check_name, COUNT(*)
FROM invoices WHERE invoice_id < 100001
UNION ALL
SELECT 'payments outside generated ID range', COUNT(*)
FROM payments WHERE payment_id < 900001;

/* ---------- C. Referential and logical integrity ---------- */
-- Payments with no matching invoice (orphans). Expected: 0 rows
SELECT p.*
FROM payments p
LEFT JOIN invoices i ON p.invoice_id = i.invoice_id
WHERE i.invoice_id IS NULL;

-- Payment dated before its invoice. Expected: 0 rows
SELECT p.payment_id, p.invoice_id, p.payment_date, i.invoice_date
FROM payments p
JOIN invoices i ON p.invoice_id = i.invoice_id
WHERE p.payment_date < i.invoice_date;

-- Due date before invoice date. Expected: 0 rows
SELECT * FROM invoices WHERE due_date < invoice_date;

-- Payment currency differs from invoice currency. Expected: 0 rows
SELECT p.payment_id, p.currency AS payment_ccy, i.currency AS invoice_ccy
FROM payments p
JOIN invoices i ON p.invoice_id = i.invoice_id
WHERE p.currency <> i.currency;

-- Overpaid invoices (negative outstanding). Expected: 0 rows
SELECT * FROM v_invoice_outstanding WHERE outstanding_amount < 0;

-- Possible duplicate invoices: same customer, date and amount
SELECT customer_id, invoice_date, invoice_amount, COUNT(*)
FROM invoices
GROUP BY customer_id, invoice_date, invoice_amount
HAVING COUNT(*) > 1;

/* ---------- D. Duplicate customer names ----------
   Caught a real issue: different customers sharing a name were
   merged in a chart grouped by name. Reporting uses a unique
   label (name + ID). This query shows the shared names. */
SELECT customer_name, COUNT(*) AS customers_with_this_name
FROM customers
GROUP BY customer_name
HAVING COUNT(*) > 1
ORDER BY 2 DESC;

/* ---------- E. FX coverage ----------
   Every invoice month needs a rate. Expected: 0 rows */
SELECT DISTINCT DATE_TRUNC('month', i.invoice_date)::date AS month_missing_rate
FROM invoices i
LEFT JOIN fx_rates f ON f.rate_month = DATE_TRUNC('month', i.invoice_date)::date
WHERE f.rate_month IS NULL;

/* ---------- F. Reconciliations ----------
   Same figure, calculated two independent ways. */

-- F1. Open balances by currency, original vs GBP
--     GBP: both columns equal. EUR: GBP column = EUR x 0.85463
SELECT currency,
       SUM(outstanding_amount) AS original_currency,
       SUM(outstanding_gbp)    AS in_gbp
FROM v_invoice_outstanding
WHERE outstanding_amount > 0
GROUP BY currency;

-- F2. Invoice-level ageing vs cumulative invoiced-minus-paid
--     Caught a real issue: a view update that had not applied.
--     Expected: both about 10,530,085, within pennies (rounding)
SELECT (SELECT SUM(outstanding_gbp)
        FROM v_invoice_outstanding
        WHERE outstanding_amount > 0)                       AS ageing_total,
       (SELECT closing_receivables
        FROM v_dso_monthly
        WHERE month_start = DATE '2026-09-01')              AS dso_view_balance;

-- F3. Ageing buckets add up to the total
SELECT SUM(total_outstanding) AS buckets_total_original_ccy, currency
FROM v_aged_debt_summary
GROUP BY currency;

-- F4. "Overdue" uses one definition everywhere
--     Caught a real issue: invoices due ON the reporting date were
--     overdue in one view and not the other. Expected: equal values
SELECT
  (SELECT ROUND(100.0 * SUM(outstanding_gbp) FILTER (WHERE days_overdue > 0)
          / SUM(outstanding_gbp), 1)
   FROM v_invoice_outstanding WHERE outstanding_amount > 0) AS overdue_pct_ageing,
  (SELECT overdue_pct FROM v_dso_monthly
   WHERE month_start = DATE '2026-09-01')                   AS overdue_pct_dso_view;
