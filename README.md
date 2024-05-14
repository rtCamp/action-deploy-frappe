This action is a part of [GitHub Actions Library](https://github.com/rtCamp/github-actions-library/) created
by [rtCamp](https://github.com/rtCamp/).

# Deploy Frappe App - GitHub Action

[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)

A [GitHub Action](https://github.com/features/actions) to deploy Frappe app on a server


## Usage

1. Create a `.github/workflows/deploy.yml` file in your GitHub repo, if one doesn't exist already.
2. Add the following code to the `deploy.yml` file.

   ```yml
   on: 
     push:
       branches:
         - main
         - staging
   
   name: Deploying Frappe Site
   jobs:
     deploy:
       name: Deploy
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v3
         - name: Deploy
           uses: rtcamp/action-deploy-frappe@main
           env:
             SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
   ```

3. Create `SSH_PRIVATE_KEY` secret
   using [GitHub Action's Secret](https://developer.github.com/actions/creating-workflows/storing-secrets) and store the
   private key that you use to ssh to server(s) defined in `hosts.yml`.

4. Create `.github/hosts.yml` inventory file, based on the following syntax: 

```yml
<branch>:
  <site-name>:
    hostname: <IP or DNS for the server to SSH into>  # Required
    user: <Username to use for SSH>  # Required
    deploy_path: <Path to the site's bench directory>  # Required
    prev_releases_limit: <Number of previous releases to keep>  # Optional
    apps_paths:  # Optional
      - <Path to the app's directory>
      - <Path to the app's directory>
    submodule_apps_path:
     - <Path to the git submodule's directory>
     - <Path to the git submodule's directory>
```

For Example:

```yaml
# denotes branch mapping
# denotes branch mapping
branch: 
  # denotes the site name, only one unique site name is allowed
  example.com: 
    hostname: example.com  # denotes the hostname of the server hosting the site
    user: example-user
    deploy_path: /path/to/bench  
    prev_releases_limit: 10 
    apps_paths: 
      - some_app
      - some_dir/another_app
    submodule_apps_path:
      - some_submodule_app
      - some_dir/some_submodule_app

# Can have more than one sites per branch
another-branch:
  some.domain:
    hostname: another.domain
    user: some-username
    deploy_path: /path/to/bench  
    prev_releases_limit: 10
    # Since `apps_paths` is not provided, the action will assume that the app is the repository itself
  another.domain:
    # ...
    # You can add more than one site for a single branch.
```

**Note:** if `apps_paths` is not provided, the action will assume that the app is the repository itself, and will try to install the entire repository as a frappe app package.

Make sure you explicitly define GitHub branch mapping. Only the GitHub branches mapped in `hosts.yml` will be deployed, rest will be filtered out.

## hosts.yml Variables

These are the variables you can provide in the `hosts.yml` file for each site:

| Variable              | Possible Values       | Example Values             | Required ? | Description                                                                             |
|-----------------------|-----------------------|----------------------------|------------|-----------------------------------------------------------------------------------------|
| hostname              | hostname/ip           | `example.rt.gw`            | true       | Hostname or IP to SSH into                                                              |
| user                  | valid username        | `root`                     | true       | The username to be used for SSH.                                                        |
| deploy\_path          | valid path            | `/home/user/example-rt-gw` | true       | Path to the site's bench directory.                                                     |
| prev\_releases\_limit | integer               | 5                          | false      | Number of previous releases to be kept on the server.                                   |
| apps_paths            | yaml list             | - frappe/catalyst          | true       | Directory mapping of the apps which will be deployed, relative to the root of the repo. |
| submodule_apps_path   | yaml list             | - frappe/catalyst          | false      | Directory mapping of the apps which will be deployed, relative to the root of the repo. |


## Environment Variables

This GitHub action's behavior can be customized using following environment variables:

| Variable        | Default    | Possible  Values    | Purpose                                                                      |
|-----------------|------------|---------------------|------------------------------------------------------------------------------|
| `FRAPPE_BRANCH` | version-14 | Valid Frappe Branch | Frappe branch. If not specified, default branch **version-14** will be used. |

## Secrets

This GitHub Action uses SSH to deploy to the server. So, you need to provide the SSH private key using the `SSH_PRIVATE_KEY` in the environment variables. It is recommended to make this key an actions secret, and provide it using the `${{ secrets.SSH_PRIVATE_KEY }}` syntax.

| Secret             | Purpose                                                                |
|--------------------|------------------------------------------------------------------------|
| `SSH_PRIVATE_KEY`  | SSH private key to access the server(s) defined in `hosts.yml`.        |

## Filters and filter.yml'

This action supports filtering of branches based on the `filter.yml` file. The `filter.yml` file should be placed in the `.github` directory of the repository. The `filter.yml` file should have the following structure:

```yaml
branches:
  include:
    - main
    - staging
  exclude:
    - feature/*
    - hotfix/*
```

The `include` key is used to specify the branches that should be included for deployment. The `exclude` key is used to specify the branches that should be excluded from deployment. If the `filter.yml` file is not present, all branches will be included for deployment.

This repository uses the [dorny/paths-filter](https://github.com/marketplace/actions/paths-changes-filter) action to filter branches based on the `filter.yml` file.

A default `filter.yml` file is provided in the repository. You can modify the `filter.yml` file as per your requirements.

```yaml
defaults:
  - .github/workflows/**
  - .github/hosts.yml
  - .github/filters.yml
```

Credits: [dorny/paths-filter](https://github.com/marketplace/actions/paths-changes-filter)

## Overriding default deployment behavior

If you need to modify the main.sh shell script of this action, you can create a file at location `.github/deploy/addon.sh` in your git repository. Checkout the [example addon.sh](https://github.com/rtCamp/action-deploy-frappe/blob/master/example/addon.php) to see how to customize.

## License

This repository is licensed under [MIT](LICENSE) License, © 2023 rtCamp.

## Does this interest you?

<a href="https://rtcamp.com/"><img src="https://rtcamp.com/wp-content/uploads/sites/2/2019/04/github-banner@2x.png" alt="Join us at rtCamp, we specialize in providing high performance enterprise WordPress solutions"></a>
