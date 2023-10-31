#!/bin/bash

#program init

echo -e "===================================初始化参数======================================"

source ./config.sh

# 获取已经被选中的节点清单

if [[ -f ./tmp/is_now_running_node.tmp ]];then

        is_running_node=`cat ./tmp/is_now_running_node.tmp | grep -v "node_ip_addr" | sed 's/$/&:59100|/g' | tr -d '\n' | sed '$s/.$//'`

else

        echo -e "====`date`==ERROR==,已被选中的节点清单不存在，无法正常进行。"
        exit 109

fi

#拼装的prom_SQL只包含已经被选中的节点

sql_get_cpu_free_rate="avg%28rate%28node_cpu_seconds_total%7Bisvke%3D%22training%22%2Cmode%3D%22idle%22%2Cinstance%3D%7E%22${is_running_node}%22%7D%5B1h%5D%29%29+by+%28instance%29+%3E+${chosen_cpu_free_limit}"
sql_get_data_disk_free_space="sum%28node_filesystem_avail_bytes%7Bdevice%3D%22%2Fdev%2Fvdb%22%2Cisvke%3D%22training%22%2Cmountpoint%3D%22%2Fmnt%2Fvdb%22%7D%29+by+%28instance%29%2F1000%2F1000%2F1000+%3E+${chosen_data_disk_need}"
sql_get_nvme_disk_free_space="sum%28node_filesystem_avail_bytes%7Bdevice%3D%7E%22%2Fdev%2Fnvme0n1.*%22%2Cisvke%3D%22training%22%2Cmountpoint%3D%22%2Fmnt%2Fnvme0n1%22%7D%29+by+%28instance%29%2F1000%2F1000%2F1000+%3E+${chosen_nvme_disk_need}"
sql_get_free_memory="sum%28node_memory_MemAvailable_bytes%7Bisvke%3D%22training%22%7D%29+by+%28instance%29%2F1000%2F1000%2F1000+%3E+${chosen_memory_need}"

this_suffix_chosen=`echo "${RANDOM}_chosen" |md5sum | awk '{print $1}'`

function clean_tmp(){

	if [[ -f ./tmp/this_suffix_chosen ]];then

		last_suffix_chosen=`cat ./tmp/this_suffix_chosen`

	fi

	echo ${this_suffix_chosen} > ./tmp/this_suffix_chosen

	if [[ -n ${last_suffix_chosen} ]];then

		for tmp_file in `ls ./tmp/ | grep ${last_suffix_chosen}`;do
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

				echo -e "====`date`==INFO==【chosen_selecter】,$3 prometheus查询结果返回正常。" >> ${log_file}
				echo ${tmp_results} | jq .data | jq .result > ./tmp/$3.json

			else

				echo -e "====`date`==ERROR==【chosen_selecter】,$3 prometheus查询结果返回了error信息，无法继续进行后续流程。信息如下：${tmp_results}" >> ${log_file}
				exit 101

			fi

		else

			echo -e "====`date`==ERROR==【chosen_selecter】,$3 prometheus查询结果返回的结果为空值，无法继续进行后续流程。" >> ${log_file}
			exit 102

		fi

	else

		echo -e "====`date`==ERROR==【chosen_selecter】,$3 调用的curl命令执行失败，无法完成接口查询。" >> ${log_file}
		exit 103

	fi

}

function make_node_list(){

	if [[ -f $1 ]];then

		cat $1 | jq .[] | jq -r .metric.instance | awk -F ":" '{print $1}' > $2

		if [[ $? -ne 0 ]];then

			echo -e "====`date`==ERROR==【chosen_selecter】,$2 文件生成失败，无法正常进行。" >> ${log_file}
			exit 104

		fi

	else

		echo -e "====`date`==ERROR==【chosen_selecter】,$1 文件未找到，无法正常进行。" >> ${log_file}
		exit 106

	fi

}


echo -e "===================================从Prometheus获取已选择节点的监控指标======================================"

get_results 180 ${sql_get_cpu_free_rate} get_cpu_free_rate_result_chosen
get_results 180 ${sql_get_data_disk_free_space} get_data_disk_free_space_result_chosen
get_results 180 ${sql_get_nvme_disk_free_space} get_nvme_disk_free_space_result_chosen
get_results 180 ${sql_get_free_memory} get_free_memory_result_chosen


echo -e "==================================分析Prometheus获取的指标并生成各符合单独指标要求的已选泽节点的清单======================================"

kubectl get node --kubeconfig=./${k8s_configfile} | grep Ready | awk '{print $1}' > ./tmp/k8s_ready.node_${this_suffix_chosen}

if [[ $? -ne 0 ]];then

	echo -e "====`date`==ERROR==【chosen_selecter】,k8s ready node 获取失败，无法正常进行。" >> ${log_file}
	exit 105

fi

make_node_list ./tmp/get_cpu_free_rate_result_chosen.json ./tmp/cpu_free.node_${this_suffix_chosen}
make_node_list ./tmp/get_data_disk_free_space_result_chosen.json ./tmp/data_disk_free_space.node_${this_suffix_chosen}
make_node_list ./tmp/get_nvme_disk_free_space_result_chosen.json ./tmp/nvme_disk_free_space.node_${this_suffix_chosen}
make_node_list ./tmp/get_free_memory_result_chosen.json ./tmp/free_memory.node_${this_suffix_chosen}


echo -e "===================================开始生成符合各指标的已选择的节点的主机清单的交集======================================"

total_this_time_tmp=`ls ./tmp/ | grep ${this_suffix_chosen} | wc -l`

if [[ ${total_this_time_tmp} -eq 5 ]];then

	sort ./tmp/cpu_free.node_${this_suffix_chosen} ./tmp/free_memory.node_${this_suffix_chosen} | uniq -d > ./tmp/step1.node_${this_suffix_chosen}
	cat ./tmp/data_disk_free_space.node_${this_suffix_chosen} ./tmp/nvme_disk_free_space.node_${this_suffix_chosen} | sort | uniq > ./tmp/step2.node_${this_suffix_chosen}
	sort ./tmp/step1.node_${this_suffix_chosen} ./tmp/step2.node_${this_suffix_chosen} | uniq -d > ./tmp/step3.node_${this_suffix_chosen}
	sort ./tmp/k8s_ready.node_${this_suffix_chosen} ./tmp/step3.node_${this_suffix_chosen} | uniq -d > ./tmp/chosen_selected.list

else

	echo -e "====`date`==ERROR==【chosen_selecter】,本次集合文件不完整，需要进行检查，无法正常进行。文件清单如下：`ls ./tmp/ | grep ${this_suffix_chosen}`" >> ${log_file}
	clean_tmp
	exit 107

fi

clean_tmp

