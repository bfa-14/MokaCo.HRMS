# MokaCo HRMS  
Before any work, read docs/MOKACO_HANDOFF.md (business, features, rules, server and deployment).  
- Deploy scripts: deploy/  
- VM house rules: never change the shared account's password, sshd config, firewall,  
  /etc/netplan/99-dns-override.yaml or the Bitdefender agent; ask Reda first.  
- Push to GitHub (origin). GitLab push is disabled.  
- Branches (both repos): `main` = production, `dev` = all work and testing. Push work to `dev` unless told
  otherwise; it is tested with deploy/sync-test.sh (laptop) + deploy/test-env/deploy-test.sh (VM). "to production"
  -> merge `dev` into `main` and push; deployed with deploy/sync-prod.sh + deploy-api.sh / deploy-web.sh.
  An urgent fix made on `main` is merged back into `dev`.
- Test environment (test API, MokaCo_HRMS_Test, the login switch): deploy/test-env/README.md.
