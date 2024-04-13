#! /bin/sh

################### Logs ###################

LOG_FILE="/root/dbms_update_log.log"
mv -f $LOG_FILE{,.old} &>/dev/null
echo -e "\n========================================================================\nStarting Update process, logs will be saved at $LOG_FILE\n========================================================================\n" | tee -a "$LOG_FILE"

################### Logs ###################

################### Variables ###################
DB_AUTH=""
OS_VERSION=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release) | cut -d "." -f1)
DATE=$(/usr/bin/date +%s)
CP_MODE=""

################### Variables ###################

################### Utilities ###################

#Execute and print
exe() {
    echo "\$ $@"
    "$@"
}

#Function to Stop the script
stop_script() {
    echo -e "\n\e[31mErrors have been detected. The script is paused, use "Ctrl + z" to have access to the console. Run fg after you check to resume the script.\e[0m"
    pkill -STOP -P $$
}

#Detect exit status
exit_status() {
    e_status="$?"
    if [[ "$e_status" == "0" ]]; then
        :
    else
        stop_script
    fi
}

#Restart and stop the DBMS
restart_mysql() {
    (systemctl restart mysql.service 2 &>/dev/null && echo "DBMS Restarted") || (/scripts/restartsrv_mysql &>/dev/null && echo "DBMS Restarted") || (systemctl restart mariadb 2 &>/dev/null && echo "DBMS Restarted") || (systemctl restart mysqld 2 &>/dev/null && echo "DBMS Restarted")
}

stop_mysql() {
    (systemctl stop mysql.service 2 &>/dev/null && echo "DBMS has been stopped") || (systemctl stop mysqld 2 &>/dev/null && echo "DBMS has been stopped") || (systemctl stop mariadb 2 &>/dev/null && echo "DBMS has been stopped")
}

#Version checking
get_version() {
    db_ver=$(mysql $DB_AUTH -V | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+" | cut -c1-5)
    echo -e "\n- Current version is $db_ver\n"
    db_ver_plesk=$(echo $db_ver | tr -d '.')
}

#HTTP check complementary function
http_check_verification_string() {
    if [[ "$CP_MODE" == "cpanel" ]]; then
        http_verification=$(sort /etc/userdomains | cut -f1 -d: | grep -v '*' | while read i; do
            curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i
            echo $i
        done)
    elif [[ "$CP_MODE" == "plesk" ]]; then
        http_verification=$( (for i in $(mysql $DB_AUTH psa -Ns -e "select name from domains"); do echo $i; done) | while read i; do
            curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i
            echo $i
        done)
    else
        http_verification=$( (for i in $(grep -h '^domain=' /usr/local/directadmin/data/users/*/domains/*.conf | sed 's/domain=//'); do echo $i; done) | while read i; do
            curl -sILo /dev/null -w "%{http_code} " -m 5 http://$i
            echo $i
        done)
    fi
}

################### Utilities ###################

################### Core Functions ###################

#SQL mode verification. my.cnf backup and cleanup.
sql_mode_check() {
    echo -e "\nBacking up the configuration file to /etc/my.cnf.$DATE:"
    cp -avr /etc/my.cnf /etc/my.cnf.$DATE
    echo -e "\n- SQL MODE:"
    (grep -Eq 'sql_mode|sql-mode' /etc/my.cnf &&
        echo -e "\e[1;92m[PASS] \e[0;32mSQL mode is set explicitly.\e(B\e[m\n" ||
        (
            echo -e "Current effective setting is: sql_mode=\"$(mysql $DB_AUTH -NBe 'select @@sql_mode;')\"\e(B\e[m"
            echo -e "Adding it to my.cnf..."
            db_sql_mode=$(mysql $DB_AUTH -NBe 'select @@sql_mode;')

            #Adding it under "[mysqld] block"
            line_num=$(awk '/^\[mysqld\]$/ {print NR; exit}' "/etc/my.cnf")
            if [[ -n "$line_num" ]]; then
                sed -i "${line_num}a\\sql_mode=$db_sql_mode" /etc/my.cnf
            elif [ ! -n "$line_num" ]; then
                echo "[mysqld]" >>/etc/my.cnf
                echo "sql_mode=$db_sql_mode" >>/etc/my.cnf
            else
                :
            fi
            echo -e "Added, restarting MYSQL\n"
            restart_mysql
            echo -e "Confirming: grep -E 'sql_mode|sql-mode' /etc/my.cnf"
            grep -E 'sql_mode|sql-mode' /etc/my.cnf && echo -e "\nGiving a few secs for MYSQL to start\n" && sleep 3
        ))

    sed -i 's/::ffff:127.0.0.1/127.0.0.1/g' /etc/my.cnf
    sed -i "s/NO_AUTO_CREATE_USER,//g" /etc/my.cnf
}

#Pre-checks
pre_checks() {

    echo -e "\n- Checking for corruption:"
    mychecktemp=$(mysqlcheck $DB_AUTH -Asc)
    echo -e "\nmysqlcheck -Asc"
    if [[ -z "$mychecktemp" ]]; then
        echo -e "\nNo output. All good.\n"
    else
        echo $mychecktemp
        mychecktemp2=$(echo $mychecktemp | grep -iE "corrupt|crashe")
        if [[ ! -z "$mychecktemp2" ]]; then
            stop_script
        else
            echo -e "\nMinor errors/warnings\n"
        fi
    fi

    echo -e "- Backups:\n"
    mkdir -p /root/dbms_back
    if [[ ! -d "/root/dbms_back/mysqldumps" ]]; then
        mkdir /root/dbms_back/mysqldumps
    fi
    echo "The backup dir is /root/dbms_back/mysqldumps"
    cd /root/dbms_back/mysqldumps
    (
        set -x
        pwd
    )
    echo -e "\n* Dumping databases:"
    exe eval '(echo "SHOW DATABASES;" | mysql $DB_AUTH -Bs | grep -v '^information_schema$' | while read i ; do echo Dumping $i ; mysqldump $DB_AUTH --single-transaction $i | gzip -c > $i.sql.gz ; done)'
    echo
    error='0'
    count=''
    for f in $(/bin/ls *.sql.gz); do
        if [[ ! $(zgrep -E 'Dump completed on [0-9]{4}-([0-9]{2}-?){2}' ${f}) ]]; then
            echo "Possible error: ${f}"
            error=$((error + 1))
        fi
        count=$((count + 1))
    done
    (
        echo "Error count: ${error}"
        echo "Total DB_dumps: ${count}"
        echo "Total DBs: $(mysql $DB_AUTH -NBe 'SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE schema_name NOT IN ("information_schema");')"
    ) | column -t
    if [[ "$error" != 0 ]]; then
        stop_script
    fi

    echo -e "\n* Rsync data dir:"
    datadir=$(mysql $DB_AUTH -e "show variables;" | grep datadir | awk {'print $2'})
    backdir=("/root/dbms_back/mysql.backup.$(date +%s)/")
    stop_mysql
    sleep 1 && echo
    echo "Path to data dir: $datadir"
    exe eval 'rsync -aHl $datadir $backdir'
    exit_status
    echo -e "Synced\n"
    echo "Restarting DBMS..."
    restart_mysql
    sleep 3

    echo -e "\n\n- Checking HTTP status of all domains prior the upgrade:\n"
    http_check_verification_string
    echo "$http_verification" >/root/dbms_back/mysql_pre_upgrade_http_check
    (
        set -x
        grep -E -v '^(0|2)00 ' /root/dbms_back/mysql_pre_upgrade_http_check
    )
    echo -e "\n\e[0;32m#### DBMS Upgrade ###\e(B\e[m"
}

#Prep work for 5 to 8 upgrades (MySQL)
mysql_five_to_eigth_prep() {
    echo -e "\nUpgrade checker:"
    echo -e "\nInstalling mysql-shell\n"
    _centos_version=$(rpm -q kernel | head -1 | grep -Po '(?<=el)[0-9]')
    if [[ "$_centos_version" == 8 ]]; then
        _repo_rpm="https://dev.mysql.com/get/mysql80-community-release-el8-8.noarch.rpm"
    elif [[ "$_centos_version" == 7 ]]; then
        _repo_rpm="https://dev.mysql.com/get/mysql80-community-release-el7-9.noarch.rpm"
    elif [[ "$_centos_version" == 6 ]]; then
        _repo_rpm="https://dev.mysql.com/get/mysql80-community-release-el6-10.noarch.rpm"
    fi
    (
        yum -y install $_repo_rpm && yum-config-manager --disable mysql80-community mysql-connectors-community mysql-tools-community
        yum -y --enablerepo=mysql-tools-community install mysql-shell
    ) 2>&1 >/dev/null
    mysql_pass=$(sed -nre '/password/s/^ *password *= *"?([^"]+)"? *$/\1/gp' /root/.my.cnf)
    if [[ -z "$mysql_pass" ]]; then
        echo "The password could not be retrieved, try to find it to resume the script"
        stop_script
    fi
    echo
    if [[ -z "$mysql_pass" ]]; then
        echo "Enter the password"
        read mysql_pass
    fi
}

#Post-check (HTTP status)
post_check() {
    sed -i 's/::ffff:127.0.0.1/127.0.0.1/g' /etc/my.cnf
    restart_mysql
    sleep 30
    mysql_upgrade $DB_AUTH

    if [[ "$CP_MODE" == "plesk" ]]; then
        echo -e "\nInforming Plesk of the changes (plesk sbin packagemng -sdf):"
        plesk sbin packagemng -sdf
        plesk bin service_node --update local
    fi
    systemctl enable mariadb 2 &>/dev/null

    echo -e "\n\nPost check:"
    http_check_verification_string
    echo "$http_verification" >/root/dbms_back/mysql_post_upgrade_http_check
    exe eval 'diff /root/dbms_back/mysql_pre_upgrade_http_check /root/dbms_back/mysql_post_upgrade_http_check'
    echo -e "\n\e[0;32m#### All set. ###\e(B\e[m"
}

#Governor upgrade
upgrade_do_governor() {
    sql_mode_check
    pre_checks
    get_version
    if [[ "$gov_package" == 0 ]]; then
        operation=$(echo "update")
    else
        operation=$(echo "install")
    fi
    echo -e "\nThis installation will use the Governor script."
    echo -e "\nTo which version would you like to upgrade?\nOptions:\n\nMYSQL:\nmysql56, mysql57, mysql80\n\nMariaDB:\nmariadb103, mariadb104, mariadb105, mariadb106, mariadb1011\n"
    read answ2
    echo -e "\nSelected: $answ2"
    supported_versions=(mysql56 mysql57 mysql80 mariadb103 mariadb104 mariadb105 mariadb106 mariadb1011)
    while true; do
        if [[ "${supported_versions[@]}" =~ "$answ2" ]]; then 
            double_checking=$(rpm -qa | grep -iEe mysql.*-server -iEe mariadb.*-server | awk '{print tolower($0)}'|cut -d'-' -f1-3)
            while true; do
                if [[ "$double_checking" == *"mariadb"* && "$answ2" == *"mariadb"* ]]  || [[ "$double_checking" == *"mysql"* && "$answ2" == *"mysql"* ]]; then
                    break
                else
                    echo "Converstion from MySQL to MariaDB or MariaDB to MySQL are not supported. Choose again."
                    read answ2
                fi
            done

            echo -e "\nUpgrading to $answ2 using the MySQL Governor script:"
            exe eval 'yum -y $operation governor-mysql'
            exe eval '/usr/share/lve/dbgovernor/mysqlgovernor.py --mysql-version=$answ2'
            exe eval '/usr/share/lve/dbgovernor/mysqlgovernor.py --install --yes'
            exit_code_gov="$?"
            if [[ "$exit_code_gov" == 1 ]]; then
                echo -e "\n\e[31mUpgrade failed.\e[0m\n"
                stop_script
            else
                post_check
            fi
            break
        else
            echo "Invalid option, choose again."
            read answ2
        fi
    done
}

#Checking if /run/mariadb exists
mariadb_rundir_check() {
    if [[ ! -d "/run/mariadb" ]]; then
        mkdir /run/mariadb && chmod 755 /run/mariadb && chown mysql:mysql /run/mariadb
    fi
    grep -q "run/mariadb" "/usr/lib/tmpfiles.d/mariadb.conf"
    exit_code_grep="$?"
    if [[ "$exit_code_grep" == 1 ]]; then
        echo "d /run/mariadb 0755 mysql mysql -" >>/usr/lib/tmpfiles.d/mariadb.conf
    fi
}

################### Core Functions ###################

################### cPanel ###################

#Upgrade using cPanel's API
main_cpanel_proc() {
    echo -e "List of available versions:\n"
    /usr/local/cpanel/bin/whmapi1 installable_mysql_versions | grep "version: '"
    echo -e "\nWhich one are you installing? Only numbers (5.7, 10.5, etc.)"
    read vers
    supported_versions=(10.5 10.6 10.11 5.7 8.0)
    while true; do
        if [[ "${supported_versions[@]}" =~ "$vers" ]]; then
            break
        else
            echo "Invalid option, choose again."
            read vers
        fi
    done

    id=$(/usr/local/cpanel/bin/whmapi1 start_background_mysql_upgrade version=$vers | grep "upgrade_id" | cut -d ":" -f2)
    id="${id:1}"
    echo -e "\nWHM Upgrade ID: $id"
    sleep 1
    cpanel_upgrade_status=$(/usr/local/cpanel/bin/whmapi1 background_mysql_upgrade_status upgrade_id=$id | tail -n6 | grep "state:" | cut -d ":" -f2 | awk '{print $1;}')
    echo -e "\nUpgrading..."
    BAR='#'
    while [[ "$cpanel_upgrade_status" == "inprogress" ]]; do
        echo -ne "${BAR}"
        sleep 5
        cpanel_upgrade_status=$(/usr/local/cpanel/bin/whmapi1 background_mysql_upgrade_status upgrade_id=$id | tail -n6 | grep "state:" | cut -d ":" -f2 | awk '{print $1;}')
    done
    sleep 5
    if [[ "$cpanel_upgrade_status" == "failed" || "$cpanel_upgrade_status" == "failure" ]]; then
        echo -e "\nCheck the log at /var/cpanel/logs/$id/unattended_background_upgrade.log"
        stop_script
    else
        echo -e "\n"
        /usr/local/cpanel/bin/whmapi1 background_mysql_upgrade_status upgrade_id=$id | tail -n6
    fi
}

#cPanel option selection
cpanel_options() {

    if [[ "$system_db_version" == "5.7."* || "$system_db_version" == "5.6."* ]]; then
        sql_mode_check
        mysql_five_to_eigth_prep
        pre_checks
        get_version
        echo
        (
            set -x
            mysqlsh -hlocalhost -uroot --password=$mysql_pass -e 'util.checkForServerUpgrade()'
        )
        echo -e "\nIf you see any errors (warnings are usually safe to ignore), pause the script with Ctrl+z."
        main_cpanel_proc
        post_check

    elif [[ "$system_db_version" == "10.3."* || "$system_db_version" == "10.5."* || "$system_db_version" == "10.6."* ]]; then
        sql_mode_check
        pre_checks
        get_version
        main_cpanel_proc
        post_check

    elif [[ "$system_db_version" == "10.11."* || "$system_db_version" == "8.0."* ]]; then
        echo -e "You are already on the latest version.\n"

    else
        echo -e "This is a not supported upgrade.\n"
    fi
}

#Main cPanel Procedure:
upgrade_do_cpanel() {
    system_db_version=$(mysql -V | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+")
    if [[ "$(cat /etc/redhat-release)" == *"CloudLinux"* ]]; then
        echo "CloudLinux server detected..."
        gov_package=$( rpm -q governor-mysql &>/dev/null; echo $? )
        dbms_packages=$( rpm -qa | grep -i "cl-mysql\|cl-mariadb" &>/dev/null; echo $? )

        if [[ "$gov_package" == 0 ]] && [[ "$dbms_packages" == 0 ]]; then
            upgrade_do_governor
        else
            echo -e "\nWill you be using the MySQL Governor's script? y/n"
            read answ
            echo $answ
            if [[ $answ == "yes" || $answ == "Yes" || $answ == "YES" || $answ == "y" ]]; then
                upgrade_do_governor
            else
                echo "Ok, cPanel upgrade then."
                cpanel_options
            fi
        fi
    fi
}

################### cPanel ###################

################### Plesk ###################

#Version checking to avoid jumpting versions
safe_diff_plesk() {
    read versl
    echo $versl
    vers=$(echo $versl | tr -d '.')
    ver_diff=$(echo "$db_ver_plesk $vers" | awk '{print $1 - $2}')
    ver_diff=$(sed "s/-//" <<<$ver_diff) #absolute value
}

#Select version (Plesk)
select_version_plesk() {
    while true; do
        if [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ "$vers" -lt "$db_ver_plesk" ]]; then
            echo "Downgrades are not supported at this time, select another version."
            safe_diff_plesk
        elif [[ "$system_db_version" == "mariadb"* ]] && [[ "$vers" == '104' ]] && [[ "$db_ver_plesk" == '55' ]]; then
            break
        elif [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ $ver_diff == '2' ]]; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff_plesk
        elif [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ $ver_diff > '2' ]]; then
            echo "Command line upgrades should be done incrementally to avoid damage, like 5.5 -> 5.6 -> 5.7 rather than straight from 5.5 -> 5.7. Please select an older version."
            safe_diff_plesk
        elif [[ "${supported_versions[@]}" =~ "$vers" ]] && [[ $ver_diff < '2' ]]; then
            break
        else
            echo "Invalid option, choose again."
            safe_diff_plesk
        fi
    done
}

#MariaDB upgrade function for Plesk
upgrade_mariadb_plesk() {
    echo -e "\n\n- Upgrading MariaDB -"
    if [ -f "/etc/yum.repos.d/MariaDB.repo" ]; then
        mv /etc/yum.repos.d/MariaDB.repo /etc/yum.repos.d/mariadb.repo
    fi

    echo -e "\n- Removing mysql-server package in case it exists"
    exe eval "rpm -e --nodeps '$(rpm -q --whatprovides mysql-server)' 2 &>/dev/null"
    sql_mode_check
    pre_checks
    get_version
    echo -e "\n-List of available versions:\n\n10.4\n10.5\n10.6\n10.11\n"
    echo -e "\nWhich one are you installing? Only the version: 10.3, 10.4, etc.)."
    safe_diff_plesk
    supported_versions=(104 105 106 1011)
    select_version_plesk

    #Adding the repo
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=$versl --os-type=rhel --os-version=$OS_VERSION
    exit_status
    stop_mysql
    exe eval 'rpm -e --nodeps MariaDB-server'
    exe eval 'rpm -e --nodeps mariadb-libs'
    exe eval 'yum install MariaDB-server -y'
    exit_status
    mariadb_rundir_check
    post_check
}

#Main Plesk Procedure:
upgrade_do_plesk() {

    #Blocking if version is MySQL 5.1/ MariaDB 5.3
    v1=$(rpm -qa | grep -iEe mysql.*-server | grep -v plesk | grep "\-5.1.")
    v2=$(rpm -qa | grep -iEe mariadb.*-server | grep -v plesk | grep "\-5.3.")
    if [[ ! -z "$v1" ]] || [[ ! -z "$v2" ]]; then
        echo -e "\nMariaDB 5.3 and MySQL 5.1 are not supported."
        pkill -9 -P $$
    else
        :
    fi

    DB_AUTH="-uadmin -p$(cat /etc/psa/.psa.shadow)"
    system_db_version=$(rpm -qa | grep -iEe mysql.*-server -iEe mariadb.*-server | grep -v plesk | awk '{print tolower($0)}')
    if [[ "$(cat /etc/redhat-release)" == *"CloudLinux"* ]]; then
        echo "CloudLinux server detected..."
        gov_package=$( rpm -q governor-mysql &>/dev/null; echo $? )
        dbms_packages=$( rpm -qa | grep -i "cl-mysql\|cl-mariadb" &>/dev/null; echo $? )

        if [[ "$gov_package" == 0 ]] && [[ "$dbms_packages" == 0 ]]; then
            upgrade_do_governor
        else
            echo -e "\nWill you be using the MySQL Governor's script? y/n"
            read answ
            echo $answ
            if [[ $answ == "yes" || $answ == "Yes" || $answ == "YES" || $answ == "y" ]]; then
                upgrade_do_governor
            else
                echo "Ok, the regular Plesk method will be used."
                if [[ "$system_db_version" == "mariadb"* ]]; then
                    upgrade_mariadb_plesk
                else
                    echo "This server does not meet the requirements for this script to run (no MariaDB installed or running MySQL, which is no longer being distributed by Plesk)."
                    stop_script
                fi
            fi
        fi
    fi
}

################### Plesk ###################

################### DirectAdmin ###################

#Select version (DA)
select_version_directadmin() {
    read answ2
    echo -e "\nSelected: $answ2"
    while true; do
        if [[ "${supported_versions[@]}" =~ "$answ2" ]]; then
            break
        else
            echo "Invalid option, choose again."
            read answ2
            echo -e "\nSelected: $answ2"
        fi
    done
}

#MariaDB upgrade function for DA
upgrade_mariadb_directadmin() {

    echo -e "\n\n- Upgrading MariaDB -"
    sql_mode_check
    pre_checks
    get_version
    echo -e "\n-List of available versions:\n\n10.3\n10.4\n10.5\n10.6\n"
    echo -e "\nWhich one are you installing? Only the version: 10.5 or 10.6, etc.)."
    supported_versions=(10.3 10.4 10.5 10.6)
    select_version_directadmin
    cd /usr/local/directadmin/custombuild
    ./build set mysql_backup no
    ./build set "mariadb" $answ2
    ./build set mysql_inst "mariadb"
    ./build "mariadb"
    exit_status
    mariadb_rundir_check
    post_check
}

#MySQL upgrade function for DA
upgrade_mysql_directadmin() {
    echo -e "\n\n- Upgrading MySQL -"
    sql_mode_check
    pre_checks
    get_version
    echo -e "\n-List of available versions:\n\n5.7\n8.0\n"
    echo -e "\nWhich one are you installing? Only the version: 5.7 or 8.0)."
    supported_versions=(5.7 8.0)
    select_version_directadmin
    cd /usr/local/directadmin/custombuild
    ./build set mysql_backup no
    ./build set "mysql" $answ2
    ./build set mysql_inst "mysql"
    ./build "mysql"
    exit_status
    post_check
}

#DA option selection
directadmin_options() {
    if [[ "$system_db_version" == "mariadb"* ]]; then
        upgrade_mariadb_directadmin
    elif [[ "$system_db_version" == "mysql"* ]]; then
        upgrade_mysql_directadmin
    else
        echo "This server does not meet the requirements for this script to run (no MariaDB or MySQL detected."
        stop_script
    fi
}

#Main DA Procedure:
upgrade_do_directadmin() {
    DB_AUTH="-uda_admin -p$(grep -oP 'password="\K[^"]+' /usr/local/directadmin/conf/my.cnf)"
    system_db_version=$(rpm -qa | grep -iEe ^mysql.*-server -iEe ^mariadb.*-server | awk '{print tolower($0)}')
    if [[ "$(cat /etc/redhat-release)" == *"CloudLinux"* ]]; then
        echo "CloudLinux server detected..."
        gov_package=$( rpm -q governor-mysql &>/dev/null; echo $? )
        dbms_packages=$( rpm -qa | grep -i "cl-mysql\|cl-mariadb" &>/dev/null; echo $? )

        if [[ "$gov_package" == 0 ]] && [[ "$dbms_packages" == 0 ]]; then
            upgrade_do_governor
        else
            echo -e "\nWill you be using the MySQL Governor's script? y/n"
            read answ
            echo $answ
            if [[ $answ == "yes" || $answ == "Yes" || $answ == "YES" || $answ == "y" ]]; then
                upgrade_do_governor
            else
                echo "Ok, the regular DirectAdmin method will be used."
                directadmin_options
            fi
        fi
    fi
}

################### DirectAdmin ###################

#Main operation
if [[ -f "/usr/local/cpanel/cpanel" ]]; then
    echo -e "cPanel installation detected, using cPanel mode.\n" | tee -a "$LOG_FILE"
    CP_MODE="cpanel"
    upgrade_do_cpanel | tee -a "$LOG_FILE"

elif [[ -f "/usr/local/psa/version" ]]; then
    echo -e "Plesk installation detected, using Plesk mode.\n" | tee -a "$LOG_FILE"
    CP_MODE="plesk"
    upgrade_do_plesk | tee -a "$LOG_FILE"

elif [[ -f "/usr/local/directadmin/directadmin" ]]; then
    echo -e "DirectAdmin installation detected, using DirectAdmin mode.\n" | tee -a "$LOG_FILE"
    upgrade_do_directadmin | tee -a "$LOG_FILE"

else
    echo "No valid control panel detected. Stopping script..." | tee -a "$LOG_FILE"
    pkill -9 -P $$
fi
