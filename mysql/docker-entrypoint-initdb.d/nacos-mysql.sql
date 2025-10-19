/*
 * copyright 1999-2018 alibaba group holding ltd.
 *
 * licensed under the apache license, version 2.0 (the "license");
 * you may not use this file except in compliance with the license.
 * you may obtain a copy of the license at
 *
 *      http://www.apache.org/licenses/license-2.0
 *
 * unless required by applicable law or agreed to in writing, software
 * distributed under the license is distributed on an "as is" basis,
 * without warranties or conditions of any kind, either express or implied.
 * see the license for the specific language governing permissions and
 * limitations under the license.
 */

/******************************************/
/*   表名称 = config_info                  */
/******************************************/
create table `config_info`
(
    `id`                 bigint(20)    not null auto_increment comment 'id',
    `data_id`            varchar(255)  not null comment 'data_id',
    `group_id`           varchar(128)           default null comment 'group_id',
    `content`            longtext      not null comment 'content',
    `md5`                varchar(32)            default null comment 'md5',
    `gmt_create`         datetime      not null default current_timestamp comment '创建时间',
    `gmt_modified`       datetime      not null default current_timestamp comment '修改时间',
    `src_user`           text comment 'source user',
    `src_ip`             varchar(50)            default null comment 'source ip',
    `app_name`           varchar(128)           default null comment 'app_name',
    `tenant_id`          varchar(128)           default '' comment '租户字段',
    `c_desc`             varchar(256)           default null comment 'configuration description',
    `c_use`              varchar(64)            default null comment 'configuration usage',
    `effect`             varchar(64)            default null comment '配置生效的描述',
    `type`               varchar(64)            default null comment '配置的类型',
    `c_schema`           text comment '配置的模式',
    `encrypted_data_key` varchar(1024) not null default '' comment '密钥',
    primary key (`id`),
    unique key `uk_configinfo_datagrouptenant` (`data_id`, `group_id`, `tenant_id`)
) engine = innodb
  default charset = utf8
  collate = utf8_bin comment ='config_info';

/******************************************/
/*   表名称 = config_info  since 2.5.0     */
/******************************************/
create table `config_info_gray`
(
    `id`                 bigint unsigned not null auto_increment comment 'id',
    `data_id`            varchar(255)    not null comment 'data_id',
    `group_id`           varchar(128)    not null comment 'group_id',
    `content`            longtext        not null comment 'content',
    `md5`                varchar(32)              default null comment 'md5',
    `src_user`           text comment 'src_user',
    `src_ip`             varchar(100)             default null comment 'src_ip',
    `gmt_create`         datetime(3)     not null default current_timestamp(3) comment 'gmt_create',
    `gmt_modified`       datetime(3)     not null default current_timestamp(3) comment 'gmt_modified',
    `app_name`           varchar(128)             default null comment 'app_name',
    `tenant_id`          varchar(128)             default '' comment 'tenant_id',
    `gray_name`          varchar(128)    not null comment 'gray_name',
    `gray_rule`          text            not null comment 'gray_rule',
    `encrypted_data_key` varchar(256)    not null default '' comment 'encrypted_data_key',
    primary key (`id`),
    unique key `uk_configinfogray_datagrouptenantgray` (`data_id`, `group_id`, `tenant_id`, `gray_name`),
    key `idx_dataid_gmt_modified` (`data_id`, `gmt_modified`),
    key `idx_gmt_modified` (`gmt_modified`)
) engine = innodb
  auto_increment = 1
  default charset = utf8 comment ='config_info_gray';

/******************************************/
/*   表名称 = config_tags_relation         */
/******************************************/
create table `config_tags_relation`
(
    `id`        bigint(20)   not null comment 'id',
    `tag_name`  varchar(128) not null comment 'tag_name',
    `tag_type`  varchar(64)  default null comment 'tag_type',
    `data_id`   varchar(255) not null comment 'data_id',
    `group_id`  varchar(128) not null comment 'group_id',
    `tenant_id` varchar(128) default '' comment 'tenant_id',
    `nid`       bigint(20)   not null auto_increment comment 'nid, 自增长标识',
    primary key (`nid`),
    unique key `uk_configtagrelation_configidtag` (`id`, `tag_name`, `tag_type`),
    key `idx_tenant_id` (`tenant_id`)
) engine = innodb
  default charset = utf8
  collate = utf8_bin comment ='config_tag_relation';

/******************************************/
/*   表名称 = group_capacity               */
/******************************************/
create table `group_capacity`
(
    `id`                bigint(20) unsigned not null auto_increment comment '主键id',
    `group_id`          varchar(128)        not null default '' comment 'group id，空字符表示整个集群',
    `quota`             int(10) unsigned    not null default '0' comment '配额，0表示使用默认值',
    `usage`             int(10) unsigned    not null default '0' comment '使用量',
    `max_size`          int(10) unsigned    not null default '0' comment '单个配置大小上限，单位为字节，0表示使用默认值',
    `max_aggr_count`    int(10) unsigned    not null default '0' comment '聚合子配置最大个数，，0表示使用默认值',
    `max_aggr_size`     int(10) unsigned    not null default '0' comment '单个聚合数据的子配置大小上限，单位为字节，0表示使用默认值',
    `max_history_count` int(10) unsigned    not null default '0' comment '最大变更历史数量',
    `gmt_create`        datetime            not null default current_timestamp comment '创建时间',
    `gmt_modified`      datetime            not null default current_timestamp comment '修改时间',
    primary key (`id`),
    unique key `uk_group_id` (`group_id`)
) engine = innodb
  default charset = utf8
  collate = utf8_bin comment ='集群、各group容量信息表';

/******************************************/
/*   表名称 = his_config_info              */
/******************************************/
create table `his_config_info`
(
    `id`                 bigint(20) unsigned not null comment 'id',
    `nid`                bigint(20) unsigned not null auto_increment comment 'nid, 自增标识',
    `data_id`            varchar(255)        not null comment 'data_id',
    `group_id`           varchar(128)        not null comment 'group_id',
    `app_name`           varchar(128)                 default null comment 'app_name',
    `content`            longtext            not null comment 'content',
    `md5`                varchar(32)                  default null comment 'md5',
    `gmt_create`         datetime            not null default current_timestamp comment '创建时间',
    `gmt_modified`       datetime            not null default current_timestamp comment '修改时间',
    `src_user`           text comment 'source user',
    `src_ip`             varchar(50)                  default null comment 'source ip',
    `op_type`            char(10)                     default null comment 'operation type',
    `tenant_id`          varchar(128)                 default '' comment '租户字段',
    `encrypted_data_key` varchar(1024)       not null default '' comment '密钥',
    `publish_type`       varchar(50)                  default 'formal' comment 'publish type gray or formal',
    `gray_name`          varchar(50)                  default null comment 'gray name',
    `ext_info`           longtext                     default null comment 'ext info',
    primary key (`nid`),
    key `idx_gmt_create` (`gmt_create`),
    key `idx_gmt_modified` (`gmt_modified`),
    key `idx_did` (`data_id`)
) engine = innodb
  default charset = utf8
  collate = utf8_bin comment ='多租户改造';


/******************************************/
/*   表名称 = tenant_capacity              */
/******************************************/
create table `tenant_capacity`
(
    `id`                bigint(20) unsigned not null auto_increment comment '主键id',
    `tenant_id`         varchar(128)        not null default '' comment 'tenant id',
    `quota`             int(10) unsigned    not null default '0' comment '配额，0表示使用默认值',
    `usage`             int(10) unsigned    not null default '0' comment '使用量',
    `max_size`          int(10) unsigned    not null default '0' comment '单个配置大小上限，单位为字节，0表示使用默认值',
    `max_aggr_count`    int(10) unsigned    not null default '0' comment '聚合子配置最大个数',
    `max_aggr_size`     int(10) unsigned    not null default '0' comment '单个聚合数据的子配置大小上限，单位为字节，0表示使用默认值',
    `max_history_count` int(10) unsigned    not null default '0' comment '最大变更历史数量',
    `gmt_create`        datetime            not null default current_timestamp comment '创建时间',
    `gmt_modified`      datetime            not null default current_timestamp comment '修改时间',
    primary key (`id`),
    unique key `uk_tenant_id` (`tenant_id`)
) engine = innodb
  default charset = utf8
  collate = utf8_bin comment ='租户容量信息表';


create table `tenant_info`
(
    `id`            bigint(20)   not null auto_increment comment 'id',
    `kp`            varchar(128) not null comment 'kp',
    `tenant_id`     varchar(128) default '' comment 'tenant_id',
    `tenant_name`   varchar(128) default '' comment 'tenant_name',
    `tenant_desc`   varchar(256) default null comment 'tenant_desc',
    `create_source` varchar(32)  default null comment 'create_source',
    `gmt_create`    bigint(20)   not null comment '创建时间',
    `gmt_modified`  bigint(20)   not null comment '修改时间',
    primary key (`id`),
    unique key `uk_tenant_info_kptenantid` (`kp`, `tenant_id`),
    key `idx_tenant_id` (`tenant_id`)
) engine = innodb
  default charset = utf8
  collate = utf8_bin comment ='tenant_info';

create table `users`
(
    `username` varchar(50)  not null primary key comment 'username',
    `password` varchar(500) not null comment 'password',
    `enabled`  boolean      not null comment 'enabled'
);

create table `roles`
(
    `username` varchar(50) not null comment 'username',
    `role`     varchar(50) not null comment 'role',
    unique index `idx_user_role` (`username` asc, `role` asc) using btree
);

create table `permissions`
(
    `role`     varchar(50)  not null comment 'role',
    `resource` varchar(128) not null comment 'resource',
    `action`   varchar(8)   not null comment 'action',
    unique index `uk_role_permission` (`role`, `resource`, `action`) using btree
);
