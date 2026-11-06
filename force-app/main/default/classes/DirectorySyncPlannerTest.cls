@IsTest
private class DirectorySyncPlannerTest {

    private static Directory_Status_Mapping__mdt mapping(String status, String state, String ou) {
        return new Directory_Status_Mapping__mdt(Status__c = status, Target_State__c = state, Target_OU__c = ou);
    }

    private static DirectoryResult users(String json) {
        return new DirectoryResult(200, json);
    }

    private static final String NONE_FOUND = '{"users":[]}';
    private static final Directory_Status_Mapping__mdt ADMITTED = mapping('Admitted', 'Active', '/Demo Students/Admitted');
    private static final Directory_Status_Mapping__mdt ENROLLED = mapping('Enrolled', 'Active', '/Demo Students/Enrolled');
    private static final Directory_Status_Mapping__mdt WITHDRAWN = mapping('Withdrawn', 'Suspended', '/Demo Students/Inactive');

    @IsTest
    static void missingMappingFailsClosed() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Mystery', null, null);
        Assert.areEqual('NONE', p.action);
        Assert.isTrue(p.reason.contains('fails closed'));
    }

    @IsTest
    static void noneTargetDoesNothing() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Applied', mapping('Applied', 'None', null), null);
        Assert.areEqual('NONE', p.action);
    }

    @IsTest
    static void activeWithNoAccountCreates() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Admitted', ADMITTED, users(NONE_FOUND));
        Assert.areEqual('CREATE', p.action);
        Assert.isTrue(p.steps[0].contains('/Demo Students/Admitted'));
    }

    @IsTest
    static void activeInRightOuIsInSync() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Admitted', ADMITTED,
            users('{"users":[{"id":"1","orgUnitPath":"/Demo Students/Admitted","suspended":false}]}'));
        Assert.areEqual('NONE', p.action);
        Assert.isTrue(p.steps.isEmpty());
    }

    @IsTest
    static void activeInWrongOuMoves() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Enrolled', ENROLLED,
            users('{"users":[{"id":"1","orgUnitPath":"/Demo Students/Admitted","suspended":false}]}'));
        Assert.areEqual('MOVE', p.action);
        Assert.areEqual(1, p.steps.size());
    }

    @IsTest
    static void activeButSuspendedReactivatesAndMoves() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Enrolled', ENROLLED,
            users('{"users":[{"id":"1","orgUnitPath":"/Demo Students/Inactive","suspended":true}]}'));
        Assert.areEqual('REACTIVATE', p.action);
        Assert.areEqual('Reactivate', p.steps[0]);
        Assert.isTrue(p.steps[1].startsWith('Move'));
    }

    @IsTest
    static void suspendedTargetSuspendsMovesAndDropsGroups() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Withdrawn', WITHDRAWN,
            users('{"users":[{"id":"1","orgUnitPath":"/Demo Students/Enrolled","suspended":false}]}'));
        Assert.areEqual('SUSPEND', p.action);
        Assert.areEqual(3, p.steps.size());
    }

    @IsTest
    static void suspendedTargetAlreadySuspendedIsInSync() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Withdrawn', WITHDRAWN,
            users('{"users":[{"id":"1","orgUnitPath":"/Demo Students/Inactive","suspended":true}]}'));
        Assert.areEqual('NONE', p.action);
    }

    @IsTest
    static void suspendedTargetWithNoAccountDoesNothing() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Withdrawn', WITHDRAWN, users(NONE_FOUND));
        Assert.areEqual('NONE', p.action);
    }

    @IsTest
    static void failedLookupIsAnError() {
        DirectoryResult failed = new DirectoryResult(403, DirectoryMock.error(403, 'quotaExceeded', 'Quota exceeded'));
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Admitted', ADMITTED, failed);
        Assert.areEqual('ERROR', p.action);
        Assert.areEqual('quotaExceeded', p.errorReason);
    }

    @IsTest
    static void multipleMatchesIsAnError() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Admitted', ADMITTED,
            users('{"users":[{"id":"1"},{"id":"2"}]}'));
        Assert.areEqual('ERROR', p.action);
        Assert.areEqual('multipleMatches', p.errorReason);
    }

    @IsTest
    static void unknownTargetStateIsAnError() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Odd', mapping('Odd', 'Archived', null), users(NONE_FOUND));
        Assert.areEqual('ERROR', p.action);
        Assert.areEqual('unknownTargetState', p.errorReason);
    }

    @IsTest
    static void planLogDescribesDecision() {
        DirectorySyncPlanner.Plan p = DirectorySyncPlanner.plan('Admitted', ADMITTED, users(NONE_FOUND));
        Directory_Sync_Log__c log = p.toLog(null, 'Admitted', ADMITTED);
        Assert.areEqual('Plan', log.Operation__c);
        Assert.isTrue(log.Dry_Run__c);
        Assert.isTrue(log.Success__c);
        Assert.areEqual('Status "Admitted" -> Active in /Demo Students/Admitted', log.Request_Summary__c);
        Assert.isTrue(log.Response_Summary__c.startsWith('CREATE'));
    }
}
