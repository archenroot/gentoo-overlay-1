#!/sbin/runscript
# Copyright 1999-2013 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
#
# Tomcat runscript template
#
# USAGE:
# Use it directly or source from the top of your runscript and override what
# you want. If you define your start() function then you should call init_vars
# before start-stop-daemon!
#

extra_commands="forcestop"

: ${LONG_NAME:="${RC_SVCNAME}"}
: ${PIDFILE:=/run/${RC_SVCNAME}.pid}


##########  Helper functions  ##########

init_defaults() {
	: ${tomcat_slot:=7}

	: ${catalina_home:=/usr/share/tomcat-${tomcat_slot}}
	: ${catalina_config:=${catalina_home}/conf/catalina.properties}
	: ${catalina_policy:=${catalina_home}/conf/catalina.policy}
	: ${tomcat_user:=tomcat}

	: ${tomcat_logging_conf:=${catalina_base}/conf/logging.properties}
	: ${tomcat_start:=start}

	: ${jpda_transport:=dt_socket}
	: ${jpda_address:=8000}
	: ${jpda_opts="-Xdebug -Xrunjdwp:transport=${jpda_transport},address=${jpda_address},server=y,suspend=n"}

	: ${jmx_ssl:=enable}
	: ${java_opts:=-XX:+UseConcMarkSweepGC}
}

init_env() {
	export JAVA_HOME=`java-config ${tomcat_jvm:+--select-vm ${tomcat_jvm}} --jre-home`

	if [ "${tomcat_logging}" = 'log4j' ]; then
		tomcat_extra_jars+="${tomcat_extra_jars:+,}log4j"
	fi
	CLASSPATH=`java-config --classpath tomcat-${tomcat_slot}${tomcat_extra_jars:+,${tomcat_extra_jars}}`
	CLASSPATH+="${tomcat_extra_classpath:+:${tomcat_extra_classpath}}"
	export CLASSPATH
}

init_command_args() {
	command=${JAVA_HOME}/bin/java

	if [ "${tomcat_start}" = "debug" ] || [ "${tomcat_start}" = "-security debug" ] ; then
		command=${JAVA_HOME}/bin/jdb
		java_opts+=" -sourcepath ${CATALINA_HOME}/../../jakarta-tomcat-catalina/catalina/src/share"
	fi
	if [ "${tomcat_start}" = "-security debug" ] || [ "${tomcat_start}" = "-security start" ]; then
		java_opts+=" -Djava.security.manager"
		java_opts+=" -Djava.security.policy=${catalina_policy}"
	fi
	if [ "${tomcat_start}" = "jpda start" ] ; then
		java_opts+=" ${jpda_opts}"
	fi

	if [ "${tomcat_logging}" = 'log4j' ]; then
		java_opts+=" -Dlog4j.configuration=file://${tomcat_logging_conf}"
	else
		java_opts+=" -Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager \
			-Djava.util.logging.config.file=${tomcat_logging_conf}"
	fi

	if [ -r "${catalina_config}" ]; then
		java_opts+=" -Dcatalina.config=${catalina_config}"
	fi
	if [ -r "${catalina_webxml}" ]; then
		java_opts+=" -Dcatalina.webxml.default=${catalina_webxml}"
	fi
	if [ "${jmx_ssl}" = "disable" ]; then
		java_opts+=" -Dcom.sun.management.jmxremote.ssl=false"
	fi
	if [ -r "${jmx_passwd_file}" ]; then
		java_opts+=" -Dcom.sun.management.jmxremote.password.file=${jmx_passwd_file}"
	fi
	if [ -r "${jmx_access_file}" ]; then
		java_opts+=" -Dcom.sun.management.jmxremote.access.file=${jmx_access_file}"
	fi
	if [ -n "${rmi_hostname}" ]; then
		java_opts+=" -Djava.rmi.server.hostname=${rmi_hostname}"
	fi

	# JVM memory parameters
	java_opts+="
		${java_min_heap_size:+ -Xms${java_min_heap_size}M}
		${java_max_heap_size:+ -Xmx${java_max_heap_size}M}
		${java_min_perm_size:+ -XX:PermSize=${java_min_perm_size}m}
		${java_max_perm_size:+ -XX:MaxPermSize=${java_max_perm_size}m}
		${java_min_new_size:+ -XX:NewSize=${java_min_new_size}m}
		${java_max_new_size:+ -XX:MaxNewSize=${java_max_new_size}m}"

	# Tomcat base parameters
	java_opts+=" 
		-Dcatalina.base=${catalina_base}
		-Dcatalina.home=${catalina_home}
		-Djava.io.tmpdir=${catalina_temp}"


	# Complete list of arguments for startup script
	command_args="
		-server
		${java_opts}
		-classpath ${CLASSPATH}
		org.apache.catalina.startup.Bootstrap
		${catalina_opts}
		${tomcat_start}"
}

check_paths() {
	if [ ! -d "${catalina_home}" ]; then
		eerror '$catalina_home does not exist or not a directory!'; eend 1
	fi
	if [ ! -d "${catalina_base}" ]; then
		eerror '$catalina_base does not exist or not a directory!'; eend 1
	fi
	if [ ! -d "${catalina_temp}" ]; then
		eerror '$catalina_temp does not exist or not a directory!'; eend 1
	fi
	if [ ! -f "${tomcat_logging_conf}" ]; then
		eerror '$tomcat_logging_conf does not exist or not a file!'; eend 1
	fi
}

init_vars() {
	init_defaults
	init_env
	init_command_args
	check_paths
}


##########  Runscript functions  ##########

depend() {
	use net
}

start()	{
	ebegin "Starting ${LONG_NAME}"

	init_vars
	start-stop-daemon  --start \
		--quiet --background \
		--chdir "${catalina_temp}" \
		--user ${tomcat_user} \
		--make-pidfile --pidfile ${PIDFILE} \
		--exec ${command} -- ${command_args}
	eend $?
}

stop()	{
	ebegin "Stopping ${LONG_NAME}"

	start-stop-daemon --stop \
		--quiet --retry=60 \
		--pidfile ${PIDFILE} \
	eend $?
}

forcestop()	{
	ebegin "Forcing ${LONG_NAME} to stop"

	start-stop-daemon --stop \
		--quiet --retry=60 \
		--pidfile ${PIDFILE} \
		--signal=9

	if service_started "${RC_SVCNAME}"; then
		mark_service_stopped "${RC_SVCNAME}"
	fi

	eend $?
}

