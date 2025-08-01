#!/bin/bash

# Copyright (c) 2021, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.
# Description
# This script is to setup and configure WebLogic cluster domain.


#Function to output message to StdErr
function echo_stderr ()
{
    echo "$@" >&2
}

#Function to display usage message
function usage()
{
  echo_stderr "./setupClusterDomain.sh <<< \"<clusterDomainSetupArgumentsFromStdIn>\""
}

function installUtilities()
{
    echo "Installing zip unzip wget vnc-server rng-tools cifs-utils"
    sudo yum install -y zip unzip wget vnc-server rng-tools cifs-utils

    #Setting up rngd utils
    attempt=1
    while [[ $attempt -lt 4 ]]
    do
       echo "Starting rngd service attempt $attempt"
       sudo systemctl start rngd
       attempt=`expr $attempt + 1`
       sudo systemctl status rngd | grep running
       if [[ $? == 0 ]];
       then
          echo "rngd utility service started successfully"
          break
       fi
       sleep 1m
    done
}

function validateInput()
{
    if [ -z "$wlsDomainName" ];
    then
        echo_stderr "wlsDomainName is required. "
    fi

    if [[ -z "$wlsUserName" || -z "$wlsPassword" ]]
    then
        echo_stderr "wlsUserName or wlsPassword is required. "
        exit 1
    fi

    if [ -z "$wlsServerName" ];
    then
        echo_stderr "wlsServerName is required. "
    fi

    if [ -z "$wlsAdminHost" ];
    then
        echo_stderr "wlsAdminHost is required. "
    fi

    if [ -z "$oracleHome" ]; 
    then 
        echo_stderr "oracleHome is required. " 
        exit 1 
    fi

    if [ -z "$storageAccountName" ];
    then 
        echo_stderr "storageAccountName is required. "
        exit 1
    fi
    
    if [ -z "$storageAccountKey" ];
    then 
        echo_stderr "storageAccountKey is required. "
        exit 1
    fi
    
    if [ -z "$mountpointPath" ];
    then 
        echo_stderr "mountpointPath is required. "
        exit 1
    fi

    if [ "${isCustomSSLEnabled}" != "true" ];
    then
        echo_stderr "Custom SSL value is not provided. Defaulting to false"
        isCustomSSLEnabled="false"
    else
        if   [ -z "$customIdentityKeyStoreData" ]    || [ -z "$customIdentityKeyStorePassPhrase" ] ||
             [ -z "$customIdentityKeyStoreType" ]    || [ -z "$customTrustKeyStoreData" ] ||
             [ -z "$customTrustKeyStorePassPhrase" ] || [ -z "$customTrustKeyStoreType" ] ||
             [ -z "$serverPrivateKeyAlias" ]         || [ -z "$serverPrivateKeyPassPhrase" ];
        then
            echo "One of the required values for enabling Custom SSL \
            (CustomKeyIdentityKeyStoreData,CustomKeyIdentityKeyStorePassPhrase,CustomKeyIdentityKeyStoreType,CustomKeyTrustKeyStoreData,CustomKeyTrustKeyStorePassPhrase,CustomKeyTrustKeyStoreType) \
            has not been provided."
            exit 1
        fi
    fi

    if [ -z "$virtualNetworkNewOrExisting" ];
    then
        echo_stderr "virtualNetworkNewOrExisting is required. "
        exit 1
    fi

    if [ -z "$storageAccountPrivateIp" ];
    then
        echo_stderr "storageAccountPrivateIp is required. "
        exit 1
    fi
}

#Function to cleanup all temporary files
function cleanup()
{
    echo "Cleaning up temporary files..."

    rm -rf $DOMAIN_PATH/admin-domain.yaml
    rm -rf $DOMAIN_PATH/managed-domain.yaml
    rm -rf $DOMAIN_PATH/*.py
    rm -rf ${CUSTOM_HOSTNAME_VERIFIER_HOME}
    echo "Cleanup completed."
}

# This function verifies whether certificate is valid and not expired
function verifyCertValidity()
{
    KEYSTORE=$1
    PASSWORD=$2
    CURRENT_DATE=$3
    MIN_CERT_VALIDITY=$4
    KEY_STORE_TYPE=$5
    VALIDITY=$(($CURRENT_DATE + ($MIN_CERT_VALIDITY*24*60*60)))
    
    echo "Verifying $KEYSTORE is valid at least $MIN_CERT_VALIDITY day from the deployment time"
    
    if [ $VALIDITY -le $CURRENT_DATE ];
    then
        echo "Error : Invalid minimum validity days supplied"
  		exit 1
  	fi 

	# Check whether KEYSTORE supplied can be opened for reading
	# Redirecting as no need to display the contents
	runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $KEYSTORE  -storepass $PASSWORD -storetype $KEY_STORE_TYPE > /dev/null 2>&1"
	if [ $? != 0 ];
	then
		echo "Error opening the keystore : $KEYSTORE"
		exit 1
	fi

	aliasList=`runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $KEYSTORE  -storepass $PASSWORD -storetype $KEY_STORE_TYPE | grep Alias" |awk '{print $3}'`
	if [[ -z $aliasList ]]; 
	then 
		echo "Error : No alias found in supplied certificate"
		exit 1
	fi
	
	for alias in $aliasList 
	do
		VALIDITY_PERIOD=`runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $KEYSTORE  -storepass $PASSWORD -storetype $KEY_STORE_TYPE -alias $alias | grep Valid"`
		echo "$KEYSTORE is \"$VALIDITY_PERIOD\""
		CERT_UNTIL_DATE=`echo $VALIDITY_PERIOD | awk -F'until:|\r' '{print $2}'`
		CERT_UNTIL_SECONDS=`date -d "$CERT_UNTIL_DATE" +%s`
		VALIDITY_REMIANS_SECONDS=`expr $CERT_UNTIL_SECONDS - $VALIDITY`
		if [[ $VALIDITY_REMIANS_SECONDS -le 0 ]];
		then
			echo_stderr "$KEYSTORE is \"$VALIDITY_PERIOD\""
			echo_stderr "Error : Supplied certificate $KEYSTORE is either expired or expiring soon within $MIN_CERT_VALIDITY day"
			exit 1
		fi		
	done
	echo "$KEYSTORE validation is successful"
}

#Creates weblogic deployment model for cluster domain admin setup
function create_admin_model()
{
    echo "Creating admin domain model"

cat /dev/null > $DOMAIN_PATH/admin-domain.yaml

    cat <<EOF >$DOMAIN_PATH/admin-domain.yaml
domainInfo:
   AdminUserName: "$wlsUserName"
   AdminPassword: "$wlsPassword"
   ServerStartMode: prod
topology:
   Name: "$wlsDomainName"
   AdminServerName: admin
   Machine:
     '$nmHost':
         NodeManager:
             ListenAddress: "$nmHost"
             ListenPort: $nmPort
             NMType : ssl
   Cluster:
        '$wlsClusterName':
             MigrationBasis: 'consensus'
   Server:
        '$wlsServerName':
            ListenPort: $wlsAdminPort
            NetworkAccessPoint:
                'adminT3Channel':
                    ListenAddress: '$wlsAdminHost'
                    ListenPort: $wlsAdminT3ChannelPort
                    Protocol: t3
                    Enabled: true
            ListenPortEnabled: ${isHTTPAdminListenPortEnabled}
            RestartDelaySeconds: 10
            ServerStart:
               Arguments: '${SERVER_STARTUP_ARGS}'
EOF

        if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
            KeyStores: 'CustomIdentityAndCustomTrust'
            CustomIdentityKeyStoreFileName: "$customIdentityKeyStoreFileName"
            CustomIdentityKeyStoreType: "$customIdentityKeyStoreType"
            CustomIdentityKeyStorePassPhraseEncrypted: "$customIdentityKeyStorePassPhrase"
            CustomTrustKeyStoreFileName: "$customTrustKeyStoreFileName"
            CustomTrustKeyStoreType: "$customTrustKeyStoreType"
            CustomTrustKeyStorePassPhraseEncrypted: "$customTrustKeyStorePassPhrase"
EOF
        fi

cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
            SSL:
               ListenPort: $wlsSSLAdminPort
               Enabled: true
EOF

        if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
               ServerPrivateKeyAlias: "$serverPrivateKeyAlias"
               ServerPrivateKeyPassPhraseEncrypted: "$serverPrivateKeyPassPhrase"
EOF
        fi

cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
   SecurityConfiguration:
       NodeManagerUsername: "$wlsUserName"
       NodeManagerPasswordEncrypted: "$wlsPassword"
EOF

hasRemoteAnonymousAttribs="$(containsRemoteAnonymousT3RMIIAttribs)"
echo "hasRemoteAnonymousAttribs: ${hasRemoteAnonymousAttribs}"

if [ "${hasRemoteAnonymousAttribs}" == "true" ];
then
echo "adding settings to disable remote anonymous t3/rmi disabled under domain security configuration"
cat <<EOF>>$DOMAIN_PATH/admin-domain.yaml
       RemoteAnonymousRmiiiopEnabled: false
       RemoteAnonymousRmit3Enabled: false
EOF
fi
}

#Creates weblogic deployment model for cluster domain managed server
function create_managed_model()
{
    echo "Creating managed domain model"
    cat <<EOF >$DOMAIN_PATH/managed-domain.yaml
domainInfo:
   AdminUserName: "$wlsUserName"
   AdminPassword: "$wlsPassword"
   ServerStartMode: prod
topology:
   Name: "$wlsDomainName"
   Machine:
     '$managedServerHost':
         NodeManager:
             ListenAddress: "$managedServerHost"
             ListenPort: $nmPort
             NMType : ssl
   Cluster:
        '$wlsClusterName':
             MigrationBasis: 'consensus'
   Server:
        '$wlsServerName' :
           ListenAddress: "$managedServerHost"
           ListenPort: $wlsManagedPort
           Notes: "$wlsServerName managed server"
           Cluster: "$wlsClusterName"
           Machine: "$managedServerHost"
           ServerStart:
               Arguments: '${SERVER_STARTUP_ARGS} -Dweblogic.Name=$wlsServerName  -Dweblogic.management.server=${SERVER_START_URL}'
EOF
    
if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/managed-domain.yaml
           KeyStores: 'CustomIdentityAndCustomTrust'
           CustomIdentityKeyStoreFileName: "$customIdentityKeyStoreFileName"
           CustomIdentityKeyStoreType: "$customIdentityKeyStoreType"
           CustomIdentityKeyStorePassPhraseEncrypted: "$customIdentityKeyStorePassPhrase"
           CustomTrustKeyStoreFileName: "$customTrustKeyStoreFileName"
           CustomTrustKeyStoreType: "$customTrustKeyStoreType"
           CustomTrustKeyStorePassPhraseEncrypted: "$customTrustKeyStorePassPhrase"
EOF
        fi

        if [ "${isCustomSSLEnabled}" == "true" ];
        then
cat <<EOF>>$DOMAIN_PATH/managed-domain.yaml
           SSL:
                ServerPrivateKeyAlias: "$serverPrivateKeyAlias"
                ServerPrivateKeyPassPhraseEncrypted: "$serverPrivateKeyPassPhrase"
EOF
        fi

    cat <<EOF >>$DOMAIN_PATH/managed-domain.yaml
   SecurityConfiguration:
       NodeManagerUsername: "$wlsUserName"
       NodeManagerPasswordEncrypted: "$wlsPassword"
EOF

hasRemoteAnonymousAttribs="$(containsRemoteAnonymousT3RMIIAttribs)"
echo "hasRemoteAnonymousAttribs: ${hasRemoteAnonymousAttribs}"


if [ "${hasRemoteAnonymousAttribs}" == "true" ];
then
echo "adding settings to disable remote anonymous t3/rmi disabled under domain security configuration"
cat <<EOF>>$DOMAIN_PATH/managed-domain.yaml
       RemoteAnonymousRmiiiopEnabled: false
       RemoteAnonymousRmit3Enabled: false
EOF
fi

}

#This function to add machine for a given managed server
function create_machine_model()
{
    echo "Creating machine name model for managed server $wlsServerName"
    cat <<EOF >$DOMAIN_PATH/add-machine.py
connect('$wlsUserName','$wlsPassword','$adminWlstURL')
edit("$wlsServerName")
startEdit()
cd('/')
cmo.createMachine('$nmHost')
cd('/Machines/$nmHost/NodeManager/$nmHost')
cmo.setListenPort(int($nmPort))
cmo.setListenAddress('$nmHost')
cmo.setNMType('ssl')
save()
resolve()
activate()
destroyEditSession("$wlsServerName")
disconnect()
EOF
}

#This function to add managed serverto admin node
function create_ms_server_model()
{
    echo "Creating managed server $wlsServerName model"
    cat <<EOF >$DOMAIN_PATH/add-server.py

isCustomSSLEnabled='${isCustomSSLEnabled}'
connect('$wlsUserName','$wlsPassword','$adminWlstURL')
edit("$wlsServerName")
startEdit()
cd('/')
cmo.createServer('$wlsServerName')
cd('/Servers/$wlsServerName')
cmo.setMachine(getMBean('/Machines/$nmHost'))
cmo.setCluster(getMBean('/Clusters/$wlsClusterName'))
cmo.setListenAddress('$nmHost')
cmo.setListenPort(int($wlsManagedPort))
cmo.setListenPortEnabled(true)

if isCustomSSLEnabled == 'true' :
    cmo.setKeyStores('CustomIdentityAndCustomTrust')
    cmo.setCustomIdentityKeyStoreFileName('$customIdentityKeyStoreFileName')
    cmo.setCustomIdentityKeyStoreType('$customIdentityKeyStoreType')
    set('CustomIdentityKeyStorePassPhrase', '$customIdentityKeyStorePassPhrase')
    cmo.setCustomTrustKeyStoreFileName('$customTrustKeyStoreFileName')
    cmo.setCustomTrustKeyStoreType('$customTrustKeyStoreType')
    set('CustomTrustKeyStorePassPhrase', '$customTrustKeyStorePassPhrase')

cd('/Servers/$wlsServerName/SSL/$wlsServerName')
cmo.setServerPrivateKeyAlias('$serverPrivateKeyAlias')
set('ServerPrivateKeyPassPhrase', '$serverPrivateKeyPassPhrase')

cd('/Servers/$wlsServerName//ServerStart/$wlsServerName')
arguments = '${SERVER_STARTUP_ARGS} -Dweblogic.Name=$wlsServerName  -Dweblogic.management.server=${SERVER_START_URL}'
oldArgs = cmo.getArguments()
if oldArgs != None:
  newArgs = oldArgs + ' ' + arguments
else:
  newArgs = arguments
cmo.setArguments(newArgs)
save()
resolve()
activate()
destroyEditSession("$wlsServerName")
nmEnroll('$DOMAIN_PATH/$wlsDomainName','$DOMAIN_PATH/$wlsDomainName/nodemanager')
nmGenBootStartupProps('$wlsServerName')
disconnect()
EOF
}

#Function to create Admin Only Domain
function create_adminSetup()
{
    echo "Creating Admin Setup"
    echo "Creating domain path $DOMAIN_PATH"
 
    sudo mkdir -p $DOMAIN_PATH 

    cd $DOMAIN_PATH

	# WebLogic base images are already having weblogic-deploy, hence no need to download
    if [ ! -d "$DOMAIN_PATH/weblogic-deploy" ];
    then
        echo "weblogic-deploy tool not found in path $DOMAIN_PATH"
        exit 1
    fi

    create_admin_model
    sudo chown -R $username:$groupname $DOMAIN_PATH
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; $DOMAIN_PATH/weblogic-deploy/bin/createDomain.sh -oracle_home $oracleHome -domain_parent $DOMAIN_PATH  -domain_type WLS -model_file $DOMAIN_PATH/admin-domain.yaml"
    if [[ $? != 0 ]]; then
       echo "Error : Admin setup failed"
       exit 1
    fi

    # For issue https://github.com/wls-eng/arm-oraclelinux-wls/issues/89
    copySerializedSystemIniFileToShare
}

#Function to setup admin boot properties
function admin_boot_setup()
{
 echo "Creating admin boot properties"
 #Create the boot.properties directory
 mkdir -p "$DOMAIN_PATH/$wlsDomainName/servers/admin/security"
 echo "username=$wlsUserName" > "$DOMAIN_PATH/$wlsDomainName/servers/admin/security/boot.properties"
 echo "password=$wlsPassword" >> "$DOMAIN_PATH/$wlsDomainName/servers/admin/security/boot.properties"
 sudo chown -R $username:$groupname $DOMAIN_PATH/$wlsDomainName/servers
 }

#This function to wait for admin server
function wait_for_admin()
{
 #wait for admin to start
count=1
CHECK_URL="http://$wlsAdminURL/weblogic/ready"
status=`curl --insecure -ILs $CHECK_URL | tac | grep -m1 HTTP/1.1 | awk {'print $2'}`
echo "Waiting for admin server to start"
while [[ "$status" != "200" ]]
do
  echo "."
  count=$((count+1))
  if [ $count -le 30 ];
  then
      sleep 1m
  else
     echo "Error : Maximum attempts exceeded while starting admin server"
     exit 1
  fi
  status=`curl --insecure -ILs $CHECK_URL | tac | grep -m1 HTTP/1.1 | awk {'print $2'}`
  if [ "$status" == "200" ];
  then
     echo "Admin Server started succesfully..."
     break
  fi
done
}

#This function to wait for packaged domain availability at ${mountpointPath} by checking ${wlsDomainName}-pack.complete
function wait_for_packaged_template()
{
 #wait for packaged domain template to be available
 count=1
 echo "Waiting for packaged domain template availability ${mountpointPath}/${wlsDomainName}-template.jar"
 while [ ! -f ${mountpointPath}/${wlsDomainName}-pack.complete ] 
 do 
 	echo "."
 	count=$((count+1))
 	if [ $count -le 30 ];
 	then
 	  sleep 1m
 	else
 	  echo "Error : Maximum attempts exceeded for waiting packaged domain template ${mountpointPath}/${wlsDomainName}-template.jar"
 	  exit 1
  	fi
 done
} 

# Create systemctl service for nodemanager
function create_nodemanager_service()
{
 echo "Setting CrashRecoveryEnabled true at $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties"
 sed -i.bak -e 's/CrashRecoveryEnabled=false/CrashRecoveryEnabled=true/g'  $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
 sed -i.bak -e 's/ListenAddress=.*/ListenAddress=/g'  $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties

if [ "${isCustomSSLEnabled}" == "true" ];
then
    echo "KeyStores=CustomIdentityAndCustomTrust" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityKeystoreType=${customIdentityKeyStoreType}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityKeyStoreFileName=${customIdentityKeyStoreFileName}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityKeyStorePassPhrase=${customIdentityKeyStorePassPhrase}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityAlias=${serverPrivateKeyAlias}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomIdentityPrivateKeyPassPhrase=${serverPrivateKeyPassPhrase}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomTrustKeystoreType=${customTrustKeyStoreType}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomTrustKeyStoreFileName=${customTrustKeyStoreFileName}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
    echo "CustomTrustKeyStorePassPhrase=${customTrustKeyStorePassPhrase}" >> $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
fi

 if [ $? != 0 ];
 then
   echo "Warning : Failed in setting option CrashRecoveryEnabled=true. Continuing without the option."
   mv $DOMAIN_PATH/nodemanager/nodemanager.properties.bak $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties
 fi
 sudo chown -R $username:$groupname $DOMAIN_PATH/$wlsDomainName/nodemanager/nodemanager.properties*
 echo "Creating NodeManager service"
 # Added waiting for network-online service and restart service 
 cat <<EOF >/etc/systemd/system/wls_nodemanager.service
 [Unit]
Description=WebLogic nodemanager service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Note that the following three parameters should be changed to the correct paths
# on your own system
WorkingDirectory=/u01/domains
Environment="JAVA_OPTIONS=${SERVER_STARTUP_ARGS}"
ExecStart=/bin/bash $DOMAIN_PATH/$wlsDomainName/bin/startNodeManager.sh
ExecStop=/bin/bash $DOMAIN_PATH/$wlsDomainName/bin/stopNodeManager.sh
User=oracle
Group=oracle
KillMode=process
LimitNOFILE=65535
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# This function to create adminserver service
function create_adminserver_service()
{
# Added waiting for network-online service and restart service   
 echo "Creating admin server service"
 cat <<EOF >/etc/systemd/system/wls_admin.service
[Unit]
Description=WebLogic Adminserver service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/u01/domains
Environment="JAVA_OPTIONS=${SERVER_STARTUP_ARGS}"
ExecStart=/bin/bash ${startWebLogicScript}
ExecStop=/bin/bash ${stopWebLogicScript}
User=oracle
Group=oracle
KillMode=process
LimitNOFILE=65535
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

#This function to start managed server
function start_managed()
{
    echo "Starting managed server $wlsServerName"
    cat <<EOF >$DOMAIN_PATH/start-server.py
connect('$wlsUserName','$wlsPassword','$adminWlstURL')
try:
   start('$wlsServerName', 'Server')
except:
   print "Failed starting managed server $wlsServerName"
   dumpStack()
disconnect()
EOF
sudo chown -R $username:$groupname $DOMAIN_PATH
runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/start-server.py"
if [[ $? != 0 ]]; then
  echo "Error : Failed in starting managed server $wlsServerName"
  exit 1
fi
}

# Create managed server setup
function create_managedSetup(){
    echo "Creating Managed Server Setup"

    sudo mkdir -p $DOMAIN_PATH 

    cd $DOMAIN_PATH
   
	# WebLogic base images are already having weblogic-deploy, hence no need to download
    if [ ! -d "$DOMAIN_PATH/weblogic-deploy" ];
    then
        echo "weblogic-deploy tool not found in path $DOMAIN_PATH"
        exit 1
    fi

    echo "Creating managed server model files"
    create_managed_model
    # Following are not requires as it is taken care by create_managed_model applied on existing domain
    #create_machine_model
    #create_ms_server_model
    
    echo "Completed managed server model files"
    sudo chown -R $username:$groupname $DOMAIN_PATH
    # Updating managed-domain.yaml using updateDomain.sh on existing domain created by create_admin_model 
    # wlsPassword is accepted from stdin to support old and new weblogic-deploy tool version
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; $DOMAIN_PATH/weblogic-deploy/bin/updateDomain.sh -admin_url $adminWlstURL -admin_user $wlsUserName -oracle_home $oracleHome -domain_home $DOMAIN_PATH/${wlsDomainName}  -domain_type WLS -model_file $DOMAIN_PATH/managed-domain.yaml <<< $wlsPassword"
    if [[ $? != 0 ]]; then
       echo "Error : Managed setup failed"
       exit 1
    fi
	
	# Following are not required as updateDomain.sh with managed-domain.yaml will take care of following
    #wait_for_admin
    ## For issue https://github.com/wls-eng/arm-oraclelinux-wls/issues/89
    #getSerializedSystemIniFileFromShare
    
    #echo "Adding machine to managed server $wlsServerName"
    #runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/add-machine.py"
    #if [[ $? != 0 ]]; then
         #echo "Error : Adding machine for managed server $wlsServerName failed"
         #exit 1
    #fi
    #echo "Adding managed server $wlsServerName"
    #runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/add-server.py"
    #if [[ $? != 0 ]]; then
         #echo "Error : Adding server $wlsServerName failed"
         #exit 1
    #fi
}

function enabledAndStartNodeManagerService()
{
  sudo systemctl enable wls_nodemanager
  sudo systemctl daemon-reload

  attempt=1
  while [[ $attempt -lt 6 ]]
  do
     echo "Starting nodemanager service attempt $attempt"
     sudo systemctl start wls_nodemanager
     sleep 1m
     attempt=`expr $attempt + 1`
     sudo systemctl status wls_nodemanager | grep running
     if [[ $? == 0 ]];
     then
         echo "wls_nodemanager service started successfully"
	 break
     fi
     sleep 3m
 done
}

function enableAndStartAdminServerService()
{
  sudo systemctl enable wls_admin
  sudo systemctl daemon-reload
  echo "Starting admin server service"
  sudo systemctl start wls_admin

}

function updateNetworkRules()
{
    # for Oracle Linux 7.3, 7.4, iptable is not running.
    if [ -z `command -v firewall-cmd` ]; then
        return 0
    fi
    
    # for Oracle Linux 7.6, open weblogic ports
    tag=$1
    if [ ${tag} == 'admin' ]; then
        echo "update network rules for admin server"
        sudo firewall-cmd --zone=public --add-port=$wlsAdminPort/tcp
        sudo firewall-cmd --zone=public --add-port=$wlsSSLAdminPort/tcp
        sudo firewall-cmd --zone=public --add-port=$wlsManagedPort/tcp
        sudo firewall-cmd --zone=public --add-port=$wlsAdminT3ChannelPort/tcp
        sudo firewall-cmd --zone=public --add-port=$nmPort/tcp
    else
        echo "update network rules for managed server"
        sudo firewall-cmd --zone=public --add-port=$wlsManagedPort/tcp
        sudo firewall-cmd --zone=public --add-port=$nmPort/tcp

        # open ports for coherence
        sudo firewall-cmd --zone=public --add-port=$coherenceListenPort/tcp
        sudo firewall-cmd --zone=public --add-port=$coherenceListenPort/udp
        sudo firewall-cmd --zone=public --add-port=$coherenceLocalport-$coherenceLocalportAdjust/tcp
        sudo firewall-cmd --zone=public --add-port=$coherenceLocalport-$coherenceLocalportAdjust/udp
        sudo firewall-cmd --zone=public --add-port=7/tcp
    fi

    sudo firewall-cmd --runtime-to-permanent
    sudo systemctl restart firewalld
}

# Mount the Azure file share on all VMs created
function mountFileShare()
{
  echo "Creating mount point"
  echo "Mount point: $mountpointPath"
  sudo mkdir -p $mountpointPath
  if [ ! -d "/etc/smbcredentials" ]; then
    sudo mkdir /etc/smbcredentials
  fi
  if [ ! -f "/etc/smbcredentials/${storageAccountName}.cred" ]; then
    echo "Crearing smbcredentials"
    echo "username=$storageAccountName >> /etc/smbcredentials/${storageAccountName}.cred"
    echo "password=$storageAccountKey >> /etc/smbcredentials/${storageAccountName}.cred"
    sudo bash -c "echo "username=$storageAccountName" >> /etc/smbcredentials/${storageAccountName}.cred"
    sudo bash -c "echo "password=$storageAccountKey" >> /etc/smbcredentials/${storageAccountName}.cred"
  fi
  echo "chmod 600 /etc/smbcredentials/${storageAccountName}.cred"
  sudo chmod 600 /etc/smbcredentials/${storageAccountName}.cred
  echo "//${storageAccountPrivateIp}/wlsshare $mountpointPath cifs nofail,vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred,dir_mode=0777,file_mode=0777,serverino"
  sudo bash -c "echo \"//${storageAccountPrivateIp}/wlsshare $mountpointPath cifs nofail,vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred,dir_mode=0777,file_mode=0777,serverino\" >> /etc/fstab"
  echo "mount -t cifs //${storageAccountPrivateIp}/wlsshare $mountpointPath -o vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred,dir_mode=0777,file_mode=0777,serverino"
  sudo mount -t cifs //${storageAccountPrivateIp}/wlsshare $mountpointPath -o vers=2.1,credentials=/etc/smbcredentials/${storageAccountName}.cred,dir_mode=0777,file_mode=0777,serverino
  if [[ $? != 0 ]];
  then
         echo "Failed to mount //${storageAccountPrivateIp}/wlsshare $mountpointPath"
	 exit 1
  fi
}

function validateSSLKeyStores()
{
   sudo chown -R $username:$groupname $KEYSTORE_PATH

   #validate identity keystore
   runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $customIdentityKeyStoreFileName -storepass $customIdentityKeyStorePassPhrase -storetype $customIdentityKeyStoreType | grep 'Entry type:' | grep 'PrivateKeyEntry'"

   if [[ $? != 0 ]]; then
       echo "Error : Identity Keystore Validation Failed !!"
       exit 1
   fi

   # Verify Identity keystore validity period more than MIN_CERT_VALIDITY
   verifyCertValidity $customIdentityKeyStoreFileName $customIdentityKeyStorePassPhrase $CURRENT_DATE $MIN_CERT_VALIDITY $customIdentityKeyStoreType

   #validate Trust keystore
   runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; keytool -list -v -keystore $customTrustKeyStoreFileName -storepass $customTrustKeyStorePassPhrase -storetype $customTrustKeyStoreType | grep 'Entry type:' | grep 'trustedCertEntry'"

   if [[ $? != 0 ]]; then
       echo "Error : Trust Keystore Validation Failed !!"
       exit 1
   fi

   # Verify Identity keystore validity period more than MIN_CERT_VALIDITY
   verifyCertValidity $customTrustKeyStoreFileName $customTrustKeyStorePassPhrase $CURRENT_DATE $MIN_CERT_VALIDITY $customTrustKeyStoreType

   echo "ValidateSSLKeyStores Successfull !!"
}

function storeCustomSSLCerts()
{
    if [ "${isCustomSSLEnabled}" == "true" ];
    then

        mkdir -p $KEYSTORE_PATH

        echo "Custom SSL is enabled. Storing CertInfo as files..."
        customIdentityKeyStoreFileName="$KEYSTORE_PATH/identity.keystore"
        customTrustKeyStoreFileName="$KEYSTORE_PATH/trust.keystore"

        customIdentityKeyStoreData=$(echo "$customIdentityKeyStoreData" | base64 --decode)
        customIdentityKeyStorePassPhrase=$(echo "$customIdentityKeyStorePassPhrase" | base64 --decode)
        customIdentityKeyStoreType=$(echo "$customIdentityKeyStoreType" | base64 --decode)

        customTrustKeyStoreData=$(echo "$customTrustKeyStoreData" | base64 --decode)
        customTrustKeyStorePassPhrase=$(echo "$customTrustKeyStorePassPhrase" | base64 --decode)
        customTrustKeyStoreType=$(echo "$customTrustKeyStoreType" | base64 --decode)

        serverPrivateKeyAlias=$(echo "$serverPrivateKeyAlias" | base64 --decode)
        serverPrivateKeyPassPhrase=$(echo "$serverPrivateKeyPassPhrase" | base64 --decode)

        #decode cert data once again as it would got base64 encoded while  storing in azure keyvault
        echo "$customIdentityKeyStoreData" | base64 --decode > $customIdentityKeyStoreFileName
        echo "$customTrustKeyStoreData" | base64 --decode > $customTrustKeyStoreFileName

        validateSSLKeyStores

    else
        echo "Custom SSL is not enabled"
    fi
}

# Copy SerializedSystemIni.dat file from admin server vm to share point
function copySerializedSystemIniFileToShare()
{
  runuser -l oracle -c "cp ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat ${mountpointPath}/."
  ls -lt ${mountpointPath}/SerializedSystemIni.dat
  if [[ $? != 0 ]]; 
  then
      echo "Failed to copy ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat"
      exit 1
  fi
}

# Get SerializedSystemIni.dat file from share point to managed server vm
function getSerializedSystemIniFileFromShare()
{
  runuser -l oracle -c "mv ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat.backup"
  runuser -l oracle -c "cp ${mountpointPath}/SerializedSystemIni.dat ${DOMAIN_PATH}/${wlsDomainName}/security/."
  ls -lt ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat
  if [[ $? != 0 ]]; 
  then
      echo "Failed to get ${mountpointPath}/SerializedSystemIni.dat"
      exit 1
  fi
  runuser -l oracle -c "chmod 640 ${DOMAIN_PATH}/${wlsDomainName}/security/SerializedSystemIni.dat"
}


# Create custom stopWebLogic script and add it to wls_admin service
# This script is created as stopWebLogic.sh will not work if non ssl admin listening port 7001 is disabled
# Refer https://github.com/wls-eng/arm-oraclelinux-wls/issues/164 
function createStopWebLogicScript()
{

cat <<EOF >${stopWebLogicScript}
#!/bin/sh
# This is custom script for stopping weblogic server using ADMIN_URL supplied
ADMIN_URL="t3://${wlsAdminURL}"
${DOMAIN_PATH}/${wlsDomainName}/bin/stopWebLogic.sh
EOF

sudo chown -R $username:$groupname ${stopWebLogicScript}
sudo chmod -R 750 ${stopWebLogicScript}

}

#this function set the umask 027 (chmod 740) as required by WebLogic security checks
function setUMaskForSecurityDir()
{
   echo "setting umask 027 (chmod 740) for domain/$wlsServerName security directory"

   if [ -f "$DOMAIN_PATH/$wlsDomainName/servers/$wlsServerName/security/boot.properties" ];
   then
      runuser -l oracle -c "chmod 740 $DOMAIN_PATH/$wlsDomainName/servers/$wlsServerName/security/boot.properties"
   fi

   if [ -d "$DOMAIN_PATH/$wlsDomainName/servers/$wlsServerName/security" ];
   then
       runuser -l oracle -c "chmod 740 $DOMAIN_PATH/$wlsDomainName/servers/$wlsServerName/security"
   fi
}

#this function checks if remote Anonymous T3/RMI Attributes are available as part of domain security configuration
function containsRemoteAnonymousT3RMIIAttribs()
{
    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; $DOMAIN_PATH/weblogic-deploy/bin/modelHelp.sh -oracle_home $oracleHome topology:/SecurityConfiguration | grep RemoteAnonymousRmiiiopEnabled" >> /dev/null

    result1=$?

    runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; $DOMAIN_PATH/weblogic-deploy/bin/modelHelp.sh -oracle_home $oracleHome topology:/SecurityConfiguration | grep RemoteAnonymousRmit3Enabled" >> /dev/null

    result2=$?

    if [ $result1 == 0 ] && [ $result2 == 0 ]; then
      echo "true"
    else
      echo "false"
    fi
}


function generateCustomHostNameVerifier()
{
   mkdir -p ${CUSTOM_HOSTNAME_VERIFIER_HOME}
   mkdir -p ${CUSTOM_HOSTNAME_VERIFIER_HOME}/src/main/java
   mkdir -p ${CUSTOM_HOSTNAME_VERIFIER_HOME}/src/test/java
   cp ${BASE_DIR}/generateCustomHostNameVerifier.sh ${CUSTOM_HOSTNAME_VERIFIER_HOME}/generateCustomHostNameVerifier.sh
   cp ${BASE_DIR}/WebLogicCustomHostNameVerifier.java ${CUSTOM_HOSTNAME_VERIFIER_HOME}/src/main/java/WebLogicCustomHostNameVerifier.java
   cp ${BASE_DIR}/HostNameValuesTemplate.txt ${CUSTOM_HOSTNAME_VERIFIER_HOME}/src/main/java/HostNameValuesTemplate.txt
   cp ${BASE_DIR}/WebLogicCustomHostNameVerifierTest.java ${CUSTOM_HOSTNAME_VERIFIER_HOME}/src/test/java/WebLogicCustomHostNameVerifierTest.java
   chown -R $username:$groupname ${CUSTOM_HOSTNAME_VERIFIER_HOME}
   chmod +x ${CUSTOM_HOSTNAME_VERIFIER_HOME}/generateCustomHostNameVerifier.sh

   runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; ${CUSTOM_HOSTNAME_VERIFIER_HOME}/generateCustomHostNameVerifier.sh ${wlsAdminHost} ${customDNSNameForAdminServer} ${customDNSNameForAdminServer} ${dnsLabelPrefix} ${wlsDomainName} ${location} ${adminVMNamePrefix} ${globalResourceNameSuffix} false"
}

function copyCustomHostNameVerifierJarsToWebLogicClasspath()
{
   runuser -l oracle -c "cp ${CUSTOM_HOSTNAME_VERIFIER_HOME}/output/*.jar $oracleHome/wlserver/server/lib/;"

   echo "Modify WLS CLASSPATH to include hostname verifier jars...."
   sed -i 's;^WEBLOGIC_CLASSPATH="${WL_HOME}/server/lib/postgresql.*;&\nWEBLOGIC_CLASSPATH="${WL_HOME}/server/lib/hostnamevalues.jar:${WL_HOME}/server/lib/weblogicustomhostnameverifier.jar:${WEBLOGIC_CLASSPATH}";' $oracleHome/oracle_common/common/bin/commExtEnv.sh
   echo "Modified WLS CLASSPATH to include hostname verifier jars."
}


function configureCustomHostNameVerifier()
{
    echo "configureCustomHostNameVerifier for domain  $wlsDomainName for server $wlsServerName"
    cat <<EOF >$DOMAIN_PATH/configureCustomHostNameVerifier.py
connect('$wlsUserName','$wlsPassword','t3://$wlsAdminURL')
try:
    edit("$wlsServerName")
    startEdit()

    cd('/Servers/$wlsServerName/SSL/$wlsServerName')
    cmo.setHostnameVerifier('com.oracle.azure.weblogic.security.util.WebLogicCustomHostNameVerifier')
    cmo.setHostnameVerificationIgnored(false)
    cmo.setTwoWaySSLEnabled(false)
    cmo.setClientCertificateEnforced(false)

    save()
    activate()
except Exception,e:
    print e
    print "Failed to configureCustomHostNameVerifier for domain  $wlsDomainName"
    dumpStack()
    raise Exception('Failed to configureCustomHostNameVerifier for domain  $wlsDomainName')
disconnect()
EOF
sudo chown -R $username:$groupname $DOMAIN_PATH
runuser -l oracle -c ". $oracleHome/oracle_common/common/bin/setWlstEnv.sh; java $WLST_ARGS weblogic.WLST $DOMAIN_PATH/configureCustomHostNameVerifier.py"
if [[ $? != 0 ]]; then
  echo "Error : Failed to configureCustomHostNameVerifier for domain $wlsDomainName"
  exit 1
fi

}

function restartAdminServer()
{
   echo "Stopping WebLogic Admin Server..."
   systemctl stop wls_admin
   sleep 2m
   systemctl start wls_admin
   echo "Starting WebLogic Admin Server..."
}

function packDomain()
{
	echo "Stopping WebLogic nodemanager ..."
	sudo systemctl stop wls_nodemanager
	echo "Stopping WebLogic Admin Server..."
	sudo systemctl stop wls_admin
	sleep 2m
	echo "Packing the cluster domain"
	runuser -l oracle -c "$oracleHome/oracle_common/common/bin/pack.sh -domain=${DOMAIN_PATH}/${wlsDomainName} -template=${mountpointPath}/${wlsDomainName}-template.jar -template_name=\"${wlsDomainName} domain\" -template_desc=\"WebLogic cluster domain\" -managed=true"
	if [[ $? != 0 ]]; then
  		echo "Error : Failed to pack the domain $wlsDomainName"
  		exit 1
	fi
	echo "Starting WebLogic nodemanager ..."
	sudo systemctl start wls_nodemanager
	echo "Starting WebLogic Admin Server..."
	sudo systemctl start wls_admin
	touch ${mountpointPath}/${wlsDomainName}-pack.complete
}

function unpackDomain()
{
	echo "Unpacking the domain"
	runuser -l oracle -c "$oracleHome/oracle_common/common/bin/unpack.sh -template=${mountpointPath}/${wlsDomainName}-template.jar -domain=${DOMAIN_PATH}/${wlsDomainName}"
	if [[ $? != 0 ]]; then
  		echo "Error : Failed to unpack the domain $wlsDomainName"
  		exit 1
	fi
}

#main script starts here

CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR="$(readlink -f ${CURR_DIR})"

# Used for certificate expiry validation
CURRENT_DATE=`date +%s`
# Supplied certificate to have minimum days validity for the deployment
# In this case set for 1 day
MIN_CERT_VALIDITY="1"

#read arguments from stdin
read wlsDomainName wlsUserName wlsPassword wlsServerName wlsAdminHost adminVMNamePrefix globalResourceNameSuffix numberOfInstances managedVMPrefix managedServerPrefix oracleHome storageAccountName storageAccountKey mountpointPath isHTTPAdminListenPortEnabled isCustomSSLEnabled customDNSNameForAdminServer dnsLabelPrefix location virtualNetworkNewOrExisting storageAccountPrivateIp customIdentityKeyStoreData customIdentityKeyStorePassPhrase customIdentityKeyStoreType customTrustKeyStoreData customTrustKeyStorePassPhrase customTrustKeyStoreType serverPrivateKeyAlias serverPrivateKeyPassPhrase

isHTTPAdminListenPortEnabled="${isHTTPAdminListenPortEnabled,,}"
isCustomSSLEnabled="${isCustomSSLEnabled,,}"

if [ "${isCustomSSLEnabled}" != "true" ];
then
    isCustomSSLEnabled="false"
fi

validateInput

coherenceListenPort=7574
coherenceLocalport=42000
coherenceLocalportAdjust=42200
wlsAdminPort=7001
wlsSSLAdminPort=7002
wlsAdminT3ChannelPort=7005
wlsManagedPort=8001

DOMAIN_PATH="/u01/domains"
CUSTOM_HOSTNAME_VERIFIER_HOME="/u01/app/custom-hostname-verifier"
startWebLogicScript="${DOMAIN_PATH}/${wlsDomainName}/startWebLogic.sh"
stopWebLogicScript="${DOMAIN_PATH}/${wlsDomainName}/bin/customStopWebLogic.sh"
SERVER_STARTUP_ARGS="-Dlog4j2.formatMsgNoLookups=true"

wlsAdminURL="$wlsAdminHost:$wlsAdminT3ChannelPort"
SERVER_START_URL="http://$wlsAdminURL"

# Unpack requires domain directory to be empty, hence creating outside the domain
KEYSTORE_PATH="${DOMAIN_PATH}/keystores"

if [ "${isCustomSSLEnabled}" == "true" ];
then
   SERVER_START_URL="https://$wlsAdminHost:$wlsSSLAdminPort"
fi

CHECK_URL="http://$wlsAdminURL/weblogic/ready"
adminWlstURL="t3://$wlsAdminURL"

wlsClusterName="cluster1"
nmHost=`hostname`
nmPort=5556

SCRIPT_PWD=`pwd`
username="oracle"
groupname="oracle"

cleanup

# Executing this function first just to make sure certificate errors are first caught
storeCustomSSLCerts

installUtilities
mountFileShare

if [ $wlsServerName == "admin" ];
then
  updateNetworkRules "admin"
  create_adminSetup
  createStopWebLogicScript
  create_nodemanager_service
  admin_boot_setup
  generateCustomHostNameVerifier
  copyCustomHostNameVerifierJarsToWebLogicClasspath
  setUMaskForSecurityDir
  create_adminserver_service
  enabledAndStartNodeManagerService
  enableAndStartAdminServerService
  wait_for_admin
  configureCustomHostNameVerifier
  # Create managed server configuration counting from 1 to number of instances
  countManagedServer=1
  while [ $countManagedServer -lt $numberOfInstances ]
  do
    managedServerHost=${managedVMPrefix}${countManagedServer}
    wlsServerName=${managedServerPrefix}${countManagedServer}
    echo "Configuring managed server ${wlsServerName} for host ${managedServerHost}"
    create_managedSetup
    countManagedServer=`expr $countManagedServer + 1`
  done
  # After domain is created pack the domain and keep it under mountFileShare location
  packDomain
else
  # Wait for admin host pack the domain and place the template under mountFileShare location	
  wait_for_packaged_template
  updateNetworkRules "managed"
  # unpack the domain from the template under mountFileShare location	
  unpackDomain
  generateCustomHostNameVerifier
  copyCustomHostNameVerifierJarsToWebLogicClasspath
  setUMaskForSecurityDir
  create_nodemanager_service
  enabledAndStartNodeManagerService
  wait_for_admin
  configureCustomHostNameVerifier
  start_managed
fi

cleanup
