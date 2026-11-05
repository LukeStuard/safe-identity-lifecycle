# Safe Identity Lifecycle

Salesforce as the system of record for identity: student records drive Google account creation, OU placement, group membership, suspension, and reactivation through the Google Admin SDK Directory API.

> **Status: Phase 0 complete.** The tenant, least-privilege service account, and Salesforce authentication are in place, and live API calls have proven create, lookup by Salesforce ID, suspend, and group membership. The integration code starts in Phase 1. Progress is logged in [`docs/PROGRESS-identity.md`](docs/PROGRESS-identity.md), and the plan is in [`docs/BRIEF-identity.md`](docs/BRIEF-identity.md).

## Why this exists

This is a clean rebuild of a production integration I built in higher education, where Salesforce provisions Microsoft 365 accounts through Microsoft Graph. Many schools run Google instead of Microsoft, so this version targets Google Cloud Identity. More importantly, it redesigns the parts of the original that failed in production:

| Lesson | Root cause in the original | Design fix |
|---|---|---|
| Students admitted through a second admit status were missed until the flow was patched | The trigger matched an enumerated list of statuses, so any admit status not on the list was skipped | Eligibility is a state predicate ("in any admitted-or-later status, not yet provisioned") driven by one configurable status grouping, plus a scheduled reconciliation sweep that catches anything missed. |
| A retry after a partial failure could create a second account for the same student | The only guard was the email field, written after the create; a name conflict was treated as a different person and retried with a numeric suffix | Look up by `externalId` (the Salesforce record ID stored on the Google user) before any create. A name conflict means "pick the next name" only when no account exists for this record. Conflicts are detected by status code, not message text. |
| Initial passwords were stored on the Contact | The password was written to a metadata field for a later job to read, then redacted; a static fallback password existed | Generate the password, create the user, and send the welcome email in one job. The password never touches a field, and there is no static fallback. |
| Bulk Contact updates could fail the user's own save | One Queueable enqueued per record inside the triggering transaction | The trigger publishes Platform Events. A subscriber running as a dedicated integration user enqueues the work. |
| Long, compound, and non-Latin names produced broken or degraded usernames | No length cap; an accent map covering a few languages, with everything else stripped; no handling for names that clean down to empty | A documented normalization function with a length budget, trimming, a broad transliteration map, a defined truncation order, empty-part fallback, and fixture tests for hard names. |
| Failures were found only when someone noticed | Errors logged to debug and a status string; no retry or alerting | Sync log records, a retry policy with backoff, and failure alerts to admin@. |

## Lifecycle covered

| Event | Trigger in Salesforce | Action in Google |
|---|---|---|
| Joiner | Applicant reaches Admitted or later | Create user in the demo OU, send welcome email |
| Mover | Status changes | Move OU |
| Mover | Program or term changes | Update group membership |
| Leaver | Withdrawn | Suspend |
| Return | Re-enrolled | Reactivate |

## Architecture

```
Salesforce
  trigger -> eligibility check -> one Queueable per record
    -> GoogleDirectoryClient (Apex)
         -> Named Credential
              -> External Credential, JWT protocol
                 (self-signed JWT per callout, signed with a non-exportable key)
              -> Google Admin SDK Directory API
    -> result written back to the record, every call logged
    -> welcome email from Salesforce after a successful create
  scheduled reconciliation sweep -> same jobs

Google Cloud Identity Free
  service account with a custom admin role (users and groups only)
  OUs and groups created by hand; the integration manages placement and membership
```

## Security design

- **No super admin in the integration path.** The service account holds a custom admin role. No domain-wide delegation and no admin impersonation, so audit logs show the service account as the actor. Non-super-admin roles cannot modify admin accounts.
- **The private key never leaves Salesforce.** The key pair is generated in Salesforce with private key export disabled. Only the public certificate is uploaded to Google. No service account key file exists.
- **No token exchange.** Each callout carries a fresh self-signed JWT valid for two minutes. There are no access tokens to cache, leak, or refresh.
- **Google's security baseline stays on.** One documented, project-scoped exception allows public key upload. Service account key creation stays disabled.
- **Default over-permissions removed.** New Google Cloud orgs let every domain user create projects and billing accounts. That grant is removed.
- **The integration doesn't build structure.** OUs and groups are created by hand. The integration only places users and manages membership.
- **Idempotent by design.** Every create looks the user up first by Salesforce ID, stored on the Google user as an external ID.
- **Demo data only,** in a clearly labeled demo OU.

## Engineering notes from Phase 0

- Salesforce's OAuth 2.0 JWT Bearer External Credential failed against Google's token endpoint with a blank error, while the identical key and claims succeeded through plain Apex. The JWT protocol (self-signed JWT straight to the API) works and turned out to be the simpler design.
- The Directory API's user update call requires the general Users > Update privilege for any change, including suspend. The narrower Suspend Users privilege alone returns 403.
- `customer=my_customer` returns 400 for a service account using its own admin role. Use the domain or customer ID.
- Reads can lag writes by seconds. The design trusts write responses and lets the reconciliation sweep handle drift.

## Stack

- Salesforce (Apex, Flow, Named and External Credentials)
- Google Cloud Identity Free and the Admin SDK Directory API
- Cloudflare DNS and Email Routing for the demo domain

Everything runs on free tiers. The only cost is the demo domain.

## What it doesn't do

- **No account deletion.** Suspension is the end state, consistent with a retention-first policy.
- **No Temporary Access Pass.** Google has no equivalent, so new accounts get a random initial password that must be changed at first sign-in. Delivering it by email is a documented trade-off.
- **No Gmail or mailboxes.** Cloud Identity Free provides identities, not mail.
- **No OU or group management.** OUs and groups are created by hand. The integration only places users and manages membership.

This section will grow as the build progresses.

## Related projects

- [safe-agent-gateway](https://github.com/LukeStuard/safe-agent-gateway): MCP server connecting AI agents to Salesforce safely
- [safe-document-intake](https://github.com/LukeStuard/safe-document-intake): serverless Salesforce-to-Google Drive document intake with AI screening