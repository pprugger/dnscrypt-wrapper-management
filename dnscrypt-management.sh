#!/usr/local/bin/bash
#CONFIG
########################################
path=/usr/local/etc/dnscrypt-wrapper/
logfile=/var/log/dnscrypt-wrapper.log
binpath=/usr/local/sbin/dnscrypt-wrapper 
LISTEN=192.168.78.50
PORT=53000
RESOLVER=9.9.9.9:53
PROVIDER_NAME=2.dnscrypt.uname
CERT_EXPIRE_DAYS=1
PUBLIC_KEYFILE=public.key
SECRET_KEYFILE=secret.key
KEY_RENEWAL_INTERVAL_SECONDS=7200 
CLIENT_RENEWAL_INTERVAL_SECONDS=3800 #Remember clients only check every 3600 seconds for new certificates, give them a bit more time..
#######################################

UPDATE_INTERVAL_SECONDS=$(($KEY_RENEWAL_INTERVAL_SECONDS-$CLIENT_RENEWAL_INTERVAL_SECONDS))

if [ $UPDATE_INTERVAL_SECONDS -lt 0 ]; then
  echo "Key renewal interval has to be higher than client renewal interval!"
  echo "Exiting"
  exit
fi

if [ -d $path ]; then
  cd $path
else
  echo "Creating directory $path"
  mkdir $path
  if [ $? -ne 0 ]; then
    echo "Unable to create directory"
    echo "Please make sure your user can write in $path"
    echo "To touch the directory manually type as root:"
    echo "mkdir $path chown -R <youruser> $path && chgrp -R <youruser> $path && chmod 744 $path"
    echo "Exiting"
    exit
  fi
  cd $path
fi

if [ ! -f $logfile ]; then
  echo "Creating logfile $logfile"
  touch $logfile
  if [ $? -ne 0 ]; then
    echo "Unable to touch logfile"
    echo "Please make sure your user can write in $logfile"
    echo "To touch the file manually type as root:"
    echo "touch $logfile && chown <youruser> $logfile && chgrp <youruser> $logfile && chmod -R 644 $logfile"
    echo "Exiting!"
    exit
  fi
fi

init_server()
{
  echo "First server start, initialising..." >> $logfile
  echo "No keys found, initialising" >> $logfile
  echo "Generating provider keypair" >> $logfile
  $binpath --gen-provider-keypair --provider-publickey-file=$PUBLIC_KEYFILE --provider-secretkey-file=$SECRET_KEYFILE -l $logfile
  $binpath --show-provider-publickey >> $logfile
  chmod 640 $PUBLIC_KEYFILE
  chmod 640 $SECRET_KEYFILE
  create_keys 1
  echo "Starting dnscrypt-wrapper"
  start_server 1
}

start_server()
{
  pkill dnscrypt-wrapper 
  tcpdrop -a -l | grep $PORT | sh 2>&1
	$binpath --resolver-address=$RESOLVER --listen-address=$LISTEN:$PORT --provider-name=$PROVIDER_NAME --crypt-secretkey-file=$1.key --provider-cert-file=$1.cert -d -l $logfile
}

restart_server()
{
  echo "Restarting with $1.key" >> $logfile
	start_server $1
}

restart_server_both_keys()
{
  echo "" >> $logfile
  echo "Restarting dnscrypt-wrapper with both certificates" >> $logfile
  pkill dnscrypt-wrapper 
  tcpdrop -a -l | grep $PORT | sh 2>&1
	$binpath --resolver-address=$RESOLVER --listen-address=$LISTEN:$PORT --provider-name=$PROVIDER_NAME --crypt-secretkey-file=1.key,2.key --provider-cert-file=1.cert,2.cert -d -l $logfile
}

create_keys()
{
  echo "" >> $logfile
  echo "Generating new key $1.key and certificate $1.cert" >> $logfile
  $binpath --gen-crypt-keypair --crypt-secretkey-file=$1.key -l $logfile
  $binpath --gen-cert-file --crypt-secretkey-file=$1.key --provider-cert-file=$1.cert --provider-publickey-file=$PUBLIC_KEYFILE --provider-secretkey-file=$SECRET_KEYFILE --cert-file-expire-days=$CERT_EXPIRE_DAYS -l $logfile
  chmod 640 $1.key
  chmod 640 $1.cert
}

delete_keys()
{
  rm $1.key $1.cert
}

check_if_server_is_running_and_restart()
{
    pgrep dnscrypt-wrapper 2>&1
    if [ $? -ne 0 ]; then
      restart_server $1
    fi
}

if [ ! -f 1.key ] && [ ! -f 2.key ]; then
  if [ ! -f $PUBLIC_KEYFILE ] && [ ! -f $SECRET_KEYFILE ]; then
    init_server
    exit
  fi
fi

if [ ! -f 1.key ] && [ ! -f 2.key ]; then
  create_keys 1
  $binpath --show-provider-publickey >> $logfile
  start_server 1
fi

#create timestamps
timenow=`date +%s`
if [ -f 1.key ]; then
  time1=`date -r 1.key +%s`
  age_key_1_seconds=$(($timenow-$time1))
fi

if [ -f 2.key ]; then
  time2=`date -r 2.key +%s`
  age_key_2_seconds=$(($timenow-$time2))
fi
#################

if [ -f 1.key ] && [ -f 2.key ]; then

	echo "Both keys found, checking..." >> $logfile
  
  if [ $age_key_1_seconds -gt $KEY_RENEWAL_INTERVAL_SECONDS ] && [ $age_key_2_seconds -gt $KEY_RENEWAL_INTERVAL_SECONDS ]; then
    echo "Both Keys to old" >> $logfile
    if [ $age_key_2_seconds -gt $age_key_1_seconds ]; then
      echo "Key 2 older than key 1, deleting key 2..." >> $logfile
      echo "Creating new key 2 and restart server with both keys" >> $logfile
      delete_keys 2
      create_keys 2
      restart_server_both_keys
      exit
    else
      echo "Key 1 older than key 2, deleting key 1..." >> $logfile
      echo "Creating new key 1 and restart server with both keys" >> $logfile
      delete_keys 1
      create_keys 1
      restart_server_both_keys
      exit
    fi
  fi
  
  if [ $age_key_2_seconds -gt $age_key_1_seconds ] && [ $age_key_2_seconds -gt $CLIENT_RENEWAL_INTERVAL_SECONDS ]; then
      echo "Clients had enough time to update, deleting key 2" >> $logfile
      delete_keys 2
      restart_server 1
			exit
  else 
      if [ $age_key_1_seconds -gt $age_key_2_seconds ] && [ $age_key_1_seconds -gt $CLIENT_RENEWAL_INTERVAL_SECONDS ]; then
        echo "Clients had enough time to update, deleting key 1" >> $logfile
        delete_keys 1
        restart_server 2
        exit
      fi
  fi
fi

if [ -f 1.key ] && [ $age_key_1_seconds -gt $KEY_RENEWAL_INTERVAL_SECONDS ]; then
    create_keys 2
    restart_server_both_keys
    exit
else 
  if [ -f 1.key ]; then
    check_if_server_is_running_and_restart 1
    exit
  fi
fi

if [ -f 2.key ] && [ $age_key_2_seconds -gt $KEY_RENEWAL_INTERVAL_SECONDS ]; then
    create_keys 1
    restart_server_both_keys
    exit
else 
  if [ -f 2.key ]; then
    check_if_server_is_running_and_restart 2
    exit
  fi
fi

