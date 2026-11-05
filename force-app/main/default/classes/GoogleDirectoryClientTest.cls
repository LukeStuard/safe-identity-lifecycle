@IsTest
private class GoogleDirectoryClientTest {

    private static final String DOMAIN = 'shuraku.org';

    private static Id contactId() {
        Contact c = new Contact(FirstName = 'Test', LastName = 'Student', Email = 'test.student@example.com');
        insert c;
        return c.Id;
    }

    private static GoogleDirectoryClient client(Id cid, Boolean dryRun) {
        return new GoogleDirectoryClient(cid, DOMAIN, dryRun);
    }

    @IsTest
    static void findByExternalIdReturnsMatchAndLogsLookup() {
        Id cid = contactId();
        DirectoryMock mock = new DirectoryMock()
            .route('GET', '/users', 200, '{"users":[{"id":"111","primaryEmail":"test.student@shuraku.org"}]}');
        Test.setMock(HttpCalloutMock.class, mock);

        GoogleDirectoryClient c = client(cid, false);
        Test.startTest();
        DirectoryResult r = c.findByExternalId(cid);
        Test.stopTest();

        Assert.isTrue(r.isSuccess());
        Assert.areEqual('111', (String) GoogleDirectoryClient.firstUser(r).get('id'));
        Assert.areEqual(1, GoogleDirectoryClient.userCount(r));

        String endpoint = mock.requests[0].getEndpoint();
        Assert.isTrue(endpoint.startsWith('callout:Google_Directory_API/admin/directory/v1/users?'), endpoint);
        Assert.isTrue(endpoint.contains('domain=shuraku.org'), endpoint);
        Assert.isTrue(endpoint.contains('query=' + EncodingUtil.urlEncode('externalId:' + cid, 'UTF-8')), endpoint);

        Directory_Sync_Log__c log = c.getPendingLogs()[0];
        Assert.areEqual('Lookup', log.Operation__c);
        Assert.isTrue(log.Success__c);
        Assert.areEqual(cid, log.Contact__c);
    }

    @IsTest
    static void findByExternalIdWithNoMatchReturnsNull() {
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, '{"kind":"admin#directory#users"}'));
        GoogleDirectoryClient c = client(contactId(), false);
        Test.startTest();
        DirectoryResult r = c.findByExternalId('003000000000001');
        Test.stopTest();

        Assert.isTrue(r.isSuccess());
        Assert.isNull(GoogleDirectoryClient.firstUser(r));
        Assert.areEqual(0, GoogleDirectoryClient.userCount(r));
    }

    @IsTest
    static void createUserSendsPasswordButNeverLogsIt() {
        DirectoryMock mock = new DirectoryMock().route('POST', '/users', 200, '{"id":"222","primaryEmail":"new.student@shuraku.org"}');
        Test.setMock(HttpCalloutMock.class, mock);
        String secret = 'S3cret-Value-For-Test';

        GoogleDirectoryClient c = client(contactId(), false);
        Test.startTest();
        DirectoryResult r = c.createUser(new Map<String, Object>{
            'primaryEmail' => 'new.student@shuraku.org',
            'password' => secret,
            'changePasswordAtNextLogin' => true
        });
        Test.stopTest();

        Assert.isTrue(r.isSuccess());
        Assert.areEqual('222', r.getString('id'));
        Assert.isTrue(mock.requests[0].getBody().contains(secret), 'Google must receive the password');

        Directory_Sync_Log__c log = c.getPendingLogs()[0];
        Assert.areEqual('Create', log.Operation__c);
        Assert.isFalse(log.Request_Summary__c.contains(secret), 'Password must never reach the log');
        Assert.isTrue(log.Request_Summary__c.contains('[REDACTED]'));
    }

    @IsTest
    static void duplicateCreateIsConflictAndNotRetryable() {
        Test.setMock(HttpCalloutMock.class, new DirectoryMock()
            .route('POST', '/users', 409, DirectoryMock.error(409, 'duplicate', 'Entity already exists.')));

        GoogleDirectoryClient c = client(contactId(), false);
        Test.startTest();
        DirectoryResult r = c.createUser(new Map<String, Object>{ 'primaryEmail' => 'taken@shuraku.org' });
        Test.stopTest();

        Assert.isTrue(r.isConflict());
        Assert.areEqual('duplicate', r.errorReason);
        Assert.isFalse(r.isRetryable());
        Assert.isFalse(c.getPendingLogs()[0].Success__c);
        Assert.areEqual('duplicate', c.getPendingLogs()[0].Error_Reason__c);
    }

    @IsTest
    static void forbiddenIsNotRetryableButQuotaIs() {
        DirectoryResult forbidden = new DirectoryResult(403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api'));
        DirectoryResult quota = new DirectoryResult(403, DirectoryMock.error(403, 'quotaExceeded', 'Quota exceeded'));
        DirectoryResult userRate = new DirectoryResult(403, DirectoryMock.error(403, 'userRateLimitExceeded', 'User rate limit exceeded'));

        Assert.isFalse(forbidden.isRetryable(), 'forbidden is a permission problem, never retried');
        Assert.isTrue(quota.isRetryable());
        Assert.isTrue(userRate.isRetryable());
    }

    @IsTest
    static void rateLimitAndServerErrorsAreRetryable() {
        Assert.isTrue(new DirectoryResult(429, null).isRetryable(), '429 with no body');
        Assert.isTrue(new DirectoryResult(503, '<html>Service Unavailable</html>').isRetryable(), '503 with non-JSON body');
        Assert.isFalse(new DirectoryResult(400, DirectoryMock.error(400, 'invalid', 'Invalid Input')).isRetryable());
        Assert.isFalse(new DirectoryResult(404, DirectoryMock.error(404, 'notFound', 'Resource Not Found')).isRetryable());
        Assert.isFalse(new DirectoryResult(200, '{}').isRetryable());
    }

    @IsTest
    static void dryRunSkipsWritesButAllowsReads() {
        // Only a read route exists: any write callout would throw UnexpectedCalloutException.
        DirectoryMock mock = new DirectoryMock().route('GET', '/users', 200, '{"users":[]}');
        Test.setMock(HttpCalloutMock.class, mock);

        GoogleDirectoryClient c = client(contactId(), true);
        Test.startTest();
        DirectoryResult read = c.findByExternalId('003000000000001');
        DirectoryResult write = c.createUser(new Map<String, Object>{ 'primaryEmail' => 'dry.run@shuraku.org', 'password' => 'x' });
        DirectoryResult patch = c.updateUser('333', new Map<String, Object>{ 'suspended' => true }, 'Suspend');
        Test.stopTest();

        Assert.areEqual(1, mock.requests.size(), 'Only the read should have been sent');
        Assert.isFalse(read.dryRun);
        Assert.isTrue(write.isSuccess() && write.dryRun);
        Assert.isTrue(patch.isSuccess() && patch.dryRun);

        List<Directory_Sync_Log__c> logs = c.getPendingLogs();
        Assert.areEqual(3, logs.size());
        Assert.isFalse(logs[0].Dry_Run__c);
        Assert.isTrue(logs[1].Dry_Run__c);
        Assert.isFalse(logs[1].Request_Summary__c.contains('"x"'), 'Dry-run logs are redacted too');
        Assert.areEqual('Suspend', logs[2].Operation__c);
    }

    @IsTest
    static void updateUserPatchesByGoogleId() {
        DirectoryMock mock = new DirectoryMock().route('PATCH', '/users/333', 200, '{"id":"333","orgUnitPath":"/Demo Students/Inactive"}');
        Test.setMock(HttpCalloutMock.class, mock);

        GoogleDirectoryClient c = client(contactId(), false);
        Test.startTest();
        DirectoryResult r = c.updateUser('333', new Map<String, Object>{ 'orgUnitPath' => '/Demo Students/Inactive' }, 'Move');
        Test.stopTest();

        Assert.isTrue(r.isSuccess());
        Assert.areEqual('PATCH', mock.requests[0].getMethod());
        Assert.isTrue(mock.requests[0].getBody().contains('/Demo Students/Inactive'));
        Assert.areEqual('Move', c.getPendingLogs()[0].Operation__c);
    }

    @IsTest
    static void groupMembershipCalls() {
        String groupPath = '/groups/' + EncodingUtil.urlEncode('program-mba@shuraku.org', 'UTF-8');
        DirectoryMock mock = new DirectoryMock()
            .route('POST', groupPath + '/members', 200, '{"id":"333","role":"MEMBER"}')
            .route('DELETE', groupPath + '/members/333', 204, null)
            .route('GET', '/groups', 200, '{"groups":[{"email":"Program-MBA@shuraku.org"},{"email":"term-fall-2026@shuraku.org"}]}');
        Test.setMock(HttpCalloutMock.class, mock);

        GoogleDirectoryClient c = client(contactId(), false);
        Test.startTest();
        DirectoryResult added = c.addMember('program-mba@shuraku.org', '333');
        DirectoryResult removed = c.removeMember('program-mba@shuraku.org', '333');
        DirectoryResult listed = c.listMemberships('333');
        Test.stopTest();

        Assert.isTrue(added.isSuccess());
        Assert.isTrue(mock.requests[0].getBody().contains('"id":"333"'), 'Members are keyed on Google user ID, not email');
        Assert.isTrue(removed.isSuccess(), '204 with empty body is success');
        Assert.isTrue(mock.requests[2].getEndpoint().contains('userKey=333'));
        Set<String> groups = GoogleDirectoryClient.groupEmails(listed);
        Assert.isTrue(groups.contains('program-mba@shuraku.org'), 'Group emails are normalized to lowercase');
        Assert.areEqual(2, groups.size());
    }

    @IsTest
    static void calloutFailureIsRetryableAndLogged() {
        Test.setMock(HttpCalloutMock.class, new DirectoryMock.Failing());

        GoogleDirectoryClient c = client(contactId(), false);
        Test.startTest();
        DirectoryResult r = c.findByExternalId('003000000000001');
        Test.stopTest();

        Assert.areEqual(0, r.statusCode);
        Assert.areEqual('calloutException', r.errorReason);
        Assert.isTrue(r.isRetryable());
        Assert.isFalse(c.getPendingLogs()[0].Success__c);
        Assert.isTrue(c.getPendingLogs()[0].Response_Summary__c.contains('Read timed out'));
    }

    @IsTest
    static void redactHandlesNestedAndNonJsonBodies() {
        String nested = '{"user":{"password":"abc","name":{"givenName":"A"}},"list":[{"hashFunction":"SHA-1"}]}';
        String out = GoogleDirectoryClient.redact(nested);
        Assert.isFalse(out.contains('abc'));
        Assert.isFalse(out.contains('SHA-1'));
        Assert.isTrue(out.contains('givenName'));
        Assert.areEqual('plain text', GoogleDirectoryClient.redact('plain text'));
        Assert.isNull(GoogleDirectoryClient.redact(null));
    }

    @IsTest
    static void fromSettingsReadsDefaultRecord() {
        Directory_Sync_Setting__mdt s = Directory_Sync_Setting__mdt.getInstance('Default');
        Assert.isNotNull(s, 'Default settings record must be deployed');

        DirectoryMock mock = new DirectoryMock().route('GET', '/users', 200, '{"users":[]}');
        Test.setMock(HttpCalloutMock.class, mock);
        Id cid = contactId();
        Test.startTest();
        GoogleDirectoryClient.fromSettings(cid).findByExternalId('x');
        Test.stopTest();

        Assert.isTrue(mock.requests[0].getEndpoint().contains('domain=' + EncodingUtil.urlEncode(s.Domain__c, 'UTF-8')));
    }
}
