DELETE FROM sales_heap WHERE product_id > 1000000;

DELETE FROM sales_partition_heap WHERE product_id > 1000000;

SELECT COUNT(*) FROM sales_heap;

SELECT COUNT(*) FROM sales_partition_heap;
