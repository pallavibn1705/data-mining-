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