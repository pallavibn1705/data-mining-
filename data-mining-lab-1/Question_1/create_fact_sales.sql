CREATE TABLE IF NOT EXISTS fact_sales (
    store_id TEXT NOT NULL,
    product_sk BIGINT NOT NULL,
    category_id TEXT NOT NULL,
    sale_date DATE NOT NULL,
    bill_no TEXT NOT NULL,
    line_no INTEGER NOT NULL,
    quantity NUMERIC(18,3) NOT NULL,
    unit_price NUMERIC(18,2) NOT NULL,
    line_type TEXT NOT NULL,
    revenue NUMERIC(18,2) NOT NULL,

    PRIMARY KEY (bill_no, line_no),

    FOREIGN KEY (store_id)
        REFERENCES dim_store(store_id),

    FOREIGN KEY (product_sk)
        REFERENCES dim_product(product_sk),

    FOREIGN KEY (category_id)
        REFERENCES dim_category(category_id),

    FOREIGN KEY (sale_date)
        REFERENCES dim_date(date_key)
);