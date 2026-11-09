/**
 * Records a log row when a DirectorySyncJob dies with an unhandled exception.
 * The job's own pending logs roll back with it, so this row is the only trace.
 *
 * If the row cannot be linked to the Contact (deleted, or not visible to the
 * running user), it is written without the link and the Contact ID is kept
 * in the summary, so a failure is never silently lost.
 *
 * Unhandled exceptions are not retried. Transient Google errors are handled
 * inside the job and retried there; an exception that escapes the job is a
 * bug or a governor limit, and running it again would fail the same way.
 */
public with sharing class DirectorySyncFinalizer implements Finalizer {

    private final Id contactId;
    private final Integer attempt;

    public DirectorySyncFinalizer(Id contactId) {
        this(contactId, null);
    }

    public DirectorySyncFinalizer(Id contactId, Integer attempt) {
        this.contactId = contactId;
        this.attempt = attempt;
    }

    public void execute(FinalizerContext ctx) {
        record(contactId, attempt, ctx.getResult(), ctx.getException());
    }

    @TestVisible
    private static void record(Id contactId, ParentJobResult result, Exception e) {
        record(contactId, null, result, e);
    }

    /** Separated from execute() so tests can drive it without a FinalizerContext. */
    @TestVisible
    private static void record(Id contactId, Integer attempt, ParentJobResult result, Exception e) {
        if (result != ParentJobResult.UNHANDLED_EXCEPTION) {
            return;
        }
        String detail = e == null ? 'Unknown failure' : e.getTypeName() + ': ' + e.getMessage();
        Directory_Sync_Log__c log = new Directory_Sync_Log__c(
            Contact__c = contactId,
            Operation__c = 'Job Failure',
            Success__c = false,
            Error_Reason__c = 'unhandledException',
            Attempt__c = attempt,
            Request_Summary__c = 'DirectorySyncJob for ' + contactId,
            Response_Summary__c = detail.left(32000)
        );
        try {
            insert log;
        } catch (DmlException linkFailure) {
            log.Contact__c = null;
            log.Response_Summary__c = (detail + '\nLog written without Contact link: '
                + linkFailure.getDmlType(0) + ': ' + linkFailure.getDmlMessage(0)).left(32000);
            insert log;
        }
    }
}
