/**
 * The welcome message with the student's username and temporary password.
 * Sent from the org-wide address (DKIM-signed for the domain) to the
 * student's personal email. Not saved as an activity, so the integration
 * user never needs Task access. The password appears only in the message
 * body, never in a log.
 */
public inherited sharing class WelcomeEmail {

    public static final String SUBJECT = 'Your Shuraku University Student Account';
    public static final String RESET_SUBJECT = 'Your Shuraku University Student Account: New Temporary Password';
    public static final String RENAME_SUBJECT = 'Your Shuraku University Student Account: New Username';
    public static final String SIGN_IN_URL = 'https://accounts.google.com';

    public static Messaging.SingleEmailMessage build(
        String firstName,
        String username,
        String password,
        String toAddress,
        String orgWideAddressId
    ) {
        return message(SUBJECT, body(firstName, username, password, false), toAddress, orgWideAddressId);
    }

    /** Sent by the reprovision action: same details, worded as a reset. */
    public static Messaging.SingleEmailMessage buildReset(
        String firstName,
        String username,
        String password,
        String toAddress,
        String orgWideAddressId
    ) {
        return message(RESET_SUBJECT, body(firstName, username, password, true), toAddress, orgWideAddressId);
    }

    /** Sent by the rename action. No password: it does not change. */
    public static Messaging.SingleEmailMessage buildRename(
        String firstName,
        String newUsername,
        String oldUsername,
        String toAddress,
        String orgWideAddressId
    ) {
        String greeting = String.isBlank(firstName) ? 'Hi,' : 'Hi ' + firstName.trim() + ',';
        String text = String.join(new List<String>{
            greeting,
            '',
            'Your student account username has changed to match your name.',
            '',
            'New username: ' + newUsername,
            'Previous username: ' + oldUsername,
            'Sign in at: ' + SIGN_IN_URL,
            '',
            'Your password has not changed. Use the new username the next time you sign in; the previous one no longer works for sign-in. The change can take up to 10 minutes to reach every Google service.',
            '',
            'If you didn\'t expect this message, please contact the school.'
        }, '\n');
        return message(RENAME_SUBJECT, text, toAddress, orgWideAddressId);
    }

    private static Messaging.SingleEmailMessage message(String subject, String text, String toAddress, String orgWideAddressId) {
        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        if (String.isNotBlank(orgWideAddressId)) {
            m.setOrgWideEmailAddressId(orgWideAddressId);
        }
        m.setToAddresses(new List<String>{ toAddress });
        m.setSubject(subject);
        m.setPlainTextBody(text);
        m.setSaveAsActivity(false);
        m.setUseSignature(false);
        m.setBccSender(false);
        return m;
    }

    @TestVisible
    private static String body(String firstName, String username, String password) {
        return body(firstName, username, password, false);
    }

    private static String body(String firstName, String username, String password, Boolean reset) {
        String greeting = String.isBlank(firstName) ? 'Hi,' : 'Hi ' + firstName.trim() + ',';
        return String.join(new List<String>{
            greeting,
            '',
            reset
                ? 'A new temporary password has been set for your student account. Your previous password no longer works.'
                : 'Your student account is ready.',
            '',
            'Username: ' + username,
            'Temporary password: ' + password,
            'Sign in at: ' + SIGN_IN_URL,
            '',
            'You\'ll be asked to choose a new password the first time you sign in. This temporary password works only until then.',
            '',
            'If you didn\'t expect this message, you can ignore it.'
        }, '\n');
    }

    /**
     * Sends one message. Returns null on success, or the error text.
     * forceFailure lets tests exercise the failure path without a real bounce.
     */
    public static String send(Messaging.SingleEmailMessage m, Boolean forceFailure) {
        if (forceFailure == true) {
            return 'Simulated send failure.';
        }
        try {
            List<Messaging.SendEmailResult> results =
                Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ m }, false);
            if (results[0].isSuccess()) {
                return null;
            }
            List<Messaging.SendEmailError> errors = results[0].getErrors();
            return errors.isEmpty() ? 'Unknown send failure.' : String.valueOf(errors[0].getStatusCode()) + ': ' + errors[0].getMessage();
        } catch (EmailException e) {
            return e.getMessage();
        }
    }

    /** Audit row for the send. Never includes the password. */
    public static Directory_Sync_Log__c log(Id contactId, String toAddress, String username, String error) {
        return new Directory_Sync_Log__c(
            Contact__c = contactId,
            Operation__c = 'Welcome Email',
            Success__c = error == null,
            Error_Reason__c = error == null ? null : 'emailFailed',
            Request_Summary__c = 'To ' + toAddress + ' for ' + username,
            Response_Summary__c = error == null ? 'Sent' : error.left(32000)
        );
    }
}
