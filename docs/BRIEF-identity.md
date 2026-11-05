# Project Brief: Safe Identity Lifecycle (working title)

Salesforce as the system of record drives Google account lifecycle: create, update, OU placement, group membership, suspend, and reactivate.

Repo: `safe-identity-lifecycle` (working name)
Progress log: `docs/PROGRESS-identity.md`
Started: November 4, 2026
Status: Phase 0 complete (two carried-forward items)

---

## 1. Goal

Rebuild my CIAM Office 365 provisioning sync against Google Cloud Identity, and fix the original's known failures by design rather than by patch.

The project serves two career tracks:

- **Director of IT:** identity lifecycle as a governed process (joiner, mover, leaver), least-privilege admin access, audit trail, secure-by-default cloud posture, and break-glass access.
- **Salesforce admin / architect / engineer:** Apex callouts, Named and External Credentials, async processing, idempotent integration design, and test coverage with callout mocks.

Possible follow-ups on the same tenant: an SSO hub (SAML into Salesforce and my other apps) and an incident response case study.

## 2. The original and its lessons

The CIAM original provisions Microsoft 365 accounts from Salesforce:

- `CIAM_CallGraphAPI` Apex class making Microsoft Graph callouts
- Chained queueables for the async work
- A "Provision O365 User" flow as the entry point
- Name normalization to build `mailNickname`

Lessons this rebuild fixes by design:

These lessons come from a review of the original implementation (create helper, three chained queueables, and the V26 record-triggered flow). An early-alpha counter issue is not included because that code no longer exists.

| Lesson | Root cause in the original | Design fix |
|---|---|---|
| Students admitted through a second admit status were missed until the flow was patched | The trigger matched an enumerated list of statuses, so any admit status not on the list was skipped | Eligibility is a state predicate ("in any admitted-or-later status, not yet provisioned") driven by one configurable status grouping, plus a scheduled reconciliation sweep that catches anything missed. |
| A retry after a partial failure could create a second account for the same student | The only guard was the email field, written after the create; a name conflict was treated as a different person and retried with a numeric suffix | Look up by `externalId` (the Salesforce record ID stored on the Google user) before any create. A name conflict means "pick the next name" only when no account exists for this record. Conflicts are detected by status code, not message text. |
| Initial passwords were stored on the Contact | The password was written to a metadata field for a later job to read, then redacted; a static fallback password existed | Generate the password, create the user, and send the welcome email in one job. The password never touches a field, and there is no static fallback. |
| Bulk Contact updates could fail the user's own save | One Queueable enqueued per record inside the triggering transaction | The trigger publishes Platform Events. A subscriber running as a dedicated integration user enqueues the work. |
| Long, compound, and non-Latin names produced broken or degraded usernames | No length cap; an accent map covering a few languages, with everything else stripped; no handling for names that clean down to empty | A documented normalization function with a length budget, trimming, a broad transliteration map, a defined truncation order, empty-part fallback, and fixture tests for hard names. |
| Failures were found only when someone noticed | Errors logged to debug and a status string; no retry or alerting | Sync log records, a retry policy with backoff, and failure alerts to admin@. |
| Changes to business timing rules (a provisioning delay added, then removed) each required a new flow version | Timing lived in flow structure (a scheduled path) | Timing rules such as a provisioning delay live in Custom Metadata, so a policy change is a configuration change. |
| Missed students were remediated by hand through anonymous Apex, and a designed backstop sweep was never built | No supported retry path; the safety net stayed on the to-do list | The reconciliation sweep is part of v1, and a "reprovision" action on the record replaces ad hoc scripts. |

Kept from the original: an **inclusion list** for "still qualified" statuses, chosen deliberately because it fails closed (a new or unexpected status never provisions by accident); a result wrapper carrying status, parsed JSON, and raw body; a Named Credential with no token handling in Apex; feature toggles and a dry-run mode in Custom Metadata; HTML-escaping in the welcome email; and redacting secrets from raw responses.

### Real-world context

How the original sits in the institution's pipeline, from past work on the production org:

- **Most applicants arrive through the portal directly.** Portal self-registration and the application form create the Contact at application time. Lead conversion is a secondary path.
- **Admissions decisions set one status field on Contact,** with values Cancelled, Denied, Admit with Conditions, Admitted, and Enrolled. Provisioning fires on the admit statuses.
- **Provisioning is upstream of other systems.** The SIS sync requires the provisioned email before it will run, and portal access and downstream eligibility checks key off it, so a silent provisioning failure cascades.
- **Post-enrollment status lives in the SIS, not Salesforce.** Leaves of absence and withdrawals are recorded in the SIS. In this demo, a Contact status field stands in for those signals; a real deployment would take leaver events from the SIS.
- **New mailboxes are not immediately reachable.** A mail security gateway rejected messages to freshly provisioned mailboxes until its directory sync caught up. Sending the welcome message to the student's personal address avoids this, and the same principle covers Google's eventual consistency.

## 3. Decisions

### Directory and tenant

- **Directory:** Google Cloud Identity Free. Active, Free edition, 50 licenses, no charges. No Gmail.
- **"Automated user provisioning" marked Premium** on the editions page refers to Google pushing users out to SAML apps. API user creation works on Free (proven in Phase 0).
- **Google Cloud project** `identity-lifecycle`, no billing account, Admin SDK API enabled.
- **Org hardening:** removed the default domain-wide Billing Account Creator and Project Creator roles so tenant users (including demo students) cannot create projects or billing accounts.
- **Admin accounts:** `luke@shuraku.org` super admin with 2SV (authenticator), saved backup codes, and verified recovery email. Break-glass super admin is optional (see Follow-ups).

### Integration identity and access

- **Service account** `salesforce-directory-sync` holding a **custom admin role**. No domain-wide delegation, no super admin impersonation, no GCP IAM roles. Audit logs show the service account as the actor.
- **Custom role `Directory Sync (Salesforce)`:** Users Create, Read, Update (full bundle); Groups Read, Update. No Users Delete, no Groups Create or Delete.
- **Why the full Update bundle:** the Directory API's `users.patch` requires the general Users > Update privilege for any field change, including suspend, and the role editor will not grant Update without all of its children (aliases, force password change, move, rename, reset password, suspend). Mitigations: non-super-admin roles cannot modify admin accounts, and OU-scoped assignment is to be tested.
- **Structure is created by hand.** OUs and groups are created once in the Admin console. The integration only places users into existing OUs (`orgUnitPath`) and manages membership of existing groups. It never creates or deletes structure.

### Authentication from Salesforce

- **Self-signed JWT through a Named Credential.** External Credential with the **JWT** protocol (not OAuth 2.0): Salesforce signs a fresh JWT for each callout and sends it directly to the Directory API as the bearer token.
  - Claims: iss and sub set to the service account email, `aud = https://admin.googleapis.com/`, `kid` set to Google's key ID, 120-second expiry.
  - No token exchange, no token caching, no authentication code in Apex.
- **Why not OAuth 2.0 / JWT Bearer:** the External Credential's token exchange against Google's token endpoint failed with a blank error, while the identical key and claims succeeded through plain Apex. Details in PROGRESS. The Apex token exchange (`Auth.JWTBearerTokenExchange`) remains a proven fallback.
- **Key handling:** the key pair is generated in Salesforce Certificate and Key Management with **Exportable Private Key off**. Only the public certificate is uploaded to the service account. No service account key file exists.
- **Google Cloud security baseline stays on.** The org enforces the legacy constraint `iam.disableServiceAccountKeyUpload`. The only change is a **project-scoped override** of that constraint. Key creation stays disabled.

### Email

- **Initial credentials:** Google has no Temporary Access Pass equivalent. Accounts get a random initial password with `changePasswordAtNextLogin = true`. See Risks.
- **Welcome message:** sent by Salesforce to the student's personal email, only after the Google create call succeeds.
- **Sending domain:** shuraku.org verified in Salesforce with an **active DKIM key** (selectors `sf1`/`sf2`, CNAMEs DNS only in Cloudflare). No Salesforce include in SPF; DKIM provides DMARC alignment.
- **Inbound:** Cloudflare Email Routing (free). Cloudflare Email Sending requires Workers Paid and is out of scope.
- **Demo users** live in the `Demo Students` OU. Email Routing catch-all stays off, so mail to demo addresses bounces.

### API behavior the design depends on (proven in Phase 0)

- Use `domain=shuraku.org` (or the customer ID) for list calls. `customer=my_customer` returns 400 for a service account using its own admin role.
- `externalIds` with custom type `salesforce_id` stores the Salesforce record ID on the Google user, and `query=externalId:<id>` finds it. This is the idempotency lookup.
- **Eventual consistency:** a read immediately after a write may not reflect it. Trust the write's response; never verify by reading back immediately; the reconciliation sweep handles drift.
- Suspended users can be group members, and suspension does not remove memberships.

## 4. Environment

| Item | Status |
|---|---|
| shuraku.org on Cloudflare; Email Routing; admin@ and luke@ routes | Done |
| Cloud Identity Free tenant; domain verified; luke@ secured | Done |
| GCP project, no billing, Admin SDK enabled | Done |
| Default domain-wide project and billing creation removed | Done |
| Service account, custom role, Demo Students OU | Done |
| Project-scoped key upload override; certificate uploaded | Done |
| Fresh Salesforce Developer Edition org | Done |
| Non-exportable certificate `Google_Directory_JWT` | Done |
| External Credential (JWT) and Named Credential; permission set `Google Directory Sync` | Done |
| DKIM key active for shuraku.org | Done |
| Proof calls: list, create, find by externalId, suspend, group add/remove | Passed |
| Record Directory API limits and quotas | Carried forward |
| OU-scoped role assignment test | Carried forward |

## 5. Architecture

```
Salesforce (system of record)
  Contact trigger (update)
    -> eligibility predicate (configurable status grouping)
    -> publish Platform Event
  Platform Event subscriber (runs as dedicated integration user)
    -> enqueue one job per record (Queueable + Finalizer)
         -> GoogleDirectoryClient (Apex)
              -> Named Credential (Generate Authorization Header)
                   -> External Credential, JWT protocol
                      (self-signed JWT per callout, non-exportable key)
                   -> Google Admin SDK Directory API
         -> write result back to the record
         -> on success: welcome email (org-wide address, DKIM)
         -> on failure: error state on record + sync log entry
  Scheduled reconciliation sweep
    -> finds eligible-but-unprovisioned and drifted records
    -> publishes the same events

Google Cloud Identity Free
  Service account  -> custom admin role (users, groups)
  Demo Students OU -> created by hand
  Groups           -> created by hand; integration manages membership
```

Design principles:

- **Idempotent operations.** Before any create, look the user up by `externalId`. The Salesforce record ID is stored on the Google user, and the immutable Google user ID is stored back on the Salesforce record. Updates key on the Google user ID, never the email address.
- **One record per job.** No shared mutable state between jobs.
- **State on the record.** Status, primary email, Google user ID, last sync time, last error.
- **Trust writes, reconcile later.** No read-after-write verification; the sweep catches drift.
- **Every call logged** to a sync log object for audit and troubleshooting.
- **Least privilege at every layer.** Custom role instead of super admin, no domain-wide delegation, no structure management, non-exportable key, one narrow policy exception.

## 6. Lifecycle scope

| Event | Salesforce trigger (demo data) | Google action |
|---|---|---|
| Joiner | Enters any admitted-or-later status, not yet provisioned | Create user in Demo Students, set externalId, send welcome email |
| Mover | Status changes (e.g. Admitted to Enrolled to Alumni) | Move OU |
| Mover | Program or term changes | Update group memberships |
| Update | Name change | Update display name. Primary email handling is an open question. |
| Leaver | Withdrawn | Suspend. Group membership handling is an open question. |
| Return | Re-enrolled | Reactivate |

Deletion is out of scope for v1. Suspend is the end state, consistent with a retention-first policy.

## 7. Phases

Each phase ends with a check: what was planned, what got done, what moved or got dropped.

**Phase 0: Tenant and proof of API access** (complete)
- All environment items in section 4 except the two carried forward.

**Phase 1: Salesforce foundation**
- Carry-forward: record Directory API limits and quotas; test OU-scoped role assignment.
- Verify the Platform Event subscriber run-as design; create the integration user and assign it the permission set.
- Contact sync and demo lifecycle fields, the status grouping configuration, and the sync log object.
- `GoogleDirectoryClient` with `HttpCalloutMock` tests.

**Phase 2: Joiner path**
- Eligibility predicate, normalization function with fixture tests, idempotent create, Demo Students placement.
- Welcome email: org-wide email address on shuraku.org (domain already verified by DKIM). Check Email Deliverability settings and Developer Edition daily limits.

**Phase 3: Mover path**
- OU moves and group membership changes.

**Phase 4: Leaver and return**
- Suspend and reactivate, with the group membership decision applied.

**Phase 5: Reconciliation and operations**
- Scheduled sweep.
- Error handling and retry policy with backoff.
- Failure alerts to admin@ (verified destination address, so free).

**Phase 6: Write-up**
- README (including "What it doesn't do"), redacted screenshots, LinkedIn post.

## 8. Ground rules

- Free tier throughout. The one paid exception is the shuraku.org domain (about $11/yr).
- Do not enable anything that bills by usage. No Cloudflare Workers Paid. The Google Cloud project has no billing account attached. Back out of any screen asking for a card or offering a trial.
- Keep Google's security baseline. Any exception is scoped as narrowly as possible and documented with its reason.
- Demo data only. No CIAM data, names, or configuration in this repo.
- Secrets never committed. The private key lives only in Salesforce. No service account key files exist.
- Public-repo hygiene: raw screenshots go in `evidence-raw/` (gitignored). Only redacted copies go in `docs/evidence/`. Keep customer ID, key ID, user IDs, and recovery contact details out of committed files.
- Check the docs for the version actually in use before writing library or API code.
- Verify against the live system, not assumptions.
- Log findings in `docs/PROGRESS-identity.md` and commit in small steps.

## 9. Risks and known trade-offs

- **Initial password by email.** Sending a temporary password to a personal inbox is weaker than a time-limited pass. Mitigations: random strong password, forced change at first sign-in, demo OU only, login audit review.
- **Full Users > Update bundle.** The role can reset passwords and change aliases for non-admin users, which v1 does not need. Mitigations: admin accounts are out of reach for non-super-admin roles; OU-scoped assignment if Google allows it for this role.
- **Key upload exception.** One baseline control is relaxed for one project. Mitigations: key creation stays disabled, the private key never leaves Salesforce, and the service account holds only a custom role.
- **Long-lived signing key.** The uploaded key does not rotate on its own. Mitigation: record its expiration and rotate by generating a new Salesforce certificate and uploading it before the old one expires.
- **Self-signed JWT support.** The design depends on the Directory API continuing to accept self-signed JWTs. Fallback: the proven Apex token exchange.
- **Eventual consistency.** Reads can lag writes. The design never depends on immediate read-back.
- **Developer Edition email limits.** Low daily cap on outbound email. Record the current number in Phase 2.
- **Cloud Identity Free user cap** is 50. The reconciliation sweep must not create users in a loop.
- **Google API quotas.** Record them and design retries with backoff.

## 10. Open questions

Resolved:
- **Student record:** Contact, matching where this data lives in the original org. Sync fields: `Google_User_Id__c` (External ID, unique), `Google_Primary_Email__c`, `Google_Account_Status__c`, `Google_Last_Sync__c`, `Google_Last_Error__c`. Demo lifecycle fields: status, program, term. Standard Email is the personal address for the welcome message. Contacts are created with no status, so the trigger runs on update only.

Proposed, pending a docs check in Phase 1:
- **Automation user:** the Contact trigger publishes a Platform Event; a subscriber configured to run as a dedicated, API-only integration user enqueues the work. Only that user holds the `Google Directory Sync` permission set. Verify subscriber run-as configuration and integration user license availability in Developer Edition.

Open:
1. **Name changes:** keep the primary email and add the new name as an alias, or rename the primary email?
2. **Group model:** groups by program, by term, or both?
3. **Security-labeled groups:** should the real program and term groups carry the security label (permanent once applied) if they will drive access, such as SSO app assignment?
4. **Memberships on suspend:** remove a suspended student from their groups (cleaner if groups grant access), or keep memberships so reactivation restores them automatically?
5. **Duplicate Contacts:** the `externalId` lookup prevents a second account for the same Contact, but not for the same person with two Contacts (for example, a returning applicant who registers again). Add a pre-create check on personal email that flags a possible duplicate for review instead of creating an account?
6. **Denied or Cancelled after provisioning:** the original never handled an admitted student who is later denied or cancels. Suspend automatically, or flag for manual review?

## 11. Follow-ups (outside v1)

- DMARC record on shuraku.org: start with `p=none` and reports to admin@, then tighten now that Salesforce DKIM is active.
- Break-glass super admin with its own 2SV, never used day to day.
- Enforce 2SV on the Demo Students OU through Admin console policy.
- Remove Organization Policy Administrator from luke@ when no longer needed (just-in-time privilege).
- SIS-driven leaver events: take leave-of-absence and withdrawal signals from the student information system instead of a Contact status field.
- Workload Identity Federation spike: test whether Salesforce can act as an OIDC issuer for Google, removing the long-lived key entirely.
- SSO hub: Google as IdP over SAML into Salesforce and my other apps.
- Incident response case study on the same tenant.

## 12. References

- Google Workspace Updates: service accounts with admin roles, no domain-wide delegation (Aug 2020): https://workspaceupdates.googleblog.com/2020/08/use-service-accounts-google-groups-without-domain-wide-delegation.html
- Google: Manage roles, role-to-privilege mapping: https://developers.google.com/workspace/admin/directory/v1/guides/manage-roles
- Google: Administrator privilege definitions: https://support.google.com/a/answer/1219251
- Google Cloud security baseline constraints: https://docs.cloud.google.com/resource-manager/docs/manage-baseline-constraints
- Salesforce: Set Up JWT Claims for External Credentials: https://help.salesforce.com/s/articleView?id=xcloud.nc_jwt_claims.htm&language=en_US&type=5
- Salesforce: OAuth External Credential with the JWT Bearer Flow: https://help.salesforce.com/s/articleView?language=en_US&id=xcloud.nc_create_edit_oath_jwt_bearer_ext_cred.htm&type=5
- Cloud Identity editions: https://cloud.google.com/identity/docs/editions