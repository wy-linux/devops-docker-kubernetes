#!/usr/bin/env bash

# -e：有任何命令失败（返回非零状态码）时立即退出
# -o pipefail：确保管道命令中任何一个失败整个管道就失败
set -eo pipefail
# 设置shell选项，让不匹配任何文件的glob模式扩展为空字符串而不是保持原样
shopt -s nullglob

# 定义日志函数，可以接受参数或标准输入，输出带时间戳的日志
mysql_log() {
	# 将传递给函数的第一个参数赋值给本地变量 type
	# shift：移除第一个参数，后续参数可以通过 $* 获取到
	local type="$1"; shift
	# 定义本地变量 text 并获取剩余参数
	# 如果没有剩余参数（即 $# 等于 0），则从标准输入读取内容并赋值给 text（cat 命令会读取标准输入的所有内容）
	local text="$*"; if [ "$#" -eq 0 ]; then text="$(cat)"; fi
	# 定义一个本地变量 dt
	# 将当前日期和时间（格式为 RFC 3339 格式）赋值给 dt
	local dt; dt="$(date --rfc-3339=seconds)"
	printf '%s [%s] [Entrypoint]: %s\n' "$dt" "$type" "$text"
}
# 普通信息日志
mysql_note() {
	mysql_log Note "$@"
}
# 警告日志
mysql_warn() {
	mysql_log Warn "$@" >&2
}
# 错误日志
mysql_error() {
	mysql_log ERROR "$@" >&2
	exit 1
}

# 从环境变量或者文件中读取敏感信息并导出为环境变量
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	# 第一个参数值、第一个参数值_FILE 对应的 value 同时设置则报错
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		mysql_error "Both $var and $fileVar are set (but are exclusive)"
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# 检查当前脚本是否被其他脚本source（而不是直接执行）
_is_sourced() {
	# FUNCNAME数组包含当前的函数调用栈
	# 如果直接执行脚本，调用栈长度通常为1；如果被source，长度会 >= 2
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		# 当前函数名是 _is_sourced（即正在执行这个函数）
		&& [ "${FUNCNAME[0]}" = '_is_sourced' ] \
		# 调用这个函数的上一级函数名是 source
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

# 处理初始化文件，根据文件扩展名执行不同的操作：
# .sh文件：如果是可执行的就运行，否则source
# 各种压缩的SQL文件：解压后执行
# 普通SQL文件：直接执行
docker_process_init_files() {
	# 定义一个数组 mysql，其中包含一个元素 docker_process_sql（兼容旧的 mysql 数组用法）
	mysql=( docker_process_sql )

	echo
	local f
	# 遍历所有参数（相当于： for f in $@）
	for f; do
		case "$f" in
			*.sh)
				# 如果文件可执行，调用 mysql_note 函数记录日志，然后在子shell中执行该脚本
				if [ -x "$f" ]; then
					mysql_note "$0: running $f"
					"$f"
				# 如果文件不可执行，调用 mysql_note 函数记录日志，然后使用 .（source）在当前Shell环境中执行执行该脚本
				else
					mysql_note "$0: sourcing $f"
					. "$f"
				fi
				;;
			*.sql)     mysql_note "$0: running $f"; docker_process_sql < "$f"; echo ;;
			*.sql.bz2) mysql_note "$0: running $f"; bunzip2 -c "$f" | docker_process_sql; echo ;;
			*.sql.gz)  mysql_note "$0: running $f"; gunzip -c "$f" | docker_process_sql; echo ;;
			*.sql.xz)  mysql_note "$0: running $f"; xzcat "$f" | docker_process_sql; echo ;;
			*.sql.zst) mysql_note "$0: running $f"; zstd -dc "$f" | docker_process_sql; echo ;;
			*)         mysql_warn "$0: ignoring $f" ;;
		esac
		echo
	done
}

_verboseHelpArgs=(
	--verbose --help
	--log-bin-index="$(mktemp -u)" # https://github.com/docker-library/mysql/issues/136
)

mysql_check_config() {
	local toRun=( "$@" "${_verboseHelpArgs[@]}" ) errors
	# 将toRun数组中命令的标准输出丢弃，标准错误输出保存到变量 errors 中。命令执行失败，执行后续then在错误日志中打印错误信息
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		mysql_error $'mysqld failed while attempting to check config\n\tcommand was: '"${toRun[*]}"$'\n\t'"$errors"
	fi
}

mysql_get_config() {
	local conf="$1"; shift
	"$@" "${_verboseHelpArgs[@]}" 2>/dev/null \
		| awk -v conf="$conf" '$1 == conf && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

mysql_socket_fix() {
	local defaultSocket
	# 获取mysql的默认 socket 配置
	defaultSocket="$(mysql_get_config 'socket' mysqld --no-defaults)"
	# 默认 socket 配置与$SOCKET配置不一样，则创建默认配置软链接指向$SOCKET配置
	if [ "$defaultSocket" != "$SOCKET" ]; then
		ln -sfTv "$SOCKET" "$defaultSocket" || :
	fi
}

# 临时启动MySQL服务
docker_temp_server_start() {
	# For 5.7+ the server is ready for use as soon as startup command unblocks
	if ! "$@" --daemonize --skip-networking --default-time-zone=SYSTEM --socket="${SOCKET}"; then
		mysql_error "Unable to start server."
	fi
}

# 临时关闭MySQL服务
docker_temp_server_stop() {
	if ! mysqladmin --defaults-extra-file=<( _mysql_passfile ) shutdown -uroot --socket="${SOCKET}"; then
		mysql_error "Unable to shut down server."
	fi
}

# 验证 MySQL Docker 容器的环境变量配置是否正确
docker_verify_minimum_env() {
	# MYSQL_ROOT_PASSWORD、MYSQL_ALLOW_EMPTY_PASSWORD 和 MYSQL_RANDOM_ROOT_PASSWORD 都未设置，打印错误信息
	if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		mysql_error <<-'EOF'
			Database is uninitialized and password option is not specified
			    You need to specify one of the following as an environment variable:
			    - MYSQL_ROOT_PASSWORD
			    - MYSQL_ALLOW_EMPTY_PASSWORD
			    - MYSQL_RANDOM_ROOT_PASSWORD
		EOF
	fi

	# MYSQL_USER 设置为 root，打印错误信息
	if [ "$MYSQL_USER" = 'root' ]; then
		mysql_error <<-'EOF'
			MYSQL_USER="root", MYSQL_USER and MYSQL_PASSWORD are for configuring a regular user and cannot be used for the root user
			    Remove MYSQL_USER="root" and use one of the following to control the root user password:
			    - MYSQL_ROOT_PASSWORD
			    - MYSQL_ALLOW_EMPTY_PASSWORD
			    - MYSQL_RANDOM_ROOT_PASSWORD
		EOF
	fi

	if [ -n "$MYSQL_USER" ] && [ -z "$MYSQL_PASSWORD" ]; then
		mysql_warn 'MYSQL_USER specified, but missing MYSQL_PASSWORD; MYSQL_USER will not be created'
	elif [ -z "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
		mysql_warn 'MYSQL_PASSWORD specified, but missing MYSQL_USER; MYSQL_PASSWORD will be ignored'
	fi
}

# 创建 MySQL 需要的目录并设置权限
docker_create_db_directories() {
	# 声明局部变量 user，获取当前用户的 UID（用户ID）
	local user; user="$(id -u)"

	local -A dirs=( ["$DATADIR"]=1 )
	local dir
	dir="$(dirname "$SOCKET")"
	dirs["$dir"]=1

	local conf
	for conf in \
		general-log-file \
		keyring_file_data \
		pid-file \
		secure-file-priv \
		slow-query-log-file \
	; do
		dir="$(mysql_get_config "$conf" "$@")"

		# skip empty values
		if [ -z "$dir" ] || [ "$dir" = 'NULL' ]; then
			continue
		fi
		case "$conf" in
			# secure-file-priv不需要处理，已经是目录
			secure-file-priv)
			    # 不做处理
				;;
			# 其他配置配置的是文件路径，需要提取目录
			*)
				dir="$(dirname "$dir")"
				;;
		esac

		dirs["$dir"]=1
	done
	#提取 dirs 数组的key(目录)并创建它们
	mkdir -p "${!dirs[@]}"
	# 如果当前用户是 root ，将dirs数组key对应目录的所有权改为 mysql 用户
	if [ "$user" = "0" ]; then
		find "${!dirs[@]}" \! -user mysql -exec chown --no-dereference mysql '{}' +
	fi
}

# 初始化 MySQL 数据库目录
docker_init_database_dir() {
	mysql_note "Initializing database files"
	# --initialize-insecure：以不安全模式初始化数据库（不生成 root 密码）
	# --default-time-zone=SYSTEM：设置默认时区为系统时区
	# --autocommit=1：启用自动提交模式
	"$@" --initialize-insecure --default-time-zone=SYSTEM --autocommit=1
	# explicitly enable autocommit to combat https://bugs.mysql.com/bug.php?id=110535 (TODO remove this when 8.0 is EOL; see https://github.com/mysql/mysql-server/commit/7dbf4f80ed15f3c925cfb2b834142f23a2de719a)
	mysql_note "Database files initialized"
}

# 设置 MySQL Docker 环境变量
docker_setup_env() {
	# 声明全局变量 DATADIR 和 SOCKET，-g 选项使变量在函数外部也可访问
	declare -g DATADIR SOCKET
	DATADIR="$(mysql_get_config 'datadir' "$@")"
	SOCKET="$(mysql_get_config 'socket' "$@")"

	file_env 'MYSQL_ROOT_HOST' '%'
	file_env 'MYSQL_DATABASE'
	file_env 'MYSQL_USER'
	file_env 'MYSQL_PASSWORD'
	file_env 'MYSQL_ROOT_PASSWORD'

	declare -g DATABASE_ALREADY_EXISTS
	if [ -d "$DATADIR/mysql" ]; then
		DATABASE_ALREADY_EXISTS='true'
	fi
}

# 执行 SQL 脚本, 通过stdin标准输入传递
# usage: docker_process_sql [--dont-use-mysql-root-password] [mysql-cli-args]
#    ie: docker_process_sql --database=mydb <<<'INSERT ...'  使用 Here String 语法传递 SQL 语句
#    ie: docker_process_sql --dont-use-mysql-root-password --database=mydb <my-file.sql  从文件读取 SQL 并禁用 root 密码
docker_process_sql() {
	passfileArgs=()
	if [ '--dont-use-mysql-root-password' = "$1" ]; then
		passfileArgs+=( "$1" )
		shift
	fi

	if [ -n "$MYSQL_DATABASE" ]; then
		set -- --database="$MYSQL_DATABASE" "$@"
	fi
	# <(command) 将command进程的输出替换为临时文件描述符（临时管道）
	mysql --defaults-extra-file=<( _mysql_passfile "${passfileArgs[@]}") --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" --comments "$@"
}

# 初始化数据库时区信息、root 密码配置、权限管理和自定义数据库/用户的创建
docker_setup_db() {
	# 加载时区信息到数据库
	if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
		# sed is for https://bugs.mysql.com/bug.php?id=20545
		mysql_tzinfo_to_sql /usr/share/zoneinfo \
			| sed 's/Local time zone must be set--see zic manual page/FCTY/' \
			| docker_process_sql --dont-use-mysql-root-password --database=mysql

	fi
	# 检查是否要求生成随机密码
	if [ -n "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)"; export MYSQL_ROOT_PASSWORD
		mysql_note "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
	fi
	# 设置 root 密码并为非 localhost 主机创建 root 用户
	local rootCreate=
	# 默认允许 root 从任何地方连接
	if [ -n "$MYSQL_ROOT_HOST" ] && [ "$MYSQL_ROOT_HOST" != 'localhost' ]; then
		# no, we don't care if read finds a terminating character in this heredoc
		# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
		read -r -d '' rootCreate <<-EOSQL || true
			CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
		EOSQL
	fi

	# 读取设置 localhost root 密码的 SQL
	local passwordSet=
	# no, we don't care if read finds a terminating character in this heredoc (see above)
	read -r -d '' passwordSet <<-EOSQL || true
		ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
	EOSQL

	# docker_process_sql --dont-use-mysql-root-password 不使用 root 密码（因为正在设置）
	docker_process_sql --dont-use-mysql-root-password --database=mysql <<-EOSQL
		-- enable autocommit explicitly (in case it was disabled globally)
		SET autocommit = 1;

		-- What's done in this file shouldn't be replicated
		--  or products like mysql-fabric won't work
		SET @@SESSION.SQL_LOG_BIN=0;

		${passwordSet}
		GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
		FLUSH PRIVILEGES ;
		${rootCreate}
		DROP DATABASE IF EXISTS test ;
	EOSQL

	# 创建自定义数据库和用户（如果指定了）
	if [ -n "$MYSQL_DATABASE" ]; then
		mysql_note "Creating database ${MYSQL_DATABASE}"
		docker_process_sql --database=mysql <<<"CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;"
	fi

	if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
		mysql_note "Creating user ${MYSQL_USER}"
		docker_process_sql --database=mysql <<<"CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;"

		if [ -n "$MYSQL_DATABASE" ]; then
			mysql_note "Giving user ${MYSQL_USER} access to schema ${MYSQL_DATABASE}"
			docker_process_sql --database=mysql <<<"GRANT ALL ON \`${MYSQL_DATABASE//_/\\_}\`.* TO '$MYSQL_USER'@'%' ;"
		fi
	fi
}

# 输出密码到客户端使用的"文件"
# ie: --defaults-extra-file=<( _mysql_passfile )
_mysql_passfile() {
	if [ '--dont-use-mysql-root-password' != "$1" ] && [ -n "$MYSQL_ROOT_PASSWORD" ]; then
		cat <<-EOF
			[client]
			password="${MYSQL_ROOT_PASSWORD}"
		EOF
	fi
}

# 标记 root 用户为过期状态，这样在进行任何其他操作之前必须更改密码
# 只支持 MySQL 5.6 及以上版本
mysql_expire_root_user() {
	if [ -n "$MYSQL_ONETIME_PASSWORD" ]; then
		docker_process_sql --database=mysql <<-EOSQL
			ALTER USER 'root'@'%' PASSWORD EXPIRE;
		EOSQL
	fi
}

# 检查 MySQL 启动参数中是否包含查看帮助信息或版本信息，而不是真正启动 MySQL 服务器
# 如果找到这样的选项，返回 true（0）
_mysql_want_help() {
	local arg
	for arg; do
		case "$arg" in
			-'?'|--help|--print-defaults|-V|--version)
				return 0
				;;
		esac
	done
	return 1
}

_main() {
	# 如果第一个参数以 - 开头，在前面添加 mysqld 命令
	if [ "${1:0:1}" = '-' ]; then
		set -- mysqld "$@"
	fi

	# 只有当第一个参数是 mysqld 且不是寻求帮助的命令时才执行初始化
	if [ "$1" = 'mysqld' ] && ! _mysql_want_help "$@"; then
		mysql_note "Entrypoint script for MySQL Server ${MYSQL_VERSION} started."

		# 检查MySQL配置文件
		mysql_check_config "$@"
		# 设置各种环境变量
		docker_setup_env "$@"
		# 创建数据库目录
		docker_create_db_directories "$@"

		# 如果容器启动用户是root，切换到专用的mysql用户重新执行脚本
		if [ "$(id -u)" = "0" ]; then
			mysql_note "Switching to dedicated user 'mysql'"
			exec gosu mysql "$BASH_SOURCE" "$@"
		fi

		# 如果数据库不存在（第一次运行），进行初始化
		if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
			# 验证必需的环境变量
			docker_verify_minimum_env

			# 检查初始化脚本目录的权限，避免部分初始化的问题
			ls /docker-entrypoint-initdb.d/ > /dev/null

			# 初始化数据库目录
			docker_init_database_dir "$@"

			mysql_note "Starting temporary server"
			# 启动临时MySQL服务器用于初始化
			docker_temp_server_start "$@"
			mysql_note "Temporary server started."

			# 修复socket文件权限问题
			mysql_socket_fix
			# 设置数据库（创建root用户等）
			docker_setup_db
			# 执行 /docker-entrypoint-initdb.d/ 目录下的所有初始化脚本
			docker_process_init_files /docker-entrypoint-initdb.d/*

			# 使root用户密码过期（如果设置了随机密码）
			mysql_expire_root_user

			mysql_note "Stopping temporary server"
			# 停止临时服务器
			docker_temp_server_stop
			mysql_note "Temporary server stopped"

			echo
			mysql_note "MySQL init process done. Ready for start up."
			echo
		else
			# 如果数据库已存在，只修复socket文件权限
			mysql_socket_fix
		fi
	fi
	# 执行传入的命令（通常是mysqld）
	exec "$@"
}

# 当脚本被直接执行而不是被source加载时，执行_main函数；否则，只加载函数定义
if ! _is_sourced; then
	_main "$@"
fi
