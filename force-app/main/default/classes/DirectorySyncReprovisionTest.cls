@IsTest
private class DirectorySyncReprovisionTest {

    private static Integer seq = 0;

    private static Directory_Sync_Setting__mdt settings(Boolean dryRun) {
        return new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default',
            Enabled__c = true,
            Dry_Run__c = dryRun,
            Send_Welcome_Email__c = true,
            Provisioning_Delay_Minutes__c = 0,
            Domain__c = 'shuraku.org'
        );
    }

    private static Contact student(String email, String googleId, String accountStatus) {
        seq++;
        Contact c = new Contact(
            FirstName = 'Jane', LastName = 'Reprovision' + seq, Email = email,
            Lifecycle_Status__c = 'Enrolled', Google_User_Id__c = googleId,
            Google_Primary_Email__c = googleId == null ? null : 'jane.reprovision' + seq + '@shuraku.org',
            Google_Account_Status__c = accountStatus
        );
        insert c;
        return c;
    }

    private static String existing(Id contactId, Boolean suspended) {
        return JSON.serialize(new Map<String, Object>{ 'users' => new List<Object>{
            new Map<String, Object>{
                'id' => 'g1', 'primaryEmail' => 'jane.doe@shuraku.org', 'orgUnitPath' => '/Demo Students/Enrolled',
                'suspended' => suspended,
                'externalIds' => new List<Object>{ new Map<String, Object>{ 'type' => 'custom', 'customType' => 'salesforce_id', 'value' => String.valueOf(contactId) } }
            }
        } });
    }

    private static void runJob(Id contactId, Boolean dryRun, Boolean failEmail) {
        DirectorySyncJob job = DirectorySyncJob.forReprovision(contactId);
        job.injectedSettings = settings(dryRun);
        job.forceEmailFailure = failEmail;
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    private static Directory_Sync_Log__c log(Id contactId, String operation) {
        List<Directory_Sync_Log__c> rows = [
            SELECT Success__c, Error_Reason__c, Alert_Status__c, Request_Summary__c, Response_Summary__c
            FROM Directory_Sync_Log__c WHERE Contact__c = :contactId AND Operation__c = :operation ORDER BY Name
        ];
        return rows.isEmpty() ? null : rows[rows.size() - 1];
    }

    private static Contact reload(Id contactId) {
        return [SELECT Google_Account_Status__c, Google_Last_Error__c FROM Contact WHERE Id = :contactId];
    }

    /** A user holding Directory Sync Admin, so the custom permission check passes. */
    private static User admin() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String tag = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User u = new User(
            ProfileId = p.Id, LastName = 'Reprovisioner', Alias = 'reprov',
            Username = 'reprov' + tag + '@example.com.identitytest', Email = 'reprov@example.com',
            TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert u;
        insert new PermissionSetAssignment(
            AssigneeId = u.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Directory_Sync_Admin'].Id
        );
        return u;
    }

    // ---------------------------------------------------------------
    // The request (button side)
    // ---------------------------------------------------------------

    @IsTest
    static void acceptedRequestLogsWhoAsked() {
        System.runAs(admin()) {
            Contact c = student('jane.personal@example.com', 'g1', 'Active');
            List<DirectorySyncReprovision.Request> reqs = new List<DirectorySyncReprovision.Request>{ new DirectorySyncReprovision.Request() };
            reqs[0].contactId = c.Id;

            DirectorySyncReprovision.Response r = DirectorySyncReprovision.request(reqs)[0];

            Assert.isTrue(r.accepted, r.message);
            Assert.isTrue(r.message.contains('jane.personal@example.com'), r.message);
            Directory_Sync_Log__c row = log(c.Id, 'Password Reset');
            Assert.isTrue(row.Request_Summary__c.startsWith('Reprovision requested by Reprovisioner'), row.Request_Summary__c);
        }
    }

    @IsTest
    static void cooldownBlocksASecondRequest() {
        System.runAs(admin()) {
            Contact c = student('jane.personal@example.com', 'g1', 'Active');
            Assert.isTrue(DirectorySyncReprovision.requestOne(c.Id).accepted);
            DirectorySyncReprovision.Response second = DirectorySyncReprovision.requestOne(c.Id);
            Assert.isFalse(second.accepted);
            Assert.isTrue(second.message.contains('last 10 minutes'), second.message);
        }
    }

    @IsTest
    static void refusesWithoutAccountEmailOrWhenSuspended() {
        System.runAs(admin()) {
            Assert.isTrue(DirectorySyncReprovision.requestOne(student('a@example.com', null, null).Id).message.contains('no Google account yet'));
            Assert.isTrue(DirectorySyncReprovision.requestOne(student('b@example.com', 'g2', 'Suspended').Id).message.contains('suspended'));
            Assert.isTrue(DirectorySyncReprovision.requestOne(student(null, 'g3', 'Active').Id).message.contains('no personal email'));
            Assert.areEqual(0, [SELECT COUNT() FROM Directory_Sync_Log__c WHERE Operation__c = 'Password Reset'], 'Refusals send nothing');
        }
    }

    @IsTest
    static void refusesWithoutTheCustomPermission() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            ProfileId = p.Id, LastName = 'NoPerm', Alias = 'noperm',
            Username = 'noperm' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com.identitytest',
            Email = 'noperm@example.com', TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert u;
        // A User insert and a Contact insert can't share a transaction (mixed DML), so the Contact goes in its own context.
        Contact c;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            c = student('jane.personal@example.com', 'g1', 'Active');
        }
        System.runAs(u) {
            DirectorySyncReprovision.Response r = DirectorySyncReprovision.requestOne(c.Id);
            Assert.isFalse(r.accepted);
            Assert.isTrue(r.message.contains('Directory Sync Reprovision permission'), r.message);
        }
    }

    // ---------------------------------------------------------------
    // The job (integration user side)
    // ---------------------------------------------------------------

    @IsTest
    static void resetsPasswordAndEmailsIt() {
        Contact c = student('jane.personal@example.com', 'g1', 'Error');
        DirectoryMock mock = new DirectoryMock()
            .route('GET', '/users', 200, existing(c.Id, false))
            .route('PATCH', '/users/g1', 200, '{"id":"g1"}');
        Test.setMock(HttpCalloutMock.class, mock);

        runJob(c.Id, false, false);

        String sent = log(c.Id, 'Password Reset').Request_Summary__c;
        Assert.isTrue(sent.contains('"password":"[REDACTED]"'), 'Password never reaches the log: ' + sent);
        Assert.isTrue(sent.contains('"changePasswordAtNextLogin":true'), sent);
        Directory_Sync_Log__c welcome = log(c.Id, 'Welcome Email');
        Assert.isTrue(welcome.Success__c);
        Directory_Sync_Log__c plan = log(c.Id, 'Plan');
        Assert.isTrue(plan.Success__c);
        Assert.isNull(plan.Alert_Status__c);
        Assert.isTrue(plan.Response_Summary__c.startsWith('REPROVISION'), plan.Response_Summary__c);
        Contact after = reload(c.Id);
        Assert.areEqual('Active', after.Google_Account_Status__c, 'An earlier email failure is cleared');
        Assert.isNull(after.Google_Last_Error__c);
    }

    @IsTest
    static void suspendedAccountIsRefusedWithoutChanges() {
        Contact c = student('jane.personal@example.com', 'g1', 'Active');
        // No PATCH route: touching the password fails the test.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, existing(c.Id, true)));

        runJob(c.Id, false, false);

        Directory_Sync_Log__c plan = log(c.Id, 'Plan');
        Assert.areEqual('suspendedAccount', plan.Error_Reason__c);
        Assert.areEqual('Pending', plan.Alert_Status__c);
        Assert.isNull(log(c.Id, 'Welcome Email'));
        Assert.isTrue(reload(c.Id).Google_Last_Error__c.startsWith('Reprovision refused (suspendedAccount)'));
    }

    @IsTest
    static void noAccountIsRefused() {
        Contact c = student('jane.personal@example.com', 'g1', 'Active');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, '{"users":[]}'));
        runJob(c.Id, false, false);
        Assert.areEqual('noAccount', log(c.Id, 'Plan').Error_Reason__c);
    }

    @IsTest
    static void noPersonalEmailMakesNoCallouts() {
        Contact c = student(null, 'g1', 'Active');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock());   // no routes at all
        runJob(c.Id, false, false);
        Assert.areEqual('noPersonalEmail', log(c.Id, 'Plan').Error_Reason__c);
    }

    @IsTest
    static void dryRunChangesNothing() {
        Contact c = student('jane.personal@example.com', 'g1', 'Active');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock());
        runJob(c.Id, true, false);
        Assert.areEqual('dryRun', log(c.Id, 'Plan').Error_Reason__c);
    }

    @IsTest
    static void failedPasswordChangeSendsNoEmail() {
        Contact c = student('jane.personal@example.com', 'g1', 'Active');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing(c.Id, false))
            .route('PATCH', '/users/g1', 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api')));

        runJob(c.Id, false, false);

        Directory_Sync_Log__c plan = log(c.Id, 'Plan');
        Assert.areEqual('forbidden', plan.Error_Reason__c);
        Assert.areEqual('Pending', plan.Alert_Status__c);
        Assert.isNull(log(c.Id, 'Welcome Email'), 'No password email when the password did not change');
    }

    @IsTest
    static void failedEmailIsAlertedAndFlagged() {
        Contact c = student('jane.personal@example.com', 'g1', 'Active');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing(c.Id, false))
            .route('PATCH', '/users/g1', 200, '{"id":"g1"}'));

        runJob(c.Id, false, true);

        Assert.areEqual('Pending', log(c.Id, 'Welcome Email').Alert_Status__c);
        Assert.areEqual('emailFailed', log(c.Id, 'Plan').Error_Reason__c);
        Assert.areEqual('Error', reload(c.Id).Google_Account_Status__c);
    }

    @IsTest
    static void reprovisionEventStartsTheJob() {
        DirectorySyncConfig.settingsOverride = settings(false);
        Contact c = student('jane.personal@example.com', 'g1', 'Active');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, '{"users":[]}'));

        Test.startTest();
        DirectorySyncRequestHandler.handle(new List<Directory_Sync_Request__e>{
            new Directory_Sync_Request__e(Kind__c = 'Reprovision', Contact_Id__c = c.Id)
        });
        Assert.areEqual(1, Limits.getQueueableJobs());
        Test.stopTest();

        Directory_Sync_Log__c plan = log(c.Id, 'Plan');
        Assert.isTrue(plan.Request_Summary__c.startsWith('Reprovision'), 'Ran in reprovision mode: ' + plan.Request_Summary__c);
    }
}
