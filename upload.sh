#!/bin/bash

echo -e "==============================初始化参数====================================="

source ./config.sh
source ./fire_alert.sh

function get_value(){

	the_ip_addr=$1
	
	if [[ -f $2 ]];then

		the_result=`cat $2  | sed 's/:59100//g' |jq .[] | jq -r --arg node ${the_ip_addr} 'if .metric.instance == $node then .value[1] else empty end'`
		
	else

		echo -e "====`date`==ERROR== 【upload】 $2 文件不存在，任务失败，请人工检查。" >> ${log_file}
		exit 201

	fi

	if [[ -z ${the_result} ]];then
	
		echo "0"
	
	else
	
		echo ${the_result}
	
	fi
}



function get_status(){

	ip_to_send=$1

	cpu_free=-1
	data_free=-1
	nvme_free=-1
	memory_free=-1

	cpu_free=$(get_value ${ip_to_send} ./tmp/get_cpu_free_rate_result.json)
	data_free=$(get_value ${ip_to_send} ./tmp/get_data_disk_free_space_result.json)
	nvme_free=$(get_value ${ip_to_send} ./tmp/get_nvme_disk_free_space_result.json)
	memory_free=$(get_value ${ip_to_send} ./tmp/get_free_memory_result.json)

}


function exclude_deport(){

        excluded_node_list=`cat $1`

        for exclude_node in `echo ${excluded_node_list}`;do

                is_in_database=`mysql ${mysql_conn_str} -e "select node_ip_addr from sh_deport_exclude_statistics where node_ip_addr = '${exclude_node}'"`

		if [[ $? -ne 0 ]];then

			echo -e "====`date`==ERROR== 【upload】判断被排除的节点${exclude_node}在数据库中是否有记录时，sql执行失败，跳过该节点。 "
			continue

		fi

		if [[ -n ${is_in_database} ]];then

                        total_exclude_count=`mysql ${mysql_conn_str} -e "select excluded_total from sh_deport_exclude_statistics where node_ip_addr = '${exclude_node}'" | grep -v "excluded_total"`

			if [[ $? -ne 0 ]];then

				echo -e "====`date`==ERROR== 【upload】 获取被排除的节点${exclude_node}的排除次数失败。" >> ${log_file}
			
			fi

			if [[ ${total_exclude_count} -eq 0 ]];then
			
				extra_exclude_field_info="first_exclude_time = now(),"
			
			fi

			already_in_black_list=`mysql ${mysql_conn_str} -e "select node_ip_addr from sh_deport_exclude_statistics where node_ip_addr = '${exclude_node}' and add_to_blacklist = 1"`


                        if [[ $? -ne 0 ]];then

                                echo -e "====`date`==ERROR== 【upload】 验证被排除节点${exclude_node}是否位于黑名单中时，执行sql失败，请检查。" >> ${log_file}
				continue
                        fi

			if [[ -z ${already_in_black_list} ]];then

				total_exclude_count=`expr ${total_exclude_count} + 1`

				mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set excluded_total = ${total_exclude_count},${extra_exclude_field_info}last_exclude_time = now() where node_ip_addr = '${exclude_node}'"
                
				if [[ $? -ne 0 ]];then

					echo -e "====`date`==ERROR== 【upload】 更新节点${exclude_node}的被排除次数失败。" >> ${log_file}
			
				fi

			fi
		
		else
                
			mysql ${mysql_conn_str} -e "insert into sh_deport_exclude_statistics (node_ip_addr,excluded_total,first_exclude_time,last_exclude_time) values (\"${exclude_node}\",1,now(),now())"
                
			if [[ $? -ne 0 ]];then

				echo -e "====`date`==ERROR== 【upload】 写入被排除的节点${exclude_node}的被排除次数失败。" >> ${log_file}
			
			fi
		
		fi

        done
}


echo -e "==============================分析需要进行的节点增删改操作内容====================================="
> ./tmp/last_node.list


mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen = 0" > ./tmp/last_node.list.tmp

if [[ $? -ne 0 ]];then
	
	echo -e "====`date`==ERROR== 【upload】 数据库中历史可用节点数据获取失败，无法继续进行。" >> ${log_file}
	exit 202

fi

cat ./tmp/last_node.list.tmp | grep -v "node_ip_addr" > ./tmp/last_node.list

if [[ -f ./tmp/selected.list ]] && [[ -f ./tmp/last_node.list ]];then

	sort ./tmp/selected.list ./tmp/last_node.list | uniq -d > ./tmp/need_update.list
	sort ./tmp/selected.list ./tmp/last_node.list ./tmp/selected.list | uniq -u > ./tmp/need_delete.list
	sort ./tmp/selected.list ./tmp/last_node.list ./tmp/last_node.list | uniq -u > ./tmp/need_insert.list

else

	echo -e "====`date`==ERROR== 【upload】 新节点清单不存在或数据库中节点清单无法查询，无法继续进行，任务失败，请人工检查。" >> ${log_file}
	exit 2000

fi

echo -e "==============================执行存量节点信息更新====================================="

for node_ip in `cat ./tmp/need_update.list`;do
	
	get_status ${node_ip}

	mysql ${mysql_conn_str} -e "update sh_selected_node set cpu_free=${cpu_free},data_free=${data_free},nvme_free=${nvme_free},memory_free=${memory_free},lastmodifytime=now() where node_ip_addr=\"${node_ip}\";"
	
	if [[ $? -ne 0 ]];then

		echo -e "====`date`==ERROR== 【upload】【update】节点 ${node_ip} 的数据更新失败，请人工检查。" > ${log_file}

	fi
done

rm -rf ./tmp/insert.tmp

for node_ip in `cat ./tmp/need_insert.list`;do

	get_status ${node_ip}
	echo -e "(\"${node_ip}\",${cpu_free},${data_free},${nvme_free},${memory_free},now(),now())," >> ./tmp/insert.tmp

done


echo -e "==============================写入合格的新节点====================================="

if [[ -s ./tmp/insert.tmp ]];then
	
	sed -i '$s/.$/;/' ./tmp/insert.tmp
	insert_values=`cat ./tmp/insert.tmp`
	mysql ${mysql_conn_str} -e "insert into sh_selected_node (node_ip_addr,cpu_free,data_free,nvme_free,memory_free,createtime,lastmodifytime) values ${insert_values}"

	if [[ $? -ne 0 ]];then

		echo -e "====`date`==ERROR== 【upload】【insert】节点数据插入失败，失败节点清单位于/tmp/insert.tmp，请人工检查。" >> ${log_file}

	fi

else

	echo -e "====`date`==INFO== 【upload】【insert】不存在需要增加的新节点。" >> ${log_file}

fi

echo -e "==============================排除不合格节点====================================="

if [[ -s ./tmp/need_delete.list ]];then

	all_need_delete_num=`cat ./tmp/need_delete.list | wc -l`

	if [[ ${all_need_delete_num} -gt ${max_exclued_per_every_exec} ]];then

		if [[ -s ./tmp/last_need_exclude_node.list ]];then
			
			echo -e "====`date`==WARNING== 【upload】连续2次运行排除的主机数量仍超过最大限制${max_exclued_per_every_exec}，触发告警。" >> ${log_file}
			assembly_message bundle warning "需要进行一次性排除的节点数量过多，超过${max_exclued_per_every_exec}台，请检查。" "一次性排除的节点数量连续2次过多。"
			fire_the_message
			exit 2011

		else
			
			cat ./tmp/need_delete.list > ./tmp/last_need_exclude_node.list
			echo -e "====`date`==WARNING== 【upload】一次性需要排除的主机过多，跳过本次排除，并备份当前清单。" >> ${log_file}
			exit 201

		fi

	fi

	cat ./tmp/need_delete.list | awk '{print "\""$0"\""}' | tr '\n' ',' |  sed '$s/.$//' > ./tmp/delete.tmp
	delete_node_list=`cat ./tmp/delete.tmp`
	mysql ${mysql_conn_str} -e "delete from sh_selected_node where node_ip_addr in (${delete_node_list});"

	if [[ $? -ne 0 ]];then
        	
		echo -e "====`date`==ERROR== 【upload】【delete】节点 ${delete_node_list} 的数据删除操作失败，请人工检查。" > ${log_file}

	else

		echo -e "==================================登记被排除的节点的统计信息======================================"
		exclude_deport ./tmp/need_delete.list

	fi

	if [[ -f ./tmp/last_need_exclude_node.list ]];then

		rm -rf ./tmp/last_need_exclude_node.list

	fi

else

	echo -e "====`date`==INFO== 【upload】【delete】不存在需要进行删除的节点。" >> ${log_file}

fi

echo -e "==============================添加黑名单，并从可选节点中驱逐或将节点移出黑名单====================================="

#将最近${update_day_range}天发生过驱逐，驱逐总数超过${max_exclude_total}，驱逐次数占比超过${max_exclude_rate}的节点加入黑名单

mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set add_to_blacklist =1,add_to_blacklist_date=now() where node_ip_addr in (select node_ip_addr from sh_deport_exclude_statistics where excluded_total > ${max_exclude_total} and exclude_rate > ${max_exclude_rate} and last_exclude_time > DATE_SUB(NOW(),INTERVAL ${update_day_range} DAY) and add_to_blacklist_date is null)"

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【upload】 将最近${update_day_range}天发生过驱逐，驱逐总数超过最大驱逐数量，驱逐次数占比超过5%的节点加入黑名单时执行sql发生异常，请检查。" >> ${log_file}

fi

#将${update_day_range}天前加入黑名单的节点从黑名单中移除

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_deport_exclude_statistics where add_to_blacklist = 1 and last_exclude_time <= DATE_SUB(NOW(),INTERVAL ${update_day_range} DAY)" > ./tmp/move_out_from_blacklist.tmp

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【upload】 获取${update_day_range}天前加入黑名单的节点清单时时，sql执行发生了异常，请检查。" >> ${log_file}

fi

mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set add_to_blacklist = 0,add_to_blacklist_date=null,last_remove_from_blacklist_date=now() where node_ip_addr in (select node_ip_addr from sh_deport_exclude_statistics where add_to_blacklist = 1 and last_exclude_time <= DATE_SUB(NOW(),INTERVAL ${update_day_range} DAY))"

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【upload】 ${update_day_range}天前加入黑名单的节点从黑名单中移除时，sql执行发生了异常，请检查。" >> ${log_file}
else

	if [[ -s ./tmp/move_out_from_blacklist.tmp ]];then

		move_out_from_blacklist=`cat ./tmp/move_out_from_blacklist.tmp | grep -v "node_ip_addr"`

		echo 

		#更新被加入黑名单的次数

		for ip_addr in `echo ${move_out_from_blacklist}`;do

			mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set add_to_blacklist_total = (select(add_to_blacklist_total + 1) from sh_deport_exclude_statistics where node_ip_addr=\"${ip_addr}\") where node_ip_addr = \"${ip_addr}\""

		done

	fi

fi



#将位于可选节点表中的已经被加入黑名单的节点驱逐

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where node_ip_addr in (select node_ip_addr from sh_deport_exclude_statistics where add_to_blacklist = 1)" > ./tmp/add_to_black_for_delete.list.tmp

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【upload】 获取需要驱逐的黑名单节点时，sql执行发生异常，无法驱逐。" >> ${log_file}

fi

cat ./tmp/add_to_black_for_delete.list.tmp | grep -v "node_ip_addr" > ./tmp/add_to_black_for_delete.list

exclude_deport ./tmp/add_to_black_for_delete.list

