#!/bin/bash

#program init

echo -e "===================================初始化参数======================================"

source ./config.sh
source ./fire_alert.sh

# 查询已经被选中的节点清单

mysql ${mysql_conn_str} -e "select node_ip_addr from sh_selected_node where is_chosen=1;" > ./tmp/is_now_running_node.tmp

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR==,已被选中的节点无法查询，无法正常进行。" >> ${log_file}
        exit 108

fi

if [[ -f ./tmp/is_now_running_node.tmp ]];then

	is_running_node=`cat ./tmp/is_now_running_node.tmp | grep -v "node_ip_addr" | sed 's/$/&:59100|/g' | tr -d '\n' | sed '$s/.$//'`

else

	echo -e "====`date`==ERROR==,已被选中的节点清单不存在，无法正常进行。"
	exit 109

fi

#拼装的prom_SQL排除已经被选中的节点，被选中的节点单独处理

sql_get_cpu_free_rate="avg%28rate%28node_cpu_seconds_total%7Bisvke%3D%22training%22%2Cmode%3D%22idle%22%2Cinstance%21%7E%22${is_running_node}%22%7D%5B1h%5D%29%29+by+%28instance%29+%3E+${cpu_free_limit}"
sql_get_cpu_core_number="count%28node_cpu_seconds_total%7Bisvke%3D%22training%22%2Cmode%3D%22idle%22%7D%29+by+%28instance%29+%3E+${cpu_core_need}"
sql_get_data_disk_free_space="sum%28node_filesystem_avail_bytes%7Bdevice%3D%22%2Fdev%2Fvdb%22%2Cisvke%3D%22training%22%2Cmountpoint%3D%22%2Fmnt%2Fvdb%22%7D%29+by+%28instance%29%2F1000%2F1000%2F1000+%3E+${data_disk_need}"
sql_get_nvme_disk_free_space="sum%28node_filesystem_avail_bytes%7Bdevice%3D%7E%22%2Fdev%2Fnvme0n1.*%22%2Cisvke%3D%22training%22%2Cmountpoint%3D%22%2Fmnt%2Fnvme0n1%22%7D%29+by+%28instance%29%2F1000%2F1000%2F1000+%3E+${nvme_disk_need}"
sql_get_free_memory="sum%28node_memory_MemAvailable_bytes%7Bisvke%3D%22training%22%7D%29+by+%28instance%29%2F1000%2F1000%2F1000+%3E+${memory_need}"



this_suffix=`echo $RANDOM |md5sum | awk '{print $1}'`

function clean_tmp(){

	if [[ -f ./tmp/this_suffix ]];then

		last_suffix=`cat ./tmp/this_suffix`

	fi

	echo ${this_suffix} > ./tmp/this_suffix

	if [[ -n ${last_suffix} ]];then

		for tmp_file in `ls ./tmp/ | grep ${last_suffix}`;do
		
			rm -f ./tmp/${tmp_file}
		
		done

	fi

}


if [[ ! -d ./tmp ]];then

	mkdir -p ./tmp/

fi

function get_results(){

	tmp_results=`curl -s -m $1 ${prometheus_api}?query=$2`

	if [[ $? -eq 0 ]];then

		if [[ -n ${tmp_results} ]];then

			if [[ `echo ${tmp_results} | jq -r .status` == "success" ]];then

				echo -e "====`date`==INFO==,$3 prometheus查询结果返回正常。" >> ${log_file}
				echo ${tmp_results} | jq .data | jq .result > ./tmp/$3.json

			else

				echo -e "====`date`==ERROR==,$3 prometheus查询结果返回了error信息，无法继续进行后续流程。信息如下：${tmp_results}" >> ${log_file}
				exit 101

			fi

		else

			echo -e "====`date`==ERROR==,$3 prometheus查询结果返回的结果为空值，无法继续进行后续流程。" >> ${log_file}
			exit 102

		fi

	else

		echo -e "====`date`==ERROR==,$3 调用的curl命令执行失败，无法完成接口查询。" >> ${log_file}
		exit 103

	fi

	if [[ $3 == "get_cpu_free_rate_result" ]];then
	
		all_ready_node_count=`kubectl get node --kubeconfig=./${k8s_configfile} | grep Ready | wc -l`
		not_running_prometheus_get_result_count=`echo ${tmp_results} | jq .data | jq .result | jq .[] | jq .metric | jq .instance | wc -l `
		is_now_running_node_count=`cat ./tmp/is_now_running_node.tmp | grep -v "node_ip_addr" | wc -l`

		prometheus_get_result_percent=`echo "scale=2;( ${not_running_prometheus_get_result_count} + ${is_now_running_node_count} ) / ${all_ready_node_count}" | bc`

		if [[ `echo "${prometheus_get_result_percent} > 0.3" | bc` -ne 1 ]];then

			assembly_message bundle error "Prometheus未能提供超过30%集群节点的监控数据，无法执行选点逻辑，程序将中止执行，需要立即检查。可能由于Prometheus故障或集群太忙无法提供满足要求的节点。" "获取监控数据异常。"
			fire_the_message
			exit 110
		
		fi

	fi

}

function make_node_list(){

	if [[ -f $1 ]];then

		cat $1 | jq .[] | jq -r .metric.instance | awk -F ":" '{print $1}' > $2

		if [[ $? -ne 0 ]];then

			echo -e "====`date`==ERROR==,$2 文件生成失败，无法正常进行。" >> ${log_file}
			exit 104

		fi

	else

		echo -e "====`date`==ERROR==,$1 文件未找到，无法正常进行。" >> ${log_file}
		exit 106

	fi

}


echo -e "===================================从Prometheus获取监控指标======================================"

get_results 180 ${sql_get_cpu_free_rate} get_cpu_free_rate_result
get_results 180 ${sql_get_cpu_core_number} get_cpu_core_number_result
get_results 180 ${sql_get_data_disk_free_space} get_data_disk_free_space_result
get_results 180 ${sql_get_nvme_disk_free_space} get_nvme_disk_free_space_result
get_results 180 ${sql_get_free_memory} get_free_memory_result


echo -e "==================================分析Prometheus获取的指标并生成除已选中节点外的各符合单独指标要求的节点清单======================================"

kubectl get node --kubeconfig=./${k8s_configfile} | grep Ready | awk '{print $1}' > ./tmp/k8s_ready.node_${this_suffix}

if [[ $? -ne 0 ]];then

	echo -e "====`date`==ERROR==,k8s ready node 获取失败，无法正常进行。" >> ${log_file}
	exit 105

fi

make_node_list ./tmp/get_cpu_free_rate_result.json ./tmp/cpu_free.node_${this_suffix}
make_node_list ./tmp/get_cpu_core_number_result.json ./tmp/cpu_core_number.node_${this_suffix}
make_node_list ./tmp/get_data_disk_free_space_result.json ./tmp/data_disk_free_space.node_${this_suffix}
make_node_list ./tmp/get_nvme_disk_free_space_result.json ./tmp/nvme_disk_free_space.node_${this_suffix}
make_node_list ./tmp/get_free_memory_result.json ./tmp/free_memory.node_${this_suffix}

#mysql ${mysql_conn_str} -e "SELECT node_ip_addr FROM sh_deport_exclude_statistics where add_to_blacklist = 1" | grep -v "node_ip_addr" > ./tmp/black_list.node_${this_suffix}

echo -e "===================================开始生成符合各指标的非已转中节点的主机清单的交集======================================"

total_this_time_tmp=`ls ./tmp/ | grep ${this_suffix} | wc -l`

if [[ ${total_this_time_tmp} -eq 6 ]];then
#if [[ ${total_this_time_tmp} -eq 7 ]];then

	sort ./tmp/cpu_free.node_${this_suffix} ./tmp/cpu_core_number.node_${this_suffix} | uniq -d > ./tmp/step1.node_${this_suffix}
	cat ./tmp/data_disk_free_space.node_${this_suffix} ./tmp/nvme_disk_free_space.node_${this_suffix} | sort | uniq > ./tmp/step2.node_${this_suffix}
	sort ./tmp/step1.node_${this_suffix} ./tmp/step2.node_${this_suffix} | uniq -d > ./tmp/step3.node_${this_suffix}
	sort ./tmp/k8s_ready.node_${this_suffix} ./tmp/free_memory.node_${this_suffix} | uniq -d > ./tmp/step4.node_${this_suffix}
#	sort ./tmp/step3.node_${this_suffix} ./tmp/step4.node_${this_suffix} | uniq -d > ./tmp/selected.list_${this_suffix}
	sort ./tmp/step3.node_${this_suffix} ./tmp/step4.node_${this_suffix} | uniq -d > ./tmp/selected.list
#	sort ./tmp/black_list.node_${this_suffix} ./tmp/selected.list_${this_suffix} ./tmp/black_list.node_${this_suffix} | uniq -u > ./tmp/selected.list

else

	echo -e "====`date`==ERROR==,本次集合文件不完整，需要进行检查，无法正常进行。文件清单如下：`ls ./tmp/ | grep ${this_suffix}`" >> ${log_file}
	clean_tmp
	exit 107

fi

clean_tmp


