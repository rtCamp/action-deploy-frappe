set -ex

export TERM=xterm-color

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
ENDCOLOR="\033[0m"

hosts_file="$GITHUB_WORKSPACE/.github/hosts.yml"

APP_NAME=$(echo "$GITHUB_REPOSITORY" | sed 's:.*/::' )
setup_frappe() {

    mkdir -p "${HOME}/${APP_NAME}"

    rsync -azh  "${GITHUB_WORKSPACE}/" "${HOME}/${APP_NAME}"
    RSYNC_STATUS=$?
    if ! [ $RSYNC_STATUS -eq 0 ]; then
        echo -e "${RED}RSYNC: FAILED${ENDCOLOR}"
        exit 1
    fi
    echo -e "${BLUE}RSYNC: FINISHED${ENDCOLOR}"

    cd "$HOME"
    if  [[ -z "$FRAPPE_BRANCH" ]]; then
        FRAPPE_BRANCH="version-14"
    fi

    bench init --frappe-branch "$FRAPPE_BRANCH" --skip-redis-config-generation --no-procfile --no-backups --skip-assets bench

    cd bench
    bench get-app --skip-assets --resolve-deps "${HOME}/${APP_NAME}"
    BUILD_STATUS=$?
    if ! [ $BUILD_STATUS -eq 0 ]; then
        echo -e "${RED} $APP_NAME BUILD: FAILED${ENDCOLOR}"
        exit 1
    fi
    echo -e "${BLUE} ${APP_NAME} BUILD: FINISHED${ENDCOLOR}"


    mkdir -p "${HOME}/release"

    rsync -azh apps "${HOME}/release/"
    RSYNC_STATUS=$?
    if ! [ $RSYNC_STATUS -eq 0 ]; then
        echo -e "${RED}RSYNC: FAILED${ENDCOLOR}"
        exit 1
    fi
    echo -e "${BLUE}RSYNC: FINISHED${ENDCOLOR}"
}

remote_execute() {
    cmd=$(echo "$1")
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "cd $REMOTE_PATH && $cmd"
}

remote_frappe_branch_handle() {
    frappe_available=$(remote_execute "[[ -d 'apps/frappe' ]] && echo true")
    if ! [ "$frappe_available" == "true" ]; then
            # not available then install frappe with the given branch
            remote_execute "bench get-app --branch $FRAPPE_BRANCH frappe"
    else
        # check if the branch is same
        frappe_current_branch=$(remote_execute "cd apps/frappe && git branch --show-current")
        echo -e "${BLUE}Server Frappe Branch: $frappe_current_branch ${ENDCOLOR}"
        if ! [[ "$frappe_current_branch" == "$FRAPPE_BRANCH" ]]; then
                remote_execute "bench switch-to-branch --upgrade $FRAPPE_BRANCH frappe"
                remote_execute "bench update --apps frappe"
        fi
    fi

}

remote_deploy_frappe() {
        branch=$(echo "$GITHUB_REF" | awk 'BEGIN {FS="/"} ; {print $NF}')
        REMOTE_HOST=$(shyaml get-value "${branch}.hostname" < "$hosts_file")
        REMOTE_USER=$(shyaml get-value "${branch}.user" < "$hosts_file")
        REMOTE_PATH=$(shyaml get-value "${branch}.deploy_path" < "$hosts_file")

        ssh-keyscan -H "$REMOTE_HOST" >>/home/frappe/.ssh/known_hosts

        # copy apps to releases folder
        REMOTE_FOLDER_NAME=$(date +'%d-%m-%y--%H-%M-%S')
        remote_execute "mkdir -p releases/${REMOTE_FOLDER_NAME}"

        #skip everything related to frappe
        rsync -azh --exclude 'frappe' "${HOME}/release/apps/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/"
        RSYNC_STATUS=$?
        if ! [ $RSYNC_STATUS -eq 0 ]; then
            echo -e "${RED}RSYNC: FAILED${ENDCOLOR}"
            exit 1
        fi
        echo -e "${BLUE}RSYNC: FINISHED${ENDCOLOR}"

        # getting apps list
        APPS_BENCH_LIST=$(remote_execute "ls -1 apps")
        BENCH_LIST_OUTPUT=$(remote_execute "bench --site ${REMOTE_HOST} list-apps -f json")
        APPS_SITE_LIST=$(echo "$BENCH_LIST_OUTPUT" | jq -cr ".\"${REMOTE_HOST}\" | .[]")

        remote_frappe_branch_handle

        # site maintenance mode -> on
        remote_execute "bench --site ${REMOTE_HOST} set-maintenance-mode on"

        for app in $(remote_execute "ls -1 releases/${REMOTE_FOLDER_NAME}"); do
            echo -e "Handling app  - $app"

            #check if the app is installed in bench
            #
            REGEX_MATCH=\\b$app\\b

            if ! [[ "$APPS_BENCH_LIST" =~ $REGEX_MATCH ]]; then

                        echo -e "Installing $app in bench"
                        #install the app into bench
                        remote_execute "bench get-app ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/$app"
            fi

            #check if the app is installed in site
            if [[ "$APPS_SITE_LIST" =~ $REGEX_MATCH ]]; then

                echo -e "Updating $app in $REMOTE_PATH"

                remote_execute "rm -rf apps/$app"
                remote_execute "cp -r ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/$app ${REMOTE_PATH}/apps/"
                remote_execute "bench build --force --production --app $app"
                remote_execute "bench --site ${REMOTE_HOST} migrate"
            else
                echo -e "Installing $app in $REMOTE_PATH"
                remote_execute "bench build --force --production --app $app"
                remote_execute "bench --site ${REMOTE_HOST} install-app $app"
                remote_execute "bench --site ${REMOTE_HOST} migrate"
            fi

            # remove node_modules from each apps
            remote_execute "rm -rf ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/${app}/node_modules ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/${app}/yarn.lock"
            echo -e "${BLUE}CLEANUP-> REMOVED: ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/${app}/node_modules ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/${app}/yarn.lock${ENDCOLOR}"

        done

        # site maintenance mode -> on
        remote_execute "bench --site ${REMOTE_HOST} set-maintenance-mode off"

    #rsync -rv $GIHUB_WORKSPACE
}
setup_frappe
remote_deploy_frappe
