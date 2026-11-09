@IsTest
private class DirectorySyncNameTest {

    private static Integer seq = 0;

    private static Directory_Sync_Setting__mdt settings() {
        return new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default',
            Enabled__c = true,
            Dry_Run__c = false,
            Send_Welcome_Email__c = true,
            Provisioning_Delay_Minutes__c = 0,
            Domain__c = 'shuraku.org'
        );
    }

    /** José García López, entered with the split wrong or right. Unique email per Contact. */
    private static Contact jose(String first, String last, String googleEmail) {
        seq++;
        Contact c = new Contact(
            FirstName = first, LastName = last, Email = 'jose' + seq + '@example.com',
            Lifecycle_Status__c = 'Enrolled', Google_User_Id__c = 'g' + seq,
            Google_Primary_Email__c = googleEmail, Google_Account_Status__c = 'Active'
        );
        insert c;
        return c;
    }

    private static String users(Id contactId, String googleId, String email, String given, String family, Boolean suspended) {
        Map<String, Object> u = new Map<String, Object>{
            'id' => googleId, 'primaryEmail' => email, 'orgUnitPath' => '/Demo Students/Enrolled', 'suspended' => suspended,
            'externalIds' => new List<Object>{ new Map<String, Object>{ 'type' => 'custom', 'customType' => 'salesforce_id', 'value' => String.valueOf(contactId) } }
        };
        if (given != null) {
            u.put('name', new Map<String, Object>{ 'givenName' => given, 'familyName' => family });
        }
        return JSON.serialize(new Map<String, Object>{ 'users' => new List<Object>{ u } });
    }

    private static void run(DirectorySyncJob job) {
        job.injectedSettings = settings();
        job.injectedGroupMappings = new List<Directory_Group_Mapping__mdt>();
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    private static List<Directory_Sync_Log__c> logs(Id contactId, String operation) {
        return [
            SELECT Success__c, Error_Reason__c, Alert_Status__c, Request_Summary__c, Response_Summary__c
            FROM Directory_Sync_Log__c WHERE Contact__c = :contactId AND Operation__c = :operation ORDER BY Name
        ];
    }

    private static Contact reload(Id contactId) {
        return [SELECT Google_Primary_Email__c, Google_Last_Error__c FROM Contact WHERE Id = :contactId];
    }

    private static User admin() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            ProfileId = p.Id, LastName = 'Renamer', Alias = 'renamer',
            Username = 'renamer' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com.identitytest',
            Email = 'renamer@example.com', TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
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
    // Display names follow the Contact automatically
    // ---------------------------------------------------------------

    @IsTest
    static void fixedNameSplitUpdatesDisplayNameOnly() {
        Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        DirectoryMock mock = new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'josegarcia.lopez@shuraku.org', 'José García', 'López', false))
            .route('GET', '/groups', 200, '{}')
            .route('PATCH', '/users/' + c.Google_User_Id__c, 200, '{}');
        Test.setMock(HttpCalloutMock.class, mock);

        run(new DirectorySyncJob(c.Id));

        String sent = logs(c.Id, 'Update')[0].Request_Summary__c;
        Assert.isTrue(sent.contains('"givenName":"José"'), sent);
        Assert.isTrue(sent.contains('"familyName":"García López"'), sent);
        Assert.isFalse(sent.contains('primaryEmail'), 'The username never changes on its own: ' + sent);
        Assert.areEqual('josegarcia.lopez@shuraku.org', reload(c.Id).Google_Primary_Email__c);
        String plan = logs(c.Id, 'Plan')[0].Response_Summary__c;
        Assert.isTrue(plan.contains('Display name updated to José García López.'), plan);
    }

    @IsTest
    static void matchingDisplayNameIsLeftAlone() {
        Contact c = jose('José', 'García López', 'jose.garcia-lopez@shuraku.org');
        // No PATCH route: an update would fail the test.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'jose.garcia-lopez@shuraku.org', 'José', 'García López', false))
            .route('GET', '/groups', 200, '{}'));

        run(new DirectorySyncJob(c.Id));

        Assert.isTrue(logs(c.Id, 'Update').isEmpty());
    }

    // ---------------------------------------------------------------
    // Rename job
    // ---------------------------------------------------------------

    @IsTest
    static void renameMovesUsernameAndEmailsTheStudent() {
        Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'josegarcia.lopez@shuraku.org', 'José', 'García López', false))
            .route('PATCH', '/users/' + c.Google_User_Id__c, 200, '{"primaryEmail":"jose.garcia-lopez@shuraku.org"}'));

        run(DirectorySyncJob.forRename(c.Id));

        String sent = logs(c.Id, 'Rename')[0].Request_Summary__c;
        Assert.isTrue(sent.contains('"primaryEmail":"jose.garcia-lopez@shuraku.org"'), sent);
        Assert.areEqual('jose.garcia-lopez@shuraku.org', reload(c.Id).Google_Primary_Email__c);
        Directory_Sync_Log__c notice = logs(c.Id, 'Welcome Email')[0];
        Assert.isTrue(notice.Success__c);
        Assert.isTrue(notice.Request_Summary__c.contains('jose.garcia-lopez@shuraku.org'), notice.Request_Summary__c);
        Directory_Sync_Log__c plan = logs(c.Id, 'Plan')[0];
        Assert.isTrue(plan.Success__c);
        Assert.isTrue(plan.Response_Summary__c.contains('renamed josegarcia.lopez@shuraku.org to jose.garcia-lopez@shuraku.org'), plan.Response_Summary__c);
    }

    @IsTest
    static void takenUsernameMovesToNextSuffix() {
        Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'josegarcia.lopez@shuraku.org', 'José', 'García López', false))
            .route('PATCH', '/users/' + c.Google_User_Id__c, 409, DirectoryMock.error(409, 'duplicate', 'Entity already exists.'))
            .route('PATCH', '/users/' + c.Google_User_Id__c, 200, '{"primaryEmail":"jose.garcia-lopez2@shuraku.org"}')
            .route('GET', '/users/*', 200, '{"id":"someone-else"}'));

        run(DirectorySyncJob.forRename(c.Id));

        Assert.areEqual('jose.garcia-lopez2@shuraku.org', reload(c.Id).Google_Primary_Email__c);
        Assert.areEqual(2, logs(c.Id, 'Rename').size());
    }

    @IsTest
    static void ownAliasIsRefused() {
        Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'josegarcia.lopez@shuraku.org', 'José', 'García López', false))
            .route('PATCH', '/users/' + c.Google_User_Id__c, 409, DirectoryMock.error(409, 'duplicate', 'Entity already exists.'))
            .route('GET', '/users/*', 200, '{"id":"' + c.Google_User_Id__c + '"}'));

        run(DirectorySyncJob.forRename(c.Id));

        Directory_Sync_Log__c plan = logs(c.Id, 'Plan')[0];
        Assert.areEqual('ownAlias', plan.Error_Reason__c);
        Assert.areEqual('Pending', plan.Alert_Status__c);
        Assert.areEqual('josegarcia.lopez@shuraku.org', reload(c.Id).Google_Primary_Email__c);
        Assert.isTrue(logs(c.Id, 'Welcome Email').isEmpty());
    }

    @IsTest
    static void suspendedAccountIsNotRenamed() {
        Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'josegarcia.lopez@shuraku.org', 'José', 'García López', true)));

        run(DirectorySyncJob.forRename(c.Id));

        Assert.areEqual('suspendedAccount', logs(c.Id, 'Plan')[0].Error_Reason__c);
    }

    @IsTest
    static void alreadyMatchingUsernameIsANoOp() {
        Contact c = jose('José', 'García López', 'jose.garcia-lopez2@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'jose.garcia-lopez2@shuraku.org', 'José', 'García López', false)));

        run(DirectorySyncJob.forRename(c.Id));

        Directory_Sync_Log__c plan = logs(c.Id, 'Plan')[0];
        Assert.isTrue(plan.Success__c);
        Assert.isNull(plan.Alert_Status__c);
        Assert.isTrue(plan.Response_Summary__c.startsWith('RENAME: nothing to do'), plan.Response_Summary__c);
    }

    @IsTest
    static void failedNoticeIsAlerted() {
        Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'josegarcia.lopez@shuraku.org', 'José', 'García López', false))
            .route('PATCH', '/users/' + c.Google_User_Id__c, 200, '{"primaryEmail":"jose.garcia-lopez@shuraku.org"}'));
        DirectorySyncJob job = DirectorySyncJob.forRename(c.Id);
        job.forceEmailFailure = true;

        run(job);

        Assert.areEqual('Pending', logs(c.Id, 'Welcome Email')[0].Alert_Status__c);
        Assert.areEqual('jose.garcia-lopez@shuraku.org', reload(c.Id).Google_Primary_Email__c, 'The rename itself stands');
        Assert.isTrue(reload(c.Id).Google_Last_Error__c.contains('jose.garcia-lopez@shuraku.org'));
    }

    @IsTest
    static void renameEventStartsTheJob() {
        DirectorySyncConfig.settingsOverride = settings();
        Contact c = jose('José', 'García López', 'jose.garcia-lopez@shuraku.org');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, users(c.Id, c.Google_User_Id__c, 'jose.garcia-lopez@shuraku.org', 'José', 'García López', false)));

        Test.startTest();
        DirectorySyncRequestHandler.handle(new List<Directory_Sync_Request__e>{
            new Directory_Sync_Request__e(Kind__c = 'Rename', Contact_Id__c = c.Id)
        });
        Assert.areEqual(1, Limits.getQueueableJobs());
        Test.stopTest();

        Assert.isTrue(logs(c.Id, 'Plan')[0].Request_Summary__c.startsWith('Rename'));
    }

    // ---------------------------------------------------------------
    // The button side
    // ---------------------------------------------------------------

    @IsTest
    static void previewShowsBothUsernamesAndChangesNothing() {
        DirectorySyncConfig.settingsOverride = settings();
        System.runAs(admin()) {
            Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
            DirectorySyncRename.Request req = new DirectorySyncRename.Request();
            req.contactId = c.Id;
            req.mode = 'preview';

            DirectorySyncRename.Response r = DirectorySyncRename.run(new List<DirectorySyncRename.Request>{ req })[0];

            Assert.isTrue(r.accepted, r.message);
            Assert.areEqual('josegarcia.lopez@shuraku.org', r.currentUsername);
            Assert.areEqual('jose.garcia-lopez@shuraku.org', r.proposedUsername);
            Assert.isTrue(logs(c.Id, 'Rename').isEmpty(), 'Preview sends nothing');
        }
    }

    @IsTest
    static void requestLogsWhoAskedAndCooldownBlocksRepeat() {
        DirectorySyncConfig.settingsOverride = settings();
        System.runAs(admin()) {
            Contact c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
            Assert.isTrue(DirectorySyncRename.request(c.Id).accepted);
            Assert.isTrue(logs(c.Id, 'Rename')[0].Request_Summary__c.startsWith('Rename requested by Renamer'));
            DirectorySyncRename.Response second = DirectorySyncRename.request(c.Id);
            Assert.isFalse(second.accepted);
            Assert.isTrue(second.message.contains('last 10 minutes'), second.message);
        }
    }

    @IsTest
    static void matchingNameHasNothingToRename() {
        DirectorySyncConfig.settingsOverride = settings();
        System.runAs(admin()) {
            Contact c = jose('José', 'García López', 'jose.garcia-lopez@shuraku.org');
            DirectorySyncRename.Response r = DirectorySyncRename.preview(c.Id);
            Assert.isFalse(r.accepted);
            Assert.isTrue(r.message.contains('already matches'), r.message);
        }
    }

    @IsTest
    static void refusesWithoutTheCustomPermission() {
        DirectorySyncConfig.settingsOverride = settings();
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            ProfileId = p.Id, LastName = 'NoRename', Alias = 'norename',
            Username = 'norename' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com.identitytest',
            Email = 'norename@example.com', TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert u;
        Contact c;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            c = jose('José', 'García López', 'josegarcia.lopez@shuraku.org');
        }
        System.runAs(u) {
            DirectorySyncRename.Response r = DirectorySyncRename.preview(c.Id);
            Assert.isFalse(r.accepted);
            Assert.isTrue(r.message.contains('Directory Sync Rename permission'), r.message);
        }
    }

    @IsTest
    static void suffixedUsernamesCountAsMatching() {
        Assert.isTrue(DirectorySyncRename.matchesBase('jane.doe@shuraku.org', 'jane.doe'));
        Assert.isTrue(DirectorySyncRename.matchesBase('jane.doe12@shuraku.org', 'jane.doe'));
        Assert.isFalse(DirectorySyncRename.matchesBase('jane.doe-smith@shuraku.org', 'jane.doe'));
        Assert.isFalse(DirectorySyncRename.matchesBase('janedoe@shuraku.org', 'jane.doe'));
        Assert.isFalse(DirectorySyncRename.matchesBase(null, 'jane.doe'));
    }
}
