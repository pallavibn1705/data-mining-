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

INSERT INTO dim_date (
    date_key,
    day_of_week,
    day_name,
    day_of_month,
    month_number,
    month_name,
    quarter_number,
    year_number
)
SELECT
    d::DATE AS date_key,
    EXTRACT(ISODOW FROM d)::INTEGER AS day_of_week,
    TRIM(TO_CHAR(d, 'Day')) AS day_name,
    EXTRACT(DAY FROM d)::INTEGER AS day_of_month,
    EXTRACT(MONTH FROM d)::INTEGER AS month_number,
    TRIM(TO_CHAR(d, 'Month')) AS month_name,
    EXTRACT(QUARTER FROM d)::INTEGER AS quarter_number,
    EXTRACT(YEAR FROM d)::INTEGER AS year_number
FROM generate_series(
    DATE '2024-01-01',
    DATE '2024-12-31',
    INTERVAL '1 day'
) AS d
ON CONFLICT (date_key) DO NOTHING;