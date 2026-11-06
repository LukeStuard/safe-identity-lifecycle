/**
 * Thin HTTP layer over the Google Admin SDK Directory API.
 *
 * - Authentication is handled entirely by the Named Credential
 *   (External Credential, JWT protocol). No tokens in Apex.
 * - No business logic: callers decide what to create, move, or suspend.
 * - No DML: every call queues a Directory_Sync_Log__c row in memory.
 *   The caller inserts getPendingLogs() after its last callout, because
 *   DML before a callout in the same transaction blocks later callouts.
 * - Dry run: reads go through; writes are skipped and logged as dry run.
 * - Secrets (password, hashFunction) are redacted before anything is logged.
 */
public inherited sharing class GoogleDirectoryClient {

    @TestVisible
    private static final String BASE = 'callout:Google_Directory_API/admin/directory/v1';
    private static final Integer MAX_SUMMARY = 32000;
    private static final Integer TIMEOUT_MS = 20000;
    private static final Set<String> SECRET_KEYS = new Set<String>{ 'password', 'hashfunction' };

    private final Id contactId;
    private final String domain;
    private final Boolean dryRun;
    private final List<Directory_Sync_Log__c> pendingLogs = new List<Directory_Sync_Log__c>();

    public GoogleDirectoryClient(Id contactId, String domain, Boolean dryRun) {
        this.contactId = contactId;
        this.domain = domain;
        this.dryRun = dryRun == true;
    }

    /** Builds a client from Directory_Sync_Setting__mdt.Default. */
    public static GoogleDirectoryClient fromSettings(Id contactId) {
        Directory_Sync_Setting__mdt s = Directory_Sync_Setting__mdt.getInstance('Default');
        if (s == null) {
            throw new DirectoryClientException('Directory_Sync_Setting__mdt record "Default" is missing.');
        }
        return new GoogleDirectoryClient(contactId, s.Domain__c, s.Dry_Run__c);
    }

    // ---------------------------------------------------------------
    // Users
    // ---------------------------------------------------------------

    /**
     * Idempotency lookup: finds users whose externalIds contain this value.
     * maxResults=2 so a caller can detect the "more than one match" anomaly.
     */
    public DirectoryResult findByExternalId(String externalId) {
        String path = '/users?domain=' + enc(domain)
            + '&query=' + enc('externalId:' + externalId)
            + '&maxResults=2';
        return send('GET', path, null, 'Lookup', false);
    }

    /** users.get by primary email, alias, or Google user ID. Used to tell whose name a 409 belongs to. */
    public DirectoryResult getUser(String userKey) {
        return send('GET', '/users/' + enc(userKey), null, 'Lookup', false);
    }

    public DirectoryResult createUser(Map<String, Object> user) {
        return send('POST', '/users', JSON.serialize(user), 'Create', true);
    }

    /**
     * users.patch. One method covers suspend, reactivate, OU move, and rename;
     * the operation label only affects the log row.
     */
    public DirectoryResult updateUser(String googleUserId, Map<String, Object> patch, String operation) {
        return send('PATCH', '/users/' + enc(googleUserId), JSON.serialize(patch), operation, true);
    }

    // ---------------------------------------------------------------
    // Groups
    // ---------------------------------------------------------------

    public DirectoryResult addMember(String groupKey, String googleUserId) {
        Map<String, Object> member = new Map<String, Object>{ 'id' => googleUserId, 'role' => 'MEMBER' };
        return send('POST', '/groups/' + enc(groupKey) + '/members', JSON.serialize(member), 'Group Add', true);
    }

    public DirectoryResult removeMember(String groupKey, String googleUserId) {
        return send('DELETE', '/groups/' + enc(groupKey) + '/members/' + enc(googleUserId), null, 'Group Remove', true);
    }

    /** Groups the user currently belongs to. */
    public DirectoryResult listMemberships(String googleUserId) {
        return send('GET', '/groups?userKey=' + enc(googleUserId) + '&maxResults=200', null, 'Lookup', false);
    }

    // ---------------------------------------------------------------
    // Result helpers
    // ---------------------------------------------------------------

    /** First user in a users.list result, or null when none matched. */
    public static Map<String, Object> firstUser(DirectoryResult r) {
        List<Object> users = listOf(r, 'users');
        return users.isEmpty() ? null : (Map<String, Object>) users[0];
    }

    public static Integer userCount(DirectoryResult r) {
        return listOf(r, 'users').size();
    }

    /** Group emails from a groups.list result. */
    public static Set<String> groupEmails(DirectoryResult r) {
        Set<String> emails = new Set<String>();
        for (Object g : listOf(r, 'groups')) {
            Object email = ((Map<String, Object>) g).get('email');
            if (email != null) {
                emails.add(String.valueOf(email).toLowerCase());
            }
        }
        return emails;
    }

    public List<Directory_Sync_Log__c> getPendingLogs() {
        return pendingLogs;
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    private DirectoryResult send(String method, String path, String body, String operation, Boolean isWrite) {
        DirectoryResult result;
        Boolean skipped = isWrite && dryRun;
        if (skipped) {
            result = DirectoryResult.dryRunResult();
        } else {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(BASE + path);
            req.setMethod(method);
            req.setTimeout(TIMEOUT_MS);
            if (body != null) {
                req.setHeader('Content-Type', 'application/json');
                req.setBody(body);
            }
            try {
                HttpResponse res = new Http().send(req);
                result = new DirectoryResult(res.getStatusCode(), res.getBody());
            } catch (CalloutException e) {
                result = DirectoryResult.calloutFailure(e.getMessage());
            }
        }
        pendingLogs.add(new Directory_Sync_Log__c(
            Contact__c = contactId,
            Operation__c = operation,
            Success__c = result.isSuccess(),
            Http_Status__c = result.statusCode,
            Error_Reason__c = truncate(result.errorReason, 255),
            Dry_Run__c = skipped,
            Request_Summary__c = truncate(method + ' ' + path + (body == null ? '' : '\n' + redact(body)), MAX_SUMMARY),
            Response_Summary__c = truncate(redact(result.rawBody != null ? result.rawBody : result.errorMessage), MAX_SUMMARY)
        ));
        return result;
    }

    private static List<Object> listOf(DirectoryResult r, String key) {
        if (r == null || !r.isSuccess() || r.body == null) {
            return new List<Object>();
        }
        Object v = r.body.get(key);
        return v instanceof List<Object> ? (List<Object>) v : new List<Object>();
    }

    @TestVisible
    private static String redact(String raw) {
        if (String.isBlank(raw)) {
            return raw;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(raw);
        } catch (JSONException e) {
            return raw;
        }
        return JSON.serialize(scrub(parsed));
    }

    private static Object scrub(Object node) {
        if (node instanceof Map<String, Object>) {
            Map<String, Object> source = (Map<String, Object>) node;
            Map<String, Object> clean = new Map<String, Object>();
            for (String key : source.keySet()) {
                clean.put(key, SECRET_KEYS.contains(key.toLowerCase()) ? (Object) '[REDACTED]' : scrub(source.get(key)));
            }
            return clean;
        }
        if (node instanceof List<Object>) {
            List<Object> clean = new List<Object>();
            for (Object item : (List<Object>) node) {
                clean.add(scrub(item));
            }
            return clean;
        }
        return node;
    }

    private static String enc(String value) {
        return value == null ? '' : EncodingUtil.urlEncode(value, 'UTF-8');
    }

    private static String truncate(String value, Integer max) {
        return value == null || value.length() <= max ? value : value.left(max);
    }

    public class DirectoryClientException extends Exception {}
}
