-- PostgreSQL seed data for the local product sample datasource.

INSERT INTO users (id, username, email) VALUES
(1, 'alice', 'alice@example.com'),
(2, 'bob', 'bob@example.com'),
(3, 'cathy', 'cathy@example.com'),
(4, 'daniel', 'daniel@example.com'),
(5, 'emily', 'emily@example.com')
ON CONFLICT (id) DO NOTHING;

INSERT INTO categories (id, name) VALUES
(1, '电子产品'),
(2, '服装'),
(3, '图书'),
(4, '家居用品'),
(5, '食品')
ON CONFLICT (id) DO NOTHING;

INSERT INTO products (id, name, price, stock) VALUES
(1, '智能手机', 2999.00, 100),
(2, 'T恤', 89.00, 500),
(3, '小说', 39.00, 200),
(4, '咖啡机', 599.00, 50),
(5, '牛奶', 15.00, 300),
(6, '笔记本电脑', 4999.00, 30),
(7, '沙发', 2599.00, 10),
(8, '巧克力', 25.00, 100),
(9, '羽绒服', 399.00, 80),
(10, '历史书', 69.00, 150)
ON CONFLICT (id) DO NOTHING;

INSERT INTO product_categories (product_id, category_id) VALUES
(1, 1),
(2, 2),
(3, 3),
(4, 1), (4, 4),
(5, 5),
(6, 1),
(7, 4),
(8, 5),
(9, 2),
(10, 3)
ON CONFLICT DO NOTHING;

INSERT INTO orders (id, user_id, total_amount, status, order_date) VALUES
(1, 1, 3088.00, 'completed', '2025-06-01 10:10:00'),
(2, 2, 39.00, 'pending', '2025-06-02 09:23:00'),
(3, 3, 1204.00, 'completed', '2025-06-03 13:45:00'),
(4, 4, 65.00, 'cancelled', '2025-06-04 16:05:00'),
(5, 5, 5113.00, 'completed', '2025-06-05 20:12:00'),
(6, 1, 814.00, 'completed', '2025-06-05 21:03:00'),
(7, 2, 424.00, 'pending', '2025-06-06 08:10:00'),
(8, 3, 524.00, 'completed', '2025-06-06 14:48:00'),
(9, 4, 399.00, 'completed', '2025-06-07 10:15:00'),
(10, 5, 129.00, 'pending', '2025-06-07 18:00:00')
ON CONFLICT (id) DO NOTHING;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price) VALUES
(1, 1, 1, 1, 2999.00),
(2, 1, 2, 1, 89.00),
(3, 2, 3, 1, 39.00),
(4, 3, 4, 2, 599.00),
(5, 3, 5, 2, 3.00),
(6, 4, 8, 2, 25.00),
(7, 4, 5, 1, 15.00),
(8, 5, 6, 1, 4999.00),
(9, 5, 2, 1, 89.00),
(10, 5, 5, 5, 5.00),
(11, 5, 8, 1, 25.00),
(12, 6, 9, 2, 399.00),
(13, 6, 3, 1, 16.00),
(14, 7, 2, 2, 89.00),
(15, 7, 3, 3, 39.00),
(16, 8, 10, 4, 69.00),
(17, 9, 9, 1, 399.00),
(18, 10, 8, 4, 25.00),
(19, 10, 5, 1, 29.00)
ON CONFLICT (id) DO NOTHING;

SELECT setval(pg_get_serial_sequence('users', 'id'), COALESCE((SELECT MAX(id) FROM users), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('categories', 'id'), COALESCE((SELECT MAX(id) FROM categories), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('products', 'id'), COALESCE((SELECT MAX(id) FROM products), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('orders', 'id'), COALESCE((SELECT MAX(id) FROM orders), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('order_items', 'id'), COALESCE((SELECT MAX(id) FROM order_items), 0) + 1, false);
