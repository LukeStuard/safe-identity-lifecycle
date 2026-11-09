/**
 * One job per Contact.
 *
 * Executes the joiner path (create), the mover path (OU moves and managed
 * group membership from Program and Term), and the leaver and return paths
 * (suspend into the Inactive OU with managed groups removed; reactivate into
 * the status's OU with groups restored from the Contact). With Dry Run on,
 * nothing is written to Google or the Contact; only the plan is logged.
 *
 * Sharing: with sharing. The integration user sees only Contacts under an
 * Account flagged Directory_Sync_In_Scope__c, through the Directory Sync
 * Scope sharing rule. A Contact outside that scope is invisible here, and
 * the job logs it as not found instead of touching Google.
 *
 * Order matters: every callout first, then the welcome email, then DML.
 * Unhandled failures are recorded by DirectorySyncFinalizer.
 *
 * Retries: a retryable Google failure (rate limit, quota, 5xx, timeout)
 * re-enqueues the whole job with a delay of 1, 2, then 4 minutes, up to
 * MAX_ATTEMPTS runs in total. A retry re-plans from the Contact and starts
 * with the salesforce_id lookup, so it resumes where the last run stopped:
 * a create that succeeded before a group add failed comes back as a mover
 * run. Every log row carries the attempt number. Developer Edition allows a
 * chain of 5 Queueables, so 4 attempts fit with room to spare. If a new
 * Contact edit enqueues a fresh job while a retry is pending, both converge
 * for the same reason (lookup first, adopt on 409, 409 and 404 on groups
 * count as success).
 *
 * Alerts: a final failure (not retryable, or out of attempts) and a failed
 * welcome email mark their log row Alert_Status__c = Pending. The hourly
 * DirectorySyncAlerts digest reports them; retries in flight never alert.
 */
public with sharing class DirectorySyncJob implements Queueable, Database.AllowsCallouts {

    public static final Integer MAX_ATTEMPTS = 4;
    public static final Integer MAX_DELAY_MINUTES = 10;   // platform limit for enqueueJob delay

    private final Id contactId;
    private final Integer attempt;

    /** First failure seen in this run; decides whether to retry. */
    private transient String failureReason;
    private transient Boolean failureRetryable;

    /** Test hooks. Instance fields travel with the job when it is enqueued. */
    @TestVisible
    private Directory_Sync_Setting__mdt injectedSettings;
    @TestVisible
    private List<Directory_Group_Mapping__mdt> injectedGroupMappings;
    @TestVisible
    private Boolean forceEmailFailure = false;

    public DirectorySyncJob(Id contactId) {
        this(contactId, 1);
    }

    public DirectorySyncJob(Id contactId, Integer attempt) {
        this.contactId = contactId;
        this.attempt = attempt == null || attempt < 1 ? 1 : attempt;
    }

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DirectorySyncFinalizer(contactId, attempt));

        List<Contact> rows = [
            SELECT Id, FirstName, LastName, Email, Lifecycle_Status__c, Program__c, Term__c, Google_User_Id__c
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            insert new Directory_Sync_Log__c(
                Operation__c = 'Plan',
                Success__c = false,
                Error_Reason__c = 'contactNotFound',
                Attempt__c = attempt,
                Request_Summary__c = 'Contact ' + contactId,
                Response_Summary__c = 'Contact not found or outside the sync scope (no in-scope Account); nothing to do.'
            );
            return;
        }
        Contact c = rows[0];

        Directory_Sync_Setting__mdt settings = injectedSettings != null ? injectedSettings : DirectorySyncConfig.settings();
        Boolean dryRun = settings.Dry_Run__c == true;
        Directory_Status_Mapping__mdt mapping = DirectorySyncConfig.mappingFor(c.Lifecycle_Status__c);
        GoogleDirectoryClient client = new GoogleDirectoryClient(contactId, settings.Domain__c, dryRun);

        DirectoryResult lookup = needsGoogle(mapping) ? client.findByExternalId(contactId) : null;
        DirectorySyncPlanner.Plan plan = DirectorySyncPlanner.plan(c.Lifecycle_Status__c, mapping, lookup);

        Contact patch = null;
        List<Directory_Sync_Log__c> extraLogs = new List<Directory_Sync_Log__c>();

        if (!dryRun) {
            List<Directory_Group_Mapping__mdt> groupRows =
                injectedGroupMappings != null ? injectedGroupMappings : DirectoryGroupPlanner.allMappings();
            Boolean syncGroups = mapping != null && mapping.Sync_Groups__c == true;
            Set<String> desiredGroups = DirectoryGroupPlanner.desired(c.Program__c, c.Term__c, groupRows);
            Set<String> managedGroups = DirectoryGroupPlanner.managed(groupRows);

            if (plan.action == 'CREATE') {
                Boolean sendWelcome = settings.Send_Welcome_Email__c == true;
                DirectoryJoiner.Outcome outcome = DirectoryJoiner.create(c, mapping, settings.Domain__c, sendWelcome, client);
                patch = outcome.toContact(contactId);
                if (!outcome.success) {
                    noteFailure(outcome.errorReason, DirectoryResult.isRetryableReason(outcome.errorReason));
                    plan.steps.add('Failed: ' + outcome.errorReason + (String.isBlank(outcome.errorMessage) ? '' : ' (' + outcome.errorMessage + ')'));
                }

                if (outcome.success && syncGroups) {
                    DirectoryMover.Result groups = new DirectoryMover.Result();
                    DirectoryMover.syncGroups(
                        outcome.googleUserId, desiredGroups, managedGroups, !outcome.adopted, client, groups
                    );
                    record(patch, groups, plan);
                    if (!groups.success) {
                        noteFailure(groups.errorReason, DirectoryResult.isRetryableReason(groups.errorReason));
                    }
                }

                // All callouts are done. The email goes out before any DML.
                if (outcome.adopted) {
                    plan.steps.add('Name was taken by this Contact\'s own account; linked it instead of creating a second one. No welcome email.');
                } else if (outcome.success && sendWelcome) {
                    Messaging.SingleEmailMessage message = WelcomeEmail.build(
                        c.FirstName, outcome.primaryEmail, outcome.password, c.Email, settings.Org_Wide_Address_Id__c
                    );
                    String emailError = WelcomeEmail.send(message, forceEmailFailure);
                    Directory_Sync_Log__c welcomeLog = WelcomeEmail.log(contactId, c.Email, outcome.primaryEmail, emailError);
                    extraLogs.add(welcomeLog);
                    if (emailError != null) {
                        welcomeLog.Alert_Status__c = 'Pending';
                        patch.Google_Account_Status__c = 'Error';
                        patch.Google_Last_Error__c = ('Welcome email failed; password reset required. ' + emailError).left(255);
                    }
                } else if (outcome.success) {
                    plan.steps.add('Welcome email disabled; the temporary password was not delivered.');
                }
                outcome.password = null;
            } else if (plan.action == 'ERROR') {
                patch = new Contact(
                    Id = contactId,
                    Google_Last_Error__c = (plan.errorReason + ': ' + plan.reason).left(255)
                );
                // A failed lookup carries the response; multipleMatches and config errors never retry.
                noteFailure(plan.errorReason, lookup != null && lookup.isRetryable());
            } else {
                patch = linkExistingAccount(c, lookup, plan);

                Map<String, Object> user = singleUser(lookup);
                String target = mapping == null ? null : mapping.Target_State__c;
                if (user != null && (target == 'Active' || target == 'Suspended')) {
                    String googleId = (String) user.get('id');
                    String currentOu = (String) user.get('orgUnitPath');
                    Boolean isSuspended = user.get('suspended') == true;
                    DirectoryMover.Result result = new DirectoryMover.Result();
                    Boolean stateOk;

                    if (target == 'Active') {
                        // Mover, or return: reactivate first, then restore groups from the Contact.
                        if (isSuspended) {
                            stateOk = DirectoryMover.setSuspended(googleId, false, currentOu, mapping.Target_OU__c, client, result);
                        } else {
                            DirectoryMover.moveIfNeeded(googleId, currentOu, mapping.Target_OU__c, client, result);
                            stateOk = result.success;
                        }
                        if (stateOk && syncGroups) {
                            DirectoryMover.syncGroups(googleId, desiredGroups, managedGroups, false, client, result);
                        }
                    } else {
                        // Leaver: cut sign-in first, then strip managed groups.
                        if (!isSuspended) {
                            stateOk = DirectoryMover.setSuspended(googleId, true, currentOu, mapping.Target_OU__c, client, result);
                        } else {
                            DirectoryMover.moveIfNeeded(googleId, currentOu, mapping.Target_OU__c, client, result);
                            stateOk = result.success;
                        }
                        if (stateOk) {
                            DirectoryMover.syncGroups(googleId, new Set<String>(), managedGroups, false, client, result);
                        }
                    }

                    if (patch == null) {
                        patch = new Contact(Id = contactId);
                    }
                    if (stateOk) {
                        patch.Google_Account_Status__c = target;
                    }
                    record(patch, result, plan);
                    if (!result.success) {
                        noteFailure(result.errorReason, DirectoryResult.isRetryableReason(result.errorReason));
                    }
                }
            }
        }

        Integer retryDelay = applyRetryPolicy(patch, plan);

        List<Directory_Sync_Log__c> logs = new List<Directory_Sync_Log__c>(client.getPendingLogs());
        Directory_Sync_Log__c planLog = plan.toLog(contactId, c.Lifecycle_Status__c, mapping, dryRun);
        if (failureRetryable != null) {
            // The run failed: the plan row says so, and a final failure waits for the digest.
            planLog.Success__c = false;
            planLog.Error_Reason__c = failureReason;
            if (retryDelay == null) {
                planLog.Alert_Status__c = 'Pending';
            }
        }
        logs.add(planLog);
        logs.addAll(extraLogs);
        for (Directory_Sync_Log__c l : logs) {
            l.Attempt__c = attempt;
        }

        if (patch != null) {
            update patch;
        }
        insert logs;

        // Last, after all DML: if this transaction rolls back, the retry is never queued.
        if (retryDelay != null) {
            enqueueRetry(retryDelay);
        }
    }

    /** Minutes to wait before the next attempt, or null when there is no next attempt. */
    @TestVisible
    private static Integer retryDelay(Integer attempt, Boolean retryable) {
        if (retryable != true || attempt == null || attempt >= MAX_ATTEMPTS) {
            return null;
        }
        return Math.min(1 << (attempt - 1), MAX_DELAY_MINUTES);
    }

    private void noteFailure(String reason, Boolean retryable) {
        if (failureRetryable == null) {
            failureReason = reason;
            failureRetryable = retryable == true;
        }
    }

    /** Records the retry decision on the plan and the Contact; returns the delay, or null. */
    private Integer applyRetryPolicy(Contact patch, DirectorySyncPlanner.Plan plan) {
        if (failureRetryable == null) {
            return null;
        }
        Integer delay = retryDelay(attempt, failureRetryable);
        String prefix;
        if (delay != null) {
            plan.steps.add('Retrying: attempt ' + (attempt + 1) + ' of ' + MAX_ATTEMPTS + ' scheduled in '
                + delay + (delay == 1 ? ' minute' : ' minutes') + ' (' + failureReason + ').');
            prefix = '[Retry ' + (attempt + 1) + ' of ' + MAX_ATTEMPTS + ' in ' + delay + ' min] ';
        } else if (failureRetryable) {
            plan.steps.add('Retryable failure (' + failureReason + '), but no attempts left (' + attempt + ' of ' + MAX_ATTEMPTS + ').');
            prefix = '[Gave up after ' + MAX_ATTEMPTS + ' attempts] ';
        } else {
            return null;
        }
        if (patch != null && String.isNotBlank(patch.Google_Last_Error__c)) {
            patch.Google_Last_Error__c = (prefix + patch.Google_Last_Error__c).left(255);
        }
        return delay;
    }

    private void enqueueRetry(Integer delayMinutes) {
        DirectorySyncJob next = new DirectorySyncJob(contactId, attempt + 1);
        next.injectedSettings = injectedSettings;
        next.injectedGroupMappings = injectedGroupMappings;
        // Apex tests cannot chain Queueables; the decision is asserted through the plan log and the Contact.
        if (Test.isRunningTest()) {
            return;
        }
        System.enqueueJob(next, delayMinutes);
    }

    private static Boolean needsGoogle(Directory_Status_Mapping__mdt mapping) {
        return mapping != null && String.isNotBlank(mapping.Target_State__c) && mapping.Target_State__c != 'None';
    }

    private static Map<String, Object> singleUser(DirectoryResult lookup) {
        if (lookup == null || !lookup.isSuccess() || GoogleDirectoryClient.userCount(lookup) != 1) {
            return null;
        }
        return GoogleDirectoryClient.firstUser(lookup);
    }

    /** Copies a mover result onto the Contact update and the plan log. */
    private static void record(Contact patch, DirectoryMover.Result r, DirectorySyncPlanner.Plan plan) {
        for (String note : r.notes) {
            plan.steps.add('Done: ' + note);
        }
        patch.Google_Last_Sync__c = System.now();
        if (r.success) {
            patch.Google_Last_Error__c = null;
        } else {
            plan.steps.add('Failed: ' + r.errorReason + (String.isBlank(r.errorMessage) ? '' : ' (' + r.errorMessage + ')'));
            patch.Google_Last_Error__c = (r.errorReason + (String.isBlank(r.errorMessage) ? '' : ': ' + r.errorMessage)).left(255);
        }
    }

    /**
     * If Google has exactly one account carrying this Contact's ID and the
     * Contact does not record it (a run that failed after the create), write
     * the account back to the Contact.
     */
    private static Contact linkExistingAccount(Contact c, DirectoryResult lookup, DirectorySyncPlanner.Plan plan) {
        Map<String, Object> user = singleUser(lookup);
        if (user == null) {
            return null;
        }
        String googleId = (String) user.get('id');
        if (googleId == null || googleId == c.Google_User_Id__c) {
            return null;
        }
        String email = (String) user.get('primaryEmail');
        plan.steps.add('Linked existing Google account ' + email + ' to this Contact.');
        return new Contact(
            Id = c.Id,
            Google_User_Id__c = googleId,
            Google_Primary_Email__c = email,
            Google_Account_Status__c = user.get('suspended') == true ? 'Suspended' : 'Active',
            Google_Last_Sync__c = System.now(),
            Google_Last_Error__c = null
        );
    }
}
