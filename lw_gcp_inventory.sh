#!/bin/bash

# Run ./lw_gcp_inventory.sh -h for help on how to run the script.
# Or just read the text in showHelp below.
# Requirements: gcloud, jq

function showHelp {
  echo "lw_gcp_inventory.sh is a tool for estimating license vCPUs in a GCP environment, based on folder,"
  echo "project or organization level. It leverages the gcp CLI and by default analyzes all project a user"
  echo "has access to. The script provides output in a CSV format to be imported into a spreadsheet, as"
  echo "well as an easy-to-read summary."
  echo ""
  echo "By default, the script will scan all projects returned by the following command:"
  echo "gcloud projects list"
  echo ""
  echo "Note the following about the script:"
  echo "* Works great in a cloud shell"
  echo "* It has been verified to work on Mac and Linux based systems"
  echo "* Has been observed to work with Windows Subsystem for Linux to run on Windows"
  echo "* Run using the following syntax: ./lw_gcp_inventory.sh, sh lw_gcp_inventory.sh will not work"
  echo ""
  echo "Available flags:"
  echo " -p       Comma separated list of GCP projects to scan."
  echo "          ./lw_gcp_inventory.sh -p project-1,project-2"
  echo " -f       Comma separated list of GCP folders to scan."
  echo "          ./lw_gcp_inventory.sh -p 1234,456"
  echo " -o       Comma separated list of GCP organizations to scan."
  echo "          ./lw_gcp_inventory.sh -o 1234,456"
  echo " -v       Enable verbose/debug mode"
  echo "          Shows detailed information about GCP API calls, projects being scanned, and progress"
  echo "          ./lw_gcp_inventory.sh -v"
  echo "          ./lw_gcp_inventory.sh --verbose"
}

#Ensure the script runs with the BASH shell
echo $BASH | grep -q "bash"
if [ $? -ne 0 ]
then
  echo The script is running using the incorrect shell.
  echo Use ./lw_gcp_inventory.sh to run the script using the required shell, bash.
  exit
fi

set -o errexit
set -o pipefail

VERBOSE="false"

while getopts ":f:o:p:-:v" opt; do
  case ${opt} in
    f )
      FOLDERS=$OPTARG
      ;;
    o )
      ORGANIZATIONS=$OPTARG
      ;;
    p )
      PROJECTS=$OPTARG
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

# Set the initial counts to zero.
TOTAL_GCE_VCPU=0
TOTAL_GCE_VM_COUNT=0
TOTAL_PROJECTS=0

function verbose {
  if [[ $VERBOSE == "true" ]]
  then
    echo "[DEBUG] $1" >&2
  fi
}

function analyzeProject {
  local project=$1
  local projectVCPUs=0
  local projectVmCount=0
  TOTAL_PROJECTS=$(($TOTAL_PROJECTS + 1))

  verbose ""
  verbose "=========================================="
  verbose "Analyzing project: $project"
  verbose "=========================================="

  # get all instances within the scope and turn into a map of `{count} {machine_type}`
  verbose "Retrieving compute instances for project $project"
  local cmd="gcloud compute instances list --project $project --quiet --format=json"
  verbose "Command: $cmd"
  local instanceList=$(gcloud compute instances list --project $project --quiet --format=json 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $instanceList"
  fi
  if [[ $instanceList = [* ]] 
  then
    verbose "Successfully retrieved instance list"
    local instanceCount=$(echo "$instanceList" | jq 'length' 2>&1)
    local jq_exit_code=$?
    if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
    then
      verbose "Error parsing instance list with jq: $instanceCount"
      instanceCount=0
    fi
    verbose "Found $instanceCount total instances (including terminated)"
    local jq_machines=$(echo "$instanceList" | jq -r '.[] | select(.status != ("TERMINATED")) | .machineType' 2>&1)
    local jq_machines_exit_code=$?
    if [[ $VERBOSE == "true" && $jq_machines_exit_code -ne 0 ]]
    then
      verbose "Error extracting machine types with jq: $jq_machines"
    fi
    local instanceMap=$(echo "$jq_machines" | sort | uniq -c)
    verbose "Processing machine types:"
    # make the for loop split on newline vs. space
    IFS=$'\n' 
    # for each entry in the map, get the vCPU value for the type and aggregate the values
    for instance in $instanceMap; 
    do
      local instance=$(echo $instance | tr -s ' ') # trim all but one leading space
      local count=$(echo $instance | cut -d ' ' -f 2)  # split and take the second value (count)
      local machineTypeUrl=$(echo $instance | cut -d ' ' -f 3) # split and take third value (machine_type)
      
      local location=$(echo $machineTypeUrl | cut -d "/" -f9) # extract location from url
      local machineType=$(echo $machineTypeUrl | cut -d "/" -f11) # extract machine type from url
      verbose "  Processing $count instances of type $machineType in zone $location"
      local cmd="gcloud compute machine-types describe $machineType --zone=$location --project=$project --format=json"
      verbose "  Command: $cmd"
      local machineTypeOutput=$(gcloud compute machine-types describe $machineType --zone=$location --project=$project --format=json 2>&1)
      if [[ $VERBOSE == "true" ]]
      then
        verbose "  Output: $machineTypeOutput"
      fi
      local typeVCPUValue=$(echo "$machineTypeOutput" | jq -r '.guestCpus' 2>&1)
      local jq_exit_code=$?
      if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
      then
        verbose "  Error parsing machine type output with jq: $typeVCPUValue"
        typeVCPUValue=0
      fi
      verbose "  Machine type $machineType has $typeVCPUValue vCPUs (count: $count, subtotal: $(($count * $typeVCPUValue)) vCPUs)"

      projectVCPUs=$(($projectVCPUs + (($count * $typeVCPUValue)))) # increment total count, including Standard GKE
      projectVmCount=$(($projectVmCount + $count)) # increment total count, including Standard GKE
    done
    verbose "Project $project summary: $projectVmCount VMs, $projectVCPUs vCPUs"

    TOTAL_GCE_VCPU=$(($TOTAL_GCE_VCPU + $projectVCPUs)) # increment total count, including Standard GKE
    TOTAL_GCE_VM_COUNT=$(($TOTAL_GCE_VM_COUNT + $projectVmCount)) # increment total count, including Standard GKE
  elif [[ $instanceList == *"SERVICE_DISABLED"* ]]
  then
    verbose "WARNING: Compute Engine API is disabled for project $project"
    projectVmCount="\"INFO: Compute instance API disabled\""
  elif [[ $instanceList == *"PERMISSION_DENIED"* ]]
  then
    verbose "WARNING: Permission denied accessing project $project"
    projectVmCount="\"INFO: Data not available. Permission denied\""
  else
    verbose "ERROR: Failed to load instance information for project $project: $instanceList"
    projectVmCount="\"ERROR: Failed to load instance information: $instanceList\""
  fi
  echo "\"$project\", $projectVmCount, $projectVCPUs"
}

function analyzeFolder {
  local folder=$1

  verbose ""
  verbose "Analyzing folder: $folder"
  verbose "Getting subfolders..."
  local cmd="gcloud resource-manager folders list --folder $folder --format=json"
  verbose "Command: $cmd"
  local foldersOutput=$(gcloud resource-manager folders list --folder $folder --format=json 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $foldersOutput"
  fi
  local folders=$(echo "$foldersOutput" | jq -r '.[] | .name' 2>&1 | sed 's/.*\///')
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error parsing folders output with jq: $folders"
  fi
  local folderCount=$(echo "$folders" | grep -v '^$' | wc -l | xargs)
  verbose "Found $folderCount subfolder(s)"
  for f in $folders;
  do
    analyzeFolder "$f"
  done

  verbose "Getting projects in folder $folder..."
  local cmd="gcloud projects list --format=json --filter=\"parent.id=$folder AND parent.type=folder\""
  verbose "Command: $cmd"
  local projectsOutput=$(gcloud projects list --format=json --filter="parent.id=$folder AND parent.type=folder" 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $projectsOutput"
  fi
  local projects=$(echo "$projectsOutput" | jq -r '.[] | .projectId' 2>&1)
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error parsing projects output with jq: $projects"
  fi
  local projectCount=$(echo "$projects" | grep -v '^$' | wc -l | xargs)
  verbose "Found $projectCount project(s) in folder $folder"
  for project in $projects;
  do
    analyzeProject "$project"
  done
}

function analyzeOrganization {
  local organization=$1

  verbose ""
  verbose "=========================================="
  verbose "Analyzing organization: $organization"
  verbose "=========================================="

  verbose "Getting folders in organization..."
  local cmd="gcloud resource-manager folders list --organization $organization --format=json"
  verbose "Command: $cmd"
  local foldersOutput=$(gcloud resource-manager folders list --organization $organization --format=json 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $foldersOutput"
  fi
  local folders=$(echo "$foldersOutput" | jq -r '.[] | .name' 2>&1 | sed 's/.*\///')
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error parsing folders output with jq: $folders"
  fi
  local folderCount=$(echo "$folders" | grep -v '^$' | wc -l | xargs)
  verbose "Found $folderCount folder(s) in organization"
  for f in $folders;
  do
    analyzeFolder "$f"
  done

  verbose "Getting projects directly under organization..."
  local cmd="gcloud projects list --format=json --filter=\"parent.id=$organization AND parent.type=organization\""
  verbose "Command: $cmd"
  local projectsOutput=$(gcloud projects list --format=json --filter="parent.id=$organization AND parent.type=organization" 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $projectsOutput"
  fi
  local projects=$(echo "$projectsOutput" | jq -r '.[] | .projectId' 2>&1)
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error parsing projects output with jq: $projects"
  fi
  local projectCount=$(echo "$projects" | grep -v '^$' | wc -l | xargs)
  verbose "Found $projectCount project(s) directly under organization"
  for project in $projects;
  do
    analyzeProject "$project"
  done
}

if [[ $VERBOSE == "true" ]]
then
  verbose "Starting GCP inventory analysis..."
  verbose "Verbose mode enabled"
  verbose "gcloud version: $(gcloud --version 2>&1 | head -1)"
  if [ -n "$PROJECTS" ]
  then
    verbose "Projects specified: $PROJECTS"
  elif [ -n "$FOLDERS" ]
  then
    verbose "Folders specified: $FOLDERS"
  elif [ -n "$ORGANIZATIONS" ]
  then
    verbose "Organizations specified: $ORGANIZATIONS"
  else
    verbose "No specific scope specified, will scan all accessible projects"
  fi
  verbose ""
fi

echo \"Project\", \"VM Count\", \"vCPUs\"

if [ -n "$FOLDERS" ]
then
  verbose "Scanning folders: $FOLDERS"
  for FOLDER in $(echo $FOLDERS | sed "s/,/ /g")
  do
    analyzeFolder "$FOLDER"
  done
elif [ -n "$ORGANIZATIONS" ]
then
  verbose "Scanning organizations: $ORGANIZATIONS"
  for ORGANIZATION in $(echo $ORGANIZATIONS | sed "s/,/ /g")
  do
    analyzeOrganization "$ORGANIZATION"
  done
elif [ -n "$PROJECTS" ]
then
  verbose "Scanning projects: $PROJECTS"
  for PROJECT in $(echo $PROJECTS | sed "s/,/ /g")
  do
    analyzeProject "$PROJECT"
  done
else
  verbose "No specific scope specified, retrieving all accessible projects..."
  cmd="gcloud projects list --format json"
  verbose "Command: $cmd"
  local projectsOutput=$(gcloud projects list --format json 2>&1)
  if [[ $VERBOSE == "true" ]]
  then
    verbose "Output: $projectsOutput"
  fi
  foundProjects=$(echo "$projectsOutput" | jq -r ".[] | .projectId" 2>&1)
  local jq_exit_code=$?
  if [[ $VERBOSE == "true" && $jq_exit_code -ne 0 ]]
  then
    verbose "Error parsing projects list output with jq: $foundProjects"
  fi
  projectCount=$(echo "$foundProjects" | grep -v '^$' | wc -l | xargs)
  verbose "Found $projectCount accessible project(s)"
  for foundProject in $foundProjects;
  do
    analyzeProject "$foundProject"
  done
fi

verbose ""
verbose "Analysis complete. Summary:"
verbose "  Total Projects: $TOTAL_PROJECTS"
verbose "  Total VMs: $TOTAL_GCE_VM_COUNT"
verbose "  Total vCPUs: $TOTAL_GCE_VCPU"


echo "##########################################"
echo "Lacework inventory collection complete."
echo ""
echo "License Summary:"
echo "================================================"
echo "Projects analyzed:                     $TOTAL_PROJECTS"
echo "Number of VMs, including standard GKE: $TOTAL_GCE_VM_COUNT"
echo "vCPUs:                                 $TOTAL_GCE_VCPU"
