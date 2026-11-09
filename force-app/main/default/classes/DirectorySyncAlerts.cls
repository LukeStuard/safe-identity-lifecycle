/**
 * Hourly failure digest for the directory sync.
 *
 * Collects log rows with Alert_Status__c = Pending (final failures, failed
 * welcome emails, and unhandled job failures) and sends one plain-text email
 * listing them to Directory_Sync_Setting__mdt.Alert_Email__c, from the
 * org-wide address. Reported rows become Sent, so nothing is reported twice.
 *
 * Email budget: Developer Edition allows 15 single emails a day, shared with
 * welcome emails. A burst of failures costs one email, not one per failure,
 * and at most Max_Alert_Emails_Per_Day__c digests go out in any rolling 24
 * hours (default 3). Past the cap, rows stay Pending for a later digest.
 * Each digest writes an Alert log row; successful ones count toward the cap.
 *
 * Runs as the user who scheduled it. Schedule once:
 *   System.schedule('Directory Sync Alerts', '0 7 * * * ?', new DirectorySyncAlerts());
 */
public with sharing class DirectorySyncAlerts implements Schedulable {

    public static final Integer DEFAULT_DAILY_CAP = 3;
    public static final Integer MAX_ROWS_IN_BODY = 50;
    private static final String TIME_ZONE = 'America/Los_Angeles';

    @TestVisible
    private static Boolean forceSendFailure = false;

    public void execute(SchedulableContext ctx) {
        run(DirectorySyncConfig.settings());
    }

    /** Sends at most one digest. Returns what happened, for tests and anonymous runs. */
    public static String run(Directory_Sync_Setting__mdt settings) {
        String recipient = settings == null ? null : settings.Alert_Email__c;
        if (String.isBlank(recipient)) {
            return 'noRecipient';
        }
        Integer cap = settings.Max_Alert_Emails_Per_Day__c == null
            ? DEFAULT_DAILY_CAP
            : settings.Max_Alert_Emails_Per_Day__c.intValue();
        Datetime since = System.now().addHours(-24);
        Integer sentRecently = [
            SELECT COUNT() FROM Directory_Sync_Log__c
            WHERE Operation__c = 'Alert' AND Success__c = true AND CreatedDate >= :since
        ];
        if (sentRecently >= cap) {
            return 'capReached';
        }

        List<Directory_Sync_Log__c> pending = [
            SELECT Id, Name, Contact__c, Contact__r.Name, Operation__c, Error_Reason__c,
                   Attempt__c, Response_Summary__c, CreatedDate
            FROM Directory_Sync_Log__c
            WHERE Alert_Status__c = 'Pending'
            ORDER BY Name
            LIMIT :MAX_ROWS_IN_BODY
        ];
        if (pending.isEmpty()) {
            return 'nothingPending';
        }
        Integer total = [SELECT COUNT() FROM Directory_Sync_Log__c WHERE Alert_Status__c = 'Pending'];

        Messaging.SingleEmailMessage message = build(
            recipient, settings.Org_Wide_Address_Id__c, pending, total, sentRecently + 1, cap
        );
        String error = send(message);

        List<String> names = new List<String>();
        for (Directory_Sync_Log__c row : pending) {
            names.add(row.Name);
        }
        Directory_Sync_Log__c alertLog = new Directory_Sync_Log__c(
            Operation__c = 'Alert',
            Success__c = error == null,
            Error_Reason__c = error == null ? null : 'emailFailed',
            Request_Summary__c = 'Digest to ' + recipient + ': ' + pending.size() + ' of ' + total + ' pending rows.',
            Response_Summary__c = (error == null ? 'Reported: ' + String.join(names, ', ') : error).left(32000)
        );

        if (error == null) {
            for (Directory_Sync_Log__c row : pending) {
                row.Alert_Status__c = 'Sent';
            }
            update pending;
        }
        insert alertLog;
        return error == null ? 'sent' : 'failed';
    }

    @TestVisible
    private static Messaging.SingleEmailMessage build(
        String recipient,
        String orgWideAddressId,
        List<Directory_Sync_Log__c> rows,
        Integer total,
        Integer digestNumber,
        Integer cap
    ) {
        String base = URL.getOrgDomainUrl().toExternalForm() + '/';
        List<String> lines = new List<String>{
            total + (total == 1 ? ' directory sync failure needs' : ' directory sync failures need') + ' attention.',
            'Digest ' + digestNumber + ' of ' + cap + ' allowed in 24 hours.',
            ''
        };
        for (Directory_Sync_Log__c row : rows) {
            String who = row.Contact__r != null && String.isNotBlank(row.Contact__r.Name) ? row.Contact__r.Name : 'No linked Contact';
            String stamp = row.CreatedDate == null ? '' : row.CreatedDate.format('yyyy-MM-dd HH:mm', TIME_ZONE);
            String attempt = row.Attempt__c == null ? '' : ' | attempt ' + row.Attempt__c.intValue();
            lines.add('- ' + row.Name + ' | ' + stamp + ' | ' + who + ' | ' + row.Operation__c + ' | '
                + (String.isBlank(row.Error_Reason__c) ? 'no reason recorded' : row.Error_Reason__c) + attempt);
            if (String.isNotBlank(row.Response_Summary__c)) {
                lines.add('  ' + row.Response_Summary__c.replaceAll('\\s*\\n\\s*', ' / ').left(300));
            }
            lines.add('  ' + base + (row.Contact__c != null ? String.valueOf(row.Contact__c) : String.valueOf(row.Id)));
        }
        if (total > rows.size()) {
            lines.add('');
            lines.add('...and ' + (total - rows.size()) + ' more, which stay pending for the next digest.');
        }
        lines.add('');
        lines.add('Each line is a Directory Sync Log record. Open the Contact for the full run.');

        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setToAddresses(new List<String>{ recipient });
        if (String.isNotBlank(orgWideAddressId)) {
            m.setOrgWideEmailAddressId(orgWideAddressId);
        }
        m.setSubject('Directory sync: ' + total + (total == 1 ? ' failure needs' : ' failures need') + ' attention');
        m.setPlainTextBody(String.join(lines, '\n'));
        m.setSaveAsActivity(false);
        return m;
    }

    /** Returns null on success, otherwise the reason the email did not go out. */
    private static String send(Messaging.SingleEmailMessage message) {
        if (forceSendFailure) {
            return 'Forced failure (test).';
        }
        try {
            Messaging.reserveSingleEmailCapacity(1);
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(
                new List<Messaging.SingleEmailMessage>{ message }, false
            );
            if (results[0].isSuccess()) {
                return null;
            }
            return results[0].getErrors()[0].getMessage();
        } catch (Exception e) {
            return e.getTypeName() + ': ' + e.getMessage();
        }
    }
}
