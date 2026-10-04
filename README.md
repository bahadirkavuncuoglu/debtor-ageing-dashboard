# Debtor Ageing & Cash Collection Dashboard

An end-to-end receivables analysis for a fictional UK wholesaler, **Northmere Trade Supplies Ltd**: Python to generate the ledger, PostgreSQL for the analysis, Power BI for reporting.

The question it answers is the one a credit controller or finance director actually asks: **of the money owed to us, how much is at risk, who should we chase first, and what would collecting faster be worth?**

![Overview page](images/overview.png)

---

## Key findings (as at 30 September 2026)

- **£10.53m** of receivables outstanding, of which **39% (£4.10m) is overdue** and **£1.99m is more than 90 days overdue**.
- **Countback DSO of 83.9 days**, against average payment terms of roughly 43 days: customers pay about six weeks later than agreed.
- **Collections are deteriorating:** overdue receivables rose from about 30% of the ledger in early 2025 to over 40% through 2026, consistently across like-for-like months.
- **The top 10 customers hold 42% of all receivables**, and several of them are also among the slowest payers. About five customers owe more than £0.4m each and pay 50–65 days late on average: the priority collections list.
- **Currency matters:** reporting euro balances without conversion would have overstated receivables by about **£228k**.

---

## What's in the report

| Page | Question it answers | Main visuals |
|---|---|---|
| **Overview** | How much is owed, how late, and is it getting worse? | KPI cards, ageing profile, simple / countback / best possible DSO trend, overdue % trend, "cash released if DSO falls by X days" slider |
| **Customers** | Who owes most, and who pays late? | Balance vs payment-lateness scatter with policy thresholds, top 10 concentration, country view, decomposition tree |
| **Collection Worklist** | Who do we call first? | Customer-by-bucket worklist sorted by oldest debt |

---

## Data

- **Invoices, payments and customers are synthetic**, generated in Python (`data_generation/`): 300 customers, ~7,000 invoices and ~7,000 payments over 24 months, with seasonality, a skewed customer size mix, four payment-behaviour profiles, part payments and instalments, and a share of never-paid invoices.
- **EUR/GBP exchange rates are real**: ECB euro foreign exchange reference rates, series `EXR.D.GBP.EUR.SP00.A`, aggregated to monthly average and month-end closing rates.
- **Northmere Trade Supplies Ltd is fictional.**

**The exact dataset behind the dashboard is in `data/`**, exported from the database the report was built on. All figures in this README come from these files. The generator is included to show how the data was built; running it yourself produces a dataset with the same structure and behaviour, but the figures may not match exactly (for example, with a different NumPy version). To reproduce the numbers above, use the CSVs in `data/`.

---

## Method

**Pipeline:** Python (generate CSVs) → PostgreSQL (tables, reporting views) → Power BI (import mode, star schema).

**Ageing** is calculated on the *outstanding balance after payments*, not the invoice value, using a fixed as-at date so every figure describes the same moment and results are reproducible.

**DSO, three ways:**
- *Simple DSO*: closing receivables ÷ month's credit sales × days in month.
- *Countback DSO*: walks back through prior months' sales until the receivables balance is used up. Used as the headline figure because the business is seasonal, and the simple method is distorted by single strong or weak sales months.
- *Best possible DSO*: DSO on not-yet-due receivables only. The gap to actual DSO is days lost to late payment.

**Currency (IAS 21 approach):** EUR receivables translated at the closing rate on the reporting date; EUR sales at the average rate of the month invoiced.

**Payment behaviour:** amount-weighted average days paid late per customer, on fully settled invoices only, with a minimum of 5 settled invoices before a customer is scored.

**Validation:** every key figure is reconciled by at least two independent routes: invoice-level ageing vs cumulative invoiced-minus-paid balances, SQL vs Power BI, and hand calculations for DSO.

---

## Data problems caught during the build

Reconciliation checks caught four real issues during development:

1. **Test data in the production dataset.** DSO figures for four months shifted between runs with no change to the logic. The differences matched the exact amounts of hand-typed test invoices that a learning script had re-inserted. Removed after verification, and a check for records outside the expected ID ranges was added.
2. **Two definitions of "overdue".** The dashboard showed 40.0% overdue and the SQL DSO view 41.6% for the same date. Cause: invoices due *on* the reporting date were counted as overdue in one place and not the other. Standardised on "overdue from the day after the due date".
3. **Duplicate customer names merged in a chart.** A customer appeared 108 days late with "285% of invoices paid late", impossible for a percentage. Several different customers shared a name, and the visual grouped by name and summed their averages. Fixed with a unique customer label built from the ID.
4. **Currencies added together.** Early totals summed EUR and GBP amounts directly, overstating receivables by about £228k. Fixed by converting at ECB rates.

---

## Limitations

- Invoice data is synthetic. The four payment profiles show as visible clusters in the customer scatter; real customer behaviour is more continuous.
- No write-offs are modelled, so very old unpaid debt stays on the ledger and the overdue share trends upward partly for that reason.
- DSO is calculated company-wide; it does not respond to country or currency filters (stated on the page).
- The first three months are excluded from DSO as ledger ramp-up.

---

## Repository structure

```
data/
  customers.csv                 The exact dataset behind the dashboard
  invoices.csv
  payments.csv
  fx_rates.csv                  Monthly EUR/GBP rates derived from ECB data
data_generation/
  generate_data.py              Python generator: customers, invoices, payments
sql/
  01_create_tables.sql          Tables and keys
  02_fx_rates.sql               ECB daily rates -> monthly average and closing rates
  03_reporting_views.sql        The five reporting views used by Power BI
  04_data_quality_checks.sql    Integrity checks and reconciliations, with expected results
powerbi/                        Power BI project (.pbip): report and semantic model as text
images/                         Dashboard screenshots
```

## How to run

### What you need

- **PostgreSQL** (15 or later) and a SQL client. These steps use **DBeaver** (free).
- **Python 3.10+** with `pandas` and `numpy` (`pip install pandas numpy`).
- **Power BI Desktop** (free, Windows only).

### 1. Create the database

In DBeaver, connect to your local PostgreSQL server and run:

```sql
CREATE DATABASE debtor_ageing;
```

Then edit the connection so it points at `debtor_ageing` (right-click the connection → Edit Connection → Database). Check the toolbar shows `public@debtor_ageing` before running anything else.

### 2. Get the data

**Recommended:** use the CSVs in `data/`. They are the exact data the dashboard was built on, so your results will match the figures in this README.

**Optional:** regenerate it yourself:

```bash
python data_generation/generate_data.py
```

This writes `customers.csv`, `invoices.csv` and `payments.csv` to `data/`. The structure is the same, but the figures may differ from those above.

**Don't open and re-save the CSVs in Excel.** Depending on your regional settings, Excel can change decimal separators and date formats without warning.

### 3. Create the tables and load the data

1. Run `sql/01_create_tables.sql`.
2. Load each CSV with DBeaver's import wizard: right-click the table → **Import Data** → CSV → select the file. On the **Tables mapping** step, check every column maps to an **existing** column (not "new").
3. Load in this order, because of the foreign keys: **customers → invoices → payments**.
4. Check the counts: 300 customers, 7,010 invoices, 7,029 payments.

### 4. Load the exchange rates

**Quick route (recommended):** run section A of `sql/02_fx_rates.sql` to create `fx_rates`, then import `data/fx_rates.csv` into it with the import wizard. Check: 24 rows, and the September 2026 closing rate is **0.85463**.

**Full route (from the raw ECB data):**

1. Download the daily series `EXR.D.GBP.EUR.SP00.A` (UK pound sterling / euro) as CSV from [data.ecb.europa.eu](https://data.ecb.europa.eu). Any date range covering October 2024 to 30 September 2026 works.
2. Open the CSV in a text editor (not Excel) and replace the first line with:
   ```
   rate_date,date_label,gbp_per_eur
   ```
   Make sure the next line still starts on its own line.
3. Run the `CREATE TABLE fx_daily` statement in section B of `sql/02_fx_rates.sql`.
4. Import the CSV into `fx_daily`: map `rate_date` and `gbp_per_eur` to the existing columns, and set `date_label` to **skip**.
5. Run the rest of section B. It removes days with no published rate and builds `fx_rates`.
6. Check: 24 rows, October 2024 to September 2026; September 2026 closing rate = **0.85463**.

### 5. Build the reporting views

Run all of `sql/03_reporting_views.sql` in one go (in DBeaver: **Alt+X**, Execute SQL Script). The views are created in order, because later ones read from earlier ones.

### 6. Run the checks

Run `sql/04_data_quality_checks.sql`. Every check has its expected result written next to it. In particular:

- the two ID-range checks return 0;
- the reconciliation (F2) shows about **£10,530,085** from both routes, within pennies;
- both overdue percentages (F4) are equal.

If any check doesn't match its expected result, stop and investigate before opening the report.

### 7. Open the report

1. Open `powerbi/Debtor_ageing.pbip` in Power BI Desktop.
2. **Transform data → Data source settings**: point the PostgreSQL source at your own server (`localhost`) and database (`debtor_ageing`), and enter your credentials. For a local database without SSL, untick **Use encrypted connection**.
3. Click **Refresh**. The Overview page should show **£10.53m** total outstanding.

### Troubleshooting

- **`relation "payments" does not exist`**: the script is running against the wrong database. Run `SELECT current_database();` and switch to `debtor_ageing`.
- **`COPY ... permission denied`**: the PostgreSQL server can't read files in your user folder. Use DBeaver's import wizard instead.
- **Import tries to add new columns**: a mapping is set to "new". Change it to the existing column, or skip it.
- **Numbers in Power BI don't match SQL**: the report holds a copy of the data. Click **Refresh** after any change in the database.

---

*Built with Python (pandas, NumPy), PostgreSQL, DBeaver and Power BI Desktop.*
