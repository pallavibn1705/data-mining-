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