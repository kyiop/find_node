#!/bin/bash

echo -e "===================================初始化参数======================================"

source ./config.sh

function get_value(){

	the_ip_addr=$1
	
	if [[ -f $2 ]];then

		the_result=`cat $2  | sed 's/:59100//g' |jq .[] | jq -r --arg node ${the_ip_addr} 'if .metric.instance == $node then .value[1] else empty end'`
		
	else

		echo -e "====`date`==ERROR== 【modify_chosen】 $2 文件不存在，任务失败，请人工检查。" >> ${log_file}
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

	cpu_free=$(get_value ${ip_to_send} ./tmp/get_cpu_free_rate_result_chosen.json)
	data_free=$(get_value ${ip_to_send} ./tmp/get_data_disk_free_space_result_chosen.json)
	nvme_free=$(get_value ${ip_to_send} ./tmp/get_nvme_disk_free_space_result_chosen.json)
	memory_free=$(get_value ${ip_to_send} ./tmp/get_free_memory_result_chosen.json)

}


function record_deport(){
	
        deported_node_list=`cat $1`

        for deport_node in `echo ${deported_node_list}`;do

                is_in_database=`mysql ${mysql_conn_str} -e "select node_ip_addr from sh_deport_exclude_statistics where node_ip_addr = '${deport_node}'"`
		
                if [[ $? -ne 0 ]];then

                        echo -e "====`date`==ERROR== 【modify_chosen】判断被排除的节点${deport_node}在数据库中是否有记录时，sql执行失败，跳过该节点。 "
                        continue

                fi	
		
		if [[ -n ${is_in_database} ]];then

                        total_deport_count=`mysql ${mysql_conn_str} -e "select deported_total from sh_deport_exclude_statistics where node_ip_addr = '${deport_node}'" | grep -v "deported_total"`

                        if [[ $? -ne 0 ]];then

                                echo -e "====`date`==ERROR== 【modify_chosen】 获取被驱逐的节点${deport_node}的排除次数失败。" >> ${log_file}

                        fi

			
                        if [[ ${total_deport_count} -eq 0 ]];then
							                                
	                        extra_deport_field_info="first_deport_time = now(),"
											                        
                        fi

                        total_deport_count=`expr ${total_deport_count} + 1`

                        mysql ${mysql_conn_str} -e "update sh_deport_exclude_statistics set deported_total = ${total_deport_count},${extra_deport_field_info}last_deport_time = now() where node_ip_addr = '${deport_node}'"

                        if [[ $? -ne 0 ]];then

                                echo -e "====`date`==ERROR== 【modify_chosen】 更新节点${deport_node}的被驱逐次数失败。" >> ${log_file}

                        fi

                else

                        mysql ${mysql_conn_str} -e "insert into sh_deport_exclude_statistics (node_ip_addr,deported_total,first_deport_time,last_deport_time) values (\"${deport_node}\",1,now(),now())"


                        if [[ $? -ne 0 ]];then

                                echo -e "====`date`==ERROR== 【modify_chosen】 写入被驱逐的节点${deport_node}的被驱逐次数失败。" >> ${log_file}

                        fi

                fi

        done
}

echo -e "===================================获取当前数据库中已选节点，并分析需要进行的操作======================================"

> ./tmp/last_node_chosen.list

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen = 1" > ./tmp/last_node_chosen.list.tmp

if [[ $? -ne 0 ]];then
	
	echo -e "====`date`==ERROR== 【modify_chosen】 数据库中已有可用节点数据获取失败，无法继续进行。" >> ${log_file}
	exit 202

fi

cat ./tmp/last_node_chosen.list.tmp | grep -v "node_ip_addr" > ./tmp/last_node_chosen.list

if [[ -f ./tmp/chosen_selected.list ]] && [[ -f ./tmp/last_node_chosen.list ]];then

	sort ./tmp/chosen_selected.list ./tmp/last_node_chosen.list | uniq -d > ./tmp/need_update_chosen.list
	sort ./tmp/chosen_selected.list ./tmp/last_node_chosen.list ./tmp/chosen_selected.list | uniq -u > ./tmp/need_delete_chosen.list

else

	echo -e "====`date`==ERROR== 【modify_chosen】 当前已选中的节点清单不存在或数据库中的已选中节点清单无法查询，无法继续进行，任务失败，请人工检查。" >> ${log_file}
	exit 2000

fi


echo -e "===================================更新已选节点的监控信息======================================"

for node_ip in `cat ./tmp/need_update_chosen.list`;do
	
	get_status ${node_ip}

	mysql ${mysql_conn_str} -e "update sh_selected_node set cpu_free=${cpu_free},data_free=${data_free},nvme_free=${nvme_free},memory_free=${memory_free},lastmodifytime=now() where node_ip_addr=\"${node_ip}\";"
	
	if [[ $? -ne 0 ]];then

		echo -e "====`date`==ERROR== 【modify_chosen】【update】节点 ${node_ip} 的数据更新失败，请人工检查。" > ${log_file}

	fi
done

echo -e "===================================驱逐不符合要求的已选节点======================================"

if [[ -s ./tmp/need_delete_chosen.list ]];then

	cat ./tmp/need_delete_chosen.list | awk '{print "\""$0"\""}' | tr '\n' ',' |  sed '$s/.$//' > ./tmp/delete_chosen.tmp
	delete_node_list=`cat ./tmp/delete_chosen.tmp`
	mysql ${mysql_conn_str} -e "delete from sh_selected_node where node_ip_addr in (${delete_node_list});"

	if [[ $? -ne 0 ]];then
        	
		echo -e "====`date`==ERROR== 【modify_chosen】【delete】节点 ${delete_node_list} 的数据删除操作失败，请人工检查。" > ${log_file}

	else

		echo -e "==================================登记被驱逐的节点的统计信息======================================"
		record_deport ./tmp/need_delete_chosen.list

	fi

else

	echo -e "====`date`==INFO== 【modify_chosen】【delete】不存在需要进行删除的节点。" >> ${log_file}

fi




