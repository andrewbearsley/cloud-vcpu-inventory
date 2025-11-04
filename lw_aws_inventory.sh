#!/bin/bash
# Script to fetch AWS inventory for Lacework sizing.
# Requirements: awscli v2, jq

# Run ./lw_aws_inventory.sh -h for help on how to run the script.
# Or just read the text in showHelp below.

function showHelp {
  echo "lw_aws_inventory.sh is a tool for estimating Lacework license vCPUs in an AWS environment."
  echo "It leverages the AWS CLI and by default the default profile that’s either configured using"
  echo "environment variables or configuration files in the ~/.aws folder. The script provides"
  echo "output in a CSV format to be imported into a spreadsheet, as well as an easy-to-read summary."
  echo ""
  echo "Note the following about the script:"
  echo "* Requires AWS CLI v2 to run"
  echo "* Works great in a cloud shell"
  echo "* It has been verified to work on Mac and Linux based systems"
  echo "* Has been observed to work with Windows Subsystem for Linux to run on Windows"
  echo "* Not compatible with Cygwin on Windows"
  echo "* Run using the following syntax: ./lw_aws_inventory.sh, sh lw_aws_inventory.sh will not work"
  echo ""
  echo "Available flags:"
  echo " -p       Comma separated list of AWS CLI profiles to scan."
  echo "          If not specified, the tool will use the connection information that the AWS CLI picks"
  echo "          by default, which will either be whatever is set in environment variables or as the"
  echo "          default profile."
  echo "          ./lw_aws_inventory.sh -p default"
  echo "          ./lw_aws_inventory.sh -p development,test,production"
  echo " -r       Comma-separated list of regions to scan."
  echo "          By default, the script will attempt to collect sizing data for all regions returned by"
  echo "          aws ec2 describe-regions. This is by default a list of 17 regions. This parameter will"
  echo "          limit the scope to a pre-defined set of regions, which will avoid errors when regions"
  echo "          are disabled and speed up the scan."
  echo "          ./lw_aws_inventory.sh -r us-east-1"
  echo "          ./lw_aws_inventory.sh -r us-east-1,us-west-1"
  echo " -o       Scan a complete AWS organization"
  echo "          This uses aws organizations list-accounts to determine what accounts are in an"
  echo "          organization and assumes a cross account role to scan each account in the organization,"
  echo "          except for the master account, which is scanned directly."
  echo "          The role typically used cross-account access is OrganizationAccountAccessRole, which"
  echo "          is accessed from a user in the master account."
  echo "          ./lw_aws_inventory.sh -o OrganizationAccountAccessRole"
  echo " -a       Scan a specific account within an organization"
  echo "          This would leverage the cross-account role defined using the -o parameter to only"
  echo "          scan an individual account within an AWS organisation."
  echo "          ./lw_aws_inventory.sh -o OrganizationAccountAccessRole -a 1234567890"
  echo " -g       Specifies a script to be generated that contains a call for each account to be analyzed."
  echo "          This is useful for analyzing AWS organizations with many accounts to break up the analysis"
  echo "          into smaller chunks."
  echo "          ./lw_aws_inventory.sh -o OrganizationAccountAccessRole -a 1234567890 -g script.sh"
  echo "          ./script.sh"
  echo " -v       Enable verbose/debug mode"
  echo "          Shows detailed information about AWS API calls, regions being scanned, and progress"
  echo "          ./lw_aws_inventory.sh -v"
  echo "          ./lw_aws_inventory.sh --verbose"
  echo " --output Specify level of output"
  echo "          all         - CSV and summary"
  echo "          summary     - Summary only"
  echo "          csv         - CSV only"
  echo "          csvnoheader - CVS only without header"
  echo "          ./lw_aws_inventory.sh --ouptput csv"
}

AWS_PROFILE=""
export AWS_MAX_ATTEMPTS=20
REGIONS=""
ORG_ACCESS_ROLE=""
ORG_SCAN_ACCOUNT=""
PRINT_CSV_DETAILS="true"
PRINT_CSV_HEADER="true"
PRINT_SUMMARY="true"
GENERATE_SCRIPT=""
VERBOSE="false"

ORG_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ORG_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ORG_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

CSV_HEADER="\"Profile\", \"Account ID\", \"Regions\", \"EC2 Instances\", \"EC2 vCPUs\", \"ECS Fargate Clusters\", \"ECS Fargate Running Containers/Tasks\", \"ECS Fargate CPU Units\", \"ECS Fargate License vCPUs\", \"Lambda Functions (Not used for licensing)\", \"Total vCPUSs\""

# Usage: ./lw_aws_inventory.sh
while getopts ":p:o:r:a:-:g:v" opt; do
  case ${opt} in
    p )
      AWS_PROFILE=$OPTARG
      ;;
    o )
      ORG_ACCESS_ROLE=$OPTARG
      ;;
    a )
      ORG_SCAN_ACCOUNT=$OPTARG
      ;;
    g )
      GENERATE_SCRIPT=$OPTARG
      ;;
    r )
      REGIONS=$OPTARG
      ;;
    v )
      VERBOSE="true"
      ;;
    -)
        case "${OPTARG}" in
            #Default configuration is to print CSV and summary. This section overrides those settings as needed
            output)
                output="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                case "${output}" in
                  csv)
                    PRINT_SUMMARY="false"
                    ;;
                  summary)
                    PRINT_CSV_DETAILS="false"
                    PRINT_CSV_HEADER="false"
                    ;;
                  all)
                    #Do nothing, default configuration
                    ;;
                  csvnoheader)
                    PRINT_CSV_HEADER="false"
                    PRINT_SUMMARY="false"
                    ;;
                  *)
                    echo "Invalid argument. Valid options for --output: csv, summary, all, csvnoheader"
                    showHelp
                    exit  
                    ;;
                esac
                ;;
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

#Check AWS CLI pre-requisites
AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d " " -f1 | cut -d "/" -f2)
if [[ $AWS_CLI_VERSION = 1* ]]
then
  echo The script requires AWS CLI v2 to run. The current version installed is version $AWS_CLI_VERSION.
  echo See https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html for instructions on how to upgrade.
  exit
fi

#Ensure the script runs with the BASH shell
echo $BASH | grep -q "bash"
if [ $? -ne 0 ]
then
  echo The script is running using the incorrect shell.
  echo Use ./lw_aws_inventory.sh to run the script using the required shell, bash.
  exit
fi

#Ensure jq is installed

if ! command -v jq &> /dev/null
then
    echo "The script requires jq to run."
    echo "See https://jqlang.github.io/jq/download/ for installation options."
    exit 1
fi

# Set the initial counts to zero.
ACCOUNTS=0
ORGANIZATIONS=0
EC2_INSTANCES=0
EC2_INSTANCE_VCPU=0
ECS_FARGATE_CLUSTERS=0
ECS_FARGATE_RUNNING_TASKS=0
ECS_FARGATE_CPUS=0
LAMBDA_FUNCTIONS=0

function cleanup {
  # Revert to original AWS CLI configuration if script is stopped during execution
  export AWS_ACCESS_KEY_ID=$ORG_AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$ORG_AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN=$ORG_AWS_SESSION_TOKEN
}
trap cleanup EXIT

function verbose {
  if [[ $VERBOSE == "true" ]]
  then
    echo "[DEBUG] $1" >&2
  fi
}

function getAccountId {
  local profile_string=$1
  local cmd="aws $profile_string sts get-caller-identity --query \"Account\" --output text"
  verbose "Getting account ID using: $cmd"
  if [[ $VERBOSE == "true" ]]
  then
    local account_id=$(aws $profile_string sts get-caller-identity --query "Account" --output text 2>&1)
    verbose "Output: $account_id"
    if [[ $account_id =~ ^[0-9]{12}$ ]]
    then
      verbose "Account ID retrieved successfully: $account_id"
    else
      verbose "Error retrieving account ID: $account_id"
    fi
    echo "$account_id"
  else
    # Non-verbose: exact same behavior as original
    aws $profile_string sts get-caller-identity --query "Account" --output text
  fi
}

function getRegions {
  local profile_string=$1
  local cmd="aws $profile_string ec2 describe-regions --output json"
  verbose "Getting regions using: $cmd"
  if [[ $VERBOSE == "true" ]]
  then
    local regions=$(aws $profile_string ec2 describe-regions --output json 2>&1)
    verbose "Output: $regions"
    if [[ $regions = {* ]]
    then
      local region_count=$(echo "$regions" | jq -r '.[] | .[] | .RegionName' | wc -l | xargs)
      verbose "Successfully retrieved $region_count regions"
    else
      verbose "Error retrieving regions: $regions"
    fi
    echo "$regions" | jq -r '.[] | .[] | .RegionName'
  else
    # Non-verbose: exact same behavior as original
    aws $profile_string ec2 describe-regions --output json | jq -r '.[] | .[] | .RegionName'
  fi
}

function getEC2Instances {
  local profile_string=$1
  local r=$2
  verbose "Scanning EC2 instances in region $r"
  local cmd="aws $profile_string ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId]' --filters Name=instance-state-name,Values=running --region $r --output json --no-cli-pager"
  verbose "Command: $cmd"
  local instances=$(aws $profile_string ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId]' --filters Name=instance-state-name,Values=running --region $r --output json --no-cli-pager  2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $instances"
  fi
  if [[ $instances = [* ]] 
  then
    local count=$(echo $instances | jq 'flatten | length')
    verbose "Found $count running EC2 instances in region $r"
    echo "$count"
  else
    verbose "Error accessing EC2 in region $r: $instances"
    echo "-1"
  fi
}

function getEC2InstacevCPUs {
  local profile_string=$1
  local r=$2
  verbose "Calculating EC2 vCPUs in region $r"
  local cmd="aws $profile_string ec2 describe-instances --query 'Reservations[*].Instances[*].[CpuOptions]' --filters Name=instance-state-name,Values=running --region $r --output json --no-cli-pager"
  verbose "Command: $cmd"
  local cpu_output=$(aws $profile_string ec2 describe-instances --query 'Reservations[*].Instances[*].[CpuOptions]' --filters Name=instance-state-name,Values=running --region $r --output json --no-cli-pager 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $cpu_output"
  fi
  local jq_output
  jq_output=$(echo "$cpu_output" | jq  '.[] | .[] | .[] | .CoreCount * .ThreadsPerCore' 2>&1)
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error calculating vCPUs in region $r (jq error): $jq_output"
  fi
  if [[ $jq_exit_code -ne 0 ]]
  then
    verbose "WARNING: jq failed to parse CPU options output, returning 0"
    echo "0"
    return
  fi
  returncount=0
  for cpucount in $jq_output; do
    returncount=$(($returncount + $cpucount))
  done
  verbose "Total EC2 vCPUs in region $r: $returncount"
  echo "${returncount}"
}

function getECSFargateClusters {
  local profile_string=$1
  local r=$2
  verbose "Scanning ECS Fargate clusters in region $r"
  local cmd="aws $profile_string ecs list-clusters --region $r --output json --no-cli-pager"
  verbose "Command: $cmd"
  local clusters=$(aws $profile_string ecs list-clusters --region $r --output json --no-cli-pager 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $clusters"
    if [[ $clusters = {* ]]
    then
      local cluster_count=$(echo "$clusters" | jq -r '.clusterArns[]' 2>&1 | wc -l | xargs)
      verbose "Found $cluster_count ECS clusters in region $r"
    else
      verbose "Error accessing ECS in region $r: $clusters"
    fi
  fi
  local jq_output
  jq_output=$(echo "$clusters" | jq -r '.clusterArns[]' 2>&1)
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error parsing ECS clusters output with jq: $jq_output"
  fi
  if [[ $jq_exit_code -eq 0 ]]
  then
    echo "$jq_output"
  fi
}

function getECSFargateRunningTasks {
  local profile_string=$1
  local r=$2
  local ecsfargateclusters=$3
  local RUNNING_FARGATE_TASKS=0
  verbose "Scanning ECS Fargate running tasks in region $r"
  for c in $ecsfargateclusters; do
    verbose "  Checking cluster: $c"
    local cmd="aws $profile_string ecs list-tasks --region $r --output json --cluster $c --no-cli-pager"
    verbose "  Command: $cmd"
    local list_output=$(aws $profile_string ecs list-tasks --region $r --output json --cluster $c --no-cli-pager 2>&1)
    if [[ $VERBOSE == "true" ]]
    then
      verbose "  Output: $list_output"
    fi
    local jq_list_output
    jq_list_output=$(echo "$list_output" | jq -r '.taskArns | join(" ")' 2>&1)
    local jq_exit_code=$?
    if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
    then
      verbose "  Error parsing list-tasks output with jq: $jq_list_output"
      jq_list_output=""
    fi
    allclustertasks="$jq_list_output"
    while read -r batch; do
      if [ -n "${batch}" ]; then
        local cmd="aws $profile_string ecs describe-tasks --region $r --output json --tasks $batch --cluster $c --no-cli-pager"
        verbose "  Command: $cmd"
        local describe_output=$(aws $profile_string ecs describe-tasks --region $r --output json --tasks $batch --cluster $c --no-cli-pager 2>&1)
        if [[ $VERBOSE == "true" ]]
        then
          verbose "  Output: $describe_output"
        fi
        local jq_result
        jq_result=$(echo "$describe_output" | jq '[.tasks[] | select(.launchType=="FARGATE") | select(.lastStatus=="RUNNING")] | length' 2>&1)
        local jq_exit_code=$?
        if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
        then
          verbose "  Error parsing describe-tasks output with jq: $jq_result"
          jq_result=0
        fi
        RUNNING_FARGATE_TASKS=$(($RUNNING_FARGATE_TASKS + $jq_result))
      fi
    done < <(echo $allclustertasks | xargs -n 90)
  done
  verbose "Found $RUNNING_FARGATE_TASKS running Fargate tasks in region $r"
  echo "${RUNNING_FARGATE_TASKS}"
}

function getECSFargateRunningCPUs {
  local profile_string=$1
  local r=$2
  local ecsfargateclusters=$3
  local RUNNING_FARGATE_CPUS=0
  verbose "Calculating ECS Fargate CPU units in region $r"
  for c in $ecsfargateclusters; do
    local cmd="aws $profile_string ecs list-tasks --region $r --output json --cluster $c --no-cli-pager"
    verbose "  Command: $cmd"
    local list_output=$(aws $profile_string ecs list-tasks --region $r --output json --cluster $c --no-cli-pager 2>&1)
    if [[ $VERBOSE == "true" ]]
    then
      verbose "  Output: $list_output"
    fi
    local jq_list_output
    jq_list_output=$(echo "$list_output" | jq -r '.taskArns | join(" ")' 2>&1)
    local jq_exit_code=$?
    if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
    then
      verbose "  Error parsing list-tasks output with jq: $jq_list_output"
      jq_list_output=""
    fi
    allclustertasks="$jq_list_output"
    while read -r batch; do
      if [ -n "${batch}" ]; then
        local cmd="aws $profile_string ecs describe-tasks --region $r --output json --tasks $batch --cluster $c --no-cli-pager"
        verbose "  Command: $cmd"
        local describe_output=$(aws $profile_string ecs describe-tasks --region $r --output json --tasks $batch --cluster $c --no-cli-pager 2>&1)
        if [[ $VERBOSE == "true" ]]
        then
          verbose "  Output: $describe_output"
        fi
        local jq_result
        jq_result=$(echo "$describe_output" | jq '[.tasks[] | select(.launchType=="FARGATE") | select(.lastStatus=="RUNNING")] | .[].cpu | tonumber' 2>&1)
        local jq_exit_code=$?
        if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
        then
          verbose "  Error parsing describe-tasks CPU output with jq: $jq_result"
          jq_result=""
        fi
        cpucounts="$jq_result"

        for cpucount in $cpucounts; do
          RUNNING_FARGATE_CPUS=$(($RUNNING_FARGATE_CPUS + $cpucount))
        done
      fi
    done < <(echo $allclustertasks | xargs -n 90)
  done
  verbose "Total Fargate CPU units in region $r: $RUNNING_FARGATE_CPUS"
  echo "${RUNNING_FARGATE_CPUS}"
}

function getLambdaFunctions {
  local profile_string=$1
  local r=$2
  verbose "Scanning Lambda functions in region $r"
  local cmd="aws $profile_string lambda list-functions --region $r --output json --no-cli-pager"
  verbose "Command: $cmd"
  # Original behavior: pipe directly to jq, let errors pass through as they would originally
  # But capture stderr for verbose mode if needed
  if [[ $VERBOSE == "true" ]]
  then
    local result=$(aws $profile_string lambda list-functions --region $r --output json --no-cli-pager 2>&1)
    verbose "Output: $result"
    if [[ $result = {* ]]
    then
      local count=$(echo "$result" | jq '.Functions | length' 2>/dev/null)
      verbose "Found $count Lambda functions in region $r"
      echo "${count}"
    else
      verbose "Error accessing Lambda in region $r: $result"
      # Match original: if error, jq would try to parse it and might fail
      echo "$result" | jq '.Functions | length' 2>/dev/null || echo "0"
    fi
  else
    # Non-verbose: exact same behavior as original
    aws $profile_string lambda list-functions --region $r --output json --no-cli-pager | jq '.Functions | length'
  fi
}

function calculateInventory {
  local account_name=$1
  local profile_string=$2
  verbose ""
  verbose "=========================================="
  verbose "Analyzing account: ${account_name:-default} (Profile: ${profile_string:-default})"
  verbose "=========================================="
  local accountid=$(getAccountId "$profile_string")
  verbose "Account ID: $accountid"
  local accountEC2Instances=0
  local accountEC2vCPUs=0
  local accountECSFargateClusters=0
  local accountECSFargateRunningTasks=0
  local accountECSFargateCPUs=0
  local accountLambdaFunctions=0
  local accountTotalvCPUs=0

  if [[ $PRINT_CSV_DETAILS == "true" ]]
  then
    printf "$account_name, $accountid,"
  fi
  local regionsToScan=$(echo $REGIONS | sed "s/,/ /g")
  if [ -z "$regionsToScan" ]
  then
      # Regions to scan not set, get list from AWS
      verbose "No regions specified, retrieving list from AWS..."
      regionsToScan=$(getRegions "$profile_string")
  else
      verbose "Using specified regions: $regionsToScan"
  fi
  local region_count=$(echo $regionsToScan | wc -w | xargs)
  verbose "Scanning $region_count region(s)"

  local region_index=0
  for r in $regionsToScan; do
    region_index=$(($region_index + 1))
    verbose ""
    verbose "--- Region $region_index/$region_count: $r ---"
    if [[ $PRINT_CSV_DETAILS == "true" ]]
    then
      printf " $r"
    fi
    # Add newline to stderr in verbose mode to separate from CSV output on same line
    if [[ $VERBOSE == "true" && $PRINT_CSV_DETAILS == "true" ]]
    then
      echo "" >&2
    fi

    instances=$(getEC2Instances "$profile_string" "$r")
    if [[ $instances < 0 ]]
    then
      verbose "WARNING: Could not access EC2 in region $r - see error output above"
      if [[ $PRINT_CSV_DETAILS == "true" ]]
      then
        printf " (ERROR: No access to $r)"
      fi
    else
      EC2_INSTANCES=$(($EC2_INSTANCES + $instances))
      accountEC2Instances=$(($accountEC2Instances + $instances))

      ec2vcpu=$(getEC2InstacevCPUs "$profile_string" "$r")
      EC2_INSTANCE_VCPU=$(($EC2_INSTANCE_VCPU + $ec2vcpu))
      accountEC2vCPUs=$(($accountEC2vCPUs + $ec2vcpu))

      ecsfargateclusters=$(getECSFargateClusters "$profile_string" "$r")
      ecsfargateclusterscount=$(echo $ecsfargateclusters | wc -w | xargs)
      ECS_FARGATE_CLUSTERS=$(($ECS_FARGATE_CLUSTERS + $ecsfargateclusterscount))
      accountECSFargateClusters=$(($accountECSFargateClusters + $ecsfargateclusterscount))

      ecsfargaterunningtasks=$(getECSFargateRunningTasks "$profile_string" "$r" "$ecsfargateclusters")
      ECS_FARGATE_RUNNING_TASKS=$(($ECS_FARGATE_RUNNING_TASKS + $ecsfargaterunningtasks))
      accountECSFargateRunningTasks=$(($accountECSFargateRunningTasks + $ecsfargaterunningtasks))

      ecsfargatecpu=$(getECSFargateRunningCPUs "$profile_string" "$r" "$ecsfargateclusters")
      ECS_FARGATE_CPUS=$(($ECS_FARGATE_CPUS + $ecsfargatecpu))
      accountECSFargateCPUs=$(($accountECSFargateCPUs + $ecsfargatecpu))

      lambdafunctions=$(getLambdaFunctions "$profile_string" "$r")
      LAMBDA_FUNCTIONS=$(($LAMBDA_FUNCTIONS + $lambdafunctions))
      accountLambdaFunctions=$(($accountLambdaFunctions + $lambdafunctions))
      
      verbose "Region $r summary: EC2=$instances instances ($ec2vcpu vCPUs), ECS=$ecsfargateclusterscount clusters, Fargate=$ecsfargaterunningtasks tasks ($ecsfargatecpu CPU units), Lambda=$lambdafunctions functions"
    fi
  done
  verbose ""
  verbose "Account summary: EC2=$accountEC2Instances instances ($accountEC2vCPUs vCPUs), ECS=$accountECSFargateClusters clusters, Fargate=$accountECSFargateRunningTasks tasks ($accountECSFargateCPUs CPU units), Lambda=$accountLambdaFunctions functions"

  accountECSFargatevCPUs=$(($accountECSFargateCPUs / 1024))
  accountTotalvCPUs=$(($accountEC2vCPUs + $accountECSFargatevCPUs))

    if [[ $PRINT_CSV_DETAILS == "true" ]]
    then
      echo , "$accountEC2Instances", "$accountEC2vCPUs", "$accountECSFargateClusters", "$accountECSFargateRunningTasks", "$accountECSFargateCPUs", "$accountECSFargatevCPUs", "$accountLambdaFunctions", "$accountTotalvCPUs"
    fi
}

function textoutput {
  echo "######################################################################"
  echo "Lacework inventory collection complete."
  echo ""
  echo "Organizations Analyzed: $ORGANIZATIONS"
  echo "Accounts Analyzed:      $ACCOUNTS"
  echo ""
  echo "EC2 Information"
  echo "===================="
  echo "EC2 Instances:     $EC2_INSTANCES"
  echo "EC2 vCPUs:         $EC2_INSTANCE_VCPU"
  echo ""
  echo "Fargate Information"
  echo "===================="
  echo "ECS Clusters:                    $ECS_FARGATE_CLUSTERS"
  echo "ECS Fargate Running Tasks:       $ECS_FARGATE_RUNNING_TASKS"
  echo "ECS Fargate Container CPU Units: $ECS_FARGATE_CPUS"
  echo "ECS Fargate vCPUs:               $ECS_FARGATE_VCPUS"
  echo ""
  echo "Lambda Information (Not used for licensing)"
  echo "============================================"
  echo "Lambda Functions:     $LAMBDA_FUNCTIONS"
  echo ""
  echo "License Summary"
  echo "===================="
  echo "  EC2 vCPUs:            $EC2_INSTANCE_VCPU"
  echo "+ ECS Fargate vCPUs:    $ECS_FARGATE_VCPUS"
  echo "----------------------------"
  echo "= Total vCPUs:          $TOTAL_VCPUS"
}

function analyzeOrganization {
    local org_profile_string=$1
    local orgAccountId=$(getAccountId "$org_profile_string")
    local cmd="aws $org_profile_string organizations list-accounts"
    verbose "Command: $cmd"
    verbose "Calling organizations list-accounts..."
    local accounts_output
    if ! accounts_output=$(aws $org_profile_string organizations list-accounts 2>&1); then
        echo "Error: Failed to list accounts in organization: $accounts_output" >&2
        echo "Make sure you have permissions to call organizations:ListAccounts and that you're running this from the organization master account." >&2
        return 1
    fi
    if [[ $VERBOSE == "true" ]]
    then
      verbose "Output: $accounts_output"
    fi
    local accounts=$(echo "$accounts_output" | jq -c '.Accounts[]' | jq -c '{Id, Name}')
    if [ -n "$ORG_SCAN_ACCOUNT" ]
    then
      local account_name=$(echo $accounts | jq -r --arg account "$ORG_SCAN_ACCOUNT" 'select(.Id==$account) | .Name')
      analyzeOrganizationAccount "$org_profile_string" "$ORG_SCAN_ACCOUNT" "$account_name"
    else
      for account in $(echo $accounts | jq -r '.Id')
      do
          local account_name=$(echo $accounts | jq -r --arg account "$account" 'select(.Id==$account) | .Name')
          if [[ $orgAccountId == $account ]]
          then
            # Found master account, role most likely don't exist, just connnect directly
            ACCOUNTS=$(($ACCOUNTS + 1))
            calculateInventory "$account_name" "$org_profile_string"
          else
            analyzeOrganizationAccount "$org_profile_string" "$account" "$account_name"
          fi
      done
    fi
}

function analyzeOrganizationAccount {
  local org_profile_string=$1
  local account=$2
  local account_name=$3

  verbose "Attempting to assume role in account $account ($account_name)"
  local role_arn="arn:aws:iam::$account:role/$ORG_ACCESS_ROLE"
  verbose "Role ARN: $role_arn"
  local cmd="aws $org_profile_string sts assume-role --role-session-name LW-INVENTORY --role-arn $role_arn"
  verbose "Command: $cmd"
  local account_credentials=$(aws $org_profile_string sts assume-role --role-session-name LW-INVENTORY --role-arn $role_arn 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $account_credentials"
  fi
  if [[ $account_credentials = {* ]] 
  then
    #Got ok credential back, do analysis
    verbose "Successfully assumed role in account $account"
    ACCOUNTS=$(($ACCOUNTS + 1))
    export AWS_ACCESS_KEY_ID=$(echo $account_credentials | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo $account_credentials | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo $account_credentials | jq -r '.Credentials.SessionToken')
    verbose "Temporary credentials set for account $account"
    calculateInventory "$account_name" ""
    export AWS_ACCESS_KEY_ID=$ORG_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ORG_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ORG_AWS_SESSION_TOKEN
    verbose "Reverted to original AWS credentials"
  else
    #Failed to connect, print error message
    verbose "ERROR: Failed to assume role in account $account: $account_credentials"
    echo "ERROR: Failed to connect to account \"$account_name\" ($account). ${account_credentials}"
    echo "aws $org_profile_string sts assume-role --role-session-name LW-INVENTORY --role-arn $role_arn"
  fi
}

function runAnalysis {
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Starting inventory analysis..."
    verbose "Verbose mode enabled"
    verbose "AWS CLI version: $(aws --version 2>&1)"
    if [ -n "$AWS_PROFILE" ]
    then
      verbose "Using AWS profile(s): $AWS_PROFILE"
    else
      verbose "Using default AWS credentials"
    fi
    if [ -n "$REGIONS" ]
    then
      verbose "Regions specified: $REGIONS"
    fi
    if [ -n "$ORG_ACCESS_ROLE" ]
    then
      verbose "Organization mode enabled with role: $ORG_ACCESS_ROLE"
    fi
    verbose ""
  fi

  if [[ $PRINT_CSV_HEADER == "true" ]]
  then
    echo $CSV_HEADER
  fi

  if [ -n "$ORG_ACCESS_ROLE" ]
  then
      if [ -n "$AWS_PROFILE" ]
      then
          for PROFILE in $(echo $AWS_PROFILE | sed "s/,/ /g")
          do
              ORGANIZATIONS=$(($ORGANIZATIONS + 1))
              PROFILE_STRING="--profile $PROFILE"
              analyzeOrganization "$PROFILE_STRING"
          done
      else
          ORGANIZATIONS=1
          analyzeOrganization ""
      fi
  else
      for PROFILE in $(echo $AWS_PROFILE | sed "s/,/ /g")
      do
          # Profile set
          PROFILE_STRING="--profile $PROFILE"
          ACCOUNTS=$(($ACCOUNTS + 1))
          calculateInventory "$PROFILE" "$PROFILE_STRING"
      done

      if [ -z "$PROFILE" ]
      then
          # No profile argument, run AWS CLI default
          ACCOUNTS=1
          calculateInventory "" ""
      fi
  fi

  ECS_FARGATE_VCPUS=$(($ECS_FARGATE_CPUS / 1024))
  TOTAL_VCPUS=$(($EC2_INSTANCE_VCPU + $ECS_FARGATE_VCPUS))

  if [[ $PRINT_SUMMARY == "true" ]]
  then
    textoutput
  fi
}

function generateOrganizationScript {
  local profile=$1
  local cliProfileString=$2
  local regionString=$3
  local orgMasterAccountID=$(getAccountId "$cliProfileString")
  local accounts=$(aws $cliProfileString organizations list-accounts | jq -c '.Accounts[]' | jq -c '{Id, Name}')

  for account in $(echo $accounts | jq -r '.Id')
  do
      if [[ $orgMasterAccountID == $account ]]
      then
        echo "$0 $profile  $regionString --output csvnoheader"  >> $GENERATE_SCRIPT
      else
        echo "$0 $profile -o $ORG_ACCESS_ROLE -a $account $regionString --output csvnoheader"  >> $GENERATE_SCRIPT
      fi
  done
}

function generateScript {
  echo Generating script $GENERATE_SCRIPT

  echo "#!/bin/bash" > $GENERATE_SCRIPT
  echo "echo $CSV_HEADER" >> $GENERATE_SCRIPT
  chmod +x $GENERATE_SCRIPT

  local scriptRegions=""
  if [ -n "$REGIONS" ]
  then
    scriptRegions="-r $REGIONS"
  fi
  if [ -n "$ORG_ACCESS_ROLE" ]
  then
      for PROFILE in $(echo $AWS_PROFILE | sed "s/,/ /g")
      do
        generateOrganizationScript "-p $PROFILE" "--profile $PROFILE" "$scriptRegions"
      done

      if [ -z "$PROFILE" ]
      then
        generateOrganizationScript "" "" "$scriptRegions"
      fi
  else
      for PROFILE in $(echo $AWS_PROFILE | sed "s/,/ /g")
      do
        echo "$0 $regionString -p $PROFILE $scriptRegions --output csvnoheader" >> $GENERATE_SCRIPT
      done

      if [ -z "$PROFILE" ]
      then
        echo "$0 $regionString $scriptRegions --output csvnoheader"  >> $GENERATE_SCRIPT
      fi
  fi
}

if [[ -n $GENERATE_SCRIPT ]]
then
  generateScript
else
  runAnalysis
fi
