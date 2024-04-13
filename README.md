# dbupdate 

A bash script to automatically upgrade the database management system on cPanel, Plesk and DirectAdmin servers. Tested on :
```
CentOS 7
CloudLinux 7
AlmaLinux 8
CloudLinux 8
AlmaLinux 9 (cPanel only)
CloudLinux 9 (cPanel only)
```

## Usage:

1. Select the proper MYSQL/MariaDB version:
```
    5.7 (MySQL)
    8.0 (MySQL)
    10.4 (MariaDB, Plesk)
    10.5 (MariaDB)
    10.6 (MariaDB)
    10.11 (MariaDB)
```

## Features:

The script will first check the SQL mode to set it explicitly in the my.cnf file (if it's not already there), then it will check for corruption, dump all the databases, back up the data dir, and lastly proceed with the upgrade. The script will be automatically stopped if an issue is detected during the backup or upgrade process. Can be executed directly with the following command via SSH:

```bash <(curl -s https://repo.stardustziggy.com/dbupdate.sh)```
