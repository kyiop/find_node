#!/bin/bash

tmp_file="message.msg"

default_alert_server_api="http://alertasdasd/api/v1/alerts"
#拼接告警信息
function assembly_message()
{

	cat > ${tmp_file} << EOF
[
	{
	    "labels": {
	       "alertname": "scriptsalert",
	       "instance": "$1",
	       "severity": "$2",
	       "job": "bundle"
	    },
	    "annotations": {
	       "description": "$3",
	       "summary": "$4"
	    }
	}
]
EOF

}
#如果tmp_file文件存在就触发告警
function fire_the_message()
{
	if [[ -z $1 ]]; then
		alert_server_api=${default_alert_server_api}
	else
		alert_server_api=$1
	fi
	if [[ -f ${tmp_file} ]]; then
		alert_message=`cat ${tmp_file}`
		echo -n "[info][`date`]: 告警信息返回状态："
		curl -XPOST -d"${alert_message}" ${alert_server_api}
		echo -e
		rm -rfv ${tmp_file} > /dev/null
	else
		echo -e "方法${FUNCNAME[0]} 需要提供${tmp_file}才能生效。"
		return 1001
	fi

}


#	assembly_message bag_checker warning "${today} Bag包检查未发现数据不一致。" "Bag包检查程序未发现异常。"
#	fire_the_message
