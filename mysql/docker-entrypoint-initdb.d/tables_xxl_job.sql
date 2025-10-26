#
# xxl-job
# copyright (c) 2015-present, xuxueli.

create database if not exists `xxl_job` default character set utf8mb4 collate utf8mb4_unicode_ci;
use `xxl_job`;

set names utf8mb4;

## —————————————————————— job group and registry ——————————————————

create table `xxl_job_group`
(
    `id`           int(11)     not null auto_increment,
    `app_name`     varchar(64) not null comment '执行器appname',
    `title`        varchar(12) not null comment '执行器名称',
    `address_type` tinyint(4)  not null default '0' comment '执行器地址类型：0=自动注册、1=手动录入',
    `address_list` text comment '执行器地址列表，多地址逗号分隔',
    `update_time`  datetime             default null,
    primary key (`id`)
) engine = innodb
  default charset = utf8mb4;

create table `xxl_job_registry`
(
    `id`             int(11)      not null auto_increment,
    `registry_group` varchar(50)  not null,
    `registry_key`   varchar(255) not null,
    `registry_value` varchar(255) not null,
    `update_time`    datetime default null,
    primary key (`id`),
    unique key `i_g_k_v` (`registry_group`, `registry_key`, `registry_value`) using btree
) engine = innodb
  default charset = utf8mb4;

## —————————————————————— job info ——————————————————

create table `xxl_job_info`
(
    `id`                        int(11)      not null auto_increment,
    `job_group`                 int(11)      not null comment '执行器主键id',
    `job_desc`                  varchar(255) not null,
    `add_time`                  datetime              default null,
    `update_time`               datetime              default null,
    `author`                    varchar(64)           default null comment '作者',
    `alarm_email`               varchar(255)          default null comment '报警邮件',
    `schedule_type`             varchar(50)  not null default 'none' comment '调度类型',
    `schedule_conf`             varchar(128)          default null comment '调度配置，值含义取决于调度类型',
    `misfire_strategy`          varchar(50)  not null default 'do_nothing' comment '调度过期策略',
    `executor_route_strategy`   varchar(50)           default null comment '执行器路由策略',
    `executor_handler`          varchar(255)          default null comment '执行器任务handler',
    `executor_param`            varchar(512)          default null comment '执行器任务参数',
    `executor_block_strategy`   varchar(50)           default null comment '阻塞处理策略',
    `executor_timeout`          int(11)      not null default '0' comment '任务执行超时时间，单位秒',
    `executor_fail_retry_count` int(11)      not null default '0' comment '失败重试次数',
    `glue_type`                 varchar(50)  not null comment 'glue类型',
    `glue_source`               mediumtext comment 'glue源代码',
    `glue_remark`               varchar(128)          default null comment 'glue备注',
    `glue_updatetime`           datetime              default null comment 'glue更新时间',
    `child_jobid`               varchar(255)          default null comment '子任务id，多个逗号分隔',
    `trigger_status`            tinyint(4)   not null default '0' comment '调度状态：0-停止，1-运行',
    `trigger_last_time`         bigint(13)   not null default '0' comment '上次调度时间',
    `trigger_next_time`         bigint(13)   not null default '0' comment '下次调度时间',
    primary key (`id`)
) engine = innodb
  default charset = utf8mb4;

create table `xxl_job_logglue`
(
    `id`          int(11)      not null auto_increment,
    `job_id`      int(11)      not null comment '任务，主键id',
    `glue_type`   varchar(50) default null comment 'glue类型',
    `glue_source` mediumtext comment 'glue源代码',
    `glue_remark` varchar(128) not null comment 'glue备注',
    `add_time`    datetime    default null,
    `update_time` datetime    default null,
    primary key (`id`)
) engine = innodb
  default charset = utf8mb4;

## —————————————————————— job log and report ——————————————————

create table `xxl_job_log`
(
    `id`                        bigint(20) not null auto_increment,
    `job_group`                 int(11)    not null comment '执行器主键id',
    `job_id`                    int(11)    not null comment '任务，主键id',
    `executor_address`          varchar(255)        default null comment '执行器地址，本次执行的地址',
    `executor_handler`          varchar(255)        default null comment '执行器任务handler',
    `executor_param`            varchar(512)        default null comment '执行器任务参数',
    `executor_sharding_param`   varchar(20)         default null comment '执行器任务分片参数，格式如 1/2',
    `executor_fail_retry_count` int(11)    not null default '0' comment '失败重试次数',
    `trigger_time`              datetime            default null comment '调度-时间',
    `trigger_code`              int(11)    not null comment '调度-结果',
    `trigger_msg`               text comment '调度-日志',
    `handle_time`               datetime            default null comment '执行-时间',
    `handle_code`               int(11)    not null comment '执行-状态',
    `handle_msg`                text comment '执行-日志',
    `alarm_status`              tinyint(4) not null default '0' comment '告警状态：0-默认、1-无需告警、2-告警成功、3-告警失败',
    primary key (`id`),
    key `i_trigger_time` (`trigger_time`),
    key `i_handle_code` (`handle_code`),
    key `i_jobid_jobgroup` (`job_id`, `job_group`),
    key `i_job_id` (`job_id`)
) engine = innodb
  default charset = utf8mb4;

create table `xxl_job_log_report`
(
    `id`            int(11) not null auto_increment,
    `trigger_day`   datetime         default null comment '调度-时间',
    `running_count` int(11) not null default '0' comment '运行中-日志数量',
    `suc_count`     int(11) not null default '0' comment '执行成功-日志数量',
    `fail_count`    int(11) not null default '0' comment '执行失败-日志数量',
    `update_time`   datetime         default null,
    primary key (`id`),
    unique key `i_trigger_day` (`trigger_day`) using btree
) engine = innodb
  default charset = utf8mb4;

## —————————————————————— lock ——————————————————

create table `xxl_job_lock`
(
    `lock_name` varchar(50) not null comment '锁名称',
    primary key (`lock_name`)
) engine = innodb
  default charset = utf8mb4;

## —————————————————————— user ——————————————————

create table `xxl_job_user`
(
    `id`         int(11)      not null auto_increment,
    `username`   varchar(50)  not null comment '账号',
    `password`   varchar(100) not null comment '密码加密信息',
    `token`      varchar(100) default null comment '登录token',
    `role`       tinyint(4)   not null comment '角色：0-普通用户、1-管理员',
    `permission` varchar(255) default null comment '权限：执行器id列表，多个逗号分割',
    primary key (`id`),
    unique key `i_username` (`username`) using btree
) engine = innodb
  default charset = utf8mb4;


## —————————————————————— for default data ——————————————————

insert into `xxl_job_group`(`id`, `app_name`, `title`, `address_type`, `address_list`, `update_time`)
values (1, 'xxl-job-executor-sample', '通用执行器sample', 0, null, now()),
       (2, 'xxl-job-executor-sample-ai', 'ai执行器sample', 0, null, now());

insert into `xxl_job_info`(`id`, `job_group`, `job_desc`, `add_time`, `update_time`, `author`, `alarm_email`,
                           `schedule_type`, `schedule_conf`, `misfire_strategy`, `executor_route_strategy`,
                           `executor_handler`, `executor_param`, `executor_block_strategy`, `executor_timeout`,
                           `executor_fail_retry_count`, `glue_type`, `glue_source`, `glue_remark`, `glue_updatetime`,
                           `child_jobid`)
values (1, 1, '示例任务01', now(), now(), 'xxl', '', 'cron', '0 0 0 * * ? *',
        'do_nothing', 'first', 'demojobhandler', '', 'serial_execution', 0, 0, 'bean', '', 'glue代码初始化',
        now(), ''),
       (2, 2, 'ollama示例任务01', now(), now(), 'xxl', '', 'none', '',
        'do_nothing', 'first', 'ollamajobhandler', '{
    "input": "慢sql问题分析思路",
    "prompt": "你是一个研发工程师，擅长解决技术类问题。",
    "model": "qwen3:0.6b"
}', 'serial_execution', 0, 0, 'bean', '', 'glue代码初始化',
        now(), ''),
       (3, 2, 'dify示例任务', now(), now(), 'xxl', '', 'none', '',
        'do_nothing', 'first', 'difyworkflowjobhandler', '{
    "inputs":{
        "input":"查询班级各学科前三名"
    },
    "user": "xxl-job",
    "baseurl": "http://localhost/v1",
    "apikey": "app-ouvgnuoqrimokfmujvbjoutn"
}', 'serial_execution', 0, 0, 'bean', '', 'glue代码初始化',
        now(), '');

insert into `xxl_job_user`(`id`, `username`, `password`, `role`, `permission`)
values (1, 'admin', '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92', 1, null);

insert into `xxl_job_lock` (`lock_name`)
values ('schedule_lock');

commit;