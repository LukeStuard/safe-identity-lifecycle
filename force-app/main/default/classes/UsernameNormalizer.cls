/**
 * Builds Google usernames (first.last) and display names from Contact names.
 *
 * Username rules:
 * - Parenthetical nicknames are dropped: "Robert (Bob)" -> "robert".
 * - Accents and special letters are transliterated: "José" -> "jose",
 *   "Müller" -> "mueller", "Straße" -> "strasse", "Łukasz" -> "lukasz".
 * - Apostrophes are dropped: "O'Brien" -> "obrien". Periods act as spaces.
 * - First name: spaces removed ("Mary Ann" -> "maryann").
 *   Last name: spaces become hyphens ("García López" -> "garcia-lopez").
 * - Output contains only a-z, 0-9, hyphen, and the single separating period.
 * - A part that cleans to nothing falls back to the other part alone; if both
 *   are empty (for example, a name in a non-Latin script), the username is
 *   "student." plus six characters of the Contact ID.
 * - The base is capped at 62 characters so a collision suffix (2 to 99) always
 *   fits in Google's 64-character limit. The last name is trimmed first.
 *
 * Display names keep Unicode, are trimmed and whitespace-collapsed, and are
 * capped at 60 characters (the limit Google enforces, confirmed live 2026-11-09).
 */
public inherited sharing class UsernameNormalizer {

    public static final Integer MAX_LOCAL_PART = 64;
    public static final Integer MAX_SUFFIX = 99;
    public static final Integer MAX_BASE = MAX_LOCAL_PART - 2;   // room for a 2-digit suffix
    public static final Integer MAX_DISPLAY_NAME = 60;
    private static final Integer MIN_LAST_WHEN_TRIMMING = 15;

    private static final Set<String> APOSTROPHES = new Set<String>{ '\'', '’', '‘', '`', 'ʼ' };
    private static Map<String, String> transliterations;

    // ---------------------------------------------------------------
    // Usernames
    // ---------------------------------------------------------------

    /** The collision-free base, e.g. "jane.doe". Never longer than MAX_BASE. */
    public static String baseLocalPart(String firstName, String lastName, Id contactId) {
        String first = cleanFirst(firstName);
        String last = cleanLast(lastName);

        if (String.isBlank(first) && String.isBlank(last)) {
            String suffix = contactId == null ? '000000' : String.valueOf(contactId).left(15).right(6).toLowerCase();
            return 'student.' + suffix;
        }
        if (String.isBlank(first)) {
            return trimHyphens(last.left(MAX_BASE));
        }
        if (String.isBlank(last)) {
            return trimHyphens(first.left(MAX_BASE));
        }

        if (first.length() + 1 + last.length() > MAX_BASE) {
            Integer roomForLast = Math.max(MAX_BASE - first.length() - 1, MIN_LAST_WHEN_TRIMMING);
            last = trimHyphens(last.left(roomForLast));
        }
        if (first.length() + 1 + last.length() > MAX_BASE) {
            first = trimHyphens(first.left(MAX_BASE - last.length() - 1));
        }
        return first + '.' + last;
    }

    /** Attempt 1 is the base itself; attempt 2 appends "2", and so on up to 99. */
    public static String localPart(String base, Integer attempt) {
        if (attempt == null || attempt < 1 || attempt > MAX_SUFFIX) {
            throw new NormalizerException('Collision attempt must be between 1 and ' + MAX_SUFFIX + '.');
        }
        return attempt == 1 ? base : base + attempt;
    }

    public static String email(String localPart, String domain) {
        return (localPart + '@' + domain).toLowerCase();
    }

    @TestVisible
    private static String cleanFirst(String raw) {
        return finish(prepare(raw).replaceAll('\\s+', ''));
    }

    @TestVisible
    private static String cleanLast(String raw) {
        return finish(prepare(raw).replaceAll('\\s+', '-'));
    }

    /** Shared steps: drop nicknames, lowercase, transliterate, drop apostrophes, periods to spaces. */
    private static String prepare(String raw) {
        if (raw == null) {
            return '';
        }
        String s = raw.replaceAll('\\([^)]*\\)', ' ').trim().toLowerCase();
        s = transliterate(s);
        String out = '';
        for (Integer cp : s.getChars()) {
            String ch = String.fromCharArray(new List<Integer>{ cp });
            if (APOSTROPHES.contains(ch)) {
                continue;
            }
            out += ch == '.' ? ' ' : ch;
        }
        return out.trim();
    }

    /** Keep only a-z, 0-9, hyphen; collapse hyphen runs; trim hyphens. */
    private static String finish(String s) {
        return trimHyphens(s.replaceAll('[^a-z0-9-]', '').replaceAll('-+', '-'));
    }

    private static String trimHyphens(String s) {
        return s == null ? '' : s.replaceAll('^-+', '').replaceAll('-+$', '');
    }

    @TestVisible
    private static String transliterate(String s) {
        if (transliterations == null) {
            transliterations = buildTransliterations();
        }
        String out = '';
        for (Integer cp : s.getChars()) {
            String ch = String.fromCharArray(new List<Integer>{ cp });
            String mapped = transliterations.get(ch);
            out += mapped == null ? ch : mapped;
        }
        return out;
    }

    private static Map<String, String> buildTransliterations() {
        Map<String, String> m = new Map<String, String>();
        addAll(m, 'àáâãåāăąǎạảấầẩẫậắằẳẵặ', 'a');
        addAll(m, 'çćĉċč', 'c');
        addAll(m, 'ďđð', 'd');
        addAll(m, 'èéêëēĕėęěẹẻẽếềểễệ', 'e');
        addAll(m, 'ĝğġģ', 'g');
        addAll(m, 'ĥħ', 'h');
        addAll(m, 'ìíîïĩīĭįıǐỉị', 'i');
        addAll(m, 'ĵ', 'j');
        addAll(m, 'ķ', 'k');
        addAll(m, 'ĺļľŀł', 'l');
        addAll(m, 'ñńņňŉ', 'n');
        addAll(m, 'òóôõōŏőǒọỏốồổỗộớờởỡợơø', 'o');
        addAll(m, 'ŕŗř', 'r');
        addAll(m, 'śŝşšș', 's');
        addAll(m, 'ţťŧț', 't');
        addAll(m, 'ùúûũūŭůűųưǔụủứừửữự', 'u');
        addAll(m, 'ŵ', 'w');
        addAll(m, 'ýÿŷỳỵỷỹ', 'y');
        addAll(m, 'źżž', 'z');
        m.put('ä', 'ae');
        m.put('æ', 'ae');
        m.put('ö', 'oe');
        m.put('œ', 'oe');
        m.put('ü', 'ue');
        m.put('ß', 'ss');
        m.put('þ', 'th');
        return m;
    }

    private static void addAll(Map<String, String> m, String sources, String target) {
        for (Integer cp : sources.getChars()) {
            m.put(String.fromCharArray(new List<Integer>{ cp }), target);
        }
    }

    // ---------------------------------------------------------------
    // Display names
    // ---------------------------------------------------------------

    /** Google givenName or familyName: Unicode kept, trimmed, capped. Falls back when blank. */
    public static String displayName(String raw, String fallback) {
        String s = raw == null ? '' : raw.replaceAll('[<>]', '').replaceAll('\\s+', ' ').trim();
        if (String.isBlank(s)) {
            s = fallback == null ? '' : fallback.trim();
        }
        return s.left(MAX_DISPLAY_NAME).trim();
    }

    public class NormalizerException extends Exception {}
}