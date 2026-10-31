# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# MokaCo HRMS
Before any work, read docs/MOKACO_HANDOFF.md (business, features, rules, server and deployment; §11 lists traps
that have already bitten this codebase).
- Deploy scripts: deploy/
- VM house rules: never change the shared account's password, sshd config, firewall,
  /etc/netplan/99-dns-override.yaml or the Bitdefender agent; ask Reda first. No reboot or `apt upgrade` without Reda.
  A refused password: stop and ask Reda. Never paste passwords into chat or tracked files.
- Push to GitHub (origin). GitLab push is disabled.
- Branches (both repos): `main` = production, `dev` = all work and testing. Push work to `dev` unless told
  otherwise; it is tested with deploy/sync-test.sh (laptop) + deploy/test-env/deploy-test.sh (VM). "to production"
  -> merge `dev` into `main` and push; deployed with deploy/sync-prod.sh, then on the VM deploy/update-prod.sh (backup, missing scripts, API; --web adds the website).
  An urgent fix made on `main` is merged back into `dev`.
- Test environment (test API, MokaCo_HRMS_Test, the login switch): deploy/test-env/README.md.

## The two repositories
This repo is the .NET API. The web front end is the sibling repo `mokaco-web-mantine` (React 19, Mantine 8, Vite,
TypeScript, i18n en/ar with RTL); the deploy scripts expect both checked out side by side.

## Commands
API (.NET 10, solution `MokaCo.HRMS.slnx`):
- Build: `dotnet build MokaCo.HRMS.slnx`
- Run: `dotnet run --project MokaCo.HRMS.API` (local secrets: copy `MokaCo.HRMS.API/appsettings.Local.example.json`
  to `appsettings.Local.json`, gitignored; `ConnectionStrings__MokaCo` overrides it)
- Tests (xUnit): `dotnet test MokaCo.HRMS.Tests`; one test: `dotnet test MokaCo.HRMS.Tests --filter "FullyQualifiedName~SchemaCheckTests"`.
  Database tests run only when a database is reachable (`MOKACO_TEST_CONNECTION`, else the API's connection string);
  otherwise they are skipped, not failed.
- SQL scenario tests: `tests/qa3/<area>/*.sql`, run with `sqlcmd -I -b -d <dev database> -i <file>`; each phase rolls
  back and prints `ok <name>`. Older end-to-end suite: `bash tests/qa/run.sh` (needs `tests/qa/.env`).

Web (in `../mokaco-web-mantine`): `npm run dev` (API + Vite), `npm run build` (`tsc -b && vite build`),
`npm test` (node --test), `npm run lint`.

## Architecture
- Layers: `MokaCo.HRMS.API` (controllers, `[HasPermission("CODE")]` authorization with a deny-by-default fallback
  policy, SignalR hubs, Quartz jobs such as the 01:00 `NightlyAttendanceJob`, the public booking endpoints) →
  `MokaCo.HRMS.Services` (rules; refusals are `WorkflowException` with an HTTP status) → `MokaCo.HRMS.Repository`
  (Dapper, almost every call is a stored procedure) → `MokaCo.HRMS.Model` (DTOs). Folders mirror the business areas:
  Attendance, Booking, Core, HR, Payroll, Report, Security, Workflow.
- Business logic lives largely in SQL Server stored procedures. The database is changed ONLY by numbered,
  idempotent scripts `docs/NN_*.sql` (CREATE OR ALTER, guarded ALTER TABLE), applied in number order with
  `sqlcmd -I -b`. Unnumbered scripts in docs/ are older than production (they are not a way to rebuild it):
  production holds procedures and column changes the repo never had, so new scripts guard against overwriting a
  newer live version.
- Deploy guard: the numbered scripts the API calls are listed in `MokaCo.HRMS.Repository/Common/Scripts.cs`
  (`Scripts.Required`, each with a marker object only that script introduces — never one production already had).
  A new numbered script whose procedures the API calls goes on that list in the same commit. `/health` reports
  `"schema":"ok|behind|unknown"`; `deploy/check-scripts.sql` lists every numbered script a database lacks.
- Production is SQL Server **Express** on a Linux VM behind nginx (no SQL Agent, no `BACKUP ... WITH COMPRESSION`).
