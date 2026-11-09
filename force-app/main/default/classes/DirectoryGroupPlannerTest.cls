@IsTest
private class DirectoryGroupPlannerTest {

    private static Directory_Group_Mapping__mdt row(String program, String term, String email) {
        return new Directory_Group_Mapping__mdt(Program__c = program, Term__c = term, Group_Email__c = email);
    }

    private static List<Directory_Group_Mapping__mdt> rows() {
        return new List<Directory_Group_Mapping__mdt>{
            row('MBA', null, 'Program-MBA@shuraku.org'),
            row('MS Analytics', null, 'program-ms-analytics@shuraku.org'),
            row(null, 'Fall 2026', 'term-fall-2026@shuraku.org'),
            row('MBA', 'Fall 2026', 'mba-fall-2026@shuraku.org'),
            row(null, null, 'ignored-no-keys@shuraku.org')
        };
    }

    @IsTest
    static void desiredMatchesFilledKeysOnly() {
        Set<String> d = DirectoryGroupPlanner.desired('MBA', 'Fall 2026', rows());
        Assert.areEqual(new Set<String>{
            'program-mba@shuraku.org', 'term-fall-2026@shuraku.org', 'mba-fall-2026@shuraku.org'
        }, d, 'Program, term, and cohort rows apply; emails lowercased; keyless row ignored');
    }

    @IsTest
    static void cohortNeedsBothKeys() {
        Set<String> d = DirectoryGroupPlanner.desired('MBA', 'Spring 2027', rows());
        Assert.areEqual(new Set<String>{ 'program-mba@shuraku.org' }, d);
    }

    @IsTest
    static void blankContactValuesMatchOnlyWildcards() {
        Assert.areEqual(new Set<String>{ 'term-fall-2026@shuraku.org' },
            DirectoryGroupPlanner.desired(null, 'Fall 2026', rows()));
        Assert.isTrue(DirectoryGroupPlanner.desired(null, null, rows()).isEmpty());
    }

    @IsTest
    static void diffNeverTouchesUnmanagedGroups() {
        Set<String> managed = DirectoryGroupPlanner.managed(rows());
        Set<String> current = new Set<String>{ 'program-mba@shuraku.org', 'book-club@shuraku.org' };
        Set<String> desired = new Set<String>{ 'program-ms-analytics@shuraku.org' };

        DirectoryGroupPlanner.Diff d = DirectoryGroupPlanner.diff(desired, current, managed);
        Assert.areEqual(new Set<String>{ 'program-ms-analytics@shuraku.org' }, d.toAdd);
        Assert.areEqual(new Set<String>{ 'program-mba@shuraku.org' }, d.toRemove);
        Assert.isFalse(d.toRemove.contains('book-club@shuraku.org'));
    }

    @IsTest
    static void matchingSetsGiveEmptyDiff() {
        Set<String> s = new Set<String>{ 'program-mba@shuraku.org' };
        Assert.isTrue(DirectoryGroupPlanner.diff(s, s, s).isEmpty());
    }
}
