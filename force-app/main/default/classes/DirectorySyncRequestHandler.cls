/**
 * Platform event subscriber. Runs as the dedicated integration user
 * (PlatformEventSubscriberConfig). Enqueues one DirectorySyncJob per
 * distinct Contact in the batch. The subscriber batch size is 50, which
 * matches the per-transaction limit on enqueued jobs.
 */
public inherited sharing class DirectorySyncRequestHandler {

    public static void handle(List<Directory_Sync_Request__e> events) {
        if (!DirectorySyncConfig.isEnabled()) {
            return;
        }
        Set<Id> contactIds = new Set<Id>();
        for (Directory_Sync_Request__e e : events) {
            Id cid = toContactId(e.Contact_Id__c);
            if (cid != null) {
                contactIds.add(cid);
            }
        }
        for (Id cid : contactIds) {
            System.enqueueJob(new DirectorySyncJob(cid));
        }
    }

    /** Returns the value as a Contact Id, or null if it is not one. */
    @TestVisible
    private static Id toContactId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            Id candidate = Id.valueOf(raw);
            return candidate.getSobjectType() == Contact.SObjectType ? candidate : null;
        } catch (StringException e) {
            return null;
        }
    }
}
