#!/usr/bin/env bash

# Exit on error. Append "|| true" if you expect an error.
set -o errexit
# Exit on error inside any functions or subshells.
set -o errtrace
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
set -o nounset
# Catch the error in case mysqldump fails (but gzip succeeds) in `mysqldump |gzip`
set -o pipefail

HOSTS_FILE="$GITHUB_WORKSPACE/.github/hosts.yml"
GITHUB_BRANCH="${GITHUB_REF_NAME}"
GITHUB_REPO_NAME="${GITHUB_REPOSITORY##*/}"

LOG_LEVEL="${LOG_LEVEL:-6}" # 7 = debug -> 0 = emergency
NO_COLOR="${NO_COLOR:-}"    # true = disable color. otherwise autodetected

RED="\033[31m"
GREEN="\033[32m"
CYAN="\033[36m"
BLUE="\033[34m"
ENDCOLOR="\033[0m"

# Define array with color codes
declare -A colors
colors["debug"]="\\x1b[35m"
colors["info"]="\\x1b[32m"
colors["notice"]="\\x1b[34m"
colors["warning"]="\\x1b[33m"
colors["error"]="\\x1b[31m"
colors["critical"]="\\x1b[1;31m"
colors["alert"]="\\x1b[1;37;41m"
colors["emergency"]="\\x1b[1;4;5;37;41m"
colors["reset"]="\\x1b[0m"

# Install yq
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &&\
chmod +x /usr/bin/yq

set -x

HOSTS_FILE_HAS_APP_PATHS="$(yq -roy ".\"${GITHUB_BRANCH}\".\"${SITE_NAME}\" | has(\"apps_paths\")" < "$HOSTS_FILE")"
HOSTS_FILE_HAS_SUBMODULE_APP_PATHS="$(yq -roy ".\"${GITHUB_BRANCH}\".\"${SITE_NAME}\" | has(\"submodule_apps_paths\")" < "$HOSTS_FILE")"

# Check if repo is app or not
if [[ 'false' == "$HOSTS_FILE_HAS_APP_PATHS" ]] && [[ 'false' == "$HOSTS_FILE_HAS_SUBMODULE_APP_PATHS" ]]; then
    echo 'BRANCH_APP=true' >> "$GITHUB_ENV"
    if [[ -z "${BRANCH_APP:-}" ]]; then
        echo "BRANCH_APP is not set, setting it to true"
        BRANCH_APP="true"
    fi
fi

set +x

BRANCH_KEYS=$(yq -Mr -o y ".${GITHUB_BRANCH}" < "$HOSTS_FILE")
[[ "${SITE_NAME:-}" ]] || emergency "Site Name not provided. Please Set env SITE_NAME to match in hosts.yml."

# Log function
function __log () {
  local log_level="${1}"
  shift
  local ___c="${colors[$log_level]}"
  # shellcheck disable=SC2034
  local ___ce="${colors["error"]}"
  # Add ANSI color codes for logging
  local color="${___c:-___ce}"
  local color_reset="${colors["reset"]}"

  if [[ "${NO_COLOR:-}" = "true" ]] || { [[ "${TERM:-}" != "xterm"* ]] && [[ "${TERM:-}" != "screen"* ]]; } || [[ ! -t 2 ]]; then
    if [[ "${NO_COLOR:-}" != "false" ]]; then
      # Don't use colors on pipes or non-recognized terminals, it can mess with formatting or break scripts
      color=""; color_reset=""
    fi
  fi

  # all remaining arguments are to be printed
  local log_line=""
  while IFS=$'\n' read -r log_line; do
    width=9
    padding=$(( (width - ${#log_level}) / 2 ))
    echo -e "$(date -u +"%Y-%m-%d %H:%M:%S UTC") ${color}$(printf "[%${padding}s%s%${padding}s]" "" "${log_level}" "" )${color_reset} ${log_line}" 1>&2
  done <<< "${@:-}"
}

# Log function aliases for each log level
function emergency () {                                  __log emergency "${@}"; exit 1; }
function alert ()     { [[ "${LOG_LEVEL:-0}" -ge 1 ]] && __log alert "${@}"; true; }
function critical ()  { [[ "${LOG_LEVEL:-0}" -ge 2 ]] && __log critical "${@}"; true; }
function error ()     { [[ "${LOG_LEVEL:-0}" -ge 3 ]] && __log error "${@}"; true; }
function warn ()      { [[ "${LOG_LEVEL:-0}" -ge 4 ]] && __log warning "${@}"; true; }
function notice ()    { [[ "${LOG_LEVEL:-0}" -ge 5 ]] && __log notice "${@}"; true; }
function info ()      { [[ "${LOG_LEVEL:-0}" -ge 6 ]] && __log info "${@}"; true; }
function debug ()     { [[ "${LOG_LEVEL:-0}" -ge 7 ]] && __log debug "${@}"; true; }

function check_command_status () {
    if [ "$?" -gt "$1" ]; then
        emergency "$2"
    else
        info "$3"
    fi
}

hosts_file="$GITHUB_WORKSPACE/.github/hosts.yml" #export PATH="$PATH:$COMPOSER_HOME/vendor/bin"
PROJECT_ROOT="$(pwd)"
export PROJECT_ROOT
export HTDOCS="$HOME/htdocs"
export GITHUB_BRANCH=${GITHUB_REF##*heads/}
CUSTOM_SCRIPT_DIR="$GITHUB_WORKSPACE/.github/deploy"
JUMPHOST_SERVER=

function init_checks() {

	# Check if branch is available
	if [[ "$GITHUB_REF" == "" ]]; then
		echo "\$GITHUB_REF is not set"
		exit 1
	fi

	# Check for SSH key if jump host is defined
	if [[ -n "$JUMPHOST_SERVER" ]]; then

		if [[ -z "$SSH_PRIVATE_KEY" ]]; then
			echo "Jump host configuration does not work with vault ssh signing."
			echo "SSH_PRIVATE_KEY secret needs to be added."
			echo "The SSH key should have access to the server as well as jumphost."
			exit 1
		fi
	fi

	# Exit if branch deletion detected
	if [[ "true" == $(jq --raw-output .deleted "$GITHUB_EVENT_PATH") ]]; then
		echo 'Branch deletion trigger found. Skipping deployment.'
		exit 78
	fi
}

function setup_hosts_file() {

	# Setup hosts file
	rsync -av --temp-dir=/tmp "$hosts_file" /hosts.yml
	cat /hosts.yml
}

function check_branch_in_hosts_file() {

	match=0
	for branch in $(cat "$hosts_file" | shyaml keys); do
		[[ "$GITHUB_REF" == "refs/heads/$branch" ]] &&
			echo "$GITHUB_REF matches refs/heads/$branch" &&
			match=1
	done

	# check if the deploy branch is same
	# Exit neutral if no match found
	if [[ "$match" -eq 0 ]]; then
		echo "$GITHUB_REF does not match with any given branch in 'hosts.yml'"
		exit 78
	fi
}

function setup_private_key() {

	if [[ -n "$SSH_PRIVATE_KEY" ]]; then
		echo "$SSH_PRIVATE_KEY" | tr -d '\r' >"$SSH_DIR/id_rsa"
		chmod 600 "$SSH_DIR/id_rsa"
		eval "$(ssh-agent -s)"
		ssh-add "$SSH_DIR/id_rsa"

		for branch in $(cat "$hosts_file" | shyaml keys); do
			hostadd=$(cat "$hosts_file" | shyaml get-value "$GITHUB_BRANCH.${SITE_NAME//[.]/\\.}.hostname")
			ssh-keyscan -H "$hostadd" >>/etc/ssh/known_hosts

		done

		if [[ -n "${JUMPHOST_SERVER:-}" ]]; then
			ssh-keyscan -H "$JUMPHOST_SERVER" >>/etc/ssh/known_hosts
		fi
	else
		# Generate a key-pair
		ssh-keygen -t rsa -b 4096 -C "GH-actions-ssh-deploy-key" -f "$HOME/.ssh/id_rsa" -N ""
	fi
}

function maybe_get_ssh_cert_from_vault() {

	# Get signed key from vault
	if [[ -n "${VAULT_GITHUB_TOKEN:-}" ]]; then
		unset VAULT_TOKEN
		vault login -method=github token="$VAULT_GITHUB_TOKEN" >/dev/null
	fi

	if [[ -n "${VAULT_ADDR:-}" ]]; then
		vault write -field=signed_key ssh-client-signer/sign/my-role public_key=@$HOME/.ssh/id_rsa.pub >$HOME/.ssh/signed-cert.pub
	fi
}

#IdentityFile ${SSH_DIR}/signed-cert.pub
function configure_ssh_config() {

	if [[ -z "$JUMPHOST_SERVER" ]]; then
		# Create ssh config file. `~/.ssh/config` does not work.
		cat >/etc/ssh/ssh_config <<EOL
Host $hostname
HostName $hostname
IdentityFile ${SSH_DIR}/id_rsa
User $ssh_user
EOL
	else
		# Create ssh config file. `~/.ssh/config` does not work.
		cat >/etc/ssh/ssh_config <<EOL
Host jumphost
	HostName $JUMPHOST_SERVER
	UserKnownHostsFile /etc/ssh/known_hosts
	User $ssh_user

Host $hostname
	HostName $hostname
	ProxyJump jumphost
	UserKnownHostsFile /etc/ssh/known_hosts
	User $ssh_user
EOL
	fi

}

function setup_ssh_access() {

	# get hostname and ssh user
	hostname=$(cat "$hosts_file" | shyaml get-value "$GITHUB_BRANCH.${SITE_NAME//[.]/\\.}.hostname") || emergency "hostname not found in hosts.yml/$SITE_NAME"
	ssh_user=$(cat "$hosts_file" | shyaml get-value "$GITHUB_BRANCH.${SITE_NAME//[.]/\\.}.user") || emergency "user not found in hosts.yml/$SITE_NAME"
	export hostname
	export ssh_user

	printf "[\e[0;34mNOTICE\e[0m] Setting up SSH access to server.\n"

	SSH_DIR="$HOME/.ssh"
	mkdir -p "$SSH_DIR"
	chmod 700 "$SSH_DIR"

	setup_private_key
	maybe_get_ssh_cert_from_vault
	configure_ssh_config
}

# Remote execute command on a ssh connection
remote_execute() {
    [[ "${REMOTE_USER}" ]] || emergency "REMOTE_USER not found."
    [[ "${REMOTE_HOST}" ]] || emergency "REMOTE_USER not found."
    path="$1"
    cmd="$2"
    to_exec="cd $path && $cmd"
    # We want expansion to happen in our script itself
    # shellcheck disable=SC2029
    ssh "${REMOTE_USER}"@"${REMOTE_HOST}" "$to_exec"
}

function maybe_install_submodules() {

	# Change directory ownership to container user due to issue https://github.com/actions/checkout/issues/760
	# This will be changed to www-data or similar on deployment by deployer.
	chown -R root: "$GITHUB_WORKSPACE"
	# Check and update submodules if any
	if [[ -f "$GITHUB_WORKSPACE/.gitmodules" ]]; then
		# add github's public key
		curl -sL https://api.github.com/meta | jq -r '.ssh_keys | .[]' | sed -e 's/^/github.com /' >>/etc/ssh/known_hosts

		identity_file=''
		if [[ -n "$SUBMODULE_DEPLOY_KEY" ]]; then
			echo "$SUBMODULE_DEPLOY_KEY" | tr -d '\r' >"$SSH_DIR/submodule_deploy_key"
			chmod 600 "$SSH_DIR/submodule_deploy_key"
			ssh-add "$SSH_DIR/submodule_deploy_key"
			identity_file="IdentityFile ${SSH_DIR}/submodule_deploy_key"
		fi

		# Setup config file for proper git cloning
		cat >>/etc/ssh/ssh_config <<EOL
Host github.com
HostName github.com
User git
UserKnownHostsFile /etc/ssh/known_hosts
${identity_file}
EOL
		git submodule update --init --recursive
	fi
}
run_deploy_sh() {
	cp -r /github/home/.ssh/ /home/frappe/.ssh
	cp /etc/ssh/ssh_config /home/frappe/.ssh/config
	chown -R frappe:frappe /home/frappe/.ssh/ /github/home/.ssh
	su frappe -c "bash /deploy.sh"
}

check_if_branch_exits_in_hosts(){
    match=1
    for branch in $(shyaml keys < "$HOSTS_FILE"); do
        [[ "$GITHUB_REF_NAME" == "$branch" ]] && match=0
    done
    if [[ "$match" -eq 1 ]]; then
        emergency "$GITHUB_REF_NAME is not configured in hosts.yml"
    fi
}


dbg_mktemp() {
    local out
    out=$(mktemp "$@")

}

init_setup(){

    # this file contains the default filters
    FILTERS_FILE="$GITHUB_WORKSPACE/.github/filters.yml"
    FILTERS_FILE_DEFAULTS=$(cat "$GITHUB_WORKSPACE/.github/filters.yml")
    FILTERS_FILE_DATA=$(mktemp)

    echo "$FILTERS_FILE_DEFAULTS" > "$FILTERS_FILE_DATA"

    if [[ "${INIT_SETUP:-}" == "true" ]]; then

        if ! yq -o y ".${GITHUB_BRANCH}.\"${SITE_NAME}\"" < "$HOSTS_FILE"; then
            emergency "$SITE_NAME not available for branch ${GITHUB_BRANCH} in hosts.yml"
        fi

        # add workflow filter
        # WORKFLOW_FILTER=$(echo "$GITHUB_WORKFLOW_REF" | grep -oE "\.github.*@")
        # WORKFLOW_FILTER="${WORKFLOW_FILTER//@/}"
        # echo "  - $WORKFLOW_FILTER" >> "$FILTERS_FILE_DATA"

        # add apps dir filters
        # install yq

        if yq -o y ".${GITHUB_BRANCH}.\"${SITE_NAME}\".apps_paths" < "$HOSTS_FILE"; then

            APPS_PATHS=$(yq -o y ".${GITHUB_BRANCH}.\"${SITE_NAME}\".apps_paths" < "$HOSTS_FILE")
            SUBMODULE_APPS_PATHS=$(yq -o y ".${GITHUB_BRANCH}.\"${SITE_NAME}\".submodule_apps_paths" < "$HOSTS_FILE")

            # check if APPS_PATHS exist
            [[ "${APPS_PATHS:-}" ]] || emergency "apps_paths key is required. Update hosts.yml"

            APPS_PATHS=$(echo "$APPS_PATHS" | yq -r '.[]')
            SUBMODULE_APPS_PATHS=$(echo "$SUBMODULE_APPS_PATHS" | yq -r '.[]')

            for app in $APPS_PATHS; do
                filter_name="${app}"
                JSON_FILTERS=$(cat "$FILTERS_FILE_DATA" | yq -o json '.')
                echo "$JSON_FILTERS" | yq -o json '.' | jq ". + {\"${filter_name}\": [\"${app}/**\"] }" | yq -o y . > "$FILTERS_FILE_DATA"
            done

            for sub_app in $SUBMODULE_APPS_PATHS; do
                sub_filter_name="${sub_app}"
                SUB_JSON_FILTERS=$(cat "$FILTERS_FILE_DATA" | yq -o json '.')
                echo "$SUB_JSON_FILTERS" | yq -o json '.' | jq ". + {\"${sub_filter_name}\": [\"${sub_app}\"] }" | yq -o y . > "$FILTERS_FILE_DATA"
            done

            cat "$FILTERS_FILE_DATA" > "$FILTERS_FILE"

        else
            # echo "Fix hosts.yml. apps_paths key should contain yaml list."
            echo "- ${GITHUB_WORKSPACE}" > "$FILTERS_FILE"  # Our repo is the app itself
        fi
        info "All Green. Proceeding with deployment."
        info "Adding $GITHUB_WORKSPACE to safe.directory"
        git config --global --add safe.directory "$GITHUB_WORKSPACE"
        exit
    fi
}

setup_basic() {
    REMOTE_HOST=$(shyaml get-value hostname <<< "$HOSTS_INFO" 2>/dev/null || exit 0)
    REMOTE_USER=$(shyaml get-value user <<< "$HOSTS_INFO" 2>/dev/null || exit 0)
    REMOTE_PATH=$(shyaml get-value deploy_path <<< "$HOSTS_INFO" 2>/dev/null || exit 0)
    FRAPPE_BRANCH=$(shyaml get-value frappe_branch <<< "$HOSTS_INFO" 2>/dev/null || exit 0)
    AUTO_UPDATE_APP_LIST=$(shyaml get-value auto_update_apps <<< "$HOSTS_INFO" 2>/dev/null || exit 0)
    RELEASES_LIMIT=$(shyaml get-value prev_releases_limit <<< "$HOSTS_INFO" 2>/dev/null || exit 0)

    REMOTE_SITE="$SITE_NAME"

    [[ "${REMOTE_HOST:-}" ]] || emergency "The variable ${CYAN} hostname ${ENDCOLOR} is missing in hosts.yml"
    [[ "${REMOTE_USER:-}" ]] || emergency "The vairable ${CYAN} user ${ENDCOLOR} is missing in hosts.yml"
    [[ "${REMOTE_SITE:-}" ]] || emergency "The variable ${CYAN} site_name ${ENDCOLOR} is missing in hosts.yml"
    [[ "${REMOTE_PATH:-}" ]] || emergency "The variable ${CYAN} deploy_path ${ENDCOLOR} is missing in hosts.yml"
    [[ "${FRAPPE_BRANCH:-}" ]] || warn "The variable ${CYAN} frappe_branch ${ENDCOLOR} is missing in hosts.yml." "Frappe branch handling will be skipped."
    [[ "${AUTO_UPDATE_APP_LIST:-}" ]] || warn "The variable ${CYAN} auto_update_apps ${ENDCOLOR} is missing in hosts.yml." "Auto Updating Frappeverse apps will be skipped."

    setup_ssh_access
    ssh-keyscan -H "$REMOTE_HOST" >> /etc/ssh/ssh_known_hosts

    # remove leading slash
    REMOTE_PATH="${REMOTE_PATH%/}"

    RELEASE_FOLDER_NAME=$(date +'%d-%b-%Y--%H-%M')

    REMOTE_RELEASE_PATH="${REMOTE_PATH}/releases/${RELEASE_FOLDER_NAME}"
    LOCAL_RELEASE_PATH="${HOME}/releases/$RELEASE_FOLDER_NAME"

    # getting apps list
    APPS_BENCH_LIST=$(remote_execute "$REMOTE_PATH" "ls -1 apps" | sort)
    SITE_LIST_OUTPUT=$(remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} list-apps")
    APPS_SITE_LIST=$(echo "$SITE_LIST_OUTPUT" | tr -s ' ' | cut -d' ' -f1 | sort)
}

# This function validates the list of apps to be auto-updated
auto_update_app_validations(){


    # If the AUTO_UPDATE_APP_LIST environment variable is set
    if [[ "${AUTO_UPDATE_APP_LIST:-}" ]];then

       # Split the list of apps to update into separate lines and sort them
       APPS_TO_UPDATE=$(awk -F',' '{ for (i=1;i<=NF;i++) print $i }' <<<"$AUTO_UPDATE_APP_LIST" | sort)

       # Create a temporary file and write the sorted list of apps to update into it
       apps_update=$(mktemp)
       echo "$APPS_TO_UPDATE" >> "$apps_update"

       # Create another temporary file and write the list of installed apps into it
       apps_installed=$(mktemp)
       echo "$APPS_BENCH_LIST" >> "$apps_installed"

       # Find the apps that are in the update list but not installed
       CHECK_APPS_TO_UPDATE=$(comm -23 "$apps_update" "$apps_installed")

       # Find the apps that are installed but not in the update list
       APPS_TO_EXCLUDE=$(comm -23 "$apps_installed" "$apps_update")

       # If there are any apps in the update list that are not installed
       if [[ "$(echo "${CHECK_APPS_TO_UPDATE}" | grep -v '^\s*$' | wc -l)" -ne 0 ]]; then

           # Warn the user that these apps are not installed
           warn "${CYAN} $(echo "${CHECK_APPS_TO_UPDATE}" | awk -v ORS=' ' '{ print }')${ENDCOLOR} is not installed in bench."

           # Warn the user that auto update is disabled and no apps will be updated
           warn "Auto update disabled, no apps are going to be updated." "Please fix ${CYAN} auto_update_app_list ${ENDCOLOR} variable in hosts.yml."
       fi
    fi
}

before_deploy() {
    if [[ -d "$LOCAL_RELEASE_PATH" ]]; then
        rm -rf "$LOCAL_RELEASE_PATH"
    fi

    # create local release folder
    mkdir -p "$LOCAL_RELEASE_PATH"

    # Create temporary files for storing the names of changed and unchanged apps
    NOT_CHANGED_APPS=$(mktemp)
    CHANGED_APPS=$(mktemp)

    # Loop through the list of changed apps

    CHANGED_APPS_LIST=$(cat "$CHANGED_APPS_LIST")
    ALL_APPS_LIST=$(cat "$ALL_APPS_LIST")

    echo "CHANGED_APPS_LIST:: $CHANGED_APPS_LIST"

    for app_dir in $CHANGED_APPS_LIST; do
        # Find the path to the hooks.py file in the app directory
        hooks_py_path=$(find "$app_dir" -maxdepth 2 -type f -name hooks.py)

        # Extract the app name from the hooks.py file
        APP_NAME=$(awk -v ORS="" '/app_name\s+=\s+(.*)/ {for (i=3;i<=NF; ++i) print $i }' "$hooks_py_path" | jq -cr "." || exit 0)
        if ! [[ "${APP_NAME:-}" ]]; then
            # If the app name is not found, use app name from basename of the app dir
            APP_NAME=${app_dir##*/}
        fi
        check_if_required_apps_available "$hooks_py_path" "$app_dir"

        # Copy the app directory to the local release path
        cp -r "${GITHUB_WORKSPACE}/${app_dir}" "$LOCAL_RELEASE_PATH/$APP_NAME"

        # Add the app name to the list of changed apps
        echo "$APP_NAME" >> "$CHANGED_APPS"
    done

    temp_changed_apps_list=$(mktemp)
    echo "$CHANGED_APPS_LIST" > "$temp_changed_apps_list"

    temp_all_apps_list=$(mktemp)
    echo "$ALL_APPS_LIST" > "$temp_all_apps_list"

    # Find the apps that have not changed by comparing the list of all apps with the list of changed apps
    NOT_CHANGED_APPS_LIST=$(comm -13 "$temp_changed_apps_list" "$temp_all_apps_list")

    # Loop through the list of unchanged apps
    for app_dir in $NOT_CHANGED_APPS_LIST; do

        # Find the path to the hooks.py file in the app directory
        hooks_py_path=$(find "$app_dir" -maxdepth 2 -type f -name hooks.py)

        # Extract the app name from the hooks.py file
        APP_NAME=$(awk -v ORS="" '/app_name\s+=\s+(.*)/ {for (i=3;i<=NF; ++i) print $i }' "$hooks_py_path" | jq -cr "." || exit 0)
        if ! [[ "${APP_NAME:-}" ]]; then
            # If the app name is not found, use app name from basename of the app dir
            APP_NAME=${app_dir##*/}
        fi

        # Add the app name to the list of unchanged apps
        echo "$APP_NAME" >> "$NOT_CHANGED_APPS"
    done

    # Read the contents of the changed and unchanged apps files into variables
    NOT_CHANGED_APPS=$(cat "$NOT_CHANGED_APPS")
    CHANGED_APPS=$(cat "$CHANGED_APPS")

    # Get the contents of the remote apps.json file
    APPSJSON=$(remote_execute "$REMOTE_PATH" "cat ${REMOTE_PATH}/sites/apps.json")

    # Write the contents of the remote apps.json file to the local release path
    echo "$APPSJSON" > "$LOCAL_RELEASE_PATH/apps.json"
}

# branch change should happen before apps update
remote_frappe_branch_handle() {
    if [[ "${FRAPPE_BRANCH:-}" ]]; then
        # Check if Frappe is available on the remote server
        frappe_available=$(remote_execute  "$REMOTE_PATH" "[[ -d 'apps/frappe' ]] && echo true")

        # If Frappe is not available on the remote server
        if ! [[ "$frappe_available" == "true" ]]; then
                # Install Frappe with the given branch
                remote_execute "$REMOTE_PATH" "bench get-app --branch $FRAPPE_BRANCH frappe"
        else
            # If Frappe is available, check if the current branch is the same as the given branch
            frappe_current_branch=$(remote_execute "$REMOTE_PATH" "cd apps/frappe && git branch --show-current")
            echo -e "${BLUE}Server Frappe Branch: $frappe_current_branch ${ENDCOLOR}"

            # If the current branch is not the same as the given branch
            if ! [[ "$frappe_current_branch" == "$FRAPPE_BRANCH" ]]; then
                    remote_execute "$REMOTE_PATH" "bench switch-to-branch --upgrade $FRAPPE_BRANCH frappe"
                    remote_execute "$REMOTE_PATH" "bench update --apps frappe --pull --build --patch --reset"
                    remote_execute "$REMOTE_PATH" "env/bin/pip install -e --upgrade apps/frappe"
                    remote_execute "$REMOTE_PATH" "bench restart"
            fi
        fi
    fi
}

handle_releases(){
    remote_execute "$REMOTE_PATH" "mkdir -p ${REMOTE_PATH}/releases"
    rsync -azh  "$LOCAL_RELEASE_PATH" "$REMOTE_USER@$REMOTE_HOST:${REMOTE_PATH}/releases/"
    check_command_status '0' 'The deployment of the code to the remote server has encountered a failure.' 'The code successfully deployed on the remote server.'

}

remote_site_exists(){
    # check if site exist
    SITE_EXIST_STRING=$(remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} scheduler status")
    if [[ "$SITE_EXIST_STRING" == *"does not exist!"* ]]; then
        emergency "Site: ${REMOTE_SITE} does not exist !!"
    fi
    info "Deployment will take place for site ${BLUE}${REMOTE_SITE}${ENDCOLOR}"
}

remote_maintenance_mode_on(){
    remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} set-maintenance-mode on"
    check_command_status '0' 'Maintenance mode could not be enabled.' 'Maintenance mode enabled.'
}

remote_maintenance_mode_off(){
    remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} set-maintenance-mode off"
    check_command_status '0' 'Maintenance mode could not be disabled.' 'Maintenance mode disabled.'
}

remote_restart(){
    remote_execute "$REMOTE_PATH" "bench restart" || true
}


update_frappeverse_apps(){

    if [[ "${AUTO_UPDATE_APP_LIST:-}" ]]; then
        if ! [[ "${CHECK_APPS_TO_UPDATE:-}" ]]; then
        #validate if the list is correct, if not then exit
        info "Updating frappeverse apps ${GREEN}$AUTO_UPDATE_APP_LIST${ENDCOLOR}"

        apps_exclude_file=$(mktemp)
        echo "$APPS_TO_EXCLUDE" >> "$apps_exclude_file"

        rsync -azh  "$apps_exclude_file" "$REMOTE_USER@$REMOTE_HOST:${REMOTE_PATH}/sites/excluded_apps.txt"

        remote_execute "$REMOTE_PATH" "bench update --pull --reset --patch" || true
        update_status="$?"
        [[ "$update_status" -gt 0 ]] && warn "${RED}Not able to update apps!!${ENDCOLOR}"
        remote_execute "$REMOTE_PATH" "bench setup requirements --node"
        for app_update in $APPS_TO_UPDATE; do
            info "Updating $app_update in Python ENV"
            remote_execute "$REMOTE_PATH" "${REMOTE_PATH}/env/bin/pip install --upgrade -e ${REMOTE_PATH}/apps/$app_update"
            remote_execute "$REMOTE_PATH" "bench build --app $app_update --force --production"
        done
        fi
    fi
}

check_if_required_apps_available(){
    local hooks_py_path
    local APP_NAME

    hooks_py_path="$1"
    APP_NAME="$2"

    # Extract the list of required dependencies from the hooks.py file
    REQUIRED_DEPS=$(awk -v ORS="" '/required_apps\s+=\s+(.*)/ {for (i=3;i<=NF; ++i) print $i }' "$hooks_py_path")

    if ! [[ "$REQUIRED_DEPS"  == '=[]' ]]; then

        # Parse the list of required dependencies and sort them
        REQUIRED_DEPS=$(echo "$REQUIRED_DEPS" | jq -cr '.[]' | sort)

        # Create a temporary file and write the sorted list of required dependencies into it
        apps_required=$(mktemp)
        echo "$REQUIRED_DEPS" >> "$apps_required"

        # Create another temporary file and write the list of installed apps into it
        apps_site=$(mktemp)
        echo "$APPS_SITE_LIST" >> "$apps_site"

        # Find the dependencies that are required but not installed
        CHECK_REQUIRED_APPS=$(comm -23 "$apps_required" "$apps_site")

        # If there are any dependencies that are required but not installed
        if [[ "$(echo "${CHECK_REQUIRED_APPS}" | grep -v '^\s*$' | wc -l)" -ne 0 ]]; then
            # Warn the user that these dependencies are not installed
            warn "${CYAN} $(echo "${CHECK_REQUIRED_APPS}" | awk -v ORS=' ' '{ print }')${ENDCOLOR} is not installed in ${BLUE}${REMOTE_SITE}${ENDCOLOR}."

            # Stop the script and tell the user to install the required dependencies before installing the app
            emergency "Please install required dependencies before installing $APP_NAME."
        fi
    fi
}

handle_apps(){
    #for app in $(remote_execute "$REMOTE_PATH" "ls -1 -d releases/${RELEASE_FOLDER_NAME}/*/"); do
    for app in ${CHANGED_APPS}; do
        app=$(basename "$app")
        echo "::group::Handling Custom App -> $app"

        #check if the app is installed in bench
        REGEX_MATCH=\\b$app\\b

        info "Symlinking $app"
        # symlink the folder
        remote_execute "$REMOTE_PATH" "ln -sfn ${REMOTE_RELEASE_PATH}/$app ${REMOTE_PATH}/apps/$app"

        # Check if the app is already listed in the apps.txt file
        match=0
        while IFS= read -r line; do
            if [ "$line" = "$app" ]; then
                match=1
            fi
        done <<< "$APPS_BENCH_LIST"

        APPS_TXT_FILE=$(mktemp)

        # If the app is not listed in the apps.txt file, add it
        if [[ "$match" -eq 0 ]]; then
            APPSTXT=$(echo -e "${APPS_BENCH_LIST}\n${app}")
            echo "$APPSTXT" >> "$APPS_TXT_FILE"
        else
            echo "$APPS_BENCH_LIST" >> "$APPS_TXT_FILE"
        fi

        # Sync the updated apps.txt file to the remote server
        rsync -azh "$APPS_TXT_FILE" "$REMOTE_USER@$REMOTE_HOST:${REMOTE_PATH}/sites/apps.txt"

        info "Updated sites/apps.txt"

        # Update the apps.json file with the app's data
        UPDATED_JSON_TEMP_FILE=$(mktemp)
        if [[ "$(echo "$APPSJSON" | jq ".${app}" | grep -qv 'null')" -eq 0 ]]; then
            idx=$(echo "$APPSJSON" | jq ".${app}.idx")
        else
            idx=$(echo "$APPSJSON" | jq '[.[] | .idx] | max + 1')
        fi

app_data=$(cat <<GG
{ "is_repo" : false , "resolution" : "not a repo", "required" : [] , "idx" : $idx , "version" : "0.0.1" }
GG
)
        echo "$APPSJSON" | jq '.[$app] = $app_data' --argjson app_data "$app_data" --arg app "$app" >> "$UPDATED_JSON_TEMP_FILE"

        # Sync the updated apps.json file to the remote server
        rsync -azh "$UPDATED_JSON_TEMP_FILE" "$REMOTE_USER@$REMOTE_HOST:${REMOTE_PATH}/sites/apps.json"
        info "Updated sites/apps.json"

        info "Installing $app in Python ENV"

        # Install the app in the Python environment on the remote server
        remote_execute "$REMOTE_PATH" "${REMOTE_PATH}/env/bin/pip install --upgrade -e ${REMOTE_PATH}/apps/$app"

        # if app is not installed on site then install it
        if ! [[ "$APPS_SITE_LIST" =~ $REGEX_MATCH ]]; then
            info "Installing $app in site"
            remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} install-app $app"
        fi

        remote_execute "$REMOTE_PATH" "bench setup requirements --node $app"
        remote_execute "$REMOTE_PATH" "bench build --app $app --force --production"

        # Update the local copies of the apps.json and apps.txt files
        APPSJSON=$(cat "$UPDATED_JSON_TEMP_FILE")
        APPS_BENCH_LIST=$(cat "$APPS_TXT_FILE")
    done

    info "Migrate site"

    remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} migrate"

    info "Clearing site cache"

    remote_execute "$REMOTE_PATH" "bench --site ${REMOTE_SITE} clear-cache"

    # For apps that have not changed, sync their current state to the release path and create a symlink
    for app in $NOT_CHANGED_APPS; do
        info "NOT CHANGED APP: $app rsync to the current release and symlink"
        current_path=$(remote_execute "$REMOTE_PATH" "readlink -f ${REMOTE_PATH}/apps/$app")
        remote_execute "$REMOTE_PATH" "rsync -azh $current_path ${REMOTE_RELEASE_PATH}/"
        # symlink the folder
        remote_execute "$REMOTE_PATH" "ln -sfn ${REMOTE_RELEASE_PATH}/$app ${REMOTE_PATH}/apps/$app"
    done
    echo "::endgroup::"
}

retain_releases(){
    echo "::group::Cleanup Releases."
    if [[ "${RELEASES_LIMIT:-}" ]]; then
        info "Removing redundant previous releases"
        info "Retain only -> $RELEASES_LIMIT releases"
        list_of_releases=$(remote_execute "${REMOTE_PATH}/releases" "ls -1t")
        RELEASES_LIMIT=$(( "$RELEASES_LIMIT" + 1 ))
        to_remove_dirs=$( tail +$RELEASES_LIMIT <<< "$list_of_releases" )

        for dir in $to_remove_dirs; do
            info "Removing dir -> $dir"
            remote_execute "${REMOTE_PATH}/releases" "rm -rf $dir"
        done
    fi
    echo "::endgroup::"
}

get_changed_apps_info() {
    set -x
  HOSTS_INFO=$(yq -Mr ".\"${SITE_NAME}\"" <<<"$BRANCH_KEYS")

    echo "BRANCH_APP is ${BRANCH_APP:-}"

    if [[ "${BRANCH_APP:-}" == "true" ]]; then
        echo "Branch is an app"
        cp -r "$GITHUB_WORKSPACE" "/tmp/$GITHUB_REPO_NAME-bkp"
        rm -rf "$GITHUB_WORKSPACE/${GITHUB_REPO_NAME:?}"
        cp -r "/tmp/$GITHUB_REPO_NAME-bkp" "$GITHUB_WORKSPACE/${GITHUB_REPO_NAME:?}"
#        echo -e "apps_paths: \n  - ${GITHUB_REPO_NAME}" > "$HOSTS_INFO"
        HOSTS_INFO=$(echo -e "$HOSTS_INFO \napps_paths: \n  - $GITHUB_REPO_NAME")
    fi

    ALL_APPS=$(yq -Mr '.apps_paths[],.submodule_apps_paths[]' <<<"$HOSTS_INFO" | sort )
    ALL_APPS_LIST=$(mktemp)
    if [[ "true" == "${BRANCH_APP:-}" ]]; then
        unset ALL_APPS;
        ALL_APPS="$GITHUB_REPO_NAME"
        echo "ALL_APPS: $ALL_APPS"
    fi
    echo "$ALL_APPS" > "$ALL_APPS_LIST"

CHANGED_APPS_LIST=$(mktemp)

# if there are any changes in defaults defined in .github/filters.yml then all the apps_paths should be deployed
IS_DEFAULT_FILTERS_CHANGED=$(grep -cw "defaults" <<< "$CHANGED_APPS" || exit 0)

if [[ "$IS_DEFAULT_FILTERS_CHANGED" -gt 0 ]]; then
    for app in $ALL_APPS; do
            echo "$app" >> "$CHANGED_APPS_LIST"
    done
else
    for app in $ALL_APPS; do
        [[ -d "$GITHUB_WORKSPACE/${app}" ]] || emergency "${app} directory is not available !"

        IS_APP_CHANGED=$(grep -cw "$app" <<< "$CHANGED_APPS" || exit 0)

        if [[ "$IS_APP_CHANGED" -gt 0 ]]; then
            echo "$app" >> "$CHANGED_APPS_LIST"
        fi
    done
fi

CHANGED_APPS_LIST_DATA=$(cat "$CHANGED_APPS_LIST")

#echo "$CHANGED_APPS_LIST_DATA" > "$CHANGED_APPS_LIST"

if ! [[ "${CHANGED_APPS_LIST_DATA:-}" ]]; then
    info "No changes can be found in the below directories to deploy"
    yq -Mr '.apps_paths | .[]' <<<"$HOSTS_INFO"
    yq -Mr '.submodule_apps_paths | .[]' <<<"$HOSTS_INFO"
    info "Exiting with success."
    exit 0
fi
set +x
}

cleanup_if_branch_is_app(){
    if [[ "${BRANCH_APP:-}" == "true" ]]; then
        rm -rf "$GITHUB_WORKSPACE/${GITHUB_REPO_NAME:?}"
        if [[ -e "/tmp/$GITHUB_REPO_NAME-bkp/${GITHUB_REPO_NAME:?}" ]]; then
            cp -r "/tmp/$GITHUB_REPO_NAME-bkp/${GITHUB_REPO_NAME:?}" "$GITHUB_WORKSPACE"
            rm -rf "/tmp/$GITHUB_REPO_NAME-bkp"
        fi
    fi
    ls -al "$GITHUB_WORKSPACE"
}



function main() {

    echo "${GITHUB_WORKSPACE}"
    ls -al "$GITHUB_WORKSPACE"
	if [[ -f "$CUSTOM_SCRIPT_DIR/addon.sh" ]]; then
			source "$CUSTOM_SCRIPT_DIR/addon.sh"
	else
	  info "Deployment on branch: ${BLUE}$GITHUB_BRANCH${ENDCOLOR} "
    check_if_branch_exits_in_hosts
    init_setup
    echo "::endgroup::"
    get_changed_apps_info
		echo "::group::Init and Validations"
    setup_basic
    auto_update_app_validations
    remote_site_exists
    echo "::endgroup::"
    remote_maintenance_mode_on
    set -x
    echo "::group::Handling Frappe and FrappeVerse apps"
    remote_frappe_branch_handle
    update_frappeverse_apps
    echo "::endgroup::"
    before_deploy
    handle_releases
    handle_apps
    remote_restart
    remote_maintenance_mode_off
    retain_releases
    cleanup_if_branch_is_app
	fi
}
main
