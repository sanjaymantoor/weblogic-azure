#!/bin/bash

# Copyright (c) 2021, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.
# Description
# This scipt is to deploy the Azure deployments based on test parameters created.

#read arguments from stdin
read prefix location template repoPath testbranchName scriptsDir

groupName=${prefix}-preflight
certDataName=certData
certPasswordName=certPassword

# create Azure resources for preflight testing
az group create --verbose --name $groupName --location ${location}

# generate parameters for testing differnt cases
parametersList=()
# parameters for cluster
bash ${scriptsDir}/gen-parameters.sh <<< "${scriptsDir}/parameters.json $repoPath $testbranchName"
parametersList+=(${scriptsDir}/parameters.json)

# parameters for cluster+db
bash ${scriptsDir}/gen-parameters-db.sh <<< "${scriptsDir}/parameters-db.json $repoPath $testbranchName"
parametersList+=(${scriptsDir}/parameters-db.json)

# parameters for cluster+coherence
bash ${scriptsDir}/gen-parameters-coherence.sh <<< "${scriptsDir}/parameters-coherence.json $repoPath $testbranchName"
parametersList+=(${scriptsDir}/parameters-coherence.json)

# parameters for cluster+ag
bash ${scriptsDir}/gen-parameters-ag.sh <<< "${scriptsDir}/parameters-ag.json $repoPath $testbranchName"
parametersList+=(${scriptsDir}/parameters-ag.json)

# parameters for cluster+db+ag
bash ${scriptsDir}/gen-parameters-db-ag.sh <<< "${scriptsDir}/parameters-db-ag.json $repoPath $testbranchName"
parametersList+=(${scriptsDir}/parameters-db-ag.json)

# run preflight tests
success=true
for parameters in "${parametersList[@]}";
do
    echo "Validating deployment for ${parameters}"
    az deployment group validate -g ${groupName} -f ${template} -p @${parameters} --no-prompt
    if [[ $? != 0 ]]; then
        echo "deployment validation for ${parameters} failed!"
        success=false
    fi
done

# release Azure resources
az group delete --yes --no-wait --verbose --name $groupName

if [[ $success == "false" ]]; then
    exit 1
else
    exit 0
fi
