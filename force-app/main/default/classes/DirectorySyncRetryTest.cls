@IsTest
private class DirectorySyncRetryTest {

    private static final String NO_USERS = '{"users":[]}';

    private static Directory_Sync_Setting__mdt settings() {
        return new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default',
            Enabled__c = true,
            Dry_Run__c = false,
            Send_Welcome_Email__c = false,
            Provisioning_Delay_Minutes__c = 0,
            Domain__c = 'shuraku.org'
        );
    }

    private static Contact student() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane.personal@example.com', Lifecycle_Status__c = 'Enrolled');
        insert c;
        return c;
    }

    private static void run(Id contactId, Integer attempt) {
        DirectorySyncJob job = new DirectorySyncJob(contactId, attempt);
        job.injectedSettings = settings();
        job.injectedGroupMappings = new List<Directory_Group_Mapping__mdt>();
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    private static Contact reload(Id contactId) {
        return [SELECT Google_Account_Status__c, Google_Last_Error__c FROM Contact WHERE Id = :contactId];
    }

    private static String planText(Id contactId) {
        return [SELECT Response_Summary__c FROM Directory_Sync_Log__c WHERE Contact__c = :contactId AND Operation__c = 'Plan'][0].Response_Summary__c;
    }

    private static void assertEveryLogIsAttempt(Id contactId, Integer attempt) {
        List<Directory_Sync_Log__c> rows = [SELECT Operation__c, Attempt__c FROM Directory_Sync_Log__c WHERE Contact__c = :contactId];
        Assert.isFalse(rows.isEmpty(), 'Expected log rows');
        for (Directory_Sync_Log__c r : rows) {
            Assert.areEqual(attempt, (Integer) r.Attempt__c, r.Operation__c + ' row carries the attempt');
        }
    }

    // ---------------------------------------------------------------
    // Policy
    // ---------------------------------------------------------------

    @IsTest
    static void backoffIsOneTwoFourThenStops() {
        Assert.areEqual(1, DirectorySyncJob.retryDelay(1, true));
        Assert.areEqual(2, DirectorySyncJob.retryDelay(2, true));
        Assert.areEqual(4, DirectorySyncJob.retryDelay(3, true));
        Assert.isNull(DirectorySyncJob.retryDelay(DirectorySyncJob.MAX_ATTEMPTS, true), 'No attempt past the maximum');
        Assert.isNull(DirectorySyncJob.retryDelay(1, false), 'Non-retryable failures never retry');
        Assert.isNull(DirectorySyncJob.retryDelay(1, null));
    }

    @IsTest
    static void classifiesReasonsAfterTheResponseIsGone() {
        for (String r : new List<String>{ 'rateLimitExceeded', 'userRateLimitExceeded', 'quotaExceeded', 'backendError',
                                          'internalError', 'calloutException', 'http429', 'http500', 'http503' }) {
            Assert.isTrue(DirectoryResult.isRetryableReason(r), r);
        }
        for (String r : new List<String>{ 'forbidden', 'duplicate', 'invalid', 'notFound', 'http400', 'http404',
                                          'httpabc', 'usernameExhausted', 'noPersonalEmail', 'multipleMatches', '', null }) {
            Assert.isFalse(DirectoryResult.isRetryableReason(r), 'reason: ' + r);
        }
    }

    // ---------------------------------------------------------------
    // Job
    // ---------------------------------------------------------------

    @IsTest
    static void rateLimitedLookupSchedulesSecondAttempt() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 429, DirectoryMock.error(429, 'rateLimitExceeded', 'Rate Limit Exceeded')));

        run(c.Id, 1);

        String err = reload(c.Id).Google_Last_Error__c;
        Assert.isTrue(err.startsWith('[Retry 2 of 4 in 1 min] rateLimitExceeded'), err);
        String plan = planText(c.Id);
        Assert.isTrue(plan.contains('Retrying: attempt 2 of 4 scheduled in 1 minute (rateLimitExceeded).'), plan);
        assertEveryLogIsAttempt(c.Id, 1);
    }

    @IsTest
    static void createBackendErrorOnSecondAttemptWaitsTwoMinutes() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 503, DirectoryMock.error(503, 'backendError', 'Backend Error')));

        run(c.Id, 2);

        Contact after = reload(c.Id);
        Assert.areEqual('Error', after.Google_Account_Status__c);
        Assert.isTrue(after.Google_Last_Error__c.startsWith('[Retry 3 of 4 in 2 min] backendError'), after.Google_Last_Error__c);
        Assert.isTrue(planText(c.Id).contains('scheduled in 2 minutes'));
        assertEveryLogIsAttempt(c.Id, 2);
    }

    @IsTest
    static void lastAttemptGivesUp() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 429, DirectoryMock.error(429, 'rateLimitExceeded', 'Rate Limit Exceeded')));

        run(c.Id, DirectorySyncJob.MAX_ATTEMPTS);

        String err = reload(c.Id).Google_Last_Error__c;
        Assert.isTrue(err.startsWith('[Gave up after 4 attempts] rateLimitExceeded'), err);
        String plan = planText(c.Id);
        Assert.isTrue(plan.contains('no attempts left (4 of 4)'), plan);
        Assert.isFalse(plan.contains('Retrying:'), plan);
    }

    @IsTest
    static void forbiddenIsNeverRetried() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api')));

        run(c.Id, 1);

        String err = reload(c.Id).Google_Last_Error__c;
        Assert.isTrue(err.startsWith('forbidden'), 'No retry prefix: ' + err);
        Assert.isFalse(planText(c.Id).contains('Retrying:'));
    }

    @IsTest
    static void successfulRetryStampsAttemptAndClearsError() {
        Contact c = student();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 200, '{"id":"g-300","primaryEmail":"jane.doe@shuraku.org"}'));

        run(c.Id, 3);

        Contact after = reload(c.Id);
        Assert.areEqual('Active', after.Google_Account_Status__c);
        Assert.isNull(after.Google_Last_Error__c);
        Assert.isFalse(planText(c.Id).contains('Retrying:'));
        assertEveryLogIsAttempt(c.Id, 3);
    }

    @IsTest
    static void finalizerRowCarriesTheAttempt() {
        Contact c = student();
        DirectorySyncFinalizer.record(c.Id, 3, ParentJobResult.UNHANDLED_EXCEPTION, new BoomException('boom'));
        Directory_Sync_Log__c row = [SELECT Operation__c, Attempt__c, Error_Reason__c FROM Directory_Sync_Log__c WHERE Contact__c = :c.Id];
        Assert.areEqual('Job Failure', row.Operation__c);
        Assert.areEqual(3, (Integer) row.Attempt__c);
    }

    private class BoomException extends Exception {}
}
