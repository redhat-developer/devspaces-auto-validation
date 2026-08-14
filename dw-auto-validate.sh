#! /bin/bash
VERBOSE=0
FULL=0
DEBUG=0
SCENARIO=""
PR_NUMBER=""
CUSTOM_IMAGE=""

# colors for fun
RED='\033[1;91m'
GREEN='\033[1;92m'
YELLOW='\033[1;93m'
BLUE='\033[1;94m'
PURPLE='\033[1;95m'
NC='\033[0m' # No Color


#################################
# Parameters for fun or experts #
#################################

while getopts "vfdhs:p:i:" o; do
  case "${o}" in
    v)
    VERBOSE=1
    echo "Using verbose mode."
    ;;
    f)
    FULL=1
    echo -e "Using full test matrix. ${YELLOW}WARNING${NC} - Can take a long time to complete."
    ;;
    d)
    DEBUG=1
    FULL=0
    VERBOSE=1
    echo -e "Using verbose mode AND do not clean resource. ${YELLOW}WARNING${NC} - This mode uses only the first item of the test matrix."
    ;;
    s)
    SCENARIO="${OPTARG}"
    if [[ ! "${SCENARIO}" =~ ^(sshd|jetbrains|vscode)$ ]]; then
      echo -e "${RED}Error:${NC} Invalid scenario '${SCENARIO}'. Valid options are: sshd, jetbrains, vscode." >&2
      exit 1
    fi
    echo "Using '${SCENARIO}' scenario."
    ;;
    p)
    PR_NUMBER="${OPTARG}"
    if [[ ! "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Error:${NC} PR number must be a positive integer." >&2
      exit 1
    fi
    echo -e "Using che-code image from PR #${PR_NUMBER}."
    ;;
    i)
    CUSTOM_IMAGE="${OPTARG}"
    echo -e "Using custom editor image: ${CUSTOM_IMAGE}"
    ;;
    h)
    echo -e "Usage: $0 [OPTIONS]\n"
    echo -e "Options:"
    echo -e "  -v\t\t\tVerbose mode"
    echo -e "  -d\t\t\tDebug mode (verbose + keep resources, single test only)"
    echo -e "  -f\t\t\tFull test matrix (all images)"
    echo -e "  -s <scenario>\t\tSkip scenario prompt (sshd|jetbrains|vscode)"
    echo -e "  -p <PR_NUMBER>\tTest a che-code PR image (from che-incubator/che-code)"
    echo -e "  -i <IMAGE>\t\tTest a custom editor image"
    echo -e "  -h\t\t\tShow this help message"
    exit 0
    ;;
    \?)
    echo "Invalid option: -$OPTARG"
    ;;
  esac
done

# -p and -i are mutually exclusive
if [ -n "${PR_NUMBER}" ] && [ -n "${CUSTOM_IMAGE}" ]; then
  echo -e "${RED}Error:${NC} -p and -i options are mutually exclusive." >&2
  exit 1
fi

# quiet logs from oc
[[ ${VERBOSE} -eq 0 ]] && QUIET="&>/dev/null"

####################
# Common Functions #
####################

log() {
  if [ ${VERBOSE} -eq 1 ]; then
    echo -e "${@}"
  fi
}

# Resolves the pod name and main container name for the current DevWorkspace.
# Sets global variables: podName, mainContainerName
# Returns 1 if pod or container cannot be found.
resolve_devworkspace_pod() {
  podNameAndDWName=$(oc get pods -o 'jsonpath={range .items[*]}{.metadata.name}{","}{.metadata.labels.controller\.devfile\.io/devworkspace_name}{"\n"}{end}')
  log "${YELLOW}podNameAndDWName: \n${NC}${podNameAndDWName}"
  podName=$(echo "${podNameAndDWName}" | grep ${DEVWORKSPACE_NAME} | cut -d, -f1)
  log "${YELLOW}podName: \n${NC}${podName}"
  mainContainerName=$(oc get pod "${podName}" -o json | jq -r '[.status.containerStatuses[] | select(.state.running and (.name | test("^che-") | not))] | first | .name // empty')
  log "${YELLOW}mainContainerName: \n${NC}${mainContainerName}"
  if [ -z "${podName}" ] || [ -z "${mainContainerName}" ]; then
    log "Could not find pod/container matching ${DEVWORKSPACE_NAME}"
    return 1
  fi
  log "${GREEN}Found ${YELLOW}${mainContainerName}${NC} container in ${YELLOW}${podName}${NC} pod"
  return 0
}

validate_devworkspace() {
  resolve_devworkspace_pod || return 1

  log "Checking editor on localhost:${LANDING_PAGE_PORT}"
  http_code=$(oc exec -n "${DEVWORKSPACE_NS}" "${podName}" -c "${mainContainerName}" -- curl -s -o /dev/null -w '%{http_code}' http://localhost:${LANDING_PAGE_PORT})
  if [ "${http_code}" == "200" ]; then
    log "${GREEN}localhost:${VALIDATION_PORT} returned HTTP ${http_code}${NC}"
    return 0
  else
    log "${YELLOW}localhost:${VALIDATION_PORT} returned HTTP ${http_code}${NC}"
    return 1
  fi
}

shouldExclude() {
  for imagePattern in "${EXCLUDED_IMAGE_PATTERNS[@]}"; do
    if [[ ${1} =~ ${imagePattern} ]]; then
      return 0
    fi
  done
  return 1
}

########
# Main #
########

# oc must be installed
echo -e "\n${BLUE}Checking oc installation...${NC}"
log "Executing 'which oc'..."
if ! [ -x "$(command -v oc)" ]; then
  echo -e "${RED}Error:${NC} oc is not installed. Please install oc CLI. You can find a getting started guide here: https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/cli_tools/openshift-cli-oc" >&2
  exit 1
else
  echo -e "${GREEN}Ok!${NC}"
fi

# jq must be installed
echo -e "\n${BLUE}Checking jq installation...${NC}"
log "Executing 'which jq'..."
if ! [ -x "$(command -v jq)" ]; then
  echo -e "${RED}Error:${NC} jq is not installed. Please install jq package." >&2
  exit 1
else
  echo -e "${GREEN}Ok!${NC}"
fi

if [ -n "${PR_NUMBER}" ]; then
  # Verify the PR image exists
  PR_IMAGE="quay.io/che-incubator-pull-requests/che-code:pr-${PR_NUMBER}-amd64"
  echo -e "\n${BLUE}Checking skopeo installation...${NC}"
  log "Executing 'which skopeo'..."
  if ! [ -x "$(command -v skopeo)" ]; then
    echo -e "${RED}Error:${NC} skopeo is not installed. Please install skopeo package." >&2
    exit 1
  else
    echo -e "${GREEN}Ok!${NC}"
    echo -e "\n${BLUE}Checking PR image...${NC}"
    log "Executing 'skopeo inspect'..."
    eval skopeo inspect --no-tags --retry-times 2 --override-arch amd64 --override-os linux "docker://${PR_IMAGE}" "${QUIET}"
    if [ $? -ne 0 ]; then
      echo -e "${RED}Error:${NC} PR image '${PR_IMAGE}' not found. Make sure the GitHub Action has published the image." >&2
      exit 1
    fi
    echo -e "${GREEN}Ok!${NC}"
  fi
fi

if [ -n "${CUSTOM_IMAGE}" ]; then
  if [ -x "$(command -v skopeo)" ]; then
    echo -e "\n${BLUE}Checking custom image...${NC}"
    log "Executing 'skopeo inspect'..."
    eval skopeo inspect --no-tags --retry-times 2 --override-arch amd64 --override-os linux "docker://${CUSTOM_IMAGE}" "${QUIET}"
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}Warning:${NC} Could not verify custom image '${CUSTOM_IMAGE}'. Proceeding anyway."
    else
      echo -e "${GREEN}Ok!${NC}"
    fi
  fi
fi

OVERRIDE_IMAGE=""
if [ -n "${PR_NUMBER}" ]; then
  OVERRIDE_IMAGE="quay.io/che-incubator-pull-requests/che-code:pr-${PR_NUMBER}-amd64"
elif [ -n "${CUSTOM_IMAGE}" ]; then
  OVERRIDE_IMAGE="${CUSTOM_IMAGE}"
fi

# You must be logged into your OpenShift Cluster
echo -e "\n${BLUE}Checking cluster connection...${NC}"
log "Executing 'oc whoami'..."
current_cluster=$(oc config current-context)
eval oc whoami --insecure-skip-tls-verify "${QUIET}"
if [ $? -eq 1 ]; then
  echo -e "${YELLOW}Not connected.${NC} Do you want to login to current cluster? Current cluster is ${PURPLE}${current_cluster}.${NC}"
  while true; do
    read -rp "(y/n)? : " yn
    case $yn in
      [Yy]* ) oc login --web; break;;
      [Nn]* ) exit;;
      * ) echo "Please answer (Yy)es or (Nn)o.";;
    esac
  done
else
  echo -e "${GREEN}Ok!${NC}\nUsing current context ${PURPLE}${current_cluster}${NC}"
fi

# Choose scenario
if [ -z "${SCENARIO}" ]; then
  echo -e "\n${BLUE}Choose the dedicated scenario to run the validation test suite.${NC}\n1-sshd\n2-jetbrains\n3-vscode"
  while true; do
    read -rp "(1/2/3)? : " scenario
    case $scenario in
      1 ) SCENARIO=sshd; break;;
      2 ) SCENARIO=jetbrains; break;;
      3 ) SCENARIO=vscode; break;;
      * ) echo "Please answer 1 or 2 or 3";;
    esac
  done
fi

# Read values from scenario's setting
# shellcheck source=settings/settings-vscode.env
. settings/settings-"${SCENARIO}".env

# user namespace where testing will occur
DEVWORKSPACE_NS=$(oc project -q)

# Override image mode: override the editor definition with a custom or PR image
EDITOR_DWT_NAME=""
if [ -n "${OVERRIDE_IMAGE}" ]; then
  echo -e "\n${BLUE}Setting up editor definition from override image: ${OVERRIDE_IMAGE}${NC}"

  TMP_EDITOR_DEF=$(mktemp -t editor-def-XXX.yaml)
  curl -sL -o "${TMP_EDITOR_DEF}" "${EDITOR_DEFINITION}"

  sed -i.bak "/name: ${EDITOR_COMPONENT_NAME}/,/image:/ s|image:.*|image: ${OVERRIDE_IMAGE}|" "${TMP_EDITOR_DEF}" && rm -f "${TMP_EDITOR_DEF}.bak" 

  if [ -n "${PR_NUMBER}" ]; then
    EDITOR_DWT_NAME="che-code-pr-${PR_NUMBER}"
  else
    EDITOR_DWT_NAME="che-code-custom"
  fi
  TMP_DWT=$(mktemp -t editor-dwt-XXX.yaml)
  cat > "${TMP_DWT}" <<DWTEOF
apiVersion: workspace.devfile.io/v1alpha2
kind: DevWorkspaceTemplate
metadata:
  name: ${EDITOR_DWT_NAME}
  namespace: ${DEVWORKSPACE_NS}
spec:
$(sed -n '/^commands:/,$ p' "${TMP_EDITOR_DEF}" | sed 's/^/  /')
DWTEOF

  log "Applying DevWorkspaceTemplate ${EDITOR_DWT_NAME}..."
  eval "oc apply -f ${TMP_DWT} ${QUIET}"
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error:${NC} Failed to apply DevWorkspaceTemplate." >&2
    exit 1
  fi
  echo -e "${GREEN}DevWorkspaceTemplate ${EDITOR_DWT_NAME} applied.${NC}"
fi

# Temporary storage for generated files
TMP_DEVFILE=$(mktemp -t devfile-"${SCENARIO}"-XXX.yaml)
TMP_DEVWORKSPACE=$(mktemp -t devworkspace-XXX.yaml)

# parsing images list
IMAGES_LIST=()
IMAGE_LIST_PATH=
if [ ${FULL} -eq 0 ]; then
  IMAGE_LIST_PATH="images/images.txt"
else
  IMAGE_LIST_PATH="images/images-full.txt"
fi

while IFS= read -r image; do
  # Skip empty lines
  [[ -z "$image" ]] && continue

  IMAGES_LIST+=("$image")

done < ${IMAGE_LIST_PATH}

# parsing devfiles list
DEVFILE_URL_LIST=()
DEVFILE_LIST_PATH=
if [ ${FULL} -eq 0 ]; then
  DEVFILE_LIST_PATH="devfiles/devfiles.txt"
else
  DEVFILE_LIST_PATH="devfiles/devfiles-full.txt"
fi

while IFS= read -r devfile; do
  # Skip empty lines
  [[ -z "$devfile" ]] && continue

  DEVFILE_URL_LIST+=("$devfile")

done < ${DEVFILE_LIST_PATH}

#Run the tests now that everything is set up
CURRENT_SERVER=$(oc whoami --show-server)
echo -e "\n${BLUE}Running test scenario '${SCENARIO}' using ${DEVWORKSPACE_NAME} devworkspace in ${DEVWORKSPACE_NS} namespace against server ${CURRENT_SERVER}...${NC}"

failed_test=()
success_count=0
total_count=0

# Start timing
START_TIME=$SECONDS

if [ ${DEBUG} -eq 0 ]; then
  total_tests=$(( ${#DEVFILE_URL_LIST[@]} * ${#IMAGES_LIST[@]} ))
  log "Iterating over ${#DEVFILE_URL_LIST[@]} Devfiles and ${#IMAGES_LIST[@]} Images"
else
  total_tests=1
  log "${YELLOW}DEBUG MODE!${NC} Only first devfile and first image used."
fi

# echo numbers of tests that will be ran
echo -e "${BLUE}There will be ${total_tests} tests performed in total.${NC}"

for devfile_url in "${DEVFILE_URL_LIST[@]}"; do
  http_code=$(curl -sL -o "${TMP_DEVFILE}" -w '%{http_code}' "${devfile_url}")
  if [ "${http_code}" != "200" ]; then
    echo "${devfile_url} — fetch failed (HTTP ${http_code}), skipping this devfile. Numbers might not be accurate. ❌"
    failed_test+=("Devfile '${devfile_url}' — fetch failed (HTTP ${http_code})")
    continue
  fi

  # Build the projects block: use the devfile's starterProjects if present,
  # otherwise fall back to the default sample project.
  # Must check before indenting the devfile.
  TMP_PROJECTS=$(mktemp -t projects-XXX.yaml)
  if grep -q '^starterProjects:' "${TMP_DEVFILE}"; then
    sed -n '/^starterProjects:/,/^[a-zA-Z]/{/^starterProjects:/p; /^  /p}' "${TMP_DEVFILE}" | \
    sed 's/^starterProjects:/projects:/' | \
    sed 's/^/    /' > "${TMP_PROJECTS}"

  else
    cat > "${TMP_PROJECTS}" <<'PROJEOF'
    projects:
      - name: project-sample
        git:
          remotes:
            origin: PROJECT_URL
PROJEOF
  fi

  sed -i.tmp 's/^/    /' "${TMP_DEVFILE}" && rm -f "${TMP_DEVFILE}.tmp"

  for image in "${IMAGES_LIST[@]}"; do
    #debug mode: stop after one iteration
    [[ ${DEBUG} -eq 1 && ${total_count} == 1 ]] && continue
    log "\n${BLUE}Begin test of ${devfile_url} with ${image}${NC}"
    ((total_count++))
    # Modify DevWorkspace template
    # Goal is to apply a devworkspace resource to the cluster, 
    # with a replacement of the below placeholder in the template:
    # DEVWORKSPACE_NAME -> the devworksapce name in the setting
    # DEVWORKSPACE_NS -> the devworkspace namespace from current context
    # DEVFILE -> one of the devfile url in a list
    # PROJECT_URL -> one the project sample url in a list
    # EDITOR_DEFINITION -> the editor definition url 
    # When using PR mode, replace uri with kubernetes reference; otherwise use uri
    if [ -n "${OVERRIDE_IMAGE}" ]; then
      EDITOR_SED_EXPR="s|uri: EDITOR_DEFINITION|kubernetes:\\
             name: ${EDITOR_DWT_NAME}|"
    else
      EDITOR_SED_EXPR="s|EDITOR_DEFINITION|${EDITOR_DEFINITION}|"
    fi
    cat devworkspace-template.yaml | \
    sed \
    -e "/DEVFILE/r ${TMP_DEVFILE}" \
    -e '/DEVFILE/ d' \
    -e "/PROJECTS/r ${TMP_PROJECTS}" \
    -e '/PROJECTS/ d' \
    -e "s|DEVWORKSPACE_NAME|${DEVWORKSPACE_NAME}|" \
    -e "s|DEVWORKSPACE_NS|${DEVWORKSPACE_NS}|" \
    -e "${EDITOR_SED_EXPR}" \
    -e "s|PROJECT_URL|${PROJECT_URL}|" | \
    # Modify the result (must be separate)
    # here is the replacement of the container image used in the devfile from an image in the list
    eval "sed \"s|image: .*|image: ${image}|\" > ${TMP_DEVWORKSPACE}"
    # Stop the DevWorkspace before applying to force a pod restart
    current_phase=$(oc get dw ${DEVWORKSPACE_NAME} -o 'jsonpath={.status.phase}' 2>/dev/null)
    if [ "${current_phase}" == "Failed" ]; then
      log -n "Force-deleting ${DEVWORKSPACE_NAME} (Failed state) ."
      eval "oc delete dw ${DEVWORKSPACE_NAME} ${QUIET}"
      log " deleted."
    elif [ "${current_phase}" == "Running" ] || [ "${current_phase}" == "Starting" ]; then
      eval "oc patch dw ${DEVWORKSPACE_NAME} --type merge -p '{\"spec\":{\"started\":false}}' ${QUIET}"
      log -n "Stopping ${DEVWORKSPACE_NAME} ."
      stop_count=0
      stop_timeout=$((TIMEOUT / 4))
      while [ "$(oc get dw ${DEVWORKSPACE_NAME} -o 'jsonpath={.status.phase}' 2>/dev/null)" != "Stopped" ] && [ ${stop_count} -lt ${stop_timeout} ]; do
        sleep 1s
        log -n "."
        stop_count=$((stop_count+1))
      done
      if [ ${stop_count} -ge ${stop_timeout} ]; then
        log "\n${YELLOW}${DEVWORKSPACE_NAME} failed to stop (timed out after ${stop_timeout}s)${NC}"
        echo "TEST [${total_count}/${total_tests}] ${devfile_url} with ${image} FAILED ❌"
        failed_test+=("Devfile '$devfile_url' using image '$image'")
        continue
      fi
      log " stopped."
    fi
    eval "oc apply -f ${TMP_DEVWORKSPACE} ${QUIET}"
    state=""
    log -n "Waiting for ${DEVWORKSPACE_NAME} to run ."
    count=0
    while [ "${state}" != "Running" ] && [ "${state}" != "Failed" ] && [ ${count} -lt ${TIMEOUT} ]; do
      state=$(oc get dw ${DEVWORKSPACE_NAME} -o 'jsonpath={.status.phase}')
      sleep 1s
      log -n "."
      count=$((count+1))
    done
    if [ "${state}" == "Running" ]; then
      log "\n${GREEN}${DEVWORKSPACE_NAME} is running.${NC}"
    else
      if [ "${state}" == "Failed" ]; then
        log "\n${YELLOW}${DEVWORKSPACE_NAME} failed to start (state: Failed after ${count}s)${NC}"
      else
        log "\n${YELLOW}${DEVWORKSPACE_NAME} failed to start (timed out after ${TIMEOUT}s, last state: ${state})${NC}"
      fi
      if shouldExclude "${image}"; then
        echo "TEST [${total_count}/${total_tests}] ${devfile_url} with ${image} FAILED ❌ (EXCLUDED ↩️ )"
        excluded_test+=("Devfile '$devfile_url' using image '$image'")
      else
        echo "TEST [${total_count}/${total_tests}] ${devfile_url} with ${image} FAILED ❌"
        failed_test+=("Devfile '$devfile_url' using image '$image'")
      fi
      continue
    fi
    log "Validating ${DEVWORKSPACE_NAME} .."
    validate_devworkspace
    if [ $? -eq 0 ]; then
      echo "TEST [${total_count}/${total_tests}] ${devfile_url} with ${image} PASSED ✅"
      ((success_count++))
    else
      if shouldExclude "${image}"; then
        echo "TEST [${total_count}/${total_tests}] ${devfile_url} with ${image} FAILED ❌ (EXCLUDED ↩️ )"
        excluded_test+=("Devfile '$devfile_url' using image '$image'")
      else
        echo "TEST [${total_count}/${total_tests}] ${devfile_url} with ${image} FAILED ❌"
        failed_test+=("Devfile '$devfile_url' using image '$image'")
      fi
    fi
    sleep 1s
  done # image loop
  [[ ${DEBUG} -eq 1 && ${total_count} -ge 1 ]] && break
done # devfile loop

# cleanup
cleanup() {
  echo -e "\n${BLUE}Cleaning up resources...${NC}"
  eval "oc delete dw ${DEVWORKSPACE_NAME} ${QUIET}"
  if [ -n "${OVERRIDE_IMAGE}" ]; then
    eval "oc delete devworkspacetemplate ${EDITOR_DWT_NAME} ${QUIET}"
  fi
  sleep 1s

  rm "$TMP_DEVFILE"
  rm "$TMP_PROJECTS"
  rm "$TMP_DEVWORKSPACE"
  if [ -n "${OVERRIDE_IMAGE}" ]; then
    rm "$TMP_EDITOR_DEF"
    rm "$TMP_DWT"
  fi
}

if [ ${DEBUG} -eq 0 ]; then
  cleanup
else
  EXTRA_MSG=""
  [ -n "${OVERRIDE_IMAGE}" ] && EXTRA_MSG="\nTemporary editor definition file (${TMP_EDITOR_DEF}) not deleted\nTemporary devworkspace template file (${TMP_DWT}) not deleted\nRemote DevworkspaceTemplate (${EDITOR_DWT_NAME}) not deleted"
  log "\n${YELLOW}Debug mode:${NC}\nRemote Devworkspace (${DEVWORKSPACE_NAME}) not deleted${DWT_MSG}\nTemporary devfile file ($TMP_DEVFILE) not deleted\nTemporary devworkspace file ($TMP_DEVWORKSPACE) not deleted${EXTRA_MSG}\nPlease delete remote Devworkspace if not needed anymore."
fi

# Calculate elapsed time
ELAPSED_TIME=$((SECONDS - START_TIME))
ELAPSED_HOURS=$((ELAPSED_TIME / 3600))
ELAPSED_MIN=$(((ELAPSED_TIME % 3600) / 60))
ELAPSED_SEC=$((ELAPSED_TIME % 60))
if [ ${ELAPSED_HOURS} -gt 0 ]; then
  ELAPSED_DISPLAY="${ELAPSED_HOURS}h ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
else
  ELAPSED_DISPLAY="${ELAPSED_MIN}m ${ELAPSED_SEC}s"
fi

echo    ""
echo    "======================"
echo    "Summary:"
echo -e "  Total tests: ${BLUE}$total_count${NC} "
echo -e "  Successful: ${GREEN}$success_count${NC}"
echo -e "  Failed: ${RED}${#failed_test[@]}${NC}"
echo -e "  Excluded: ${YELLOW}${#excluded_test[@]}${NC}"
echo -e "  Elapsed time: ${PURPLE}${ELAPSED_DISPLAY}${NC}"
echo    "======================"

if [ ${#failed_test[@]} -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for tst in "${failed_test[@]}"; do
    echo "  - $tst"
  done
  exit 1
fi

