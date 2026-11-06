@IsTest
private class DirectorySyncFlowTest {

    private static void setEnabled(Boolean enabled) {
        DirectorySyncConfig.settingsOverride = new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default',
            Enabled__c = enabled,
            Dry_Run__c = true,
            Send_Welcome_Email__c = false,
            Provisioning_Delay_Minutes__c = 0,
            Domain__c = 'shuraku.org'
        );
    }

    private static List<Contact> newContacts(Integer count) {
        List<Contact> rows = new List<Contact>();
        for (Integer i = 0; i < count; i++) {
            rows.add(new Contact(FirstName = 'Demo', LastName = 'Student' + i, Email = 'demo.student' + i + '@example.com'));
        }
        insert rows;
        return rows;
    }

    private static void mockNoGoogleUsers() {
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, '{"users":[]}'));
    }

    private static List<Directory_Sync_Log__c> logs(String operation) {
        return [
            SELECT Contact__c, Operation__c, Success__c, Dry_Run__c, Http_Status__c, Error_Reason__c,
                   Request_Summary__c, Response_Summary__c
            FROM Directory_Sync_Log__c
            WHERE Operation__c = :operation
        ];
    }

    @IsTest
    static void statusChangeRunsWholeChainAndWritesLogs() {
        Contact c = newContacts(1)[0];
        setEnabled(true);
        mockNoGoogleUsers();

        Test.startTest();
        c.Lifecycle_Status__c = 'Admitted';
        update c;
        Test.getEventBus().deliver();
        Test.stopTest();

        // Inserted log rows keep every field (not just the in-memory records).
        List<Directory_Sync_Log__c> lookups = logs('Lookup');
        Assert.areEqual(1, lookups.size());
        Assert.areEqual(c.Id, lookups[0].Contact__c);
        Assert.areEqual(200, lookups[0].Http_Status__c);
        Assert.isTrue(lookups[0].Success__c);
        Assert.isTrue(lookups[0].Request_Summary__c.startsWith('GET /users?'));

        List<Directory_Sync_Log__c> plans = logs('Plan');
        Assert.areEqual(1, plans.size());
        Assert.areEqual(c.Id, plans[0].Contact__c);
        Assert.isTrue(plans[0].Dry_Run__c);
        Assert.isTrue(plans[0].Response_Summary__c.startsWith('CREATE'));
    }

    @IsTest
    static void untrackedChangePublishesNothing() {
        Contact c = newContacts(1)[0];
        setEnabled(false);
        c.Lifecycle_Status__c = 'Admitted';
        update c;
        setEnabled(true);
        mockNoGoogleUsers();

        Test.startTest();
        c.Email = 'changed@example.com';
        update c;
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(0, logs('Plan').size());
    }

    @IsTest
    static void blankStatusPublishesNothing() {
        Contact c = newContacts(1)[0];
        setEnabled(true);
        mockNoGoogleUsers();

        Test.startTest();
        c.FirstName = 'Renamed';
        update c;
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(0, logs('Plan').size());
    }

    @IsTest
    static void disabledPublishesNothing() {
        Contact c = newContacts(1)[0];
        setEnabled(false);
        mockNoGoogleUsers();

        Test.startTest();
        c.Lifecycle_Status__c = 'Admitted';
        update c;
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(0, logs('Plan').size());
    }

    @IsTest
    static void bulkUpdateRunsOneJobPerContact() {
        List<Contact> rows = newContacts(3);
        setEnabled(true);
        mockNoGoogleUsers();

        Test.startTest();
        for (Contact c : rows) {
            c.Lifecycle_Status__c = 'Enrolled';
        }
        update rows;
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(3, logs('Plan').size());
    }

    @IsTest
    static void subscriberDeduplicatesContacts() {
        Contact c = newContacts(1)[0];
        setEnabled(true);

        Test.startTest();
        DirectorySyncRequestHandler.handle(new List<Directory_Sync_Request__e>{
            new Directory_Sync_Request__e(Contact_Id__c = c.Id),
            new Directory_Sync_Request__e(Contact_Id__c = c.Id),
            new Directory_Sync_Request__e(Contact_Id__c = 'not-an-id')
        });
        Assert.areEqual(1, Limits.getQueueableJobs(), 'Duplicates and invalid IDs collapse to one job');
        Test.stopTest();
    }

    @IsTest
    static void contactIdValidation() {
        Assert.isNull(DirectorySyncRequestHandler.toContactId(null));
        Assert.isNull(DirectorySyncRequestHandler.toContactId('garbage'));
        Assert.isNull(DirectorySyncRequestHandler.toContactId(UserInfo.getUserId()), 'A non-Contact Id is rejected');
    }

    @IsTest
    static void deletedContactIsLoggedWithoutLookup() {
        Contact c = newContacts(1)[0];
        Id cid = c.Id;
        delete c;

        Test.startTest();
        System.enqueueJob(new DirectorySyncJob(cid));
        Test.stopTest();

        List<Directory_Sync_Log__c> plans = logs('Plan');
        Assert.areEqual(1, plans.size());
        Assert.areEqual('contactNotFound', plans[0].Error_Reason__c);
        Assert.isNull(plans[0].Contact__c);
        Assert.areEqual(0, logs('Lookup').size(), 'No callout for a missing Contact');
    }

    @IsTest
    static void finalizerRecordsUnhandledFailure() {
        Contact c = newContacts(1)[0];

        DirectorySyncFinalizer.record(c.Id, ParentJobResult.UNHANDLED_EXCEPTION, new DmlException('boom'));
        DirectorySyncFinalizer.record(c.Id, ParentJobResult.SUCCESS, null);

        List<Directory_Sync_Log__c> failures = logs('Job Failure');
        Assert.areEqual(1, failures.size(), 'Only the failed run is logged');
        Assert.areEqual('unhandledException', failures[0].Error_Reason__c);
        Assert.isTrue(failures[0].Response_Summary__c.contains('boom'));
    }

    @IsTest
    static void finalizerFallsBackWhenContactCannotBeLinked() {
        Contact c = newContacts(1)[0];
        Id cid = c.Id;
        delete c;

        DirectorySyncFinalizer.record(cid, ParentJobResult.UNHANDLED_EXCEPTION, new DmlException('boom'));

        List<Directory_Sync_Log__c> failures = logs('Job Failure');
        Assert.areEqual(1, failures.size(), 'The failure is still recorded');
        Assert.isNull(failures[0].Contact__c);
        Assert.isTrue(failures[0].Response_Summary__c.contains('without Contact link'));
        Assert.isTrue(failures[0].Response_Summary__c.contains('boom'));
    }
}
