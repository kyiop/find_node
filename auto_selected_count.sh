#!/bin/bash

echo -e "========================================开始计算弹性节点数量==============================================="
source ./fire_alert.sh

log_file=select_nodes.log

#可选节点的数量限制

selected_limit=50
min_selected_num=8

#可选节点数量变更生效的最低振幅
amplitude=3

#可选节点数量变更的平均值计算范围，次数越多时间范围越长
amplitude_compute_range=24

#解包任务的预计处理时长，单位分
hibag_job_exec_time=60

#期望的全量任务完成时长，单位分
hibag_job_finish_in=720

#hibag数据库连接信息
mysql_host_hibag=sdfjskdjfklsdf
mysql_port_hibag=13
database_hibag=hibag
mysqluser_hibag=user

mysql_conn_str_hibag="--defaults-extra-file=./connect_hibag.mysql -h${mysql_host_hibag} -P${mysql_port_hibag} -D${database_hibag} -u${mysqluser_hibag}"


#idle-resource-utilization数据库连接信息

mysql_host=ashdjkashdkjasdhkjashd
mysql_port=2883
database=bundle
mysqluser=bundle

mysql_conn_str="--defaults-extra-file=./connect.mysql -h${mysql_host} -P${mysql_port} -D${database} -u${mysqluser}"

#获取待执行的解包任务总数
mysql ${mysql_conn_str_hibag} -e "SELECT count(*) as total_jobs FROM data_jobs where job_status = 10 and next_time <= now() and job_type = \"BagExtract\"" > ./tmp/job_need_exec_sql.tmp

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【auto_selected_count】 数据库中待解包任务总数获取失败，无法继续进行。" >> ${log_file}
        exit 901

fi

job_need_exec_total=`cat ./tmp/job_need_exec_sql.tmp | grep -v "total_jobs"`

echo "========================================当前待处理任务数量为${job_need_exec_total}==============================================="

#限制平滑取点数量不超过36个点，最小任务完成时长不小于360分钟

if [[ ${amplitude_compute_range} -gt 36 ]];then

        amplitude_compute_range=36

        echo -e "====`date`==WARNING== 【auto_selected_count】设定的用于平滑节点扩缩容的取点数量超限，最大值为36，将自动使用最大值。" >> ${log_file}

fi

if [[ ${hibag_job_finish_in} -lt 360 ]];then

        hibag_job_finish_in=360

        echo -e "====`date`==WARNING== 【auto_selected_count】设定的判定任务完成周期的最小时间单位过低，将自动使用默认值360。" >> ${log_file}

fi

#计算任务完成的最小时长

amplitude_compute_range_time=`expr ${amplitude_compute_range} \* 5`

if [[ `expr ${hibag_job_finish_in} / 2` -ge ${amplitude_compute_range_time} ]];then

        at_least_hibag_job_finish_in=`expr ${hibag_job_finish_in} - ${amplitude_compute_range_time}`

else

        at_least_hibag_job_finish_in=`expr ${hibag_job_finish_in} / 2`

fi

#计算解包任务预计总耗时以及${hibag_job_finish_in}设置下最小节点数量

total_cost_time_hibag=`echo "scale=0;${job_need_exec_total} * ${hibag_job_exec_time}" | bc`

at_least_selected_num=`expr ${total_cost_time_hibag} / ${at_least_hibag_job_finish_in} / 24 + 1`

echo -e "=============================获取满足特定时间内完成的最小节点数量的计算过程  expr ${total_cost_time_hibag} / ${at_least_hibag_job_finish_in} / 24 + 1 ，计算结果为${at_least_selected_num}=================================="

#获取当前已选中的节点数量

mysql ${mysql_conn_str} -e "select count(*) as t from sh_selected_node where is_chosen = 1" > ./tmp/hibag_last_selected_sql.tmp

if [[ $? -ne 0 ]];then

        echo -e "====`date`==ERROR== 【auto_selected_count】 上一次节点选择数量获取失败，无法继续进行。" >> ${log_file}
        exit 902

fi

hibag_last_selected_count=`cat ./tmp/hibag_last_selected_sql.tmp | grep -v t`

echo -e "=============================当前数据库中已选的节点数量为${hibag_last_selected_count}===================================="

#截取最后${amplitude_compute_range}个数据点，并计算其平均值
tail -n ${amplitude_compute_range} ./tmp/max_selected_num.tmp > ./tmp/used_to_compute.tmp

#echo -e "================================本次生成的过去24个取点数据文件内容如下：`cat ./tmp/used_to_compute.tmp`======================================="

total_s=0

for before in `cat ./tmp/used_to_compute.tmp`;do

	total_s=`expr ${total_s} + ${before}`

done

total_times_count=`cat ./tmp/used_to_compute.tmp | wc -l`

avg_selected_num=`expr ${total_s} / ${total_times_count}`

echo -e "==============================获取应选节点平均值的计算过程为  expr ${total_s} / ${total_times_count},结果为${avg_selected_num}================================="
echo -e "============================根据./tmp/used_to_compute.tmp 文件计算的平均取点值为${avg_selected_num}===================================="


#计算最后${amplitude_compute_range}个数据点的平均值与实际已选点数量的绝对值
the_gap=`expr ${avg_selected_num} - ${hibag_last_selected_count}`

final_gap=`echo ${the_gap} | awk '{print sqrt($1*$1)}'`

#判断是否扩缩容，根据振幅决定是否执行

if [[ ${final_gap} -ge ${amplitude} ]];then

	max_selected_num=${avg_selected_num}

else

        #当前振幅不够大，不进行扩缩容。

        max_selected_num=${hibag_last_selected_count}

fi

#控制可选节点值不溢出上下边界

if [[ ${min_selected_num} -gt ${max_selected_num} ]];then

        max_selected_num=${min_selected_num}

fi

if [[ ${max_selected_num} -gt ${selected_limit} ]];then

	assembly_message bundle auto_selected_warning "需要选择的节点数量为${max_selected_num},超过最大选点上限${selected_limit}。" "节点需求量超限"
	fire_the_message
	max_selected_num=${selected_limit}

fi


#将每次计算结果写入临时文件，用于均值计算
echo ${at_least_selected_num} >> ./tmp/max_selected_num.tmp

echo -e "========================================弹性节点数量计算完成，结果为${max_selected_num}==============================================="
