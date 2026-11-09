# Project Brief: Safe Identity Lifecycle (working title)

Salesforce as the system of record drives Google account lifecycle: create, update, OU placement, group membership, suspend, and reactivate.

Repo: `safe-identity-lifecycle` (working name)
Progress log: `docs/PROGRESS-identity.md`
Started: November 4, 2026
Status: Phases 0 through 5 complete (lifecycle paths, retries, alerts, reconciliation sweep, reprovision, and name changes, all proven live; 144 tests). Phase 6 (write-up) next.

---

## 1. Goal

Rebuild my Office 365 provisioning sync against Google Cloud Identity, and fix the original's known failures by design rather than by patch.

The project serves two career tracks:

- **Director of IT:** identity lifecycle as a governed process (joiner, mover, leaver), least-privilege admin access, audit trail, secure-by-default cloud posture, and break-glass access.
- **Salesforce admin / architect / engineer:** Apex callouts, Named and External Credentials, async processing, idempotent integration design, and test coverage with callout mocks.

Possible follow-ups on the same tenant: an SSO hub (SAML into Salesforce and my other apps) and an incident response case study.

## 2. The original and its lessons

The original provisions Microsoft 365 accounts from Salesforce:

- 'CallGraphAPI` Apex class making Microsoft Graph callouts
- Chained queueables for the async work
- A "Provision O365 User" flow as the entry point
- Name normalization to build `mailNickname`
- A welcome email sent through Microsoft Graph from a shared mailbox

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

Kept from the original: an **inclusion list** for "still qualified" statuses, chosen deliberately because it fails closed (a new or unexpected status never provisions by accident); a result wrapper carrying status, parsed JSON, and raw body; a Named Credential with no token handling in Apex; feature toggles and a dry-run mode in Custom Metadata; and redacting secrets from raw responses. The original HTML-escaped its welcome email; this one is plain text, so there is nothing to escape.

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
- **Org hardening:** removed the default domain-wide Billing Account Creator and Project Creator roles so tenant users (including demo students) cannot create projects or billing accounts. Organization Policy Administrator was granted to luke@ only long enough to set the key upload exception, then removed. Organization Administrator can re-grant it if another exception is ever needed.
- **Admin accounts:** `luke@shuraku.org` super admin with 2SV (authenticator), saved backup codes, and verified recovery email. Break-glass super admin is optional (see Follow-ups).

### Integration identity and access

- **Service account** `salesforce-directory-sync` holding a **custom admin role**. No domain-wide delegation, no super admin impersonation, no GCP IAM roles. Audit logs show the service account as the actor.
- **Custom role `Directory Sync (Salesforce)`:** Users Create, Read, Update (full bundle); Groups Read, Update. No Users Delete, no Groups Create or Delete.
- **Why the full Update bundle:** the Directory API's `users.patch` requires the general Users > Update privilege for any field change, including suspend, and the role editor will not grant Update without all of its children (aliases, force password change, move, rename, reset password, suspend). Mitigation: non-super-admin roles cannot modify admin accounts.
- **Role scope is domain-wide, by necessity.** Google offers OU-restricted role assignment only for users and groups; the service account assignment flow has no OU option, and the Admin console offered only All organizational units. OU scoping would require a user or group admin that the service account acts as, which means domain-wide delegation and impersonation. The design rules both out, so it accepts a domain-wide role. Remaining fences: no Users > Delete, no access to admin accounts, Users and Groups privileges only, the integration targets the student OU tree by configuration, and the reconciliation sweep flags any Google user with a `salesforce_id` outside that tree (a detective control in place of the missing preventive one).
- **Structure is created by hand.** OUs and groups are created once in the Admin console. The integration only places users into existing OUs (`orgUnitPath`) and manages membership of existing groups. It never creates or deletes structure.

### Automation user (confirmed by docs and org checks)

- **The Contact trigger publishes a Platform Event** (`Directory_Sync_Request__e`, High Volume, Publish After Commit). An Apex subscriber trigger enqueues the work.
- **The subscriber runs as a dedicated integration user,** set through `PlatformEventSubscriberConfig` (deployed as metadata). The default Automated Process user cannot send email; a specified user can. Run-as configuration applies to Apex subscribers only, so the subscriber is an Apex trigger, not a Flow.
- **Integration user** `directory-sync@identity-lifecycle.dev`: Salesforce Integration license (Developer Edition includes one), Minimum Access - API Only Integrations profile, Salesforce API Integration permission set license. It never logs in.
- **Org checks passed:** it can hold the `Google Directory Sync` permission set (External Credential Principal Access); it can be granted Contact Read/Edit with field-level access on standard and custom fields through `Directory Sync Data Access`; and it can send email through the org-wide address from the subscriber trigger.
- **The integration user publishes events too.** The sweep and the two Contact actions hand work to the integration user by publishing `Directory_Sync_Request__e`, so it needs Create on that event (granted in `Directory Sync Data Access`). Without it the first sweep's repair silently never ran: `EventBus.publish` does not throw on failure, it returns the error. Every publish result is now checked.
- **Only the integration user holds `Google Directory Sync`.** Removed from luke's own user at the end of Phase 1. Staff who edit Contacts never hold the callout credential.
- **License-scoped grants:** Read on User External Credentials, granted in `Google Directory Sync` (a standard permission set), did not take effect for the Integration-licensed user. The grant had to live in `Directory Sync Data Access`, which is built on the Salesforce API Integration license. Assigning a permission set is not proof that every grant in it applies.

### Record access

- **Account-scoped sharing, not a bypass.** Account org-wide default is Private and Contact is Controlled by Parent. A checkbox, `Account.Directory_Sync_In_Scope__c`, marks in-scope Accounts; the criteria sharing rule Directory Sync Scope shares them Read/Write with the Directory Sync Integration group, whose only member is the integration user. The job runs `with sharing` and sees only those Contacts.
- **Why Read/Write on the Account rule:** with Contact Controlled by Parent, a sharing rule has no separate Contact access; Contacts inherit the Account level. The integration user's permission set grants only Read on the Account object, so it still cannot edit Accounts.
- **Private Contacts** (no Account) are invisible to the integration user, and lookups to a record the running user cannot see fail even in system mode. Demo Contacts live under the Demo Students Account.
- **People** get `Directory Sync Admin`: edit on the demo lifecycle fields, read-only on sync state, read-only on the logs (View All), the log tab, the Shuraku University app, and the custom permissions `Directory_Sync_Reprovision` and `Directory_Sync_Rename` that the two Contact actions check. Profiles grant nothing; fields and objects deployed from source get no profile access.

### Authentication from Salesforce

- **Self-signed JWT through a Named Credential.** External Credential `Google_Directory` with the **JWT** protocol (not OAuth 2.0), used by Named Credential `Google_Directory_API`: Salesforce signs a fresh JWT for each callout and sends it directly to the Directory API as the bearer token.
  - Claims: iss and sub set to the service account email, `aud = https://admin.googleapis.com/`, `kid` set to Google's key ID, 120-second expiry.
  - No token exchange, no token caching, no authentication code in Apex.
- **Why not OAuth 2.0 / JWT Bearer:** the External Credential's token exchange against Google's token endpoint failed with a blank error, while the identical key and claims succeeded through plain Apex. Details in PROGRESS. The Apex token exchange (`Auth.JWTBearerTokenExchange`) remains a proven fallback.
- **Key handling:** the key pair is generated in Salesforce Certificate and Key Management with **Exportable Private Key off**. Only the public certificate is uploaded to the service account. No service account key file exists.
- **Key lifetime and rotation:** the certificate `Google_Directory_JWT` and the uploaded Google key both expire **November 4, 2027**. Rotation overlaps rather than cutting over, since Google allows several keys per service account: create a new non-exportable certificate, upload it as a second key, point the External Credential at the new certificate and `kid`, verify with one list call, then delete the old key.
- **Google Cloud security baseline stays on.** The org enforces the legacy constraint `iam.disableServiceAccountKeyUpload`. The only change is a **project-scoped override** of that constraint. Key creation stays disabled.

### Email

- **Initial credentials:** Google has no Temporary Access Pass equivalent. Accounts get a random initial password with `changePasswordAtNextLogin = true`. See Risks.
- **Welcome message:** "Your Shuraku University Student Account", sent by Salesforce to the student's personal email, only after the Google create call succeeds and after every callout in the job. Plain text, with the username, temporary password, and sign-in link. Sent only when the job has just created the account and holds its password; a linked or adopted account gets no email.
- **Why Salesforce sends it, not Google:** the original sent through Microsoft Graph, which bundles directory and mail in one API. Google splits them. Cloud Identity Free has no mailboxes, the Directory API cannot send mail, and sending through the Gmail API would require domain-wide delegation and user impersonation, which the design rules out. Salesforce email keeps the service account's scope to directory work only.
- **Sender:** org-wide address `admin@shuraku.org` (display name Shuraku Admissions), verified, available to the System Administrator and Minimum Access - API Only Integrations profiles. Sent from the subscriber trigger as the integration user (Check 3 passed; DKIM signed by shuraku.org).
- **Other messages from the same address:** a reset notice (new temporary password) from the reprovision action, a new-username notice (no password) from the rename action, and the hourly failure digest to admin@.
- **Daily budget:** Developer Edition allows 15 single emails a day, shared by all of the above. The digest sends at most 3 in any rolling 24 hours, so failures cannot starve welcome emails, and it reserves capacity before every send.
- **The integration user cannot query `OrgWideEmailAddress`,** so the address ID lives in Custom Metadata rather than being looked up at runtime.
- **`setSaveAsActivity(false)`** on every welcome email, so the integration user never needs Task create access.
- **Sending domain:** shuraku.org verified in Salesforce with an **active DKIM key** (selectors `sf1`/`sf2`, CNAMEs DNS only in Cloudflare). No Salesforce include in SPF; DKIM provides DMARC alignment.
- **Inbound:** Cloudflare Email Routing (free). Cloudflare Email Sending requires Workers Paid and is out of scope.
- **Demo users** live in the `Demo Students` OU. Email Routing catch-all stays off, so mail to demo addresses bounces.

### Usernames

- **Format:** `first.last@shuraku.org`, lowercase. Parenthetical nicknames dropped; accents transliterated (José to jose, Müller to mueller, ß to ss); apostrophes dropped; periods treated as spaces; spaces removed in first names and turned into hyphens in last names; only `a-z`, `0-9`, `.`, and `-` emitted.
- **Fallbacks:** a part that cleans to nothing falls back to the other part; if both are empty (a name entirely in a non-Latin script), the username is `student.` plus six characters of the Contact ID.
- **Length:** the base is capped at 62 characters, last name trimmed first, so a collision suffix up to 99 always fits Google's 64. Display names keep Unicode and are capped at 60, the limit Google enforces (confirmed live).
- **Collisions:** on a 409, the job fetches the account holding the name. If it carries this Contact's `salesforce_id`, it is this student's account (an earlier run that failed after the create) and is linked, not duplicated. Otherwise the next suffix is tried, up to 10.
- **Source data decides username quality.** The normalizer follows the first and last name fields as entered. A double surname typed partly into First Name produces a different username, and no code can tell a middle name from a first surname. Only the form, or the person, can.

### Name changes (was open question 1)

- **Hybrid.** Display names (givenName, familyName) follow the Contact automatically on every run. The username changes only through the **Rename Google Username** action, because a rename changes how the student signs in.
- **Rename behavior:** Google turns the old address into an alias (on a Workspace tenant, mail to it still arrives; Cloud Identity Free has no mail). The password does not change. The student gets a notice with both usernames. Renames can take up to 10 minutes to propagate.
- **Collisions on rename** use the same suffixes as a create. If the name is already an alias of the same account (renaming back to a previous name), the job refuses and says how to remove the alias, rather than handing out a suffixed name.

### Job design

- **One job per Contact, in a fixed order:** read the Contact, look the user up by `salesforce_id`, plan, make every callout, send the welcome email, then write the Contact and logs. DML before a callout would block the callout, and email is only sent when the transaction commits.
- **Google work is not rolled back by a Salesforce failure.** When a write-back failed after a successful create, the transaction rolled back the email and logs but the account remained. The next run found it by `salesforce_id` and linked it without a duplicate. This is why every run looks up before it creates.
- **Settings are source-controlled.** Custom Metadata records deploy like code; a full deploy overwrote a Dry Run change made in Setup. Change settings in source.
- **Retries:** a retryable Google failure (rate limit, quota, 5xx, timeout) re-enqueues the whole job after 1, 2, then 4 minutes, 4 attempts in total. Developer Edition caps a Queueable chain at 5, so the maximum is a constant. A retry re-plans from the Contact and starts with the lookup, so it resumes where the last run stopped. Every log row carries its attempt number.
- **Alerts:** a final failure (not retryable, or out of attempts), a failed email, or an unhandled job failure marks its log row Pending. The hourly digest reports Pending rows to admin@ and marks them Sent. Retries in flight never alert.
- **Tests do not depend on org settings.** The job takes test settings through instance fields (which travel with an enqueued job), and the flow tests pass with Dry Run on or off.

### Operations

- **Reconciliation sweep, daily at 8:23 AM.** Lists every user in the domain (500 per page, trimmed to five fields) and compares them with the Contacts in scope. Drift (wrong suspended state or OU, or an unrecorded Google ID) and never-provisioned Contacts are repaired by republishing a sync request, so the normal job fixes them with its own retries and alerts. Out-of-tree `salesforce_id`, unmanaged users inside the student tree, orphans, accounts missing from Google, a truncated sweep, and failed publishes are report-only and go to the digest. A missing account is never recreated automatically.
- **Scheduled Apex cannot make callouts and runs as whoever scheduled it,** and staff do not hold the callout credential. The schedule and both Contact actions therefore only publish an event (`Kind__c` Sweep, Reprovision, or Rename); the subscriber starts the work as the integration user.
- **Reprovision action:** new temporary password (change required at next sign-in) and a reset notice, for an existing active account. Refuses with no account, a suspended account, no personal email, or dry run on.
- **Both actions** check a custom permission, apply a 10-minute cooldown per Contact, log who asked, and do not retry (a retry could send a second password or rename twice).
- **Scheduled jobs block Apex deploys** by default. This dev org allows deployments with pending Apex jobs; a production org would pause and reschedule instead.

### Groups

- **Flat program and term groups**, six created by hand. `Directory_Group_Mapping__mdt` keys on Program and Term; a blank key matches anything, so a cohort group (both keys filled) can be added later as a record, not code.
- **Only managed groups are touched.** The job reads a user's groups, adds what is missing, and removes mapped groups that no longer apply. Any other group is left alone. "Already a member" (409) and "not a member" (404) count as success, so retries converge.
- **Membership keys on the immutable Google user ID**, never the email address.
- **Suspend strips managed groups; return restores them** from the Contact's Program and Term. Nothing has to remember prior memberships because the Contact is the source.

### Lifecycle state

- **Status mapping** (`Directory_Status_Mapping__mdt`) gives each status a target state and OU: Admitted and Admit with Conditions to Active in `/Demo Students/Admitted`; Enrolled and Alumni to Active in their OUs; Withdrawn, Denied, and Cancelled to Suspended in `/Demo Students/Inactive`; Applied to no action. A status with no record fails closed.
- **Suspend and move in one call; reactivate and move in one call.** Sign-in is cut before groups are touched; a failed suspend leaves groups alone. The Contact shows Suspended or Active only when the account change succeeded.

### API behavior the design depends on (proven in Phase 0)

- Use `domain=shuraku.org` (or the customer ID) for list calls. `customer=my_customer` returns 400 for a service account using its own admin role.
- `externalIds` with custom type `salesforce_id` stores the Salesforce record ID on the Google user, and `query=externalId:<id>` finds it. This is the idempotency lookup.
- **Eventual consistency:** a read immediately after a write may not reflect it. Trust the write's response; never verify by reading back immediately; the reconciliation sweep handles drift.
- Suspended users can be group members, and suspension does not remove memberships.
- **`groups.list` needs `domain` too.** With only `userKey`, the service account got 404 "Domain not found"; the API requires `customer` or `domain`, and a service account has no default customer. Key-based calls (users.get, users.patch, members insert and delete) need neither.

### Directory API limits (from Google's docs)

- **Names:** Google's docs disagree (the users resource reference and the Help Center say 60; the Limits page says 40). A live create settled it: 41 and 60 characters were accepted and stored in full; 61 returned 400 `invalid`. The limit is 60.
- **Usernames (local part):** up to 64 characters, lowercase, no consecutive periods, cannot begin or end with a period. Google allows apostrophes and some symbols but warns they break downstream sync tools, so the normalizer emits only `a-z`, `0-9`, `.`, and `-`.
- **Passwords:** 8 to 100 ASCII characters.
- **Rate limits:** user creates capped at 10 per domain per second; default quota 2,400 queries per minute per user per project. One record per job stays far below both.
- **Retryable errors:** 403 `quotaExceeded`, 403 `userRateLimitExceeded`, and 429 `rateLimitExceeded`. A 403 can also mean permission denied, so the client branches on the error `reason`, not the status code. Google recommends exponential backoff (1s doubling to 16s, five retries); Apex cannot sleep, so retries use delayed Queueables at minute granularity.
- **Renames** can take up to 10 minutes to propagate across Google services.
- **Users list pages:** default 100, maximum 500.

## 4. Environment

| Item | Status |
|---|---|
| shuraku.org on Cloudflare; Email Routing; admin@ and luke@ routes | Done |
| Cloud Identity Free tenant; domain verified; luke@ secured | Done |
| GCP project, no billing, Admin SDK enabled | Done |
| Default domain-wide project and billing creation removed | Done |
| Service account, custom role, Demo Students OU | Done |
| Project-scoped key upload override; certificate uploaded | Done |
| Organization Policy Administrator removed from luke@ | Done |
| Fresh Salesforce Developer Edition org; Salesforce DX project in the repo | Done |
| Non-exportable certificate `Google_Directory_JWT` (expires Nov 4, 2027) | Done |
| External Credential `Google_Directory` (JWT) and Named Credential `Google_Directory_API`; permission set `Google Directory Sync` | Done |
| DKIM key active for shuraku.org | Done |
| Org-wide address admin@shuraku.org verified | Done |
| Integration user, `Directory Sync Data Access` permission set | Done |
| Platform Event `Directory_Sync_Request__e`, subscriber trigger, subscriber config (run as integration user, batch 50) | Done |
| Child OUs Admitted, Enrolled, Alumni, Inactive under Demo Students | Done |
| Six program and term groups (Only invited users, no external members) | Done |
| Account org-wide default Private; Directory Sync Scope sharing rule; Demo Students Account | Done |
| `Directory Sync Admin` permission set; Directory Sync Logs tab; Shuraku University app | Done |
| Custom Metadata: settings, status mapping, group mapping (with page layouts) | Done |
| Proof calls: list, create, find by externalId, suspend, group add/remove | Passed |
| Integration user checks: credential permission set, Contact access, email send | Passed |
| Directory API limits and quotas recorded | Done |
| Scheduled jobs: alert digest hourly at :07, reconciliation sweep daily at 8:23 AM | Done |
| Deployment Settings: allow deployments with pending Apex jobs (dev org) | Done |
| Contact actions Reprovision Google Account and Rename Google Username (screen flows, quick actions, custom permissions) | Done |
| OU-scoped role assignment | Not available for service accounts (see Decisions) |

## 5. Architecture

```
Salesforce (system of record)
  Contact trigger (update; status, program, term, or name changed)
    -> publish Directory_Sync_Request__e (Publish After Commit)
  Platform Event subscriber (Apex trigger, runs as dedicated integration user)
    -> enqueue one DirectorySyncJob per Contact (Queueable + Finalizer)
         -> read the Contact (with sharing: in-scope Accounts only)
         -> GoogleDirectoryClient: look up by salesforce_id
         -> DirectorySyncPlanner: target state from the status mapping
         -> DirectoryJoiner (create) or DirectoryMover (move, suspend,
            reactivate, managed group sync)
              -> Named Credential Google_Directory_API
                   -> External Credential Google_Directory, JWT protocol
                      (self-signed JWT per callout, non-exportable key)
                   -> Google Admin SDK Directory API
         -> welcome email after the last callout (org-wide address, DKIM)
         -> write state to the Contact; insert every call's log row
         -> retryable failure: re-enqueue itself after 1, 2, 4 minutes
         -> final failure: log row marked Pending for the digest
  Contact actions (Reprovision, Rename; custom permission, cooldown)
    -> publish the same event with Kind__c; the subscriber runs the job
       in reprovision or rename mode as the integration user
  Daily sweep schedule
    -> publishes Kind__c = Sweep; DirectorySyncSweep runs as the
       integration user, one Queueable per 500 users
    -> drift and never-provisioned: republishes sync requests
    -> out-of-tree, unmanaged, orphan, missing: reported, not changed
  Hourly alert digest
    -> one email to admin@ listing Pending rows, at most 3 per day

Google Cloud Identity Free
  Service account  -> custom admin role (users, groups), domain-wide scope
  Demo Students OU -> created by hand
  Groups           -> created by hand; integration manages membership
```

Design principles:

- **Idempotent operations.** Before any create, look the user up by `externalId`. The Salesforce record ID is stored on the Google user, and the immutable Google user ID is stored back on the Salesforce record. Updates key on the Google user ID, never the email address.
- **One record per job.** No shared mutable state between jobs.
- **State on the record.** Status, primary email, Google user ID, last sync time, last error.
- **Trust writes, reconcile later.** No read-after-write verification; the sweep catches drift.
- **Every call logged** to a sync log object for audit and troubleshooting.
- **Configuration in Custom Metadata.** Settings (enabled, dry run, welcome email, provisioning delay, domain, org-wide address ID), status mapping (target state, OU, group sync), and group mapping.
- **Least privilege at every layer.** Custom role instead of super admin, no domain-wide delegation, no structure management, non-exportable key, one narrow policy exception, and the callout credential held only by the integration user.

## 6. Lifecycle scope

| Event | Salesforce trigger (demo data) | Google action |
|---|---|---|
| Joiner | Enters an Active status, no account yet | Create in the status's OU with `salesforce_id`, add program and term groups, send welcome email |
| Mover | Status changes between Active statuses | Move OU |
| Mover | Program or term changes | Add and remove managed groups |
| Update | Name change | Display name follows the Contact automatically; username changes only through the Rename Google Username action |
| Leaver | Withdrawn, Denied, or Cancelled | Suspend and move to Inactive in one call, then remove managed groups |
| Return | Back to an Active status | Reactivate and move in one call, then restore groups from the Contact |

Deletion is out of scope for v1. Suspend is the end state, consistent with a retention-first policy.

## 7. Phases

Each phase ends with a check: what was planned, what got done, what moved or got dropped.

**Phase 0: Tenant and proof of API access** (complete)
- All environment items in section 4.

**Phase 1: Salesforce foundation** (complete)
- Data model, sync log, Custom Metadata settings and status mapping; `GoogleDirectoryClient` with a routed callout mock; event plumbing running as the integration user; Account-scoped sharing. Moved: the real trigger body replaced the test stub.

**Phase 2: Joiner path** (complete)
- Normalizer with 20 name fixtures (including an apostrophe name), idempotent create with collision handling, welcome email. Proven live, including recovery from a create whose write-back failed. Moved to Phase 5: the live 41 to 60 character name create and recording the Developer Edition daily email limit.

**Phase 3: Mover path** (complete)
- OU moves and managed group sync from Program and Term, proven live. Found: `groups.list` needs `domain` for a service account.

**Phase 4: Leaver and return** (complete)
- Suspend into Inactive with groups removed; reactivate with groups restored. Proven live.

**Phase 5: Reconciliation and operations** (complete)
- Quick checks: Developer Edition single email limit is 15 a day; Google's name limit is 60 (display name cap raised from 40).
- Retry with backoff through delayed Queueables, attempt on every log row.
- Hourly failure digest to admin@, capped at 3 a day.
- Daily reconciliation sweep with the out-of-tree check. Its first live run found real drift (a student in the wrong OU) and exposed a silent publish failure: the integration user lacked Create on the request event. Fixed, re-run, repaired, and a third run came back clean.
- Reprovision action, proven live (new password delivered, cooldown refused a second click, forced change at sign-in).
- Name changes decided (hybrid) and built: display names sync automatically; the Rename action renamed the demo student's username and sent the notice.

**Phase 6: Write-up**
- README (including "What it doesn't do"), redacted screenshots, LinkedIn post.

## 8. Ground rules

- Free tier throughout. The one paid exception is the shuraku.org domain (about $11/yr).
- Do not enable anything that bills by usage. No Cloudflare Workers Paid. The Google Cloud project has no billing account attached. Back out of any screen asking for a card or offering a trial.
- Keep Google's security baseline. Any exception is scoped as narrowly as possible and documented with its reason.
- Demo data only. No non project data, names, or configuration in this repo.
- Secrets never committed. The private key lives only in Salesforce. No service account key files exist.
- Public-repo hygiene: raw screenshots go in `evidence-raw/` (gitignored). Only redacted copies go in `docs/evidence/`. Keep customer ID, key ID, user IDs, and recovery contact details out of committed files.
- Check the docs for the version actually in use before writing library or API code.
- Verify against the live system, not assumptions.
- Log findings in `docs/PROGRESS-identity.md` and commit in small steps.

## 9. Risks and known trade-offs

- **Initial password by email.** Sending a temporary password to a personal inbox is weaker than a time-limited pass. Mitigations: random strong password, forced change at first sign-in, demo OU only, login audit review.
- **Full Users > Update bundle.** The role can reset passwords and change aliases for non-admin users, which v1 does not need. Mitigation: admin accounts are out of reach for non-super-admin roles.
- **Domain-wide role scope.** The service account can act on any non-admin user in the tenant, not just students. Mitigations: no Delete privilege, configuration-driven OU targeting, and the sweep's out-of-tree check. Accepted in exchange for avoiding domain-wide delegation.
- **Key upload exception.** One baseline control is relaxed for one project. Mitigations: key creation stays disabled, the private key never leaves Salesforce, and the service account holds only a custom role.
- **Long-lived signing key.** The uploaded key does not rotate on its own and expires November 4, 2027. Mitigation: overlapping rotation (see Decisions) before expiry.
- **Self-signed JWT support.** The design depends on the Directory API continuing to accept self-signed JWTs. Fallback: the proven Apex token exchange.
- **Eventual consistency.** Reads can lag writes. The design never depends on immediate read-back.
- **Name limits.** Google's docs give 40 and 60; a live create in Phase 5 confirmed 60 is enforced. Display names are capped at 60.
- **Developer Edition email limits.** 15 single emails per day, shared by welcome emails, reprovisioning and alerts. Alerts are capped so failures can't starve joiners.
- **Partial failures across systems.** A Salesforce failure cannot undo a Google write. Mitigation: every run looks up by `salesforce_id` first and links what it finds; a lost temporary password is fixed with the Reprovision action.
- **Name quality depends on data entry.** Usernames follow the name fields as entered; a wrong split produces a valid but wrong username, fixable through the Rename action after the name fields are corrected.
- **Cloud Identity Free user cap** is 50. The sweep never creates users directly; it only republishes requests for Contacts that were never attempted, and it never recreates a missing account.
- **Silent publish failures.** `EventBus.publish` returns errors instead of throwing. Every publish result is checked, and a failure is reported to the digest.
- **Google API quotas.** Recorded (see Decisions). Retries back off and branch on error reason.

## 10. Open questions

Resolved:
- **Student record:** Contact, matching where this data lives in the original org. Sync fields: `Google_User_Id__c` (External ID, unique), `Google_Primary_Email__c`, `Google_Account_Status__c`, `Google_Last_Sync__c`, `Google_Last_Error__c`. Demo lifecycle fields: status, program, term. Standard Email is the personal address for the welcome message. Contacts are created with no status, so the trigger runs on update only.
- **Automation user:** a Platform Event subscriber running as a dedicated, API-only integration user. Confirmed by Salesforce docs and three org checks (see Decisions).
- **OU-scoped role assignment:** not available for service accounts. Accepted a domain-wide role with compensating controls (see Decisions).
- **Denied or Cancelled after provisioning:** suspend automatically, same as Withdrawn. Suspension is reversible, and the Return path reactivates if the status moves back to an admit status.
- **Group model (was question 2):** flat program and term groups, with cohort groups possible later as configuration (see Decisions).
- **Memberships on suspend (was question 4):** remove managed groups on suspend; restore them from the Contact on return.
- **Username format:** `first.last`, with the rules in Decisions.
- **Name changes (was question 1):** hybrid. Display names follow the Contact; the username changes only through the Rename action (see Decisions).

Open:
3. **Security-labeled groups:** should the real program and term groups carry the security label (permanent once applied) if they will drive access, such as SSO app assignment?
5. **Duplicate Contacts:** the `externalId` lookup prevents a second account for the same Contact, but not for the same person with two Contacts (for example, a returning applicant who registers again). Add a pre-create check on personal email that flags a possible duplicate for review instead of creating an account?


## 11. Follow-ups (outside v1)

- DMARC record on shuraku.org: start with `p=none` and reports to admin@, then tighten now that Salesforce DKIM is active.
- Break-glass super admin with its own 2SV, never used day to day.
- Enforce 2SV on the Demo Students OU through Admin console policy.
- SIS-driven leaver events: take leave-of-absence and withdrawal signals from the student information system instead of a Contact status field.
- Workload Identity Federation spike: test whether Salesforce can act as an OIDC issuer for Google, removing the long-lived key entirely.
- SSO hub: Google as IdP over SAML into Salesforce and my other apps.
- Incident response case study on the same tenant.
- Cohort groups (program and term together) as Custom Metadata records, if cohort communication is needed.
- Group membership in the sweep (one call per user; the job already reconciles groups on every event).
- Alias cleanup after renames, once the old addresses are no longer needed.

## 12. References

- Google Workspace Updates: service accounts with admin roles, no domain-wide delegation (Aug 2020): https://workspaceupdates.googleblog.com/2020/08/use-service-accounts-google-groups-without-domain-wide-delegation.html
- Google: Manage roles, role-to-privilege mapping: https://developers.google.com/workspace/admin/directory/v1/guides/manage-roles
- Google: Administrator privilege definitions: https://support.google.com/a/answer/1219251
- Google: Assign specific admin roles (OU restriction; service account assignment): https://knowledge.workspace.google.com/admin/users/assign-specific-admin-roles
- Google: Directory API limits and quotas: https://developers.google.com/admin-sdk/directory/v1/limits
- Google: Directory API users resource: https://developers.google.com/admin-sdk/directory/v1/reference/users
- Google: Name guidelines for users and groups: https://knowledge.workspace.google.com/admin/users/name-guidelines-for-users-and-groups
- Google Cloud security baseline constraints: https://docs.cloud.google.com/resource-manager/docs/manage-baseline-constraints
- Salesforce: Set Up JWT Claims for External Credentials: https://help.salesforce.com/s/articleView?id=xcloud.nc_jwt_claims.htm&language=en_US&type=5
- Salesforce: OAuth External Credential with the JWT Bearer Flow: https://help.salesforce.com/s/articleView?language=en_US&id=xcloud.nc_create_edit_oath_jwt_bearer_ext_cred.htm&type=5
- Salesforce: PlatformEventSubscriberConfig (Tooling API): https://developer.salesforce.com/docs/atlas.en-us.api_tooling.meta/api_tooling/tooling_api_objects_platformeventsubscriberconfig.htm
- Google: Directory API groups.list (customer or domain required): https://developers.google.com/admin-sdk/directory/reference/rest/v1/groups/list
- Cloud Identity editions: https://cloud.google.com/identity/docs/editions
- Google: Change a user's email address (old address becomes an alias): https://knowledge.workspace.google.com/admin/users/change-a-users-email-address
- Salesforce: Queueable Apex (delayed enqueue, chain depth): https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_queueing_jobs.htm
- Salesforce: Platform event permissions (Create to publish): https://developer.salesforce.com/docs/atlas.en-us.platform_events.meta/platform_events/platform_events_intro_emp.htm