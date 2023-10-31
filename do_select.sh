#!/bin/bash

echo -e "===================================初始化参数======================================"


source ./config.sh

source ./auto_selected_count.sh

source ./fire_alert.sh

#生成数据库中未被选中的所有可选节点的清单

echo -e "===================================生成数据库中未被选中的所有可选节点的清单======================================"

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where nvme_free != 0 and memory_free != 0 and cpu_free > ${min_one_hour_avg} and is_chosen = 0 order by cpu_free desc"  > ./tmp/can_be_select.list.tmp

if [[ $? -ne 0 ]];then

	echo -e "====`date`==ERROR== 【do_select】 无法访问数据库，或访问数据库失败。" >> ${log_file}
	exit 401

fi

if [[ -s ./tmp/can_be_select.list.tmp ]];then

	cat ./tmp/can_be_select.list.tmp | grep -v "node_ip_addr" > ./tmp/can_be_select.list
else

	echo -e "====`date`==ERROR== 【do_select】可选节点临时清单未生成，无法进行处理"
	exit 402

fi

if [[ -s ./tmp/can_be_select.list ]];then

#	查询未被选中的节点，且7天平均cpu空闲率高于${min_seven_day_avg}的所有节点的IP清单

echo -e "===================================分析过去7天的CPU指标是否符合标准======================================"

	instance_prom=`mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen = 0" | grep -v "node_ip_addr" | sed 's/$/&:59100|/g' | tr -d '\n' | sed '$s/.$//'`
	query_cmd="avg%28rate%28node_cpu_seconds_total%7Bisvke%3D%22training%22%2Cmode%3D%22idle%22%2Cinstance%3D%7E%22${instance_prom}%22%7D%5B7d%5D%29%29+by+%28instance%29+%3E+${min_seven_day_avg}"
	get_prom_good_result=`curl -s -m 180 ${prometheus_api}?query=${query_cmd}`
	echo ${get_prom_good_result} | jq .data.result | jq .[] | jq -r .metric.instance | awk -F ":" '{print $1}' > ./tmp/seven_day_avg_good.list

#	生成本次全量可选择的IP地址清单及数量
	echo -e "===================================生成本次全量可选择的IP地址清单及数量====================================="
	sort ./tmp/seven_day_avg_good.list ./tmp/can_be_select.list | uniq -d > ./tmp/this_time_could_select.list
	node_select_count=`cat ./tmp/this_time_could_select.list | wc -l`

#	获取当前已经处于选中状态的IP地址的清单及数量
	echo -e "===================================获取当前已经处于选中状态的IP地址的清单及数量====================================="
	mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen=1"  | grep -v "node_ip_addr" > ./tmp/last_selected.list
	num_last_selected=`cat ./tmp/last_selected.list | wc -l`

#	echo -e "==================================数据库中查询的已选中清单如下：`cat ./tmp/last_selected.list`,计算出的数量为${num_last_selected}====================================="
	echo -e "==================================确定最终的新选中节点数量====================================="
	echo -e "==================================选点算法给出的选点数量的值为${max_selected_num}====================================="

#	获取本次需要选择的节点的数量
	this_need_select_num=`expr ${max_selected_num} - ${num_last_selected}`

	echo -e "=================================本次需要选中的点的数量为${this_need_select_num}====================================="

	if [[ ${this_need_select_num} -gt ${node_select_count} ]] && [[ ${node_select_count} -ne 0 ]];then

		this_need_select_num=${node_select_count}
		echo -e "====`date`==WARNING== 【do_select】 可选择的节点数量小于需要的节点数量,计划选中的节点总数量为${max_selected_num},此前已被选中的节点数量为${num_last_selected},当前可选的节点数量为${node_select_count}。" >> ${log_file}
		assembly_message bundle node_select_warning "可选择的节点数量小于需要的节点数量,计划选中的节点总数量为${max_selected_num},此前已被选中的节点数量为${num_last_selected},当前可选的节点数量为${node_select_count}。" "可选节点数量不足"
		fire_the_message

	elif [[ ${node_select_count} -eq 0 ]] && [[ ${this_need_select_num} -gt 0 ]];then

		echo -e "====`date`==WARNING== 【do_select】 可选择的节点数量为0，无法增加新节点。" >> ${log_file}
		assembly_message bundle node_select_warning "idle-resource-utillization项目的可选择的节点数量为0，无法增加新节点。" "无可选节点供扩容使用。"
		fire_the_message

	fi

	if [[ ${this_need_select_num} -gt 0 ]];then
	
		echo -e "===================================选中新节点，并更新已选节点清单====================================="
	
		in_file_count=0
		> ./tmp/new_add_node.list

                for selected_node in `cat ./tmp/this_time_could_select.list`;do

                	if [[ ${in_file_count} -eq ${this_need_select_num} ]];then

                        	 break

                        fi

                        echo ${selected_node} >> ./tmp/new_add_node.list
                        in_file_count=`expr ${in_file_count} + 1`

                done

                if [[ -s ./tmp/new_add_node.list ]];then

                	new_add_node=`cat ./tmp/new_add_node.list | awk '{print "\""$0"\""}' | tr '\n' ',' |  sed '$s/.$//'`

			mysql ${mysql_conn_str} -e "update sh_selected_node set is_chosen=1,choosetime=now() where node_ip_addr in (${new_add_node});"

                        if [[ $? -ne 0 ]];then

                        	echo -e "====`date`==ERROR== 【do_select】 向数据库更新新增节点失败，请检查。" >> ${log_file}

                        fi

		fi
	
#	判断是否有需要驱逐的节点，如有则进行驱逐,此类驱逐非算法逻辑导致的驱逐，需要进行排查。


	elif [[ ${this_need_select_num} -lt 0 ]];then

		echo -e "===================================被选中的节点数量过多，按CPU使用率由高到低进行驱逐。======================================"
		
		echo -e "====`date`==INFO== 【do_select】 当前已选择的节点数量大于预设值，将根据CPU过去1小时的平均使用率执行驱逐,按升序执行驱逐,主动驱逐，不计入驱逐统计。" >> ${log_file}

		mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen=1 and node_ip_addr not in (select node_ip_addr from sh_selected_node where is_chosen=1 order by cpu_free desc limit ${max_selected_num});" | grep -v "node_ip_addr" > ./tmp/need_delete_this_time.list


		if [[ -s ./tmp/need_delete_this_time.list ]];then

			need_delete_node=`cat ./tmp/need_delete_this_time.list | awk '{print "\""$0"\""}' | tr '\n' ',' |  sed '$s/.$//'`
                	mysql ${mysql_conn_str} -e "update sh_selected_node set is_chosen=0,choosetime=null where node_ip_addr in (${need_delete_node});"

                	if [[ $? -ne 0 ]];then

                		echo -e "====`date`==ERROR== 【do_select】 驱逐节点时sql执行发生异常，请检查。" >> ${log_file}
			else

				echo -e "====`date`==INFO== 【do_select】 驱逐节点成功，被驱逐的节点清单为${need_delete_node}" >> ${log_file}

				assembly_message bundle node_unchosen info "选中节点资源充足，回收`cat ./tmp/need_delete_this_time.list | tr '\n' ',' |  sed '$s/.$//'`,以避免资源浪费。" "工作节点过多执行回收过程。"
				fire_the_message

                	fi
		
		fi

	else
		
		echo -e "===================================节点无变化，不进行处理。======================================"	
		echo -e "====`date`==INFO== 【do_select】 无需要增加或驱逐的的节点。" >> ${log_file}
	

	fi

else

	echo -e "====`date`==ERROR== 【do_select】 未从数据库中查询到可选节点，无法继续进行，请人工检查。" >> ${log_file}
        exit 301

fi

echo -e "===================================计算被驱逐或被排除的节点的驱逐率或被排除率。======================================"

mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set deport_rate=deported_total/(select sum(deported_total) from sh_deport_exclude_statistics where deported_total > 0) where node_ip_addr in (select node_ip_addr from sh_deport_exclude_statistics where deported_total > 0)"

if [[ $? -ne 0 ]];then

	echo -e "====`date`==ERROR== 【do_select】 驱逐率计算失败，请检查。" >> ${log_file}

fi

mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set exclude_rate=excluded_total/(select sum(excluded_total) from sh_deport_exclude_statistics where excluded_total > 0) where node_ip_addr in (select node_ip_addr from sh_deport_exclude_statistics where excluded_total > 0)"

if [[ $? -ne 0 ]];then

	echo -e "====`date`==ERROR== 【do_select】 排除率计算失败，请检查。" >> ${log_file}

fi

