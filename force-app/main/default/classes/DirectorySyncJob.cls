/**
 * One job per Contact. Phase 1: plans only. It reads the Contact, resolves
 * the target state, looks the user up in Google by external ID, and logs
 * what it would do. It makes no writes to Google.
 *
 * Sharing: with sharing. The integration user sees only Contacts under an
 * Account flagged Directory_Sync_In_Scope__c, through the Directory Sync
 * Scope sharing rule. A Contact outside that scope is invisible here, and
 * the job logs it as not found instead of touching Google.
 *
 * Logs are inserted after the last callout (DML before a callout in the same
 * transaction blocks the callout). Unhandled failures are recorded by
 * DirectorySyncFinalizer.
 */
public with sharing class DirectorySyncJob implements Queueable, Database.AllowsCallouts {

    private final Id contactId;

    public DirectorySyncJob(Id contactId) {
        this.contactId = contactId;
    }

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DirectorySyncFinalizer(contactId));

        List<Contact> rows = [
            SELECT Id, Lifecycle_Status__c, Google_User_Id__c
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
        Directory_Status_Mapping__mdt mapping = DirectorySyncConfig.mappingFor(c.Lifecycle_Status__c);

        GoogleDirectoryClient client = GoogleDirectoryClient.fromSettings(contactId);
        DirectoryResult lookup = null;
        Boolean needsLookup = mapping != null
            && String.isNotBlank(mapping.Target_State__c)
            && mapping.Target_State__c != 'None';
        if (needsLookup) {
            lookup = client.findByExternalId(contactId);
        }

        DirectorySyncPlanner.Plan plan = DirectorySyncPlanner.plan(c.Lifecycle_Status__c, mapping, lookup);

        List<Directory_Sync_Log__c> logs = new List<Directory_Sync_Log__c>(client.getPendingLogs());
        logs.add(plan.toLog(contactId, c.Lifecycle_Status__c, mapping));
        insert logs;
    }
}
