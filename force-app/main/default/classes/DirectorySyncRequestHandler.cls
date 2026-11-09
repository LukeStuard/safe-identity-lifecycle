/**
 * Platform event subscriber. Runs as the dedicated integration user
 * (PlatformEventSubscriberConfig). Enqueues one DirectorySyncJob per
 * distinct Contact in the batch. The subscriber batch size is 50, which
 * matches the per-transaction limit on enqueued jobs.
 *
 * An event with Kind__c = "Sweep" starts DirectorySyncSweep instead. The
 * schedule publishes that event, so the sweep's callouts run as the
 * integration user rather than as whoever scheduled it.
 *
 * An event with Kind__c = "Reprovision" starts a password reprovision job
 * for its Contact (see DirectorySyncReprovision).
 */
public inherited sharing class DirectorySyncRequestHandler {

    public static void handle(List<Directory_Sync_Request__e> events) {
        if (!DirectorySyncConfig.isEnabled()) {
            return;
        }
        Set<Id> contactIds = new Set<Id>();
        Set<Id> reprovisionIds = new Set<Id>();
        Boolean sweep = false;
        for (Directory_Sync_Request__e e : events) {
            if (e.Kind__c == DirectorySyncSweep.KIND) {
                sweep = true;
                continue;
            }
            if (e.Kind__c == DirectorySyncReprovision.KIND) {
                Id rid = toContactId(e.Contact_Id__c);
                if (rid != null) {
                    reprovisionIds.add(rid);
                }
                continue;
            }
            Id cid = toContactId(e.Contact_Id__c);
            if (cid != null) {
                contactIds.add(cid);
            }
        }
        for (Id cid : contactIds) {
            System.enqueueJob(new DirectorySyncJob(cid));
        }
        for (Id rid : reprovisionIds) {
            System.enqueueJob(DirectorySyncJob.forReprovision(rid));
        }
        if (sweep) {
            System.enqueueJob(new DirectorySyncSweep());
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
