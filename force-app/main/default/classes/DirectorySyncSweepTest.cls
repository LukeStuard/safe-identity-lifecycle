@IsTest
private class DirectorySyncSweepTest {

    private static final String ENROLLED_OU = '/Demo Students/Enrolled';
    private static final String INACTIVE_OU = '/Demo Students/Inactive';

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

    private static Integer seq = 0;

    /** Unique name and email per Contact, so the org's duplicate rule never fires. */
    private static Contact student(String status, String googleId, String accountStatus) {
        seq++;
        Contact c = new Contact(
            FirstName = 'Jane', LastName = 'Sweep' + seq, Email = 'jane.sweep' + seq + '@example.com',
            Lifecycle_Status__c = status, Google_User_Id__c = googleId, Google_Account_Status__c = accountStatus
        );
        insert c;
        return c;
    }

    private static Map<String, Object> user(String id, String email, String ou, Boolean suspended, String sfId) {
        Map<String, Object> u = new Map<String, Object>{
            'id' => id, 'primaryEmail' => email, 'orgUnitPath' => ou, 'suspended' => suspended
        };
        if (sfId != null) {
            u.put('externalIds', new List<Object>{
                new Map<String, Object>{ 'type' => 'custom', 'customType' => 'salesforce_id', 'value' => sfId }
            });
        }
        return u;
    }

    private static String page(List<Map<String, Object>> users, String nextToken) {
        Map<String, Object> body = new Map<String, Object>{ 'users' => users };
        if (nextToken != null) {
            body.put('nextPageToken', nextToken);
        }
        return JSON.serialize(body);
    }

    private static void sweep(String body) {
        sweep(new DirectorySyncSweep(), 200, body);
    }

    private static void sweep(DirectorySyncSweep job, Integer status, String body) {
        DirectorySyncSweep.publishEvents = false;
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', status, body));
        job.injectedSettings = settings();
        Test.startTest();
        job.execute(null);
        Test.stopTest();
    }

    private static List<Directory_Sync_Log__c> findings() {
        return [
            SELECT Contact__c, Error_Reason__c, Alert_Status__c, Request_Summary__c, Response_Summary__c
            FROM Directory_Sync_Log__c
            WHERE Operation__c = 'Sweep' AND Error_Reason__c != null
            ORDER BY Name
        ];
    }

    private static Directory_Sync_Log__c only(String kind) {
        List<Directory_Sync_Log__c> rows = findings();
        Assert.areEqual(1, rows.size(), 'Findings: ' + rows);
        Assert.areEqual(kind, rows[0].Error_Reason__c);
        return rows[0];
    }

    private static Directory_Sync_Log__c summary() {
        List<Directory_Sync_Log__c> rows = [
            SELECT Request_Summary__c, Response_Summary__c FROM Directory_Sync_Log__c
            WHERE Operation__c = 'Sweep' AND Error_Reason__c = null AND Http_Status__c = null
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    // ---------------------------------------------------------------
    // Per-user checks
    // ---------------------------------------------------------------

    @IsTest
    static void matchingAccountIsQuiet() {
        Contact c = student('Enrolled', 'g1', 'Active');
        sweep(page(new List<Map<String, Object>>{
            user('g1', 'jane.doe@shuraku.org', ENROLLED_OU, false, c.Id),
            user('admin', 'luke@shuraku.org', '/', false, null)
        }, null));

        Assert.isTrue(findings().isEmpty(), 'No findings: ' + findings());
        Directory_Sync_Log__c s = summary();
        Assert.isTrue(s.Request_Summary__c.startsWith('Sweep complete: 1 page, 2 users'), s.Request_Summary__c);
        Assert.areEqual('Repaired (sync requested): 0. Reported: 0.', s.Response_Summary__c);
    }

    @IsTest
    static void wrongOuIsRepairedNotAlerted() {
        Contact c = student('Enrolled', 'g1', 'Active');
        sweep(page(new List<Map<String, Object>>{
            user('g1', 'jane.doe@shuraku.org', '/Demo Students/Admitted', false, c.Id)
        }, null));

        Directory_Sync_Log__c f = only('drift');
        Assert.areEqual(c.Id, f.Contact__c);
        Assert.isNull(f.Alert_Status__c, 'Repairs go through the job, which alerts on its own failures');
        Assert.isTrue(f.Response_Summary__c.contains('expected OU ' + ENROLLED_OU), f.Response_Summary__c);
        Assert.isTrue(f.Response_Summary__c.contains('Sync requested'), f.Response_Summary__c);
        Assert.areEqual(new List<Id>{ c.Id }, DirectorySyncSweep.republishedIds);
        Assert.areEqual('Repaired (sync requested): 1. Reported: 0.', summary().Response_Summary__c);
    }

    @IsTest
    static void failedPublishIsReported() {
        Contact c = student('Enrolled', 'g1', 'Active');
        DirectorySyncSweep.forcePublishError = 'INSUFFICIENT_ACCESS_OR_READONLY insufficient access rights';
        sweep(page(new List<Map<String, Object>>{
            user('g1', 'jane.doe@shuraku.org', '/Demo Students/Admitted', false, c.Id)
        }, null));

        List<Directory_Sync_Log__c> rows = findings();
        Assert.areEqual(2, rows.size(), 'drift plus publishFailed: ' + rows);
        Directory_Sync_Log__c failed = rows[1];
        Assert.areEqual('publishFailed', failed.Error_Reason__c);
        Assert.areEqual('Pending', failed.Alert_Status__c, 'A repair that never started must reach the digest');
        Assert.isTrue(failed.Response_Summary__c.contains(String.valueOf(c.Id) + ': INSUFFICIENT_ACCESS'), failed.Response_Summary__c);
        Assert.isTrue(summary().Response_Summary__c.contains('Reported: 1.'), summary().Response_Summary__c);
    }

    @IsTest
    static void activeAccountForWithdrawnStudentIsDrift() {
        Contact c = student('Withdrawn', 'g1', 'Suspended');
        sweep(page(new List<Map<String, Object>>{
            user('g1', 'jane.doe@shuraku.org', ENROLLED_OU, false, c.Id)
        }, null));

        Directory_Sync_Log__c f = only('drift');
        Assert.isTrue(f.Response_Summary__c.contains('expected suspended'), f.Response_Summary__c);
        Assert.isTrue(f.Response_Summary__c.contains('expected OU ' + INACTIVE_OU), f.Response_Summary__c);
        Assert.areEqual(new List<Id>{ c.Id }, DirectorySyncSweep.republishedIds);
    }

    @IsTest
    static void unrecordedGoogleIdIsDrift() {
        Contact c = student('Enrolled', null, 'Error');
        sweep(page(new List<Map<String, Object>>{
            user('g1', 'jane.doe@shuraku.org', ENROLLED_OU, false, c.Id)
        }, null));

        Assert.isTrue(only('drift').Response_Summary__c.contains('Contact records Google ID null'));
        Assert.areEqual(new List<Id>{ c.Id }, DirectorySyncSweep.republishedIds);
    }

    @IsTest
    static void outOfTreeIsReported() {
        Contact c = student('Enrolled', 'g1', 'Active');
        sweep(page(new List<Map<String, Object>>{
            user('g1', 'jane.doe@shuraku.org', '/Staff', false, c.Id)
        }, null));

        Directory_Sync_Log__c f = findings()[0];
        Assert.areEqual('outOfTree', f.Error_Reason__c);
        Assert.isTrue(DirectorySyncSweep.republishedIds.isEmpty(), 'Report only');
        Assert.areEqual('Pending', f.Alert_Status__c);
        Assert.isTrue(f.Response_Summary__c.contains('Report only'), f.Response_Summary__c);
    }

    @IsTest
    static void unmanagedUserInTreeIsReported() {
        sweep(page(new List<Map<String, Object>>{
            user('g9', 'stray@shuraku.org', '/Demo Students/Admitted', false, null)
        }, null));

        Directory_Sync_Log__c f = only('unmanagedInTree');
        Assert.areEqual('Pending', f.Alert_Status__c);
        Assert.isTrue(f.Request_Summary__c.startsWith('stray@shuraku.org (g9) in /Demo Students/Admitted'), f.Request_Summary__c);
    }

    @IsTest
    static void orphanIsReportedWithoutContactLink() {
        sweep(page(new List<Map<String, Object>>{
            user('g9', 'gone@shuraku.org', ENROLLED_OU, false, '003000000000999AAA')
        }, null));

        Directory_Sync_Log__c f = only('orphan');
        Assert.isNull(f.Contact__c);
        Assert.areEqual('Pending', f.Alert_Status__c);
    }

    @IsTest
    static void usersOutsideTreeWithoutIdAreIgnored() {
        sweep(page(new List<Map<String, Object>>{
            user('a', 'luke@shuraku.org', '/', false, null),
            user('b', 'staff@shuraku.org', '/Staff', true, null)
        }, null));
        Assert.isTrue(findings().isEmpty());
    }

    // ---------------------------------------------------------------
    // End-of-sweep checks
    // ---------------------------------------------------------------

    @IsTest
    static void recordedAccountMissingFromGoogleIsReported() {
        Contact c = student('Enrolled', 'gone', 'Active');
        sweep(page(new List<Map<String, Object>>(), null));

        Directory_Sync_Log__c f = only('missingAccount');
        Assert.areEqual(c.Id, f.Contact__c);
        Assert.areEqual('Pending', f.Alert_Status__c, 'Never recreated automatically');
        Assert.isTrue(DirectorySyncSweep.republishedIds.isEmpty(), 'Report only');
    }

    @IsTest
    static void neverProvisionedIsRepaired() {
        Contact c = student('Enrolled', null, null);
        student('Enrolled', null, 'Error');      // failed earlier: already alerted, skipped
        sweep(page(new List<Map<String, Object>>(), null));

        Directory_Sync_Log__c f = only('neverProvisioned');
        Assert.areEqual(c.Id, f.Contact__c);
        Assert.isNull(f.Alert_Status__c);
        Assert.areEqual(new List<Id>{ c.Id }, DirectorySyncSweep.republishedIds, 'The Error Contact is skipped');
    }

    // ---------------------------------------------------------------
    // Paging and failures
    // ---------------------------------------------------------------

    @IsTest
    static void firstOfSeveralPagesSkipsEndChecks() {
        student('Enrolled', 'g-later', 'Active');   // on a later page
        sweep(page(new List<Map<String, Object>>(), 'token-2'));

        Assert.isTrue(findings().isEmpty(), 'missingAccount waits for the last page');
        Assert.isNull(summary(), 'No summary until the sweep ends');
    }

    @IsTest
    static void lastPageUsesIdsSeenOnEarlierPages() {
        Contact c = student('Enrolled', 'g1', 'Active');
        DirectorySyncSweep job = new DirectorySyncSweep(
            'token-2', 2, new Set<String>{ String.valueOf(c.Id) }, new Map<String, Integer>{ 'users' => 500 }
        );
        sweep(job, 200, page(new List<Map<String, Object>>(), null));

        Assert.isTrue(findings().isEmpty(), 'Seen on page 1, so not missing');
        Assert.isTrue(summary().Request_Summary__c.startsWith('Sweep complete: 2 pages, 500 users'), summary().Request_Summary__c);
    }

    @IsTest
    static void chainLimitTruncatesAndAlerts() {
        student('Enrolled', 'g1', 'Active');
        DirectorySyncSweep job = new DirectorySyncSweep(
            'token-5', DirectorySyncSweep.MAX_PAGES, new Set<String>(), new Map<String, Integer>{ 'users' => 2000 }
        );
        sweep(job, 200, page(new List<Map<String, Object>>(), 'token-6'));

        Directory_Sync_Log__c f = only('sweepTruncated');
        Assert.areEqual('Pending', f.Alert_Status__c);
        Assert.isTrue(summary().Request_Summary__c.startsWith('Sweep truncated'));
    }

    @IsTest
    static void listFailureIsAlerted() {
        sweep(new DirectorySyncSweep(), 403, DirectoryMock.error(403, 'forbidden', 'Not Authorized to access this resource/api'));

        Directory_Sync_Log__c row = [SELECT Success__c, Error_Reason__c, Alert_Status__c FROM Directory_Sync_Log__c WHERE Operation__c = 'Sweep'];
        Assert.isFalse(row.Success__c);
        Assert.areEqual('forbidden', row.Error_Reason__c);
        Assert.areEqual('Pending', row.Alert_Status__c);
        Assert.isNull(summary());
    }

    @IsTest
    static void listRequestAsksOnlyForComparedFields() {
        DirectoryMock mock = new DirectoryMock().route('GET', '/users', 200, page(new List<Map<String, Object>>(), null));
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        new GoogleDirectoryClient(null, 'shuraku.org', false).listUsers('abc');
        Test.stopTest();
        String endpoint = EncodingUtil.urlDecode(mock.requests[0].getEndpoint(), 'UTF-8');
        Assert.isTrue(endpoint.contains('maxResults=500'), endpoint);
        Assert.isTrue(endpoint.contains('fields=nextPageToken,users(id,primaryEmail,suspended,orgUnitPath,externalIds)'), endpoint);
        Assert.isTrue(endpoint.contains('pageToken=abc'), endpoint);
    }

    // ---------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------

    @IsTest
    static void sweepEventStartsSweep() {
        DirectorySyncConfig.settingsOverride = settings();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, page(new List<Map<String, Object>>(), null)));

        Test.startTest();
        DirectorySyncRequestHandler.handle(new List<Directory_Sync_Request__e>{ new Directory_Sync_Request__e(Kind__c = 'Sweep') });
        Assert.areEqual(1, Limits.getQueueableJobs(), 'One sweep job, no Contact jobs');
        Test.stopTest();

        Assert.isNotNull(summary(), 'The sweep ran');
    }

    @IsTest
    static void requestPublishesAndScheduleRuns() {
        // Published events are delivered in the test, so the sweep may run: give it a mock.
        DirectorySyncConfig.settingsOverride = settings();
        Test.setMock(HttpCalloutMock.class, new DirectoryMock().route('GET', '/users', 200, page(new List<Map<String, Object>>(), null)));
        Assert.isTrue(DirectorySyncSweep.request());
        Test.startTest();
        System.schedule('Directory Sync Sweep test', '0 23 8 * * ?', new DirectorySyncSweepSchedule());
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Directory Sync Sweep test']);
    }
}
