/**
 * Backs the Reprovision Google Account quick action on Contact.
 *
 * The person clicking does not hold Google callout access, so this never
 * calls Google. It checks what it can in Salesforce, then publishes a
 * Directory_Sync_Request__e with Kind__c = "Reprovision"; the subscriber runs
 * the reprovision job as the integration user.
 *
 * Guards:
 * - The Directory_Sync_Reprovision custom permission (via Directory Sync
 *   Admin). The button alone is not enough.
 * - The Contact must record a Google account, not be Suspended, and have a
 *   personal email. The job re-checks all of this against Google.
 * - Cooldown: one request per Contact every COOLDOWN_MINUTES, read from the
 *   Password Reset log rows. A double click costs one email, not two.
 *
 * Each accepted request writes a Password Reset log row naming who asked.
 */
public with sharing class DirectorySyncReprovision {

    public static final String KIND = 'Reprovision';
    public static final String PERMISSION = 'Directory_Sync_Reprovision';
    public static final Integer COOLDOWN_MINUTES = 10;

    public class Request {
        @InvocableVariable(label='Contact ID' required=true)
        public Id contactId;
    }

    public class Response {
        @InvocableVariable(label='Accepted')
        public Boolean accepted;
        @InvocableVariable(label='Message')
        public String message;

        Response(Boolean accepted, String message) {
            this.accepted = accepted;
            this.message = message;
        }
    }

    @InvocableMethod(
        label='Request Google Reprovision'
        description='Requests a new temporary password and reset email for the Contact\'s Google account.'
        category='Directory Sync'
    )
    public static List<Response> request(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            out.add(requestOne(r.contactId));
        }
        return out;
    }

    public static Response requestOne(Id contactId) {
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            return new Response(false, 'You need the Directory Sync Reprovision permission to do this.');
        }
        List<Contact> rows = [
            SELECT Id, Email, Google_User_Id__c, Google_Primary_Email__c, Google_Account_Status__c
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return new Response(false, 'Contact not found.');
        }
        Contact c = rows[0];
        if (String.isBlank(c.Google_User_Id__c)) {
            return new Response(false, 'This student has no Google account yet. Accounts are created from the Lifecycle Status.');
        }
        if (c.Google_Account_Status__c == 'Suspended') {
            return new Response(false, 'The Google account is suspended. Change the Lifecycle Status to reactivate it first.');
        }
        if (String.isBlank(c.Email)) {
            return new Response(false, 'This student has no personal email address to send the new password to.');
        }

        Datetime since = System.now().addMinutes(-COOLDOWN_MINUTES);
        Integer recent = [
            SELECT COUNT() FROM Directory_Sync_Log__c
            WHERE Contact__c = :contactId AND Operation__c = 'Password Reset' AND CreatedDate >= :since
        ];
        if (recent > 0) {
            return new Response(false, 'A reprovision was already requested in the last ' + COOLDOWN_MINUTES + ' minutes. Check the student\'s personal inbox, or try again later.');
        }

        Database.SaveResult published = EventBus.publish(new Directory_Sync_Request__e(Kind__c = KIND, Contact_Id__c = contactId));
        if (!published.isSuccess()) {
            String error = published.getErrors().isEmpty() ? 'unknown error' : published.getErrors()[0].getMessage();
            return new Response(false, 'The request could not be sent: ' + error);
        }
        insert new Directory_Sync_Log__c(
            Contact__c = contactId,
            Operation__c = 'Password Reset',
            Success__c = true,
            Request_Summary__c = 'Reprovision requested by ' + UserInfo.getName() + ' for ' + c.Google_Primary_Email__c,
            Response_Summary__c = 'Request sent; the new password goes to ' + c.Email + '.'
        );
        return new Response(true, 'Requested. A new temporary password for ' + c.Google_Primary_Email__c
            + ' will be emailed to ' + c.Email + ' within a minute or two.');
    }
}
