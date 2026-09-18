# Question 1 - Annapurna Data Platform
# Reproducible PowerShell / SQL command record
# Generated from the commands used for Q1(a)-Q1(f).
# Run from the Question 1 data directory.

# ============================================================
# Q1(a) - Stand up platform and partition sales files
# ============================================================

# Docker environment
docker --version
docker compose version
docker compose up -d
docker ps

# Partition original sales files by store and month.
# Original sales/ files are copied, not modified.
Get-ChildItem .\sales -Recurse -File | ForEach-Object {
    if ($_.Name -match '^SALES_(S\d+)_(\d{4})(\d{2})(\d{2})') {
        $store = $matches[1]
        $year = $matches[2]
        $month = $matches[3]
        $destination = ".\partitioned_sales\store=$store\month=$year-$month"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item $_.FullName -Destination $destination
    }
}

# Example DuckDB SQL used to prove partition pruning:
# SELECT COUNT(*) AS total_rows
# FROM read_csv_auto('partitioned_sales/store=S12/month=2024-10/*.csv');
# Result: 9,826 rows
# S12 October: 31 files, 527,831 bytes
# Whole sales corpus: 68,706,877 bytes


# ============================================================
# Q1(b) - Idempotent loading / safe re-runs
# ============================================================

# Run the following in DuckDB (annapurna.duckdb):
<#
CREATE TABLE IF NOT EXISTS sales_lines (
    bill_no VARCHAR,
    line_no INTEGER,
    product_code VARCHAR,
    qty DECIMAL(18,3),
    unit_price DECIMAL(18,2),
    line_type VARCHAR,
    ts VARCHAR,
    PRIMARY KEY (bill_no, line_no)
);

-- Sales dialect groups were loaded with INSERT OR IGNORE so the
-- (bill_no,line_no) primary key makes repeated runs idempotent.

-- Validation after each complete load:
SELECT
    COUNT(*) AS row_count,
    MD5(STRING_AGG(
        bill_no || '|' || CAST(line_no AS VARCHAR) || '|' ||
        COALESCE(product_code,'') || '|' || CAST(qty AS VARCHAR) || '|' ||
        CAST(unit_price AS VARCHAR) || '|' || COALESCE(line_type,'') || '|' ||
        COALESCE(ts,''),
        '' ORDER BY bill_no, line_no
    )) AS checksum
FROM sales_lines;

-- Observed after runs 1, 2 and 3:
-- row_count = 1,120,924
-- checksum  = 8ab655fab69de24932d7bd9d559ac859
#>


# ============================================================
# Q1(c) - Dimensional model
# ============================================================

# PostgreSQL master data was loaded from masters.sql.
# Example:
# Get-Content .\masters.sql | docker exec -i annapurna-postgres `
#     psql -U annapurna -d annapurna

# Dimension/fact DDL used in PostgreSQL:
<#
CREATE TABLE IF NOT EXISTS dim_store (
    store_id TEXT PRIMARY KEY,
    store_name TEXT NOT NULL,
    address_line TEXT NOT NULL,
    city TEXT NOT NULL,
    state TEXT NOT NULL,
    region TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_category (
    category_id TEXT PRIMARY KEY,
    category_name TEXT NOT NULL,
    department TEXT NOT NULL,
    gst_rate NUMERIC(4,3) NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_product (
    product_sk BIGINT PRIMARY KEY,
    product_code TEXT NOT NULL,
    product_name TEXT NOT NULL,
    category_id TEXT NOT NULL,
    brand TEXT,
    pack_size TEXT,
    uom TEXT,
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL,
    is_current BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_date (
    date_key DATE PRIMARY KEY,
    day_of_week INTEGER NOT NULL,
    day_name TEXT NOT NULL,
    day_of_month INTEGER NOT NULL,
    month_number INTEGER NOT NULL,
    month_name TEXT NOT NULL,
    quarter_number INTEGER NOT NULL,
    year_number INTEGER NOT NULL
);

INSERT INTO dim_date
SELECT
    d::DATE,
    EXTRACT(ISODOW FROM d)::INTEGER,
    TRIM(TO_CHAR(d, 'Day')),
    EXTRACT(DAY FROM d)::INTEGER,
    EXTRACT(MONTH FROM d)::INTEGER,
    TRIM(TO_CHAR(d, 'Month')),
    EXTRACT(QUARTER FROM d)::INTEGER,
    EXTRACT(YEAR FROM d)::INTEGER
FROM generate_series(
    DATE '2024-01-01',
    DATE '2024-12-31',
    INTERVAL '1 day'
) AS x(d)
ON CONFLICT (date_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS fact_sales (
    store_id TEXT NOT NULL,
    product_sk BIGINT,
    category_id TEXT,
    sale_date DATE NOT NULL,
    bill_no TEXT NOT NULL,
    line_no INTEGER NOT NULL,
    quantity NUMERIC(18,3) NOT NULL,
    unit_price NUMERIC(18,2) NOT NULL,
    line_type TEXT NOT NULL,
    revenue NUMERIC(18,2) NOT NULL,
    PRIMARY KEY (bill_no, line_no),
    FOREIGN KEY (store_id) REFERENCES dim_store(store_id),
    FOREIGN KEY (product_sk) REFERENCES dim_product(product_sk),
    FOREIGN KEY (category_id) REFERENCES dim_category(category_id),
    FOREIGN KEY (sale_date) REFERENCES dim_date(date_key)
);

CREATE INDEX IF NOT EXISTS idx_fact_sales_store
    ON fact_sales(store_id);
CREATE INDEX IF NOT EXISTS idx_fact_sales_product
    ON fact_sales(product_sk);
CREATE INDEX IF NOT EXISTS idx_fact_sales_category
    ON fact_sales(category_id);
CREATE INDEX IF NOT EXISTS idx_fact_sales_date
    ON fact_sales(sale_date);
CREATE INDEX IF NOT EXISTS idx_fact_sales_line_type
    ON fact_sales(line_type);

ANALYZE fact_sales;
#>

# Export product validity mapping from PostgreSQL for the DuckDB
# transformation stage.
docker exec annapurna-postgres psql -U annapurna -d annapurna -c "\copy (SELECT product_sk, product_code, category_id, valid_from, valid_to FROM products) TO '/tmp/products_master.csv' WITH (FORMAT CSV, HEADER true)"
docker cp annapurna-postgres:/tmp/products_master.csv .\products_master.csv

# Fact generation SQL used in DuckDB:
<#
COPY (
    WITH sales_with_date AS (
        SELECT
            bill_no,
            line_no,
            product_code,
            qty,
            unit_price,
            line_type,
            CAST(
                SUBSTR(SPLIT_PART(bill_no, '/', 2), 1, 4) || '-' ||
                SUBSTR(SPLIT_PART(bill_no, '/', 2), 5, 2) || '-' ||
                SUBSTR(SPLIT_PART(bill_no, '/', 2), 7, 2)
                AS DATE
            ) AS sale_date
        FROM sales_lines
        WHERE line_type IN ('SALE', 'RETURN', 'DISCOUNT', 'VOID')
    )
    SELECT
        SPLIT_PART(s.bill_no, '/', 1) AS store_id,
        p.product_sk,
        p.category_id,
        s.sale_date,
        s.bill_no,
        s.line_no,
        s.qty AS quantity,
        s.unit_price,
        s.line_type,
        CAST(s.qty * s.unit_price AS DECIMAL(18,2)) AS revenue
    FROM sales_with_date s
    LEFT JOIN products_master p
        ON s.product_code = p.product_code
       AND s.product_code <> 'DISC'
       AND s.sale_date BETWEEN p.valid_from AND p.valid_to
) TO 'fact_sales.csv' (HEADER, DELIMITER ',');
#>

docker cp .\fact_sales.csv annapurna-postgres:/tmp/fact_sales.csv
docker exec annapurna-postgres psql -U annapurna -d annapurna -c "\copy fact_sales (store_id, product_sk, category_id, sale_date, bill_no, line_no, quantity, unit_price, line_type, revenue) FROM '/tmp/fact_sales.csv' WITH (FORMAT CSV, HEADER true)"


# ============================================================
# Q1(d) - Historical price reporting
# ============================================================

# PostgreSQL SQL:
<#
CREATE OR REPLACE VIEW fact_sales_priced AS
SELECT
    f.store_id,
    f.product_sk,
    f.category_id,
    f.sale_date,
    f.bill_no,
    f.line_no,
    f.quantity,
    f.unit_price AS recorded_unit_price,
    f.line_type,
    f.revenue AS recorded_revenue,
    pr.selling_price AS applied_price,
    CASE
        WHEN f.product_sk IS NOT NULL
        THEN f.quantity * pr.selling_price
        ELSE f.revenue
    END AS price_based_revenue
FROM fact_sales f
LEFT JOIN price_revisions pr
    ON f.product_sk = pr.product_sk
   AND f.sale_date BETWEEN pr.effective_from AND pr.effective_to;

-- The same report logic is used for every period; only dates change.
-- March 2024 result:
-- lines = 64,507
-- quantity = 126,760.00
-- price_based_revenue = 41,971,885.88
--
-- December 2024 result:
-- lines = 74,511
-- quantity = 146,119.00
-- price_based_revenue = 50,736,426.71
#>


# ============================================================
# Q1(e) - Query across MinIO and PostgreSQL
# ============================================================

docker exec annapurna-minio mc alias set local http://127.0.0.1:9000 admin admin12345
docker exec annapurna-minio mc mb local/sales
docker cp .\partitioned_sales annapurna-minio:/tmp/partitioned_sales
docker exec annapurna-minio mc cp --recursive /tmp/partitioned_sales local/sales/
docker exec annapurna-minio mc ls --recursive local/sales/

# DuckDB SQL:
<#
INSTALL httpfs;
LOAD httpfs;

SET s3_endpoint='localhost:9000';
SET s3_access_key_id='admin';
SET s3_secret_access_key='admin12345';
SET s3_use_ssl=false;
SET s3_url_style='path';

INSTALL postgres;
LOAD postgres;

ATTACH 'host=localhost port=5432 dbname=annapurna user=annapurna password=annapurna'
AS pg (TYPE POSTGRES, READ_ONLY);

SELECT COUNT(*) AS sales_rows
FROM read_csv_auto(
    's3://sales/partitioned_sales/store=S01/month=2024-01/*.csv'
);

SELECT
    st.store_id,
    st.store_name,
    p.product_code,
    COUNT(*) AS sales_lines,
    ROUND(SUM(s.qty * s.unit_price), 2) AS revenue
FROM read_csv_auto(
    's3://sales/partitioned_sales/store=S01/month=2024-01/*.csv'
) s
JOIN pg.public.stores st
    ON st.store_id = SPLIT_PART(s.bill_no, '/', 1)
JOIN pg.public.products p
    ON p.product_code = s.product_code
WHERE s.line_type = 'SALE'
GROUP BY
    st.store_id,
    st.store_name,
    p.product_code
ORDER BY revenue DESC
LIMIT 10;

-- EXPLAIN ANALYZE of the query showed:
-- READ_CSV_AUTO reading 31 MinIO files / 9,260 rows,
-- PostgreSQL table scans for products (1,224 rows) and stores (12 rows),
-- and DuckDB HASH_JOIN / HASH_GROUP_BY operators.
#>


# ============================================================
# Q1(f) - Finance reconciliation
# ============================================================

# DuckDB SQL after PostgreSQL is attached as pg:
<#
SELECT
    STRFTIME(f.sale_date, '%Y-%m') AS month,
    ROUND(SUM(f.revenue), 2) AS our_revenue,
    ROUND(fin.revenue_inr, 2) AS finance_revenue,
    ROUND(SUM(f.revenue) - fin.revenue_inr, 2) AS difference
FROM pg.public.fact_sales f
JOIN read_csv_auto('finance_monthly.csv') fin
    ON STRFTIME(f.sale_date, '%Y-%m') = fin.month
GROUP BY
    STRFTIME(f.sale_date, '%Y-%m'),
    fin.revenue_inr
ORDER BY month;

-- Differences:
-- March    -486,250.00 : finance scope includes outside-till institutional order.
-- July     -232,131.70 : source-data gap; S07 July 09-11 exports missing.
-- December      +50.48 : finance rounds each bill to rupees.
-- October         0.00 : exact match; no duplicate inflation.
#>

Write-Host "Q1 script record complete."
