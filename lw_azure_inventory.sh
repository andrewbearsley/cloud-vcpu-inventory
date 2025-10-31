#!/bin/bash

# Script to fetch Azure inventory for Lacework sizing.
# Requirements: az cli, jq, cut, grep

# This script can be run from Azure Cloud Shell.
# Run ./lw_azure_inventory.sh -h for help on how to run the script.
# Or just read the text in showHelp below.

function showHelp {
  echo "lw_azure_inventory.sh is a tool for estimating license vCPUs in an Azure environment, based on"
  echo "subscription or management group level. It leverages the az CLI and by default analyzes all"
  echo "subscriptions a user has access to. The script provides output in a CSV format to be imported"
  echo "into a spreadsheet, as well as an easy-to-read summary."
  echo ""
  echo "By default, the script will scan all subscriptions returned by the following command:"
  echo "az account subscription list"
  echo ""
  echo "Note the following about the script:"
  echo "* Works great in a cloud shell"
  echo "* It has been verified to work on Mac and Linux based systems"
  echo "* Has been observed to work with Windows Subsystem for Linux to run on Windows"
  echo "* Run using the following syntax: ./lw_azure_inventory.sh, sh lw_azure_inventory.sh will not work"
  echo ""
  echo "Available flags:"
  echo " -s       Comma separated list of Azure subscriptions to scan."
  echo "          ./lw_azure_inventory.sh -p subscription-1,subscription-2"
  echo " -m       Comma separated list of Azure management groups to scan."
  echo "          ./lw_azure_inventory.sh -m 1234,456"
  echo " -v       Enable verbose/debug mode"
  echo "          Shows detailed information about Azure API calls, subscriptions being scanned, and progress"
  echo "          ./lw_azure_inventory.sh -v"
  echo "          ./lw_azure_inventory.sh --verbose"
}

#Ensure the script runs with the BASH shell
echo $BASH | grep -q "bash"
if [ $? -ne 0 ]
then
  echo The script is running using the incorrect shell.
  echo Use ./lw_azure_inventory.sh to run the script using the required shell, bash.
  exit
fi

set -o errexit
set -o pipefail

VERBOSE="false"

while getopts ":m:s:-:v" opt; do
  case ${opt} in
    s )
      SUBSCRIPTION=$OPTARG
      ;;
    m )
      MANAGEMENT_GROUP=$OPTARG
      ;;
    v )
      VERBOSE="true"
      ;;
    -)
      case "${OPTARG}" in
        verbose)
          VERBOSE="true"
          ;;
        *)
          showHelp
          exit
          ;;
      esac;;
    \? )
      showHelp
      exit 1
      ;;
    : )
      showHelp
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

function verbose {
  if [[ $VERBOSE == "true" ]]
  then
    echo "[DEBUG] $1" >&2
  fi
}

function removeMap {
  if [[ -f "./tmp_map" ]]; then
    rm ./tmp_map
  fi
}

function installExtensions {
  verbose "Checking for required Azure CLI extensions..."
  resourceGraphPresent=$(az extension list -o json  --query "contains([].name, \`resource-graph\`)")
  if [ "$resourceGraphPresent" != true ] ; then
    verbose "Resource-graph extension not present, enabling..."
    echo "Resource-graph extension not present in Az CLI installation. Enabling..."
    az extension add --name "resource-graph"
  else
    verbose "Resource-graph extension already present"
    echo "Resource-graph extension already present..."
  fi
  accountPresent=$(az extension list -o json  --query "contains([].name, \`account\`)")
  if [ "$accountPresent" != true ] ; then
    verbose "Account extension not present, enabling..."
    echo "Account extension not present in Az CLI installation. Enabling..."
    az extension add --name "account"
  else
    verbose "Account extension already present"
    echo "Account extension already present..."
  fi
}

# set trap to remove tmp_map file regardless of exit status
trap removeMap EXIT


# Set the initial counts to zero.
AZURE_VMS_VCPU=0
AZURE_VMS_COUNT=0
AZURE_VMSS_VCPU=0
AZURE_VMSS_VM_COUNT=0
AZURE_VMSS_COUNT=0

if [[ $VERBOSE == "true" ]]
then
  verbose "Starting Azure inventory analysis..."
  verbose "Verbose mode enabled"
  verbose "Azure CLI version: $(az version 2>&1 | head -1)"
  if [ -n "$SUBSCRIPTION" ]
  then
    verbose "Subscriptions specified: $SUBSCRIPTION"
  elif [ -n "$MANAGEMENT_GROUP" ]
  then
    verbose "Management groups specified: $MANAGEMENT_GROUP"
  else
    verbose "No specific scope specified, will scan all accessible subscriptions"
  fi
  verbose ""
fi

installExtensions

verbose "Building Azure VM SKU to vCPU map..."
echo "Building Azure VM SKU to vCPU map..."
cmd="az vm list-skus --resource-type virtualmachines -o json"
verbose "Command: $cmd"
az vm list-skus --resource-type virtualmachines -o json |\
  jq -r '.[] | .name as $parent | select(.capabilities != null) | .capabilities[] | select(.name == "vCPUs") | $parent+":"+.value' |\
  sort | uniq > ./tmp_map
mapSize=$(wc -l < ./tmp_map | xargs)
verbose "Map built successfully with $mapSize SKU entries"
echo "Map built successfully."
###################################

function runSubscriptionAnalysis {
  local subscriptionId=$1
  local subscriptionName=$2
  local vms=$3
  local vmss=$4
  local subscriptionVmVcpu=0
  local subscriptionVmCount=0
  local subscriptionVmssVcpu=0
  local subscriptionVmssVmCount=0
  local subscriptionVmssCount=0

  verbose ""
  verbose "=========================================="
  verbose "Analyzing subscription: $subscriptionId${subscriptionName:+ ($subscriptionName)}"
  verbose "=========================================="
  
  # tally up VM vCPU 
  verbose "Processing VMs..."
  local VM_LINES=$(echo $vms | jq -r --arg subscriptionId "$subscriptionId" '.data[] | select(.subscriptionId==$subscriptionId) | select(.powerState=="PowerState/running") | .sku')
  if [[ ! -z $VM_LINES ]]
  then
    local vmCount=$(echo "$VM_LINES" | grep -v '^$' | wc -l | xargs)
    verbose "Found $vmCount running VM(s)"
    while read i; do
      # lookup the vCPU in the map, extract the value
      local vCPU=$(grep $i: ./tmp_map | cut -d: -f2)
      if [[ ! -z $vCPU ]]
      then
        verbose "  VM SKU $i: $vCPU vCPUs"
        subscriptionVmCount=$(($subscriptionVmCount + 1))
        subscriptionVmVcpu=$(($subscriptionVmVcpu + $vCPU))
      else
        verbose "  WARNING: Could not find vCPU mapping for SKU $i"
      fi
    done <<< "$VM_LINES"
    verbose "Subscription VM summary: $subscriptionVmCount VMs, $subscriptionVmVcpu vCPUs"
  else
    verbose "No running VMs found in subscription"
  fi

  # tally up VMSS vCPU -- using a here string to populate the while loop
  verbose "Processing VM Scale Sets..."
  local VMSS_LINES=$(echo $vmss | jq -r --arg subscriptionId "$subscriptionId" '.data[] | select(.subscriptionId==$subscriptionId) | .sku+":"+(.capacity|tostring)')
  if [[ ! -z $VMSS_LINES ]]
  then
    local vmssCount=$(echo "$VMSS_LINES" | grep -v '^$' | wc -l | xargs)
    verbose "Found $vmssCount VM Scale Set(s)"
    while read i; do
      local sku=$(echo $i | cut -d: -f1)
      local capacity=$(echo $i | cut -d: -f2)

      local vCPU=$(grep $sku: ./tmp_map | cut -d: -f2)
      if [[ ! -z $vCPU ]]
      then
        local total_vCPU=$(($vCPU * $capacity))
        verbose "  VMSS SKU $sku: $vCPU vCPUs per instance, capacity $capacity, total $total_vCPU vCPUs"

        subscriptionVmssVcpu=$(($subscriptionVmssVcpu + $total_vCPU))
        subscriptionVmssVmCount=$(($subscriptionVmssVmCount + $capacity))
        subscriptionVmssCount=$(($subscriptionVmssCount + 1))
      else
        verbose "  WARNING: Could not find vCPU mapping for VMSS SKU $sku"
      fi
    done <<< "$VMSS_LINES"
    verbose "Subscription VMSS summary: $subscriptionVmssCount scale sets, $subscriptionVmssVmCount instances, $subscriptionVmssVcpu vCPUs"
  else
    verbose "No VM Scale Sets found in subscription"
  fi
  
  verbose "Subscription $subscriptionId total: VMs=$subscriptionVmCount ($subscriptionVmVcpu vCPUs), VMSS=$subscriptionVmssCount scale sets with $subscriptionVmssVmCount instances ($subscriptionVmssVcpu vCPUs), Total=$(($subscriptionVmVcpu + $subscriptionVmssVcpu)) vCPUs"

  AZURE_VMS_COUNT=$(($AZURE_VMS_COUNT + $subscriptionVmCount))
  AZURE_VMS_VCPU=$(($AZURE_VMS_VCPU + $subscriptionVmVcpu))
  AZURE_VMSS_VCPU=$(($AZURE_VMSS_VCPU + $subscriptionVmssVcpu))
  AZURE_VMSS_VM_COUNT=$(($AZURE_VMSS_VM_COUNT + $subscriptionVmssVmCount))
  AZURE_VMSS_COUNT=$(($AZURE_VMSS_COUNT + $subscriptionVmssCount))

  echo "\"$subscriptionId\", \"$subscriptionName\", $subscriptionVmCount, $subscriptionVmVcpu, $subscriptionVmssCount, $subscriptionVmssVmCount, $subscriptionVmssVcpu, $(($subscriptionVmVcpu + $subscriptionVmssVcpu))"
}

function runAnalysis {
  local scope=$1
  verbose ""
  verbose "=========================================="
  verbose "Running analysis with scope: $scope"
  verbose "=========================================="
  
  verbose "Loading subscriptions..."
  echo Load subscriptions
  local cmd="az graph query -q \"resourcecontainers | where type == 'microsoft.resources/subscriptions' | project name, subscriptionId\" $scope -o json"
  verbose "Command: $cmd"
  local expectedSubscriptions=$(az graph query -q "resourcecontainers | where type == 'microsoft.resources/subscriptions' | project name, subscriptionId" $scope  -o json)
  local expectedSubscriptionIds=$(echo $expectedSubscriptions | jq -r '.data[] | .subscriptionId' | sort)
  local expectedCount=$(echo "$expectedSubscriptions" | jq '.data | length')
  verbose "Found $expectedCount expected subscription(s)"
  
  verbose "Loading VMs..."
  echo Load VMs
  local cmd="az graph query -q \"Resources | where type=~'microsoft.compute/virtualmachines' | project subscriptionId, name, sku=properties.hardwareProfile.vmSize, powerState=properties.extended.instanceView.powerState.code\" $scope -o json"
  verbose "Command: $cmd"
  local vms=$(az graph query -q "Resources | where type=~'microsoft.compute/virtualmachines' | project subscriptionId, name, sku=properties.hardwareProfile.vmSize, powerState=properties.extended.instanceView.powerState.code" $scope  -o json)
  local vmCount=$(echo "$vms" | jq '.data | length')
  verbose "Found $vmCount VM resource(s)"
  
  verbose "Loading VM Scale Sets..."
  echo Load VMSS
  local cmd="az graph query -q \"Resources | where type=~ 'microsoft.compute/virtualmachinescalesets' | project subscriptionId, name, sku=sku.name, capacity = toint(sku.capacity)\" $scope -o json"
  verbose "Command: $cmd"
  local vmss=$(az graph query -q "Resources | where type=~ 'microsoft.compute/virtualmachinescalesets' | project subscriptionId, name, sku=sku.name, capacity = toint(sku.capacity)" $scope -o json)
  local vmssCount=$(echo "$vmss" | jq '.data | length')
  verbose "Found $vmssCount VM Scale Set resource(s)"

  local actualSubscriptionIds=$(echo $vms | jq -r '.data[] | .subscriptionId' | sort | uniq)
  local actualCount=$(echo "$actualSubscriptionIds" | grep -v '^$' | wc -l | xargs)
  verbose "Found $actualCount subscription(s) with VM resources"
  verbose ""

  echo '"Subscription ID", "Subscription Name", "VM Instances", "VM vCPUs", "VM Scale Sets", "VM Scale Set Instances", "VM Scale Set vCPUs", "Total Subscription vCPUs"'

  #First analyze data for all subscriptions we didn't expect to find
  verbose "Analyzing subscriptions with resources but not in expected list..."
  for actualSubscriptionId in $actualSubscriptionIds
  do
    local foundSubscriptionId=$(echo $expectedSubscriptions | jq -r  --arg subscriptionId "$actualSubscriptionId" '.data[] | select(.subscriptionId==$subscriptionId) | .subscriptionId')
    if [ "$actualSubscriptionId" != "$foundSubscriptionId" ]; then
      verbose "Found unexpected subscription: $actualSubscriptionId"
      runSubscriptionAnalysis $actualSubscriptionId "" "$vms" "$vmss"
    fi
  done

  # Go through all results, sorted by all subscriptions we'd expect to find
  verbose "Analyzing expected subscriptions..."
  for expectedSubscriptionId in $expectedSubscriptionIds
  do
    local subscriptionName=$(echo $expectedSubscriptions | jq -r  --arg subscriptionId "$expectedSubscriptionId" '.data[] | select(.subscriptionId==$subscriptionId) | .name')
    runSubscriptionAnalysis $expectedSubscriptionId "$subscriptionName" "$vms" "$vmss"
  done
}


# Management group takes precedence...partial scopes ALLOWED
if [[ ! -z "$MANAGEMENT_GROUP" ]]; then
  verbose "Using management group scope: $MANAGEMENT_GROUP"
  runAnalysis "--management-groups ${MANAGEMENT_GROUP//,/ }"
elif [[ ! -z "$SUBSCRIPTION" ]]; then
  verbose "Using subscription scope: $SUBSCRIPTION"
  runAnalysis "--subscriptions ${SUBSCRIPTION//,/ }"
else
  echo "Load all subscriptions available to user"
  verbose "No specific scope specified, retrieving all accessible subscriptions..."
  cmd="az account subscription list -o json"
  verbose "Command: $cmd"
  subscriptions=$(az account subscription list -o json | jq -r '.[] | .subscriptionId')
  subCount=$(echo "$subscriptions" | grep -v '^$' | wc -l | xargs)
  verbose "Found $subCount accessible subscription(s)"
  runAnalysis "--subscriptions $subscriptions"
fi

verbose ""
verbose "Analysis complete. Final summary:"
verbose "  Total VM Instances: $AZURE_VMS_COUNT"
verbose "  Total VM vCPUs: $AZURE_VMS_VCPU"
verbose "  Total VM Scale Sets: $AZURE_VMSS_COUNT"
verbose "  Total VMSS Instances: $AZURE_VMSS_VM_COUNT"
verbose "  Total VMSS vCPUs: $AZURE_VMSS_VCPU"
verbose "  Grand Total vCPUs: $(($AZURE_VMS_VCPU + $AZURE_VMSS_VCPU))"

echo "##########################################"
echo "Lacework inventory collection complete."
echo ""
echo "VM Summary:"
echo "==============================="
echo "VM Instances:     $AZURE_VMS_COUNT"
echo "VM vCPUS:         $AZURE_VMS_VCPU"
echo ""
echo "VM Scale Set Summary:"
echo "==============================="
echo "VM Scale Sets:          $AZURE_VMSS_COUNT"
echo "VM Scale Set Instances: $AZURE_VMSS_VM_COUNT"
echo "VM Scale Set vCPUs:     $AZURE_VMSS_VCPU"
echo ""
echo "License Summary"
echo "==============================="
echo "  VM vCPUS:             $AZURE_VMS_VCPU"
echo "+ VM Scale Set vCPUs:   $AZURE_VMSS_VCPU"
echo "-------------------------------"
echo "Total vCPUs:            $(($AZURE_VMS_VCPU + $AZURE_VMSS_VCPU))"
