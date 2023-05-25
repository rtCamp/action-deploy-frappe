#!/usr/bin/env bash

# Exit on error
set -e
hosts_file="$GITHUB_WORKSPACE/.github/hosts.yml" #export PATH="$PATH:$COMPOSER_HOME/vendor/bin"
export PROJECT_ROOT="$(pwd)"
export HTDOCS="$HOME/htdocs"
export GITHUB_BRANCH=${GITHUB_REF##*heads/}
CUSTOM_SCRIPT_DIR="$GITHUB_WORKSPACE/.github/deploy"

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
			hostadd=$(cat "$hosts_file" | shyaml get-value ${branch}.hostname)
			ssh-keyscan -H $hostadd >>/etc/ssh/known_hosts

		done

		if [[ -n "$JUMPHOST_SERVER" ]]; then
			ssh-keyscan -H "$JUMPHOST_SERVER" >>/etc/ssh/known_hosts
		fi
	else
		# Generate a key-pair
		ssh-keygen -t rsa -b 4096 -C "GH-actions-ssh-deploy-key" -f "$HOME/.ssh/id_rsa" -N ""
	fi
}

function maybe_get_ssh_cert_from_vault() {

	# Get signed key from vault
	if [[ -n "$VAULT_GITHUB_TOKEN" ]]; then
		unset VAULT_TOKEN
		vault login -method=github token="$VAULT_GITHUB_TOKEN" >/dev/null
	fi

	if [[ -n "$VAULT_ADDR" ]]; then
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
	export hostname=$(cat "$hosts_file" | shyaml get-value "$GITHUB_BRANCH.hostname")
	export ssh_user=$(cat "$hosts_file" | shyaml get-value "$GITHUB_BRANCH.user")

	printf "[\e[0;34mNOTICE\e[0m] Setting up SSH access to server.\n"

	SSH_DIR="$HOME/.ssh"
	mkdir -p "$SSH_DIR"
	chmod 700 "$SSH_DIR"

	setup_private_key
	maybe_get_ssh_cert_from_vault
	configure_ssh_config
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
function main() {

	init_checks
	setup_hosts_file
	check_branch_in_hosts_file
	setup_ssh_access
	run_deploy_sh

}
main
