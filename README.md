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
   private key that you use use to ssh to server(s) defined in `hosts.yml`.

4. Create `.github/hosts.yml` inventory file, based on 

```yml
main:
  hostname: production.com 
  user: frappe
  site_name: production-site.com
  deploy_path: /home/frappe/production

staging:
  hostname: staging.com 
  user: frappe
  site_name: staging-site.com
  deploy_path: /home/frappe/staging

```

Make sure you explictly define GitHub branch mapping. Only the GitHub branches mapped in `hosts.yml` will be deployed, rest will be filtered out.

## hosts.yml Variables
- All of these variables are mandatory.

| Variable      | Possible Values | Purpose                                |
|:-------------:|:---------------:|:--------------------------------------:|
| `hostname`    | ip or DNS FQDN  | hostname for ssh.                      |
| `user`        | valid username  | Username for ssh.                      |
| `site_name`   | site name       | Frappe Site Name for app installation. |
| `deploy_path` | path            | Bench path.                            |


## Environment Variables

This GitHub action's behavior can be customized using following environment variables:

| Variable        | Default    | Possible  Values    | Purpose                                                                      |
|-----------------|------------|---------------------|------------------------------------------------------------------------------|
| `FRAPPE_BRANCH` | version-14 | Valid Frappe Branch | Frappe branch. If not specified, default branch **version-14** will be used. |
|                 |            |                     |                                                                              |

## Limitations

- Only supports one site per bench.
- Building app might break when using github hosted runner for complex apps like insights. (lack of ram)

## License

[MIT](LICENSE) © 2023 rtCamp

## Does this interest you?

<a href="https://rtcamp.com/"><img src="https://rtcamp.com/wp-content/uploads/sites/2/2019/04/github-banner@2x.png" alt="Join us at rtCamp, we specialize in providing high performance enterprise WordPress solutions"></a>
