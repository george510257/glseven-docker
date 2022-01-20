-- 创建数据库 redmine
CREATE DATABASE `redmine` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 redmine
CREATE USER `redmine`@`%` IDENTIFIED WITH mysql_native_password BY 'redmine';
GRANT ALL PRIVILEGES ON `redmine`.* TO `redmine`@`%`;

-- 创建数据库 rap2
CREATE DATABASE `rap2` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 rap2
CREATE USER `rap2`@`%` IDENTIFIED WITH mysql_native_password BY 'rap2';
GRANT ALL PRIVILEGES ON `rap2`.* TO `rap2`@`%`;

-- 创建数据库 zentao
CREATE DATABASE `zentao` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 zentao
CREATE USER `zentao`@`%` IDENTIFIED WITH mysql_native_password BY 'zentao';
GRANT ALL PRIVILEGES ON `zentao`.* TO `zentao`@`%`;

-- 创建数据库 jumpserver
CREATE DATABASE `jumpserver` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 jumpserver
CREATE USER `jumpserver`@`%` IDENTIFIED WITH mysql_native_password BY 'jumpserver';
GRANT ALL PRIVILEGES ON `jumpserver`.* TO `jumpserver`@`%`;

-- 创建数据库 xxl_job
CREATE DATABASE `xxl_job` CHARACTER SET 'utf8mb4' COLLATE 'utf8mb4_general_ci';
-- 创建普通用户 xxl_job
CREATE USER `xxl_job`@`%` IDENTIFIED WITH mysql_native_password BY 'xxl_job';
GRANT ALL PRIVILEGES ON `xxl_job`.* TO `xxl_job`@`%`;

flush privileges;
