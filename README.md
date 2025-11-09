## Testing & development
- These scripts were tested on Ubuntu 24.04 LTS
- Scripts are for development and testing purposes only, they should not be used in Production
- No liability is provided with these scripts
- Use at your own risk and validate the content before use

## Features
- Both scripts are idempodent and can be ran multiple times until all components have passed successfully
- Exception: the final ./install-upgrade.sh script provided by the Dell Automation Platform install bundle cannot run parallel exceutions and must complete before re-running.

## DNS Entries required
- host.domain (used for k8s API and primary host DNS)
- portal.host.domain
- orchestrator.host.domain
- mtls-orchestrator.host.domain
- mtls-recovery-orchestrator.host.domain
- registry.domain

## Instructions
- Review and modify the 'user configurable variables' section of both scripts
- Run the 'k8s_install.sh' script first, then when complete without errors, run the 'dap_install.sh' script

## Step 1: k8s_install.sh
```
sudo ./k8s_install.sh -U <docker username> -T <docker token>
```

## Step 2: dap_install.sh
```
sudo ./dap_install.sh -Q <quay registry username> -q <quay password>
```



  