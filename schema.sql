-- ============================================================
-- ecommerce_myshop schema + seed (RDS MySQL)
-- ============================================================

-- Si quieres reset total, usa DROP en el script bash con flag.
CREATE DATABASE IF NOT EXISTS ecommerce_myshop
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE ecommerce_myshop;

SET FOREIGN_KEY_CHECKS=0;

-- =====================
-- USERS
-- =====================
CREATE TABLE IF NOT EXISTS users (
  id BIGINT NOT NULL AUTO_INCREMENT,
  username VARCHAR(50) NOT NULL,
  password VARCHAR(255) NOT NULL,
  role ENUM('ADMIN','OPERATOR','CUSTOMER') NOT NULL DEFAULT 'CUSTOMER',
  created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY username (username)
);

INSERT INTO users (id, username, password, role, created_at) VALUES
(1,'raul','$2a$10$q8RlpK0b2NAHf7xfFQEIJOYACCpyvqYIjF.xK953MLfmkHcqM5V9a','ADMIN','2026-01-23 00:29:00'),
(2,'admin','$2a$10$FFyoOvhDSDbpRoZenlN.P.q8VGVFiwmwmPaOE4EPod2Olc4MMlrl6','ADMIN','2026-01-24 22:16:19')
ON DUPLICATE KEY UPDATE
username=VALUES(username),
password=VALUES(password),
role=VALUES(role),
created_at=VALUES(created_at);

-- =====================
-- CATEGORIES
-- =====================
CREATE TABLE IF NOT EXISTS categories (
  id BIGINT NOT NULL AUTO_INCREMENT,
  name VARCHAR(100) NOT NULL,
  description TEXT,
  created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY name (name)
);

INSERT INTO categories (id,name,description,created_at) VALUES
(1,'Vinos','Vinos artesanales','2026-01-22 22:50:10'),
(2,'Licores','Licores nacionales','2026-01-22 22:50:10'),
(3,'Snacks','Acompañantes','2026-01-22 22:50:10')
ON DUPLICATE KEY UPDATE
name=VALUES(name),
description=VALUES(description),
created_at=VALUES(created_at);

-- =====================
-- PRODUCTS
-- =====================
CREATE TABLE IF NOT EXISTS products (
  id BIGINT NOT NULL AUTO_INCREMENT,
  name VARCHAR(150) NOT NULL,
  slug VARCHAR(150),
  description TEXT,
  image_folder VARCHAR(255),
  price DECIMAL(10,2) NOT NULL,
  stock INT NOT NULL,
  age_restricted TINYINT(1) NOT NULL DEFAULT 0,
  category_id BIGINT NOT NULL,
  created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY slug (slug),
  CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES categories(id),
  CHECK (stock >= 0)
);

INSERT INTO products (id,name,slug,description,image_folder,price,stock,age_restricted,category_id,created_at) VALUES
(1,'Vino de Corozo 750ml',NULL,NULL,NULL,42000,50,1,1,'2026-01-22 22:50:22'),
(2,'Ron Añejo 700ml',NULL,NULL,NULL,68000,30,1,2,'2026-01-22 22:50:22'),
(3,'Maní Tostado 200g',NULL,NULL,NULL,6500,100,0,3,'2026-01-22 22:50:22'),
(4,'Laptop Gamer',NULL,'RTX 4060',NULL,4500,5,0,1,'2026-01-23 20:42:12')
ON DUPLICATE KEY UPDATE
name=VALUES(name),
description=VALUES(description),
price=VALUES(price),
stock=VALUES(stock),
age_restricted=VALUES(age_restricted),
category_id=VALUES(category_id),
created_at=VALUES(created_at);

-- =====================
-- CUSTOMERS
-- =====================
CREATE TABLE IF NOT EXISTS customers (
  id BIGINT NOT NULL AUTO_INCREMENT,
  user_id BIGINT,
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  email VARCHAR(150) NOT NULL,
  phone VARCHAR(20),
  address TEXT,
  city VARCHAR(100),
  country VARCHAR(100),
  postal_code VARCHAR(20),
  created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY email (email),
  CONSTRAINT fk_customers_user FOREIGN KEY (user_id) REFERENCES users(id)
);

INSERT INTO customers (id,user_id,first_name,last_name,email,phone,address,city,country,postal_code,created_at) VALUES
(1,NULL,'Ana','Pérez','ana@demo.com','3001112233',NULL,'Valledupar','Colombia',NULL,'2026-01-22 22:49:57'),
(2,NULL,'Luis','Gómez','luis@demo.com','3004445566',NULL,'Bosconia','Colombia',NULL,'2026-01-22 22:49:57')
ON DUPLICATE KEY UPDATE
first_name=VALUES(first_name),
last_name=VALUES(last_name),
phone=VALUES(phone),
city=VALUES(city),
country=VALUES(country),
created_at=VALUES(created_at);

-- =====================
-- ORDERS
-- =====================
CREATE TABLE IF NOT EXISTS orders (
  id BIGINT NOT NULL AUTO_INCREMENT,
  customer_id BIGINT,
  total DECIMAL(10,2) NOT NULL,
  status ENUM('PENDING','WHATSAPP_PENDING','CONFIRMED','SHIPPED','COMPLETED','CANCELLED') NOT NULL DEFAULT 'WHATSAPP_PENDING',
  channel ENUM('WEB','WHATSAPP') NOT NULL DEFAULT 'WHATSAPP',
  contact_phone VARCHAR(20),
  notes TEXT,
  confirmed_at DATETIME,
  created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers(id)
);

INSERT INTO orders (id,customer_id,total,status,channel,contact_phone,notes,confirmed_at,created_at) VALUES
(1,1,110500,'CONFIRMED','WEB',NULL,NULL,NULL,'2026-01-22 22:52:03'),
(2,1,9000,'PENDING','WEB','3001234567','Entregar en la tarde',NULL,'2026-01-23 23:39:23'),
(3,1,9000,'PENDING','WEB','3001234567','Entregar en la tarde',NULL,'2026-01-24 15:55:11'),
(4,1,9000,'PENDING','WEB','3001234567','Entregar en la tarde',NULL,'2026-01-24 16:15:43')
ON DUPLICATE KEY UPDATE
total=VALUES(total),
status=VALUES(status),
channel=VALUES(channel),
contact_phone=VALUES(contact_phone),
notes=VALUES(notes),
confirmed_at=VALUES(confirmed_at),
created_at=VALUES(created_at);

-- =====================
-- ORDER ITEMS
-- =====================
CREATE TABLE IF NOT EXISTS order_items (
  id BIGINT NOT NULL AUTO_INCREMENT,
  order_id BIGINT NOT NULL,
  product_id BIGINT NOT NULL,
  quantity INT NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_oi_order FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  CONSTRAINT fk_oi_product FOREIGN KEY (product_id) REFERENCES products(id),
  CHECK (quantity > 0)
);

INSERT INTO order_items (id,order_id,product_id,quantity,price) VALUES
(1,1,1,1,42000),
(2,1,2,1,68000),
(3,2,4,2,4500),
(4,3,4,2,4500),
(5,4,4,2,4500)
ON DUPLICATE KEY UPDATE
quantity=VALUES(quantity),
price=VALUES(price);

-- =====================
-- PAYMENTS
-- =====================
CREATE TABLE IF NOT EXISTS payments (
  id BIGINT NOT NULL AUTO_INCREMENT,
  order_id BIGINT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  method ENUM('CASH','CARD','PSE','TRANSFER') NOT NULL,
  status ENUM('APPROVED','REJECTED') NOT NULL,
  created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY order_id (order_id),
  CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders(id)
);

INSERT INTO payments (id,order_id,amount,method,status,created_at) VALUES
(5,3,150,'CARD','APPROVED','2026-01-24 15:59:58'),
(6,1,150,'CARD','REJECTED','2026-01-24 17:26:03')
ON DUPLICATE KEY UPDATE
amount=VALUES(amount),
method=VALUES(method),
status=VALUES(status),
created_at=VALUES(created_at);

-- =====================
-- PRE ORDERS
-- =====================
CREATE TABLE IF NOT EXISTS pre_orders (
  id BIGINT NOT NULL AUTO_INCREMENT,
  customer_id BIGINT,
  guest_name VARCHAR(150),
  guest_phone VARCHAR(20),
  guest_city VARCHAR(100),
  total DECIMAL(10,2) NOT NULL,
  status ENUM('DRAFT','SENT','CONVERTED','ABANDONED') NOT NULL DEFAULT 'DRAFT',
  whatsapp_link TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT fk_pre_orders_customer FOREIGN KEY (customer_id) REFERENCES customers(id)
);

INSERT INTO pre_orders (id,customer_id,guest_name,guest_phone,guest_city,total,status,whatsapp_link,created_at) VALUES
(1,1,NULL,NULL,NULL,74500,'SENT','https://wa.me/573001112233','2026-01-22 22:50:31'),
(2,1,NULL,NULL,NULL,74500,'SENT','https://wa.me/573001112233','2026-01-22 22:51:40')
ON DUPLICATE KEY UPDATE
total=VALUES(total),
status=VALUES(status),
whatsapp_link=VALUES(whatsapp_link),
created_at=VALUES(created_at);

-- =====================
-- PRE ORDER ITEMS
-- =====================
CREATE TABLE IF NOT EXISTS pre_order_items (
  id BIGINT NOT NULL AUTO_INCREMENT,
  pre_order_id BIGINT NOT NULL,
  product_id BIGINT NOT NULL,
  quantity INT NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_poi_preorder FOREIGN KEY (pre_order_id) REFERENCES pre_orders(id) ON DELETE CASCADE,
  CONSTRAINT fk_poi_product FOREIGN KEY (product_id) REFERENCES products(id),
  CHECK (quantity > 0)
);

INSERT INTO pre_order_items (id,pre_order_id,product_id,quantity,price) VALUES
(1,1,1,1,42000),
(2,1,3,1,6500)
ON DUPLICATE KEY UPDATE
quantity=VALUES(quantity),
price=VALUES(price);

SET FOREIGN_KEY_CHECKS=1;