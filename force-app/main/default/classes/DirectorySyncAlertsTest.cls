@IsTest
private class DirectorySyncAlertsTest {

    private static Directory_Sync_Setting__mdt settings(String recipient, Integer cap) {
        return new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default',
            Enabled__c = true,
            Dry_Run__c = false,
            Send_Welcome_Email__c = false,
            Provisioning_Delay_Minutes__c = 0,
            Domain__c = 'shuraku.org',
            Alert_Email__c = recipient,
            Max_Alert_Emails_Per_Day__c = cap
        );
    }

    private static Contact student() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane.personal@example.com', Lifecycle_Status__c = 'Enrolled');
        insert c;
        return c;
    }

    private static List<Directory_Sync_Log__c> pending(Id contactId, Integer n) {
        List<Directory_Sync_Log__c> rows = new List<Directory_Sync_Log__c>();
        for (Integer i = 0; i < n; i++) {
            rows.add(new Directory_Sync_Log__c(
                Contact__c = contactId, Operation__c = 'Plan', Success__c = false,
                Error_Reason__c = 'forbidden', Attempt__c = 1, Alert_Status__c = 'Pending',
                Response_Summary__c = 'CREATE\n- Failed: forbidden (Not Authorized)'
            ));
        }
        insert rows;
        return rows;
    }

    private static Integer countStatus(String status) {
        return [SELECT COUNT() FROM Directory_Sync_Log__c WHERE Alert_Status__c = :status];
    }

    private static List<Directory_Sync_Log__c> alertLogs() {
        return [SELECT Success__c, Error_Reason__c, Request_Summary__c, Response_Summary__c FROM Directory_Sync_Log__c WHERE Operation__c = 'Alert'];
    }

    // ---------------------------------------------------------------
    // Digest
    // ---------------------------------------------------------------

    @IsTest
    static void sendsOneDigestAndMarksRowsSent() {
        pending(student().Id, 2);

        String outcome = DirectorySyncAlerts.run(settings('admin@shuraku.org', 3));

        Assert.areEqual('sent', outcome);
        Assert.areEqual(1, Limits.getEmailInvocations(), 'One email for the whole batch');
        Assert.areEqual(0, countStatus('Pending'));
        Assert.areEqual(2, countStatus('Sent'));
        List<Directory_Sync_Log__c> alerts = alertLogs();
        Assert.areEqual(1, alerts.size());
        Assert.isTrue(alerts[0].Success__c);
        Assert.isTrue(alerts[0].Request_Summary__c.contains('2 of 2'), alerts[0].Request_Summary__c);
    }

    @IsTest
    static void nothingPendingSendsNothing() {
        Assert.areEqual('nothingPending', DirectorySyncAlerts.run(settings('admin@shuraku.org', 3)));
        Assert.areEqual(0, Limits.getEmailInvocations());
        Assert.isTrue(alertLogs().isEmpty());
    }

    @IsTest
    static void blankRecipientTurnsAlertsOff() {
        pending(student().Id, 1);
        Assert.areEqual('noRecipient', DirectorySyncAlerts.run(settings(null, 3)));
        Assert.areEqual(1, countStatus('Pending'));
    }

    @IsTest
    static void capHoldsRowsForLater() {
        pending(student().Id, 1);
        insert new List<Directory_Sync_Log__c>{
            new Directory_Sync_Log__c(Operation__c = 'Alert', Success__c = true),
            new Directory_Sync_Log__c(Operation__c = 'Alert', Success__c = true)
        };

        Assert.areEqual('capReached', DirectorySyncAlerts.run(settings('admin@shuraku.org', 2)));
        Assert.areEqual(0, Limits.getEmailInvocations());
        Assert.areEqual(1, countStatus('Pending'), 'Row waits for a later digest');
    }

    @IsTest
    static void blankCapMeansThree() {
        pending(student().Id, 1);
        insert new List<Directory_Sync_Log__c>{
            new Directory_Sync_Log__c(Operation__c = 'Alert', Success__c = true),
            new Directory_Sync_Log__c(Operation__c = 'Alert', Success__c = true),
            new Directory_Sync_Log__c(Operation__c = 'Alert', Success__c = true)
        };
        Assert.areEqual('capReached', DirectorySyncAlerts.run(settings('admin@shuraku.org', null)));
    }

    @IsTest
    static void failedSendKeepsRowsPendingAndDoesNotCountTowardCap() {
        pending(student().Id, 1);
        DirectorySyncAlerts.forceSendFailure = true;

        Assert.areEqual('failed', DirectorySyncAlerts.run(settings('admin@shuraku.org', 1)));
        Assert.areEqual(1, countStatus('Pending'));
        Directory_Sync_Log__c failed = alertLogs()[0];
        Assert.isFalse(failed.Success__c);
        Assert.areEqual('emailFailed', failed.Error_Reason__c);

        DirectorySyncAlerts.forceSendFailure = false;
        Assert.areEqual('sent', DirectorySyncAlerts.run(settings('admin@shuraku.org', 1)), 'A failed digest does not use up the cap');
    }

    @IsTest
    static void bodyListsRowsLinksAndOverflow() {
        Contact c = student();
        pending(c.Id, 2);
        List<Directory_Sync_Log__c> rows = [
            SELECT Id, Name, Contact__c, Contact__r.Name, Operation__c, Error_Reason__c, Attempt__c, Response_Summary__c, CreatedDate
            FROM Directory_Sync_Log__c ORDER BY Name
        ];

        Messaging.SingleEmailMessage m = DirectorySyncAlerts.build('admin@shuraku.org', null, rows, 5, 1, 3);
        String body = m.getPlainTextBody();

        Assert.areEqual('Directory sync: 5 failures need attention', m.getSubject());
        Assert.isTrue(body.contains(rows[0].Name + ' | '), body);
        Assert.isTrue(body.contains('Jane Doe | Plan | forbidden | attempt 1'), body);
        Assert.isTrue(body.contains('CREATE / - Failed: forbidden'), 'Summary flattened to one line: ' + body);
        Assert.isTrue(body.contains('/' + String.valueOf(c.Id)), 'Links to the Contact');
        Assert.isTrue(body.contains('...and 3 more'), body);
        Assert.isTrue(body.contains('Digest 1 of 3'), body);
    }

    @IsTest
    static void scheduledEntryPointRuns() {
        Test.startTest();
        System.schedule('Directory Sync Alerts test', '0 7 * * * ?', new DirectorySyncAlerts());
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Directory Sync Alerts test']);
    }

    // ---------------------------------------------------------------
    // What gets marked Pending
    // ---------------------------------------------------------------

    private static void runJob(Id contactId, Integer attempt) {
        DirectorySyncJob job = new DirectorySyncJob(contactId, attempt);
        job.injectedSettings = settings('admin@shuraku.org', 3);
        job.injectedGroupMappings = new List<Directory_Group_Mapping__mdt>();
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    private static Directory_Sync_Log__c planRow(Id contactId) {
        return [SELECT Success__c, Error_Reason__c, Alert_Status__c FROM Directory_Sync_Log__c WHERE Contact__c = :contactId AND Operation__c = 'Plan'];
    }

    @IsTest
    static void finalFailureIsPending() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, '{"users":[]}')
            .route('POST', '/users', 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api')));

        runJob(c.Id, 1);

        Directory_Sync_Log__c plan = planRow(c.Id);
        Assert.areEqual('Pending', plan.Alert_Status__c);
        Assert.isFalse(plan.Success__c, 'A failed run is not a successful plan');
        Assert.areEqual('forbidden', plan.Error_Reason__c);
    }

    @IsTest
    static void retryInFlightDoesNotAlert() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 429, DirectoryMock.error(429, 'rateLimitExceeded', 'Rate Limit Exceeded')));

        runJob(c.Id, 1);

        Directory_Sync_Log__c plan = planRow(c.Id);
        Assert.isNull(plan.Alert_Status__c);
        Assert.isFalse(plan.Success__c);
    }

    @IsTest
    static void givingUpIsPending() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 429, DirectoryMock.error(429, 'rateLimitExceeded', 'Rate Limit Exceeded')));

        runJob(c.Id, DirectorySyncJob.MAX_ATTEMPTS);

        Assert.areEqual('Pending', planRow(c.Id).Alert_Status__c);
    }

    @IsTest
    static void successDoesNotAlert() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, '{"users":[]}')
            .route('POST', '/users', 200, '{"id":"g-1","primaryEmail":"jane.doe@shuraku.org"}'));

        runJob(c.Id, 1);

        Directory_Sync_Log__c plan = planRow(c.Id);
        Assert.isNull(plan.Alert_Status__c);
        Assert.isTrue(plan.Success__c);
    }

    @IsTest
    static void jobFailureIsPending() {
        Contact c = student();
        DirectorySyncFinalizer.record(c.Id, 1, ParentJobResult.UNHANDLED_EXCEPTION, new BoomException('boom'));
        Assert.areEqual('Pending', [SELECT Alert_Status__c FROM Directory_Sync_Log__c WHERE Contact__c = :c.Id AND Operation__c = 'Job Failure'].Alert_Status__c);
    }

    private class BoomException extends Exception {}
}
