set -ex

export TERM=xterm-color

RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
ENDCOLOR="\e[0m"

hosts_file="$GITHUB_WORKSPACE/.github/hosts.yml"

APP_NAME=$(echo $GITHUB_REPOSITORY | sed 's:.*/::' )
setup_frappe() {

    mkdir -p $HOME/$APP_NAME

    rsync -azh  $GITHUB_WORKSPACE/ $HOME/$APP_NAME
    RSYNC_STATUS=$?
    if ! [ $RSYNC_STATUS -eq 0 ]; then
        echo "${RED}RSYNC: FAILED${ENDCOLOR}"
        exit 1
    fi
    echo "${BLUE}RSYNC: FINISHED${ENDCOLOR}"

    cd $HOME
    if ! [[ -n "$FRAPPE_BRANCH" ]]; then
        FRAPPE_BRANCH=develop
    fi

    bench init --frappe-branch $FRAPPE_BRANCH --skip-redis-config-generation --no-procfile --no-backups --skip-assets bench

    cd bench
    bench get-app --skip-assets --resolve-deps $HOME/$APP_NAME
    BUILD_STATUS=$?
    if ! [ $BUILD_STATUS -eq 0 ]; then
        echo "${RED} $APP_NAME BUILD: FAILED${ENDCOLOR}"
        exit 1
    fi
    echo "${BLUE} ${APP_NAME} BUILD: FINISHED${ENDCOLOR}"

    # remove node_modlues in apps
    for app in $(ls -1 apps); do
        rm -rf apps/${app}/node_modules
    done
    echo "${BLUE}NODE_MODULES: REMOVED${ENDCOLOR}"

    mkdir -p $HOME/release

    rsync -azh apps $HOME/release/
    RSYNC_STATUS=$?
    if ! [ $RSYNC_STATUS -eq 0 ]; then
        echo "${RED}RSYNC: FAILED${ENDCOLOR}"
        exit 1
    fi
    echo "${BLUE}RSYNC: FINISHED${ENDCOLOR}"
}

remote_execute() {
    cmd=$(echo "$1")
    ssh ${REMOTE_USER}@${REMOTE_HOST} "cd $REMOTE_PATH && $cmd"
}

remote_frappe_branch_handle() {
    frappe_available=$(remote_execute "[[ -d 'apps/frappe' ]] && echo true")
    if ! [ "$frappe_available" == "true" ]; then
            # not available then install frappe with the given branch
            remote_execute "bench get-app --branch $FRAPPE_BRANCH frappe"
    else
        # check if the branch is same
        frappe_current_branch=$(remote_execute "cd apps/frappe && git branch --show-current")
        if ! [[ "$frappe_current_branch" == "$FRAPPE_BRANCH" ]]; then
                remote_execute "bench switch-to-branch --upgrade $FRAPPE_BRANCH frappe "
                remote_execute "bench update --patch"
        fi
    fi

}

remote_deploy_frappe() {
    for branch in $(cat "$hosts_file" | shyaml keys); do
        REMOTE_HOST=$(cat "$hosts_file" | shyaml get-value ${branch}.hostname)
        REMOTE_USER=$(cat "$hosts_file" | shyaml get-value ${branch}.user)
        REMOTE_PATH=$(cat "$hosts_file" | shyaml get-value ${branch}.deploy_path)

        ssh-keyscan -H $REMOTE_HOST >>/home/frappe/.ssh/known_hosts

        # copy apps to releases folder
        REMOTE_FOLDER_NAME=$(date +'%d-%m-%y--%H-%M-%S')
        remote_execute "mkdir -p releases/${REMOTE_FOLDER_NAME}"

        #skip everything related to frappe
        rsync -azh --exclude 'frappe' $HOME/release/apps/ ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/
        RSYNC_STATUS=$?
        if ! [ $RSYNC_STATUS -eq 0 ]; then
            echo "${RED}RSYNC: FAILED${ENDCOLOR}"
            exit 1
        fi
        echo "${BLUE}RSYNC: FINISHED${ENDCOLOR}"

        # getting apps list
        APPS_BENCH_LIST=$(remote_execute "ls -1 apps")
        BENCH_LIST_OUTPUT=$(remote_execute "bench --site ${REMOTE_HOST} list-apps -f json")
        APPS_SITE_LIST=$(echo "$BENCH_LIST_OUTPUT" | jq -cr ".\"${REMOTE_HOST}\" | .[]")

        remote_frappe_branch_handle

        # site maintenance mode -> on
        remote_execute "bench --site ${REMOTE_HOST} set-maintenance-mode on"

        for app in $(remote_execute "ls -1 releases/${REMOTE_FOLDER_NAME}"); do
            echo "Handling app  - $app"

            #check if the app is installed in bench
            #
            REGEX_MATCH=\\b$app\\b

            if ! [[ "$APPS_BENCH_LIST" =~ $REGEX_MATCH ]]; then

                        echo "Installing $app in bench"
                        #install the app into bench
                        remote_execute "bench get-app ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/$app"
            fi

            #check if the app is installed in site
            if [[ "$APPS_SITE_LIST" =~ $REGEX_MATCH ]]; then

                echo "Updating $app in $REMOTE_PATH"

                remote_execute "sudo rm -rf apps/$app"
                remote_execute "cp -r ${REMOTE_PATH}/releases/${REMOTE_FOLDER_NAME}/$app ${REMOTE_PATH}/apps/"
                remote_execute "bench build --force --production --app $app"
                remote_execute "bench --site ${REMOTE_HOST} migrate"
            else
                echo "Installing $app in $REMOTE_PATH"
                remote_execute "bench build --force --production --app $app"
                remote_execute "bench --site ${REMOTE_HOST} install-app $app"
                remote_execute "bench --site ${REMOTE_HOST} migrate"
            fi

        done

        # site maintenance mode -> on
        remote_execute "bench --site ${REMOTE_HOST} set-maintenance-mode off"

    done

    #rsync -rv $GIHUB_WORKSPACE
}
setup_frappe
remote_deploy_frappe
