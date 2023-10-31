#!/bin/bash

#program init

function log_head(){
	
	echo -e >> $1
	echo -e >> $1
        echo -e "+--------------------------------------------+" >> $1
        echo -e "|         Select node is new staring!        |" >> $1 
        echo -e "|            `date +"%Y/%m/%d %H:%M:%S"`             |" >> $1
        echo -e "+--------------------------------------------+" >> $1
	echo -e >> $1
	echo -e >> $1

}

source ./config.sh

log_head ${log_file}
log_head ./select_running.log


rclone version > /dev/null

if [[ $? -ne 0 ]];then

	echo -e "依赖的rclone程序不存在或有运行故障，无法继续执行。"
	exit

fi

mysql -V > /dev/null

if [[ $? -ne 0 ]];then

        echo -e "依赖的mysql客户端不存在或有运行故障，无法继续执行。"
        exit

fi


kubectl > /dev/null

if [[ $? -ne 0 ]];then

        echo -e "依赖的kubectl程序不存在或有运行故障，无法继续执行。"
        exit

fi

if [[ -s ./select_node.pid ]];then

	echo -e "当前已有进程运行，进程PID为`cat ./select_node.pid`，跳过执行。"
	exit 10000

fi

echo "$$" > ./select_node.pid

echo -e
echo -e "get_nodes is running"
echo -e

./get_nodes.sh

if [[ $? -eq 0 ]];then
	echo -e
	echo -e "get_nodes.sh 成功执行。"
else
	echo -e
	echo -e "get_nodes.sh 执行异常。"
	rm -f ./select_node.pid
	exit
fi

echo -e
echo -e "upload.sh is running"
echo -e

sleep 1

./upload.sh

if [[ $? -eq 0 ]];then
	echo -e
	echo -e "upload.sh 成功执行。"
else
	echo -e
	echo -e "upload.sh 执行异常。"
	rm -f ./select_node.pid
	exit
fi

echo -e
echo -e "check_chosen is running"
echo -e

sleep 1

./check_chosen.sh

if [[ $? -eq 0 ]];then
	echo -e
	echo -e "check_chosen.sh 成功执行。"
else
	echo -e
	echo -e "check_chosen.sh 执行异常。"
	rm -f ./select_node.pid
	exit
fi
echo -e
echo -e "modify_chosen is running"
echo -e

sleep 1

./modify_chosen.sh

if [[ $? -eq 0 ]];then
	echo -e
	echo -e "modify_chosen.sh 成功执行。"
else
	echo -e
	echo -e "modify_chosen.sh 执行异常。"
	rm -f ./select_node.pid
	exit
fi
echo -e
echo -e "do_select.sh is running"
echo -e

sleep 1

./do_select.sh

if [[ $? -eq 0 ]];then
	echo -e
	echo -e "do_select.sh 成功执行。"
else
	echo -e
	echo -e "do_select.sh 执行异常。"
	rm -f ./select_node.pid
	exit
fi
echo -e

./check_if_is_running.sh
./check_if_is_starting.sh

rm -f ./select_node.pid
