# MokaCo HRMS  
Before any work, read docs/MOKACO_HANDOFF.md (business, features, rules, server and deployment).  
- Deploy scripts: deploy/  
- VM house rules: never change the shared account's password, sshd config, firewall,  
  /etc/netplan/99-dns-override.yaml or the Bitdefender agent; ask Reda first.  
- Push to GitHub (origin). GitLab push is disabled.  
- Where to push: `main` unless told otherwise. "test" -> branch `test` in the repo(s) that change, deployed to
  the test side only (deploy/sync-test.sh on the laptop, deploy/test-env/deploy-test.sh on the VM). "to production"
  -> merge `test` into `main`, then the usual production deploy.
- Test environment (test API, MokaCo_HRMS_Test, the login switch): deploy/test-env/README.md.
