/**
 * One job per Contact.
 *
 * Executes the joiner path (Phase 2) and the mover path for active accounts
 * (Phase 3): OU moves and managed group membership from Program and Term.
 * Suspend and reactivate (Phase 4) are still logged as plans only. With Dry
 * Run on, nothing is written to Google or the Contact; only the plan is logged.
 *
 * Sharing: with sharing. The integration user sees only Contacts under an
 * Account flagged Directory_Sync_In_Scope__c, through the Directory Sync
 * Scope sharing rule. A Contact outside that scope is invisible here, and
 * the job logs it as not found instead of touching Google.
 *
 * Order matters: every callout first, then the welcome email, then DML.
 * Unhandled failures are recorded by DirectorySyncFinalizer.
 */
public with sharing class DirectorySyncJob implements Queueable, Database.AllowsCallouts {

    private final Id contactId;

    /** Test hooks. Instance fields travel with the job when it is enqueued. */
    @TestVisible
    private Directory_Sync_Setting__mdt injectedSettings;
    @TestVisible
    private List<Directory_Group_Mapping__mdt> injectedGroupMappings;
    @TestVisible
    private Boolean forceEmailFailure = false;

    public DirectorySyncJob(Id contactId) {
        this.contactId = contactId;
    }

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DirectorySyncFinalizer(contactId));

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

                if (outcome.success && syncGroups) {
                    DirectoryMover.Result groups = new DirectoryMover.Result();
                    DirectoryMover.syncGroups(
                        outcome.googleUserId, desiredGroups, managedGroups, !outcome.adopted, client, groups
                    );
                    record(patch, groups, plan);
                }

                // All callouts are done. The email goes out before any DML.
                if (outcome.adopted) {
                    plan.steps.add('Name was taken by this Contact\'s own account; linked it instead of creating a second one. No welcome email.');
                } else if (outcome.success && sendWelcome) {
                    Messaging.SingleEmailMessage message = WelcomeEmail.build(
                        c.FirstName, outcome.primaryEmail, outcome.password, c.Email, settings.Org_Wide_Address_Id__c
                    );
                    String emailError = WelcomeEmail.send(message, forceEmailFailure);
                    extraLogs.add(WelcomeEmail.log(contactId, c.Email, outcome.primaryEmail, emailError));
                    if (emailError != null) {
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
            } else {
                patch = linkExistingAccount(c, lookup, plan);

                Map<String, Object> user = singleUser(lookup);
                Boolean activeAccount = user != null
                    && user.get('suspended') != true
                    && mapping != null
                    && mapping.Target_State__c == 'Active';
                if (activeAccount) {
                    String googleId = (String) user.get('id');
                    DirectoryMover.Result moved = new DirectoryMover.Result();
                    DirectoryMover.moveIfNeeded(googleId, (String) user.get('orgUnitPath'), mapping.Target_OU__c, client, moved);
                    if (moved.success && syncGroups) {
                        DirectoryMover.syncGroups(googleId, desiredGroups, managedGroups, false, client, moved);
                    }
                    if (patch == null) {
                        patch = new Contact(Id = contactId);
                    }
                    if (moved.success) {
                        patch.Google_Account_Status__c = 'Active';
                    }
                    record(patch, moved, plan);
                }
            }
        }

        List<Directory_Sync_Log__c> logs = new List<Directory_Sync_Log__c>(client.getPendingLogs());
        logs.add(plan.toLog(contactId, c.Lifecycle_Status__c, mapping, dryRun));
        logs.addAll(extraLogs);

        if (patch != null) {
            update patch;
        }
        insert logs;
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
