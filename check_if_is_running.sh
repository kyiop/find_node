#!/bin/bash

source ./config.sh
source ./fire_alert.sh

#超过1小时还未启动任务的节点

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen = 1 and node_ip_addr not in (select bundle_host_ip from bundle_task_schedule_bundle_node_info) and choosetime <= DATE_SUB(NOW(),INTERVAL 1 HOUR)" > ./tmp/still_not_running_over_one_hour.list.tmp

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【check_if_is_running】 查询超过1小时未能启动的节点时访问数据库失败。" >> ${log_file}
        exit 401

fi

cat ./tmp/still_not_running_over_one_hour.list.tmp | grep -v "node_ip_addr" > ./tmp/still_not_running_over_one_hour.list


if [[ -s ./tmp/still_not_running_over_one_hour.list ]];then

	still_not_running_over_one_hour=`cat ./tmp/still_not_running_over_one_hour.list | tr '\n' ',' |  sed '$s/.$//'`

	assembly_message bundle warning "节点${still_not_running_over_one_hour}超过1小时未能完成启动，请检查。" "节点启动不正常。"
	fire_the_message

else

	echo -e "====`date`==INFO== 【check_if_is_running】 超过1小时未启动的节点清单文件不存在或为空。" >> ${log_file}

fi

