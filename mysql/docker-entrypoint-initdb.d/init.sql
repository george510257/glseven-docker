-- 创建数据库 keycloak
CREATE DATABASE `keycloak` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 keycloak
CREATE USER `keycloak`@`%` IDENTIFIED WITH mysql_native_password BY 'keycloak';
GRANT ALL PRIVILEGES ON `keycloak`.* TO `keycloak`@`%`;

-- 创建数据库 xxl_job
CREATE DATABASE `xxl_job` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 xxl_job
CREATE USER `xxl_job`@`%` IDENTIFIED WITH mysql_native_password BY 'xxl_job';
GRANT ALL PRIVILEGES ON `xxl_job`.* TO `xxl_job`@`%`;

flush privileges;
