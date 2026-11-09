/**
 * Backs the Rename Google Username quick action on Contact.
 *
 * Display names follow the Contact automatically (the sync job updates them
 * on every name change). The username is different: renaming it changes how
 * the student signs in, so it only happens when a person asks, through this
 * action.
 *
 * mode "preview" shows the current and proposed username without changing
 * anything. mode "request" re-checks, applies the cooldown, and publishes a
 * Directory_Sync_Request__e with Kind__c = "Rename"; the subscriber runs the
 * rename as the integration user. The person clicking never calls Google.
 *
 * Guards: the Directory_Sync_Rename custom permission; the Contact must
 * record an active Google account and a personal email (the new username is
 * emailed there); one request per Contact every COOLDOWN_MINUTES.
 */
public with sharing class DirectorySyncRename {

    public static final String KIND = 'Rename';
    public static final String PERMISSION = 'Directory_Sync_Rename';
    public static final Integer COOLDOWN_MINUTES = 10;

    public class Request {
        @InvocableVariable(label='Contact ID' required=true)
        public Id contactId;
        @InvocableVariable(label='Mode (preview or request)' required=true)
        public String mode;
    }

    public class Response {
        @InvocableVariable(label='Accepted')
        public Boolean accepted;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='Current Username')
        public String currentUsername;
        @InvocableVariable(label='Proposed Username')
        public String proposedUsername;
    }

    @InvocableMethod(
        label='Google Username Rename'
        description='Previews or requests a rename of the Contact\'s Google username to match their current name.'
        category='Directory Sync'
    )
    public static List<Response> run(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            out.add(r.mode == 'request' ? request(r.contactId) : preview(r.contactId));
        }
        return out;
    }

    public static Response preview(Id contactId) {
        Response r = check(contactId);
        if (r.accepted) {
            r.message = 'Current username: ' + r.currentUsername + '. New username: ' + r.proposedUsername
                + ' (with a number added if that name is taken).';
        }
        return r;
    }

    public static Response request(Id contactId) {
        Response r = check(contactId);
        if (!r.accepted) {
            return r;
        }
        Datetime since = System.now().addMinutes(-COOLDOWN_MINUTES);
        Integer recent = [
            SELECT COUNT() FROM Directory_Sync_Log__c
            WHERE Contact__c = :contactId AND Operation__c = 'Rename' AND CreatedDate >= :since
        ];
        if (recent > 0) {
            return refuse(r, 'A rename was already requested in the last ' + COOLDOWN_MINUTES + ' minutes. Check the Contact\'s sync logs, or try again later.');
        }
        Database.SaveResult published = EventBus.publish(new Directory_Sync_Request__e(Kind__c = KIND, Contact_Id__c = contactId));
        if (!published.isSuccess()) {
            String error = published.getErrors().isEmpty() ? 'unknown error' : published.getErrors()[0].getMessage();
            return refuse(r, 'The request could not be sent: ' + error);
        }
        insert new Directory_Sync_Log__c(
            Contact__c = contactId,
            Operation__c = 'Rename',
            Success__c = true,
            Request_Summary__c = 'Rename requested by ' + UserInfo.getName() + ': ' + r.currentUsername + ' to ' + r.proposedUsername,
            Response_Summary__c = 'Request sent.'
        );
        r.message = 'Requested. ' + r.currentUsername + ' will be renamed to ' + r.proposedUsername
            + ' (or the next free variant) within a minute or two, and the student will be emailed.';
        return r;
    }

    /** Everything that can be checked in Salesforce. The job re-checks against Google. */
    private static Response check(Id contactId) {
        Response r = new Response();
        r.accepted = false;
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            return refuse(r, 'You need the Directory Sync Rename permission to do this.');
        }
        List<Contact> rows = [
            SELECT Id, FirstName, LastName, Email, Google_User_Id__c, Google_Primary_Email__c, Google_Account_Status__c
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return refuse(r, 'Contact not found.');
        }
        Contact c = rows[0];
        if (String.isBlank(c.Google_User_Id__c) || String.isBlank(c.Google_Primary_Email__c)) {
            return refuse(r, 'This student has no Google account yet. Accounts are created from the Lifecycle Status.');
        }
        if (c.Google_Account_Status__c == 'Suspended') {
            return refuse(r, 'The Google account is suspended. Change the Lifecycle Status to reactivate it first.');
        }
        if (String.isBlank(c.Email)) {
            return refuse(r, 'This student has no personal email address to send the new username to.');
        }
        String domain = DirectorySyncConfig.settings().Domain__c;
        String base = UsernameNormalizer.baseLocalPart(c.FirstName, c.LastName, c.Id);
        r.currentUsername = c.Google_Primary_Email__c;
        r.proposedUsername = UsernameNormalizer.email(base, domain);
        if (matchesBase(c.Google_Primary_Email__c, base)) {
            return refuse(r, 'The username ' + r.currentUsername + ' already matches the name on this Contact. Nothing to rename.');
        }
        r.accepted = true;
        return r;
    }

    /** True when the address is the base or the base plus a collision suffix (jane.doe, jane.doe2). */
    public static Boolean matchesBase(String email, String base) {
        if (String.isBlank(email) || String.isBlank(base)) {
            return false;
        }
        String local = email.substringBefore('@').toLowerCase();
        if (local == base) {
            return true;
        }
        return local.startsWith(base) && local.removeStart(base).isNumeric();
    }

    private static Response refuse(Response r, String message) {
        r.accepted = false;
        r.message = message;
        return r;
    }
}
