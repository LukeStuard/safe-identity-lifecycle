@IsTest
private class DirectoryMoverTest {

    private static final String MBA = 'program-mba@shuraku.org';
    private static final String ANALYTICS = 'program-ms-analytics@shuraku.org';
    private static final String FALL = 'term-fall-2026@shuraku.org';

    private static Directory_Sync_Setting__mdt live() {
        return new Directory_Sync_Setting__mdt(
            DeveloperName = 'Default', Enabled__c = true, Dry_Run__c = false,
            Send_Welcome_Email__c = true, Provisioning_Delay_Minutes__c = 0, Domain__c = 'shuraku.org'
        );
    }

    private static List<Directory_Group_Mapping__mdt> groupRows() {
        return new List<Directory_Group_Mapping__mdt>{
            new Directory_Group_Mapping__mdt(Program__c = 'MBA', Group_Email__c = MBA),
            new Directory_Group_Mapping__mdt(Program__c = 'MS Analytics', Group_Email__c = ANALYTICS),
            new Directory_Group_Mapping__mdt(Term__c = 'Fall 2026', Group_Email__c = FALL)
        };
    }

    private static Contact student(String status, String program, String term, String googleId) {
        Contact c = new Contact(
            FirstName = 'Jane', LastName = 'Doe', Email = 'jane.personal@example.com',
            Lifecycle_Status__c = status, Program__c = program, Term__c = term, Google_User_Id__c = googleId
        );
        insert c;
        return c;
    }

    private static void run(Id contactId) {
        DirectorySyncJob job = new DirectorySyncJob(contactId);
        job.injectedSettings = live();
        job.injectedGroupMappings = groupRows();
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    private static String existing(String ou, Boolean suspended) {
        return '{"users":[{"id":"g1","primaryEmail":"jane.doe@shuraku.org","orgUnitPath":"' + ou
            + '","suspended":' + suspended + '}]}';
    }

    private static String groups(List<String> emails) {
        List<Object> items = new List<Object>();
        for (String e : emails) {
            items.add(new Map<String, Object>{ 'email' => e });
        }
        return JSON.serialize(new Map<String, Object>{ 'groups' => items });
    }

    private static String members(String groupEmail) {
        return '/groups/' + EncodingUtil.urlEncode(groupEmail, 'UTF-8') + '/members';
    }

    private static Contact reload(Id contactId) {
        return [SELECT Google_Account_Status__c, Google_Last_Error__c, Google_Last_Sync__c FROM Contact WHERE Id = :contactId];
    }

    private static Integer count(Id contactId, String operation) {
        return [SELECT COUNT() FROM Directory_Sync_Log__c WHERE Contact__c = :contactId AND Operation__c = :operation];
    }

    private static String planText(Id contactId) {
        return [SELECT Response_Summary__c FROM Directory_Sync_Log__c WHERE Contact__c = :contactId AND Operation__c = 'Plan'][0].Response_Summary__c;
    }

    @IsTest
    static void statusAndProgramChangeMovesAndSwapsGroups() {
        Contact c = student('Enrolled', 'MS Analytics', 'Fall 2026', 'g1');
        // book-club is unmanaged and the term group already matches: no routes, so touching them fails the test.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing('/Demo Students/Admitted', false))
            .route('PATCH', '/users/g1', 200, '{"id":"g1","orgUnitPath":"/Demo Students/Enrolled"}')
            .route('GET', '/groups', 200, groups(new List<String>{ MBA, FALL, 'book-club@shuraku.org' }))
            .route('POST', members(ANALYTICS), 200, '{"id":"g1","role":"MEMBER"}')
            .route('DELETE', members(MBA) + '/g1', 204, null));

        run(c.Id);

        Contact after = reload(c.Id);
        Assert.areEqual('Active', after.Google_Account_Status__c);
        Assert.isNull(after.Google_Last_Error__c);
        Assert.isNotNull(after.Google_Last_Sync__c);
        Assert.areEqual(1, count(c.Id, 'Move'));
        Assert.areEqual(1, count(c.Id, 'Group Add'));
        Assert.areEqual(1, count(c.Id, 'Group Remove'));
        String plan = planText(c.Id);
        Assert.isTrue(plan.startsWith('MOVE'), plan);
        Assert.isTrue(plan.contains('Done: Moved to /Demo Students/Enrolled.'), plan);
        Assert.isTrue(plan.contains('Done: Removed from ' + MBA), plan);
    }

    @IsTest
    static void inSyncAccountMakesNoWrites() {
        Contact c = student('Enrolled', 'MBA', 'Fall 2026', 'g1');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing('/Demo Students/Enrolled', false))
            .route('GET', '/groups', 200, groups(new List<String>{ MBA, FALL })));

        run(c.Id);

        Assert.areEqual(0, count(c.Id, 'Move'));
        Assert.areEqual(0, count(c.Id, 'Group Add'));
        Assert.areEqual(0, count(c.Id, 'Group Remove'));
        Assert.isTrue(planText(c.Id).contains('Groups already match.'));
        Assert.areEqual('Active', reload(c.Id).Google_Account_Status__c);
    }

    @IsTest
    static void newAccountGetsGroupsWithoutReadingMemberships() {
        Contact c = student('Admitted', 'MBA', 'Fall 2026', null);
        // No GET /groups route: a fresh account has no memberships to read.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, '{"users":[]}')
            .route('POST', '/users', 200, '{"id":"g9","primaryEmail":"jane.doe@shuraku.org"}')
            .route('POST', members(MBA), 200, '{"id":"g9"}')
            .route('POST', members(FALL), 200, '{"id":"g9"}'));

        run(c.Id);

        Assert.areEqual('Active', reload(c.Id).Google_Account_Status__c);
        Assert.areEqual(2, count(c.Id, 'Group Add'));
        Assert.areEqual(1, count(c.Id, 'Welcome Email'));
    }

    @IsTest
    static void alreadyMemberAndNotMemberCountAsSuccess() {
        Contact c = student('Enrolled', 'MS Analytics', null, 'g1');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing('/Demo Students/Enrolled', false))
            .route('GET', '/groups', 200, groups(new List<String>{ MBA }))
            .route('POST', members(ANALYTICS), 409, DirectoryMock.error(409, 'duplicate', 'Member already exists.'))
            .route('DELETE', members(MBA) + '/g1', 404, DirectoryMock.error(404, 'notFound', 'Resource Not Found: memberKey')));

        run(c.Id);

        Contact after = reload(c.Id);
        Assert.isNull(after.Google_Last_Error__c, 'Retried membership changes converge');
        Assert.areEqual('Active', after.Google_Account_Status__c);
    }

    @IsTest
    static void failedMoveSkipsGroupsAndRecordsError() {
        Contact c = student('Enrolled', 'MBA', 'Fall 2026', 'g1');
        // No GET /groups route: groups must not be attempted after a failed move.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing('/Demo Students/Admitted', false))
            .route('PATCH', '/users/g1', 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api')));

        run(c.Id);

        Contact after = reload(c.Id);
        Assert.isTrue(after.Google_Last_Error__c.startsWith('forbidden'), after.Google_Last_Error__c);
        Assert.isTrue(planText(c.Id).contains('Failed: forbidden'));
    }

    @IsTest
    static void suspendedAccountIsLeftForPhaseFour() {
        Contact c = student('Enrolled', 'MBA', 'Fall 2026', 'g1');
        // No PATCH or groups routes: reactivation is plan-only until Phase 4.
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing('/Demo Students/Inactive', true)));

        run(c.Id);

        Assert.isTrue(planText(c.Id).startsWith('REACTIVATE'));
        Assert.areEqual(0, count(c.Id, 'Move'));
    }

    @IsTest
    static void groupListFailureRecordsError() {
        Contact c = student('Enrolled', 'MBA', 'Fall 2026', 'g1');
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('GET', '/users', 200, existing('/Demo Students/Enrolled', false))
            .route('GET', '/groups', 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api')));

        run(c.Id);

        Assert.isTrue(reload(c.Id).Google_Last_Error__c.startsWith('forbidden'));
    }
}
