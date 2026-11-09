/**
 * Joiner path: creates the Google account for a Contact.
 *
 * - Username is first.last@domain from UsernameNormalizer.
 * - On a 409 conflict, checks whose account holds the name. If it carries this
 *   Contact's salesforce_id, it is this student's account (an earlier run that
 *   failed after the create, or a lookup that lagged a write), so it is adopted
 *   instead of creating a second account. Otherwise the next suffix is tried.
 * - The temporary password exists only in memory, in Outcome.password, until
 *   the caller has sent the welcome email. It is never stored or logged.
 *
 * Callouts only. No DML and no email here; the job does both after the last
 * callout.
 */
public inherited sharing class DirectoryJoiner {

    public static final Integer MAX_ATTEMPTS = 10;
    public static final Integer PASSWORD_LENGTH = 20;

    @TestVisible
    private static final String PASSWORD_CHARS =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%*+-=?';

    public class Outcome {
        public Boolean success = false;
        public Boolean adopted = false;
        public String googleUserId;
        public String primaryEmail;
        public String password;
        public String errorReason;
        public String errorMessage;

        /** The Contact update that records this outcome. */
        public Contact toContact(Id contactId) {
            Contact c = new Contact(Id = contactId, Google_Last_Sync__c = System.now());
            if (success) {
                c.Google_User_Id__c = googleUserId;
                c.Google_Primary_Email__c = primaryEmail;
                c.Google_Account_Status__c = 'Active';
                c.Google_Last_Error__c = null;
            } else {
                c.Google_Account_Status__c = 'Error';
                c.Google_Last_Error__c = (errorReason + (String.isBlank(errorMessage) ? '' : ': ' + errorMessage)).left(255);
            }
            return c;
        }
    }

    public static Outcome create(
        Contact c,
        Directory_Status_Mapping__mdt mapping,
        String domain,
        Boolean requirePersonalEmail,
        GoogleDirectoryClient client
    ) {
        Outcome o = new Outcome();
        if (requirePersonalEmail == true && String.isBlank(c.Email)) {
            return fail(o, 'noPersonalEmail', 'No personal email for the welcome message; account not created.');
        }

        String base = UsernameNormalizer.baseLocalPart(c.FirstName, c.LastName, c.Id);
        String password = generatePassword();

        for (Integer attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            String email = UsernameNormalizer.email(UsernameNormalizer.localPart(base, attempt), domain);
            DirectoryResult created = client.createUser(payload(c, mapping, email, password));

            if (created.isSuccess()) {
                String returned = created.getString('primaryEmail');
                o.success = true;
                o.googleUserId = created.getString('id');
                o.primaryEmail = String.isBlank(returned) ? email : returned;
                o.password = password;
                return o;
            }
            if (!created.isConflict()) {
                String reason = created.errorReason != null ? created.errorReason : 'http' + created.statusCode;
                return fail(o, reason, created.errorMessage);
            }

            DirectoryResult holder = client.getUser(email);
            if (holder.isSuccess() && belongsTo(holder.body, c.Id)) {
                o.success = true;
                o.adopted = true;
                o.googleUserId = holder.getString('id');
                o.primaryEmail = holder.getString('primaryEmail');
                return o;
            }
        }
        return fail(o, 'usernameExhausted', 'No free username after ' + MAX_ATTEMPTS + ' attempts starting at ' + base + '.');
    }

    @TestVisible
    private static Map<String, Object> payload(
        Contact c,
        Directory_Status_Mapping__mdt mapping,
        String email,
        String password
    ) {
        return new Map<String, Object>{
            'primaryEmail' => email,
            'name' => new Map<String, Object>{
                'givenName' => UsernameNormalizer.displayName(c.FirstName, c.LastName),
                'familyName' => UsernameNormalizer.displayName(c.LastName, c.FirstName)
            },
            'password' => password,
            'changePasswordAtNextLogin' => true,
            'orgUnitPath' => mapping.Target_OU__c,
            'externalIds' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'custom',
                    'customType' => 'salesforce_id',
                    'value' => String.valueOf(c.Id)
                }
            }
        };
    }

    /** True when the Google user carries this Contact's salesforce_id. */
    @TestVisible
    private static Boolean belongsTo(Map<String, Object> user, Id contactId) {
        Object ext = user == null ? null : user.get('externalIds');
        if (!(ext instanceof List<Object>) || contactId == null) {
            return false;
        }
        String wanted = String.valueOf(contactId);
        for (Object item : (List<Object>) ext) {
            if (item instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) item;
                if (m.get('customType') == 'salesforce_id' && m.get('value') == wanted) {
                    return true;
                }
            }
        }
        return false;
    }

    /** Random temporary password; also used by the reprovision path. */
    public static String generatePassword() {
        Integer n = PASSWORD_CHARS.length();
        String out = '';
        for (Integer i = 0; i < PASSWORD_LENGTH; i++) {
            Integer r = Math.mod(Crypto.getRandomInteger(), n);
            if (r < 0) {
                r += n;
            }
            out += PASSWORD_CHARS.substring(r, r + 1);
        }
        return out;
    }

    private static Outcome fail(Outcome o, String reason, String message) {
        o.success = false;
        o.errorReason = reason;
        o.errorMessage = message;
        return o;
    }
}
