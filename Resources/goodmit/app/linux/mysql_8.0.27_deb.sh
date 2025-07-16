#!/bin/bash

# Check if mysql-server is installed
chk_mysql=`apt list --installed 2>/dev/null | grep -i mysql-server | awk '{print $1}'`
sql_conf01="/tmp/mysql_8.0.27/my.cnf"
sql_conf02="/etc/mysql/my.cnf"
sql_conf_bak="/etc/mysql/my.cnf.bak"

sql_user=$1
sql_db=$2
sql_pass="Goodmit0802!"

########## mysql install & root password change

# Update package list
apt update

if apt-cache show mysql-server >/dev/null 2>&1; then
    # Install mysql-server
    DEBIAN_FRONTEND=noninteractive apt install mysql-server -y
    sleep 30
    sql_svc=`service mysql status | grep "Active:" | awk '{print $2}'`
    echo "Successfully installation mysql-server"

    if [ "$sql_svc" = "inactive" ] || [ "$sql_svc" = "dead" ]; then
        service mysql start
        sleep 10
        # Ubuntu MySQL installation doesn't create temporary password
        # Set root password directly
        mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$sql_pass';"
        echo "Successfully set sql root password"
    else
        echo "MySQL is already running"
    fi
else
    echo "Fail mysql-server installation"
fi

########## sql user, db create

if [ -n "$sql_user" ]; then
    mysql -uroot -p$sql_pass -e "CREATE USER '$sql_user'@'%' IDENTIFIED BY 'P@ssw0rd01!';" 2>/dev/null
    mysql -uroot -p$sql_pass -e "FLUSH PRIVILEGES;" 2>/dev/null
    echo "Successfully create db user"

    if [ -n "$sql_db" ]; then
        mysql -uroot -p$sql_pass -e "CREATE DATABASE $sql_db DEFAULT CHARACTER SET utf8;" 2>/dev/null
        mysql -uroot -p$sql_pass -e "GRANT ALL PRIVILEGES ON $sql_db.* TO '$sql_user'@'%';" 2>/dev/null
        echo "Successfully create database & grant db user"
    else
        echo "Fail to create database & grant db user"
    fi
else
    echo "Fail to create db user"
fi

########## sql config file change

sql_svc=`service mysql status | grep "Active:" | awk '{print $2}'`

if [ "$sql_svc" = "active" ]; then
    service mysql stop
    sleep 3
    mv $sql_conf02 $sql_conf_bak
    cp -p $sql_conf01 $sql_conf02
    chk_config=`diff $sql_conf01 $sql_conf02`

    if [ -z "$chk_config" ]; then
        service mysql start
        systemctl enable mysql
        echo "Successfully change my.cnf file"
    else
        echo "Fail to change my.cnf file"
    fi
else
    echo "Fail to stop mysql service"
fi