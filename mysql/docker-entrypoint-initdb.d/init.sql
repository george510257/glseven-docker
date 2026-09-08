-- 创建数据库 xxl_job
create database `xxl_job` character set 'utf8mb4' collate 'utf8mb4_general_ci';
-- 创建普通用户 xxl_job
create user `xxl_job`@`%` identified with caching_sha2_password by 'xxl_job';
grant all privileges on `xxl_job`.* to `xxl_job`@`%`;

-- 创建数据库 nacos_devtest
create database `nacos_devtest` character set 'utf8mb4' collate 'utf8mb4_general_ci';
-- 创建普通用户 nacos
create user `nacos`@`%` identified with caching_sha2_password by 'nacos';
grant all privileges on `nacos_devtest`.* to `nacos`@`%`;

-- 创建数据库 keycloak
create database `keycloak` character set 'utf8mb4' collate 'utf8mb4_unicode_ci';
-- 创建普通用户 keycloak
create user `keycloak`@`%` identified with caching_sha2_password by 'keycloak';
grant all privileges on `keycloak`.* to `keycloak`@`%`;

flush privileges;
