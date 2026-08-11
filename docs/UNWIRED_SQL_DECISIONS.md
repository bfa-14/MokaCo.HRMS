# Unwired SQL features — the decision (P9)

Audit item B7 listed stored procedures with no backend caller and asked for each to be *wired or
dropped*. Checked against the live database and the current code on 2026-08-11. **Nothing is
dropped.** Two of the entries turned out to rest on a wrong premise, and the rest are harmless.

## Not actually unwired — no action

| Proc | Finding |
|---|---|
| `attendance.usp_ShiftAssignment_ApplyPattern` | **It is called.** `RosterRepository` calls `usp_ShiftAssignment_ApplyPatternForMonth`, which is an 11-line wrapper that `EXEC`s this one. A name-prefix search missed the indirection. |
| `workflow.usp_DecisionType_GetAll` | Handled by P12 — the frontend already calls `GET /api/workflow/decision-types`. |
| `workflow.usp_Definition_SetStepDecisions` | Handled by P12 — the frontend already calls `PUT /api/workflow/definitions/steps/{id}/decisions`. |
| `workflow.usp_Request_GetStaleDrafts` | Handled by P12 — the frontend already calls `GET /api/workflow/stale-drafts`. |

## Must NOT be dropped — the reason to drop them is already satisfied

| Proc | Finding |
|---|---|
| `payroll.usp_Advance_Create` | **Already a refusal stub.** Ten lines: a single `RAISERROR` pointing at the request chain. |
| `payroll.usp_Adjustment_Create` | Same — `RAISERROR('Adjustments now go through a request: raise a Payroll Adjustment, HR then the Owner sign it, and the row is created at approval.')`. |

The audit suggested dropping these so "nothing can bypass the request chain". Nothing can already:
they create no rows. Dropping them would make things **worse** — a caller that still exists somewhere
would get `Could not find stored procedure` instead of a sentence telling them where the door moved.
Keep them exactly as they are; they are documentation that executes.

## Genuinely unwired, deliberately left alone

Read-only monitors and one config writer. None presents a bypass risk (nothing here writes business
data), none has a screen asking for it, and wiring an endpoint nobody calls is how the last round of
dead surface got created.

| Proc | If it is ever wanted |
|---|---|
| `workflow.usp_Workflow_GetStalledRequests` | A tile on `WorkflowOversightPage`, beside stale drafts and long holds. |
| `workflow.usp_Workflow_GetRoleHealth` | Same page — roles with no active members break approval chains silently. |
| `hr.usp_Branch_GetManagerRoleGaps` | Pairs with the existing branch-manager screen; a branch with no usable manager login already gets a red banner there. |
| `workflow.usp_RequestType_GetAllWithChainState` | An admin view of which types have a published chain. |
| `attendance.usp_Attendance_UnmarkAbsentees` | The undo for a mis-run `mark-absentees`; today the fix is to re-process the day. |
| `workflow.usp_DecisionType_Upsert` | `POST /api/workflow/decision-types`, once the frontend grows an editor (P12 wires the read side only). |

**Revisit trigger:** wire one when a screen needs it, not before.
