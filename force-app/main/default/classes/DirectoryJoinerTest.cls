@IsTest
private class DirectoryJoinerTest {

    private static Directory_Sync_Setting__mdt settings(Boolean dryRun, Boolean sendWelcome) {
        return new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default',
            Enabled__c = true,
            Dry_Run__c = dryRun,
            Send_Welcome_Email__c = sendWelcome,
            Provisioning_Delay_Minutes__c = 0,
            Domain__c = 'shuraku.org'
        );
    }

    private static Contact student(String email) {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = email, Lifecycle_Status__c = 'Enrolled');
        insert c;
        return c;
    }

    private static void run(Id contactId, Directory_Sync_Setting__mdt s, Boolean failEmail) {
        DirectorySyncJob job = new DirectorySyncJob(contactId);
        job.injectedSettings = s;
        job.forceEmailFailure = failEmail;
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    private static Contact reload(Id contactId) {
        return [
            SELECT Google_User_Id__c, Google_Primary_Email__c, Google_Account_Status__c,
                   Google_Last_Error__c, Google_Last_Sync__c
            FROM Contact WHERE Id = :contactId
        ];
    }

    private static List<Directory_Sync_Log__c> logs(Id contactId, String operation) {
        return [
            SELECT Success__c, Dry_Run__c, Error_Reason__c, Request_Summary__c, Response_Summary__c
            FROM Directory_Sync_Log__c
            WHERE Contact__c = :contactId AND Operation__c = :operation
            ORDER BY Name
        ];
    }

    private static String userJson(String id, String email, String salesforceId) {
        return JSON.serialize(new Map<String, Object>{
            'id' => id,
            'primaryEmail' => email,
            'externalIds' => new List<Object>{
                new Map<String, Object>{ 'type' => 'custom', 'customType' => 'salesforce_id', 'value' => salesforceId }
            }
        });
    }

    private static final String NO_USERS = '{"users":[]}';
    private static final String TAKEN_NAME_PATH = '/users/' + EncodingUtil.urlEncode('jane.doe@shuraku.org', 'UTF-8');

    @IsTest
    static void createsAccountSendsWelcomeAndWritesBack() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 200, '{"id":"g-100","primaryEmail":"jane.doe@shuraku.org"}'));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('g-100', after.Google_User_Id__c);
        Assert.areEqual('jane.doe@shuraku.org', after.Google_Primary_Email__c);
        Assert.areEqual('Active', after.Google_Account_Status__c);
        Assert.isNull(after.Google_Last_Error__c);
        Assert.isNotNull(after.Google_Last_Sync__c);

        List<Directory_Sync_Log__c> creates = logs(c.Id, 'Create');
        Assert.areEqual(1, creates.size());
        String sent = creates[0].Request_Summary__c;
        Assert.isTrue(sent.contains('"password":"[REDACTED]"'), 'Password never reaches the log');
        Assert.isTrue(sent.contains('"orgUnitPath":"/Demo Students/Enrolled"'), sent);
        Assert.isTrue(sent.contains('"changePasswordAtNextLogin":true'), sent);
        Assert.isTrue(sent.contains(String.valueOf(c.Id)), 'Salesforce ID stored as externalId');

        List<Directory_Sync_Log__c> welcome = logs(c.Id, 'Welcome Email');
        Assert.areEqual(1, welcome.size());
        Assert.isTrue(welcome[0].Success__c);
        Assert.isTrue(welcome[0].Request_Summary__c.contains('jane.doe@shuraku.org'));

        Assert.isFalse(logs(c.Id, 'Plan')[0].Dry_Run__c, 'Plan row reflects a live run');
    }

    @IsTest
    static void takenNameMovesToNextSuffix() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 409, DirectoryMock.error(409, 'duplicate', 'Entity already exists.'))
            .route('POST', '/users', 200, '{"id":"g-101","primaryEmail":"jane.doe2@shuraku.org"}')
            .route('GET', TAKEN_NAME_PATH, 200, userJson('g-other', 'jane.doe@shuraku.org', '003000000000999AAA')));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('jane.doe2@shuraku.org', after.Google_Primary_Email__c);
        Assert.areEqual('Active', after.Google_Account_Status__c);

        List<Directory_Sync_Log__c> creates = logs(c.Id, 'Create');
        Assert.areEqual(2, creates.size());
        Assert.areEqual('duplicate', creates[0].Error_Reason__c);
        Assert.isTrue(creates[1].Request_Summary__c.contains('jane.doe2@shuraku.org'));
    }

    @IsTest
    static void nameHeldByOwnAccountIsLinkedNotDuplicated() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 409, DirectoryMock.error(409, 'duplicate', 'Entity already exists.'))
            .route('GET', TAKEN_NAME_PATH, 200, userJson('g-mine', 'jane.doe@shuraku.org', String.valueOf(c.Id)))
            .route('GET', '/groups', 200, '{}'));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('g-mine', after.Google_User_Id__c);
        Assert.areEqual('Active', after.Google_Account_Status__c);
        Assert.areEqual(1, logs(c.Id, 'Create').size(), 'No second account');
        Assert.areEqual(0, logs(c.Id, 'Welcome Email').size(), 'No new password to send');
        Assert.isTrue(logs(c.Id, 'Plan')[0].Response_Summary__c.contains('linked it instead'));
    }

    @IsTest
    static void lookupFindsUnlinkedAccountAndLinksIt() {
        Contact c = student('jane.personal@example.com');
        // No POST route: any create attempt would fail the test.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200,
                '{"users":[{"id":"g-102","primaryEmail":"jane.doe@shuraku.org","orgUnitPath":"/Demo Students/Enrolled","suspended":false}]}')
            .route('GET', '/groups', 200, '{}'));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('g-102', after.Google_User_Id__c);
        Assert.areEqual('jane.doe@shuraku.org', after.Google_Primary_Email__c);
        Assert.areEqual('Active', after.Google_Account_Status__c);
        Assert.areEqual(0, logs(c.Id, 'Create').size());
    }

    @IsTest
    static void createErrorMarksContactWithoutCreating() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api')));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('Error', after.Google_Account_Status__c);
        Assert.isTrue(after.Google_Last_Error__c.startsWith('forbidden'), after.Google_Last_Error__c);
        Assert.isNull(after.Google_User_Id__c);
        Assert.areEqual(0, logs(c.Id, 'Welcome Email').size());
    }

    @IsTest
    static void stopsAfterMaxAttempts() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 409, DirectoryMock.error(409, 'duplicate', 'Entity already exists.'))
            .route('GET', '/users/*', 200, userJson('g-other', 'someone@shuraku.org', '003000000000999AAA')));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('Error', after.Google_Account_Status__c);
        Assert.isTrue(after.Google_Last_Error__c.startsWith('usernameExhausted'), after.Google_Last_Error__c);
        Assert.areEqual(DirectoryJoiner.MAX_ATTEMPTS, logs(c.Id, 'Create').size());
    }

    @IsTest
    static void missingPersonalEmailBlocksCreate() {
        Contact c = student(null);
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, NO_USERS));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.areEqual('Error', after.Google_Account_Status__c);
        Assert.isTrue(after.Google_Last_Error__c.startsWith('noPersonalEmail'));
        Assert.areEqual(0, logs(c.Id, 'Create').size());
    }

    @IsTest
    static void failedWelcomeEmailFlagsResetButKeepsAccount() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 200, '{"id":"g-103","primaryEmail":"jane.doe@shuraku.org"}'));

        run(c.Id, settings(false, true), true);

        Contact after = reload(c.Id);
        Assert.areEqual('g-103', after.Google_User_Id__c, 'The account exists and is recorded');
        Assert.areEqual('Error', after.Google_Account_Status__c);
        Assert.isTrue(after.Google_Last_Error__c.contains('password reset required'));
        Assert.isFalse(logs(c.Id, 'Welcome Email')[0].Success__c);
    }

    @IsTest
    static void welcomeDisabledStillCreates() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, NO_USERS)
            .route('POST', '/users', 200, '{"id":"g-104","primaryEmail":"jane.doe@shuraku.org"}'));

        run(c.Id, settings(false, false), false);

        Assert.areEqual('Active', reload(c.Id).Google_Account_Status__c);
        Assert.areEqual(0, logs(c.Id, 'Welcome Email').size());
        Assert.isTrue(logs(c.Id, 'Plan')[0].Response_Summary__c.contains('Welcome email disabled'));
    }

    @IsTest
    static void dryRunWritesNothing() {
        Contact c = student('jane.personal@example.com');
        // No POST route: a create attempt would fail the test.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, NO_USERS));

        run(c.Id, settings(true, true), false);

        Contact after = reload(c.Id);
        Assert.isNull(after.Google_User_Id__c);
        Assert.isNull(after.Google_Account_Status__c);
        Directory_Sync_Log__c plan = logs(c.Id, 'Plan')[0];
        Assert.isTrue(plan.Dry_Run__c);
        Assert.isTrue(plan.Response_Summary__c.startsWith('CREATE'));
    }

    @IsTest
    static void failedLookupRecordsErrorOnly() {
        Contact c = student('jane.personal@example.com');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 403, DirectoryMock.error(403, 'quotaExceeded', 'Quota exceeded')));

        run(c.Id, settings(false, true), false);

        Contact after = reload(c.Id);
        Assert.isTrue(after.Google_Last_Error__c.startsWith('[Retry 2 of 4 in 1 min] quotaExceeded'), after.Google_Last_Error__c);
        Assert.isNull(after.Google_Account_Status__c, 'A failed lookup does not change account status');
    }

    @IsTest
    static void passwordsAreRandomAndWellFormed() {
        String a = DirectoryJoiner.generatePassword();
        String b = DirectoryJoiner.generatePassword();
        Assert.areEqual(DirectoryJoiner.PASSWORD_LENGTH, a.length());
        Assert.areNotEqual(a, b);
        for (Integer i = 0; i < a.length(); i++) {
            Assert.isTrue(DirectoryJoiner.PASSWORD_CHARS.contains(a.substring(i, i + 1)), 'Unexpected character');
        }
    }

    @IsTest
    static void belongsToMatchesOnlyThisContact() {
        Id mine = '003000000000001AAA';
        Map<String, Object> user = (Map<String, Object>) JSON.deserializeUntyped(userJson('g', 'x@shuraku.org', String.valueOf(mine)));
        Assert.isTrue(DirectoryJoiner.belongsTo(user, mine));
        Assert.isFalse(DirectoryJoiner.belongsTo(user, '003000000000002AAA'));
        Assert.isFalse(DirectoryJoiner.belongsTo(new Map<String, Object>{ 'id' => 'g' }, mine));
        Assert.isFalse(DirectoryJoiner.belongsTo(null, mine));
    }
}
