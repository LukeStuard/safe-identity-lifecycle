@IsTest
private class UsernameNormalizerTest {

    private static final Id CONTACT_ID = '003000000012345AAA';

    private static String base(String first, String last) {
        return UsernameNormalizer.baseLocalPart(first, last, CONTACT_ID);
    }

    /** Every username, from any fixture, must satisfy Google's rules and ours. */
    private static void assertValid(String local) {
        Assert.isTrue(local.length() <= UsernameNormalizer.MAX_BASE, 'Too long: ' + local);
        Assert.isTrue(Pattern.matches('[a-z0-9][a-z0-9.-]*[a-z0-9]', local), 'Bad characters or edges: ' + local);
        Assert.isFalse(local.contains('..'), 'Consecutive periods: ' + local);
        Assert.isTrue(local.countMatches('.') <= 1, 'More than one period: ' + local);
    }

    @IsTest
    static void fixtures() {
        // first, last, expected
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'Jane', 'Doe', 'jane.doe' },
            new List<String>{ '  Luke ', 'Stuard ', 'luke.stuard' },
            new List<String>{ 'Mary Ann', 'Lee', 'maryann.lee' },
            new List<String>{ 'Ana', 'García López', 'ana.garcia-lopez' },
            new List<String>{ 'Jean-Luc', 'Picard', 'jean-luc.picard' },
            new List<String>{ 'Conan', 'O\'Brien', 'conan.obrien' },
            new List<String>{ 'Sinéad', 'O’Connor', 'sinead.oconnor' },
            new List<String>{ 'José', 'Núñez', 'jose.nunez' },
            new List<String>{ 'Jürgen', 'Müller', 'juergen.mueller' },
            new List<String>{ 'Hans', 'Straße', 'hans.strasse' },
            new List<String>{ 'Søren', 'Kierkegaard', 'soren.kierkegaard' },
            new List<String>{ 'Łukasz', 'Wałęsa', 'lukasz.walesa' },
            new List<String>{ 'Thị Minh', 'Nguyễn', 'thiminh.nguyen' },
            new List<String>{ 'Ayşe', 'Yılmaz', 'ayse.yilmaz' },
            new List<String>{ 'François', 'Dœuf', 'francois.doeuf' },
            new List<String>{ 'Robert (Bob)', 'Smith', 'robert.smith' },
            new List<String>{ 'J.R.', 'St. John', 'jr.st-john' },
            new List<String>{ 'Anne-Marie', 'van der  Berg', 'anne-marie.van-der-berg' },
            new List<String>{ 'Zoë', 'Smith-', 'zoe.smith' },
            new List<String>{ 'Émile', 'Zola Jr.', 'emile.zola-jr' }
        };
        for (List<String> c : cases) {
            String actual = base(c[0], c[1]);
            Assert.areEqual(c[2], actual, c[0] + ' / ' + c[1]);
            assertValid(actual);
        }
    }

    @IsTest
    static void onePartEmptyUsesTheOther() {
        Assert.areEqual('doe', base('', 'Doe'));
        Assert.areEqual('cher', base('Cher', null));
        Assert.areEqual('tanaka', base('明', 'Tanaka'), 'A part that cleans to nothing is dropped');
    }

    @IsTest
    static void bothPartsEmptyFallsBackToContactId() {
        String local = base('李', '王');
        Assert.areEqual('student.' + String.valueOf(CONTACT_ID).left(15).right(6).toLowerCase(), local);
        assertValid(local);
        Assert.isTrue(base(null, '   ').startsWith('student.'));
        Assert.isTrue(base('(Nickname)', '!!!').startsWith('student.'));
    }

    @IsTest
    static void longLastNameIsTrimmedFirst() {
        String longLast = 'Wolfeschlegelsteinhausenbergerdorffwelchevoralternwarengewissenhaft';
        String local = base('Hubert', longLast);
        assertValid(local);
        Assert.isTrue(local.startsWith('hubert.wolfeschlegel'), 'First name kept whole: ' + local);
        Assert.areEqual(UsernameNormalizer.MAX_BASE, local.length());
    }

    @IsTest
    static void bothPartsLongStillFit() {
        String a = 'Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';   // 40
        String b = 'Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';   // 40
        String local = base(a, b);
        assertValid(local);
        Assert.isTrue(local.substringAfter('.').length() >= 15, 'Last name keeps at least 15 characters: ' + local);
    }

    @IsTest
    static void truncationNeverLeavesTrailingHyphen() {
        // First name is 41 characters, leaving 20 for the last name; the 20th character is a hyphen.
        String last = 'Abcdefghijklmnopqrs-Tuvwxyzabcdefghijklmnopqrstuvwxyz';
        String local = base('Firstnamefortythreecharacterslongxxxxxxxx', last);
        assertValid(local);
        Assert.isTrue(local.endsWith('.abcdefghijklmnopqrs'), 'Trailing hyphen trimmed after the cut: ' + local);
    }

    @IsTest
    static void collisionSuffixes() {
        Assert.areEqual('jane.doe', UsernameNormalizer.localPart('jane.doe', 1));
        Assert.areEqual('jane.doe2', UsernameNormalizer.localPart('jane.doe', 2));
        String maxed = UsernameNormalizer.localPart('x'.repeat(UsernameNormalizer.MAX_BASE), 99);
        Assert.isTrue(maxed.length() <= UsernameNormalizer.MAX_LOCAL_PART, 'Longest base plus suffix fits');
        try {
            UsernameNormalizer.localPart('jane.doe', 100);
            Assert.fail('Expected an exception past 99');
        } catch (UsernameNormalizer.NormalizerException e) {
            Assert.isTrue(e.getMessage().contains('99'));
        }
    }

    @IsTest
    static void emailIsLowercase() {
        Assert.areEqual('jane.doe2@shuraku.org', UsernameNormalizer.email('jane.doe2', 'Shuraku.ORG'));
    }

    @IsTest
    static void displayNames() {
        Assert.areEqual('José', UsernameNormalizer.displayName('  José  ', 'x'), 'Unicode kept, trimmed');
        Assert.areEqual('Mary Ann', UsernameNormalizer.displayName('Mary   Ann', 'x'));
        Assert.areEqual('Doe', UsernameNormalizer.displayName('   ', 'Doe'), 'Blank falls back');
        Assert.areEqual('Bob', UsernameNormalizer.displayName('<Bob>', 'x'), 'Angle brackets removed');
        Assert.areEqual(40, UsernameNormalizer.displayName('A'.repeat(60), 'x').length());
        Assert.areEqual('李', UsernameNormalizer.displayName('李', 'x'), 'Non-Latin display names are kept');
    }
}