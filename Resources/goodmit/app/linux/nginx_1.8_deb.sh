#!/bin/bash

chk_nginx=`apt list --installed 2>/dev/null | grep -i ^nginx/ | awk '{print $1}'`
nginx_conf01="/tmp/nginx_1.8/nginx.conf"
nginx_conf02="/etc/nginx/nginx.conf"
nginx_conf_bak="/etc/nginx/nginx.conf.bak"
was_ip=$1

if [ -z "$1" ]; then
    echo "Please provide WAS IP address as an argument"
    exit 1
fi

# Check if nginx package exists in repository
if apt-cache show nginx >/dev/null 2>&1; then
    # Install nginx
    apt update
    apt install nginx -y
    nginx_svc=`service nginx status | grep "Active:" | awk '{print $2}'`
    echo "Install successfully nginx"
    
    if [ "$nginx_svc" = "inactive" ] || [ "$nginx_svc" = "dead" ]; then
        mv $nginx_conf02 $nginx_conf_bak
        cp -p $nginx_conf01 $nginx_conf02
        sed -i 's/was-server/'$was_ip'/g' $nginx_conf02
        check_config=`grep -i $1 $nginx_conf02`

        if [ -n "$check_config" ]; then
            service nginx start
            systemctl enable nginx
            nginx_stat=`service nginx status | grep "Active:" | awk '{print $2}'`
            echo "Successfully start nginx $nginx_stat status"
        else
            echo "Fail to load nginx"
        fi
    else
        echo "Check nginx.conf file"
    fi
else
    echo "Not found nginx repository"
fi