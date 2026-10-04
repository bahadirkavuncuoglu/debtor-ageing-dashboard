/* ============================================================
   02 - EXCHANGE RATES (real data)
   Source: ECB euro foreign exchange reference rates,
           series EXR.D.GBP.EUR.SP00.A (GBP per 1 EUR, daily)
           Download as CSV from data.ecb.europa.eu
   Daily rates -> monthly average (for sales)
               -> month-end closing rate (for balances, IAS 21)
   ============================================================ */

-- Raw daily rates. NOT NULL is applied after cleaning, because the
-- ECB export contains dates with no published rate.
CREATE TABLE fx_daily (
    rate_date    DATE PRIMARY KEY,
    gbp_per_eur  NUMERIC(10,5)
);

-- Load the CSV into fx_daily (date column -> rate_date,
-- value column -> gbp_per_eur, skip the text date column), then:

DELETE FROM fx_daily WHERE gbp_per_eur IS NULL;   -- days with no rate
ALTER TABLE fx_daily ALTER COLUMN gbp_per_eur SET NOT NULL;

-- Monthly table used by the reporting views
CREATE TABLE fx_rates AS
SELECT DATE_TRUNC('month', rate_date)::date                  AS rate_month,
       ROUND(AVG(gbp_per_eur), 5)                            AS eur_gbp_avg,
       -- last available business day of the month
       (ARRAY_AGG(gbp_per_eur ORDER BY rate_date DESC))[1]   AS eur_gbp_close
FROM fx_daily
WHERE rate_date BETWEEN DATE '2024-10-01' AND DATE '2026-09-30'
GROUP BY 1;

ALTER TABLE fx_rates ADD PRIMARY KEY (rate_month);

-- Checks: 24 rows; September 2026 close = 0.85463
SELECT * FROM fx_rates ORDER BY rate_month;
