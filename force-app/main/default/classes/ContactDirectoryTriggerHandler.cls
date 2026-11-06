/**
 * Publishes one Directory_Sync_Request__e per Contact whose sync-relevant
 * fields changed. No callouts, no queries, no enqueued jobs here, so a
 * bulk Contact update can never fail because of the integration.
 * Events publish after commit, so a rolled-back save publishes nothing.
 */
public inherited sharing class ContactDirectoryTriggerHandler {

    @TestVisible
    private static final List<SObjectField> TRACKED_FIELDS = new List<SObjectField>{
        Contact.Lifecycle_Status__c,
        Contact.Program__c,
        Contact.Term__c,
        Contact.FirstName,
        Contact.LastName
    };

    public static void afterUpdate(List<Contact> newList, Map<Id, Contact> oldMap) {
        if (!DirectorySyncConfig.isEnabled()) {
            return;
        }
        List<Directory_Sync_Request__e> events = new List<Directory_Sync_Request__e>();
        for (Contact c : newList) {
            if (String.isBlank(c.Lifecycle_Status__c)) {
                continue;
            }
            if (hasTrackedChange(c, oldMap.get(c.Id))) {
                events.add(new Directory_Sync_Request__e(Contact_Id__c = c.Id));
            }
        }
        if (events.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = EventBus.publish(events);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'Directory sync event not published for '
                    + events[i].Contact_Id__c + ': ' + results[i].getErrors());
            }
        }
    }

    @TestVisible
    private static Boolean hasTrackedChange(Contact current, Contact previous) {
        if (previous == null) {
            return true;
        }
        for (SObjectField f : TRACKED_FIELDS) {
            if (current.get(f) != previous.get(f)) {
                return true;
            }
        }
        return false;
    }
}
