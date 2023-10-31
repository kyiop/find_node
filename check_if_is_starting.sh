#!/bin/bash

source ./config.sh
source ./fire_alert.sh

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen = 1 and choosetime > DATE_SUB(NOW(),INTERVAL 1 HOUR)" > ./tmp/chosen_node_num_in_past_one_hour.tmp


if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【check_if_is_starting】 查询过去1小时内被选中节点总数时无法访问数据库，或访问数据库失败。" >> ${log_file}
        exit 405

fi

cat ./tmp/chosen_node_num_in_past_one_hour.tmp | grep -v "node_ip_addr" > ./tmp/chosen_node_num_in_past_one_hour.list


if [[ -s ./tmp/chosen_node_num_in_past_one_hour.list ]];then

	kubectl get pod --namespace idle-resource-utilization --kubeconfig=${k8s_configfile} | grep -v "NAME" > ./tmp/all_k8s_launched_pod_info.tmp

	if [[ $? -ne 0 ]];then

        	echo -e "====`date`==ERROR== 【check_if_is_starting】 查询已经全部节点上idle-resource-utilization命名空间的pod清单失败。" >> ${log_file}
	        exit 403

	fi

	cat ./tmp/all_k8s_launched_pod_info.tmp | awk '{print $1}' | awk -F "-" '{print $(NF-1)}' > ./tmp/all_k8s_launched_pod.list

	cat ./tmp/all_k8s_launched_pod_info.tmp | grep "Running" | awk '{print $1}' | awk -F "-" '{print $(NF-1)}' > ./tmp/node_is_already_running.list

	cat ./tmp/all_k8s_launched_pod_info.tmp | grep -v "Running" | awk '{print $1}' | awk -F "-" '{print $(NF-1)}' > ./tmp/node_is_perpare_to_start.list
	
	sort ./tmp/chosen_node_num_in_past_one_hour.list ./tmp/all_k8s_launched_pod.list ./tmp/all_k8s_launched_pod.list | uniq -u > ./tmp/node_have_not_launched.list
	sort ./tmp/chosen_node_num_in_past_one_hour.list ./tmp/node_is_perpare_to_start.list | uniq -d > ./tmp/node_is_now_preparing.list
	
	node_have_not_launched_list=`cat ./tmp/node_have_not_launched.list | tr '\n' ',' |  sed '$s/.$//'`
	node_is_now_preparing_list=`cat ./tmp/node_is_now_preparing.list | tr '\n' ',' |  sed '$s/.$//'`
	
	if_done=`cat ./tmp/if_done.tmp`

	if [[ -s ./tmp/node_is_now_preparing.list ]] || [[ -s ./tmp/node_have_not_launched.list ]];then

		assembly_message bundle warning "过去1小时内新增节点${node_is_now_preparing_list}正在启动中,${node_have_not_launched_list}暂未启动。" "节点正在启动中。"
		fire_the_message
	
	else

		sort ./tmp/chosen_node_num_in_past_one_hour.list ./tmp/node_is_already_running.list | uniq -d > ./tmp/node_is_already_running_properly.list
		node_is_already_running_properly_list=`cat ./tmp/node_is_already_running_properly.list | tr '\n' ',' |  sed '$s/.$//'`
		assembly_message bundle info "过去1小时内新增节点${node_is_already_running_properly_list}启动成功。" "节点启动成功。"
		fire_the_message
	
	fi

else

	echo -e "====`date`==INFO== 【check_if_is_starting】 过去1小时内没有新增的被选中节点。" >> ${log_file}
	echo "none" > ./tmp/if_done.tmp

fi


