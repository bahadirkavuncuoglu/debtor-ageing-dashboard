/* ============================================================
   01 - TABLES
   Database: debtor_ageing (PostgreSQL)
   Load order matters because of the foreign keys:
   customers -> invoices -> payments
   CSVs are produced by the generator in data_generation/
   ============================================================ */

CREATE TABLE customers (
    customer_id    INTEGER PRIMARY KEY,
    customer_name  VARCHAR(100) NOT NULL,
    country        VARCHAR(50),
    payment_terms  INTEGER NOT NULL
);

CREATE TABLE invoices (
    invoice_id      INTEGER PRIMARY KEY,
    customer_id     INTEGER NOT NULL REFERENCES customers(customer_id),
    invoice_date    DATE NOT NULL,
    due_date        DATE NOT NULL,
    invoice_amount  NUMERIC(12,2) NOT NULL,
    currency        CHAR(3) NOT NULL
);

CREATE TABLE payments (
    payment_id      INTEGER PRIMARY KEY,
    invoice_id      INTEGER NOT NULL REFERENCES invoices(invoice_id),
    payment_date    DATE NOT NULL,
    payment_amount  NUMERIC(12,2) NOT NULL,
    currency        CHAR(3) NOT NULL
);

-- After loading the CSVs (e.g. DBeaver import wizard), expected counts:
--   customers 300 | invoices 7,010 | payments 7,029
