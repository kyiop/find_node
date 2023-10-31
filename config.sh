#!/bin/bash

###########################################基本参数###########################################


#=======公共参数=======

log_file=select_nodes.log

#MySQL


mysql_host=ashdjasdasdj
mysql_port=2883
database=schedule
mysqluser=schedule

mysql_conn_str="--defaults-extra-file=./connect.mysql -h${mysql_host} -P${mysql_port} -D${database} -u${mysqluser}"

#Promethues

prometheus_api="http://prasdjasdhjkashdjkahsjkd:9090/api/v1/query"

#K8Sconfig

k8s_configfile="kubeconfig_prod.yaml"



#======get_nodes独享=======


#非选中节点cpu最低空闲百分比

cpu_free_limit=0.6

#最低空闲容量，单位G

data_disk_need=800
nvme_disk_need=800
memory_need=400

#cpu最低空闲核心数量要求

cpu_at_least=50



#======upload独享=======

#一次执行干预的节点的最大数量，为了平滑批量异常或突发带来的干扰
max_exclued_per_every_exec=15

#最大允许的被排除主机的占比和次数，同时超过2个数值将被加入黑名单
max_exclude_rate=0.03
max_exclude_total=10

#黑名单解除时间
update_day_range=1



#======check_chosen独享=======


#已被选中的节点，cpu最低空闲百分比

chosen_cpu_free_limit=0.2

#已被选中的节点，最低空闲容量，单位G

chosen_data_disk_need=400
chosen_nvme_disk_need=400
chosen_memory_need=200



#======do_select独享=======


#最大选点数量,此项将作为选点算法发生异常时的默认值
max_selected_num=8

#选点时最低允许的7天平均空闲率,取值范围不能超过1，数值越大，筛选出来的可选节点数量越少
min_seven_day_avg=0.5


###########################################一级衍生参数#########################################



#======get_nodes独享=======


#CPU最低核心数量

cpu_core_need=`echo "${cpu_at_least} / ${cpu_free_limit}" | bc`



#======do_select独享=======


#选点时，cpu最近1小时的最低空闲率

min_one_hour_avg=`echo "scale=2;${min_seven_day_avg} * 1.1" | bc`





