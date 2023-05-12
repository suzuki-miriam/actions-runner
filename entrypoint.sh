#!/bin/bash

## Colors
ESC_SEQ="\x1b["
C_RESET=$ESC_SEQ"39;49;00m"
C_BOLD=$ESC_SEQ"39;49;01m"
C_RED=$ESC_SEQ"31;01m"
C_YEL=$ESC_SEQ"33;01m"

ACTION_USER='actions-runner'

RUNNER_PROG_NAME='Runner.Listen'
RUNNER_WORK_NAME='Runner.Worker'

RUNNER_DIR='/runner'
RUNNER_VOLUME_DIR="${RUNNER_DIR}/_volume/ramdisk"

RUNNER_LAST_CHECHED_TIME=$(date +'%Y%m%d%H%M')
RUNNER_CHECK_AGAIN_IN=60    ## 10 in 10 minutes (Avoid Rate limit)

RUNNER_DISABLE_CLEAN_PROCESS="${RUNNER_DIR}/disableCleanAll"

GITHUB_CACHED_DIR="/opt/hostedtoolcache"
GITHUB_RUNNER_WORK_TOOL_DIR="${RUNNER_VOLUME_DIR}/_tool"

function _log() {
    case $1 in
      erro) logLevel="${C_RED}[ERRO]${C_RESET}";;
      warn) logLevel="${C_YEL}[WARN]${C_RESET}";;
      *)    logLevel="${C_BOLD}[INFO]${C_RESET}";;
    esac

    echo -e "$(date +"%d-%b-%Y %H:%M:%S") ${logLevel} - ${2}"
}

RUNNER_URL="https://api.github.com/orgs/${GITHUB_ORG}/actions/runners"
TOKEN_URL="${RUNNER_URL}/registration-token"
GITHUB_ORG_URL="https://github.com/${GITHUB_ORG}"

_log info "Getting token from: ${TOKEN_URL}"
CURL_HEADERS="-H 'Authorization: token ${GITHUB_TOKEN}' -H 'Accept: application/vnd.github.v3+json'"
CRUL_CMD="curl -sX POST ${CURL_HEADERS} ${TOKEN_URL} | jq --raw-output .token"
TOKEN=$(eval ${CRUL_CMD})

function _removeOldRunners() {
    OFFLINE_RUNNERS=$(eval curl -s ${CURL_HEADERS} ${RUNNER_URL}?per_page=100 | jq '.runners[] | .id,.name,.status' 2> /dev/null | grep -iB 2 'offline')

    ((${#OFFLINE_RUNNERS}>10)) && (
        _log info "Starting runner cleanup..." &&
        for runner in ${OFFLINE_RUNNERS}; do
            RUNNER_ID=${runner/ */}
            if grep -v "^[0-9]*$" <<< ${RUNNER_ID}; then continue;fi
            _log info "RunnerID to be removed [${RUNNER_ID}]"
            eval curl -s -XDELETE ${CURL_HEADERS} ${RUNNER_URL}/${RUNNER_ID} &&
                   _log info "Removed" ||
                   _log erro "NOT Removed"
        done) ||
        _log info "No offline runners found to be cleaned"
}

function _isRunnerAlive() {

    ## FIRTS Check on GITHUB

    ## Load runner id from file
    RUNNER_ID=$(test -f ${RUNNER_DIR}/.runner && jq --raw-output .agentId ${RUNNER_DIR}/.runner || echo 'IDNotFound')
    RUNNER_NAME=$(hostname)

    let DIFF_LAST_TIME_TO_NOW=$(date +'%Y%m%d%H%M')-${RUNNER_LAST_CHECHED_TIME}

    ## Check if it's time check runner (Avoid Rate limit)
    ((${DIFF_LAST_TIME_TO_NOW} > ${RUNNER_CHECK_AGAIN_IN})) &&
        _log info "Time to check if runner [${RUNNER_NAME}] with id [${RUNNER_ID}] is alive on GITHUB..." ||
        return

    RUNNER_STATUS_ON_GH=$(eval curl -s ${CURL_HEADERS} ${RUNNER_URL}/${RUNNER_ID} | jq -r '.status')

    if egrep -qi 'online|idle|active' <<< ${RUNNER_STATUS_ON_GH}; then
        _log info "Runner [${RUNNER_NAME}] is ONLINE. Status is [${RUNNER_STATUS_ON_GH}]"
    else
        _log warn "Runner [${RUNNER_NAME}] is NOT online. Status was [${RUNNER_STATUS_ON_GH}]. Runner will be killed NOW..."
        _unregisterRunner 1
    fi

    ## SECOND - Check if docker is runnig
    _log info "Checking if docker is running..."
    docker ps > /dev/null &&
        _log info "Docker is UP AND RUNNING." ||
        _unregisterRunner 1

    ## Update date after verification
    RUNNER_LAST_CHECHED_TIME=$(date +'%Y%m%d%H%M')
}

function _registerRunner() {
    _log info "Configuring and registring runner with token [${TOKEN}]..."
    ./config.sh \
       --replace \
       --unattended \
       --work ${RUNNER_VOLUME_DIR} \
       --url ${GITHUB_ORG_URL} \
       --token ${TOKEN} \
       --labels ${GITHUB_RUNNER_LABELS}
}

function _ensureVolumeExistence() {
    if [[ ! -d ${RUNNER_VOLUME_DIR} ]]; then 
        _log warn "Directory ${RUNNER_VOLUME_DIR} didn't existed prior. Maybe this is a volume related issue"
        mkdir -p ${RUNNER_VOLUME_DIR}
        _log warn "Directory ${RUNNER_VOLUME_DIR} created."
    else
        _log info "Directory ${RUNNER_VOLUME_DIR} exists."
    fi
}

function _changeVolumeOwner() {
    _log info "Owner of $RUNNER_VOLUME_DIR changed to ${ACTION_USER}"
    [[ -d ${RUNNER_VOLUME_DIR} ]] && sudo chown -R ${ACTION_USER}: $RUNNER_VOLUME_DIR
}

function _setupPythonWorkArround() {
    _log info "Keep Self Hosted Cache similar to Github Hosted. Link ${GITHUB_CACHED_DIR} -> ${GITHUB_RUNNER_WORK_TOOL_DIR}"
    sudo ln -s ${GITHUB_RUNNER_WORK_TOOL_DIR} ${GITHUB_CACHED_DIR}
}

function _unregisterRunner() {
    _log info "Removing runner [$(hostname)] with token [${TOKEN}] from org: ${GITHUB_ORG}"

    ## Load runner id from file
    RUNNER_ID=$(test -f ${RUNNER_DIR}/.runner && jq --raw-output .agentId ${RUNNER_DIR}/.runner || echo 'IDNotFound')

    ## If any job is running on shutdown, need to kill
    pgrep ${RUNNER_WORK_NAME} > /dev/null &&
        _log info "Forced to kill current job on [$(hostname)] due a shutdown..." &&
        pkill -15 -P $(pgrep ${RUNNER_WORK_NAME}) &&
        WAIT_COUNT=0 &&
        WAIT_TIMEOUT=20 &&
        while [[ -n "$(pgrep ${RUNNER_WORK_NAME})" ]] && ((WAIT_COUNT<WAIT_TIMEOUT)); do
            let WAIT_COUNT++
            sleep 1
        done

    ## Kill listener to avoid "zombie" runner
    pgrep ${RUNNER_PROG_NAME} > /dev/null &&
        _log info "Killing master process [${RUNNER_PROG_NAME}] due a shutdown..." &&
        pkill -15 -P $(pgrep ${RUNNER_PROG_NAME})

    _log info "Trying to unregister now..."
    ./config.sh remove --token ${TOKEN}
    sleep 1

    WAIT_COUNT=0
    WAIT_TIMEOUT=10
    CURL_CMD="curl -s -XDELETE --write-out '%{http_code}' ${CURL_HEADERS} ${RUNNER_URL}/${RUNNER_ID}"
    _log info "ENSURE to remove runnerId [${RUNNER_ID}] from org: ${GITHUB_ORG} by API [${RUNNER_URL}/${RUNNER_ID}]"
    while CURL_RESPONSE=$(eval ${CURL_CMD}) && ((WAIT_COUNT<WAIT_TIMEOUT)); do
        let WAIT_COUNT++
        _log info "Waiting 2xx from API response: status code [${CURL_RESPONSE}]..."
        grep -q '2..' <<< ${CURL_RESPONSE} && break
        sleep 1
    done

    ## To be sure that nothing was leaving behind
    (sleep 1; sudo pkill -u root; pkill -u ${ACTION_USER}) &

    if [[ "$1" == "0" ]]; then
        _log info "Docker/Pod is shutting down, exiting bye :)"
        exit 0
    else
        _log erro "Something went wrong :("
        exit 1
    fi
}

function _createWelcomeMessage() {
    _log info "Creating Welcome message [.bashrc]..."
    echo "echo 'To disable clean process, just create this file [touch ${RUNNER_DISABLE_CLEAN_PROCESS}]'" >> /home/${ACTION_USER}/.bashrc
}

## Clean all Mess (Looping)
function _cleanAllTheMessLeaveBehind(){
    while true; do
        sleep 30

        ## Debug mode to not clean workdir
        test -f ${RUNNER_DISABLE_CLEAN_PROCESS} &&
            _log warn "File [${RUNNER_DISABLE_CLEAN_PROCESS}] is enabled. The cleaning process will be skipped now. BE CAREFUL!" &&
            continue

        ## Check if a job is execution or a self-update
        SLEEP_UPDATE=300
        test -d ${RUNNER_VOLUME_DIR}/_update &&
            stat ${RUNNER_VOLUME_DIR}/_update | grep -q $(date +%Y-%m-%d) &&
            _log warn "Sleep for ${SLEEP_UPDATE} seconds more due update..." &&
            sleep ${SLEEP_UPDATE}
        (ps -eo ppid | grep -q "$(pgrep ${RUNNER_PROG_NAME})" || egrep -q "_update|safe_sleep" <<< $(ps -ef)) &&
            _log warn "There is a JOB running right now. Will not check the mess! Sleeping..." &&
            continue

        _isRunnerAlive

        _log info "Starting process to clean the mess (Docker, Docker images, Process...)"

        ## Always clean Workdir
        _log info "Clean up ramdisk status before: [$(df -h | grep ${RUNNER_VOLUME_DIR})]..."
        sudo rm -rf ${RUNNER_VOLUME_DIR}/*
        _log info "Clean up ramdisk status after: [$(df -h | grep ${RUNNER_VOLUME_DIR})]"

        ## Remove .npmrc to avoid https://olxbrasil.slack.com/archives/CC4GUQSBB/p1680537167192689
        ## People using old procedure
        test -f ${HOME}/.npmrc &&
            _log info "Removing dirt left by other runs [${HOME}/.npmrc]..." &&
            rm ${HOME}/.npmrc

        ## Lost Process (Like cypress in Background)
        ## Process with PPID 1 is lost (Only entrypoint cloud be 1)
        ps -eo ppid,pid,args | egrep -v "cron|sleep|bash" | awk '$1 == 1 {print}'
        pidsToKill=$(ps -eo ppid,pid,args | egrep -v "cron|sleep|bash" | awk '$1 == 1 {print $2}')
        ((${#pidsToKill}>1)) &&
            _log info "Killing [${#pidsToKill}] lost process(es) leave behind..." &&
            kill -9 ${pidsToKill}

        ## Docker
        dockerImagesUp=($(docker ps -q))
        ((${#dockerImagesUp}>1)) &&
            _log info "Cleaning up [${#dockerImagesUp[@]})] docker images up." &&
            docker stop ${dockerImagesUp}

        _log info "Clean up unnecessary images to avoid Evictions..."
        regexImages='ecr.*.amazonaws.com|olxbr|^vivareal/'
        docker images | egrep ${regexImages} &&
        docker rmi -f $(docker images | egrep ${regexImages} | awk '{print $1":"$2}')

        _log info "Clean up images Built Locally..."
        for imageAndTag in $(docker images | awk '{print $1":"$2}'| grep -v REPOSITORY); do
            arrayIntermediateImagesID=($(docker history -q ${imageAndTag} | grep -v "missing"))

            ## Images built locally has more than 1 intermediate image ID
            ((${#arrayIntermediateImagesID[@]}>1)) &&
                _log info "Removing image [${imageAndTag}] built locally..." &&
                docker rmi -f ${imageAndTag}
        done

        _log info "Listing Docker images size..."
        docker system df

        _log info "Clean up docker system..."
        docker system prune -f

        _log info "Clean All The Mess, finished!"
    done
}

## MAIN ##
(sleep 120 && _removeOldRunners) &
trap "_unregisterRunner 0" SIGTERM
sudo /etc/init.d/cron start
_cleanAllTheMessLeaveBehind &
_createWelcomeMessage
_ensureVolumeExistence
_changeVolumeOwner
_setupPythonWorkArround
_registerRunner
_log info "New execution. Starting runner..."
./run.sh "$*" &
wait $!
_log warn "Runner has been stopped. Maybe a self update :/"

## Loop if self update occurs
RETRY=0
RETRY_TIMEOUT=90
while ((${RETRY}<${RETRY_TIMEOUT})); do
    let RETRY++
    _log info "Waiting Runner for boot: retry (${RETRY}/${RETRY_TIMEOUT})..."
    sleep 1

    ## Keep this loop if runner was self-updated and still running
    while [[ -n "$(pgrep ${RUNNER_PROG_NAME})" ]]; do
        if ((${RETRY}>0)); then
            _log info "Runner is up with pid [$(pgrep ${RUNNER_PROG_NAME})]"
            RETRY=0
        fi
        sleep 2
    done
done

_log erro "Exceeded max retry count, giving up to wait, EXIT..."
_unregisterRunner 1
