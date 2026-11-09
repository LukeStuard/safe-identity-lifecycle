/**
 * Reconciliation sweep: compares every Google user in the domain with the
 * Contacts the integration user can see, one users.list page (500 users) per
 * job.
 *
 * Findings, one Sweep log row each:
 * - drift (repaired): an in-scope Contact whose account has the wrong
 *   suspended state or OU for its Lifecycle Status, or whose Contact does not
 *   record the account's Google ID. The sweep republishes a sync request; the
 *   normal job repairs it with its own retries and alerts.
 * - neverProvisioned (repaired): a Contact whose status calls for an active
 *   account, with no account, no recorded Google ID, and no earlier attempt.
 * - outOfTree (report): a user outside TREE_ROOT carrying a salesforce_id.
 * - unmanagedInTree (report): a user inside TREE_ROOT with no salesforce_id.
 * - orphan (report): a user inside TREE_ROOT whose salesforce_id matches no
 *   Contact in scope (deleted, or its Account is out of scope).
 * - missingAccount (report): a Contact records a Google ID, but no user
 *   carries its salesforce_id. Not recreated automatically: someone removed
 *   the account in Google, and that is a decision for a person.
 * Report-only findings are marked for the alert digest and change nothing.
 *
 * Not checked: group membership (one call per user; the job reconciles groups
 * on every event). Contacts that failed before (status Error) are skipped,
 * since the job already alerted on them.
 *
 * Paging chains one job per page, carrying the salesforce_ids seen so far.
 * Developer Edition caps a Queueable chain at 5, so a sweep covers at most
 * 2,500 users; past that it records sweepTruncated and skips the end-of-sweep
 * checks, which would otherwise report false missing accounts.
 *
 * Every callout happens before any DML or event publish in each job.
 * EventBus.publish does not throw on failure, so each result is checked; a
 * failed publish is recorded as a publishFailed finding for the digest, and
 * the repairs it names did not start.
 */
public with sharing class DirectorySyncSweep implements Queueable, Database.AllowsCallouts {

    public static final String KIND = 'Sweep';
    public static final String TREE_ROOT = '/Demo Students';
    public static final Integer MAX_PAGES = 5;

    private final String pageToken;
    private final Integer page;
    private final Set<String> seen;
    private final Map<String, Integer> totals;

    @TestVisible
    private Directory_Sync_Setting__mdt injectedSettings;

    /**
     * Test switch. Events published in a test are delivered at Test.stopTest(),
     * which would start real sync jobs; tests turn publishing off and assert on
     * republishedIds instead.
     */
    @TestVisible
    private static Boolean publishEvents = true;
    @TestVisible
    private static List<Id> republishedIds = new List<Id>();
    @TestVisible
    private static String forcePublishError;

    public DirectorySyncSweep() {
        this(null, 1, new Set<String>(), new Map<String, Integer>());
    }

    @TestVisible
    private DirectorySyncSweep(String pageToken, Integer page, Set<String> seen, Map<String, Integer> totals) {
        this.pageToken = pageToken;
        this.page = page;
        this.seen = seen;
        this.totals = totals;
    }

    /** Publishes a sweep request. Safe to call from a schedule or anonymous Apex. */
    public static Boolean request() {
        return EventBus.publish(new Directory_Sync_Request__e(Kind__c = KIND)).isSuccess();
    }

    public void execute(QueueableContext ctx) {
        Directory_Sync_Setting__mdt settings = injectedSettings != null ? injectedSettings : DirectorySyncConfig.settings();
        GoogleDirectoryClient client = new GoogleDirectoryClient(null, settings.Domain__c, settings.Dry_Run__c);
        DirectoryResult listed = client.listUsers(pageToken);
        // ---- No callouts below this line ----

        List<Directory_Sync_Log__c> logs = new List<Directory_Sync_Log__c>(client.getPendingLogs());
        if (!listed.isSuccess()) {
            for (Directory_Sync_Log__c l : logs) {
                l.Alert_Status__c = 'Pending';
            }
            insert logs;
            return;
        }

        List<Object> users = GoogleDirectoryClient.users(listed);
        add('users', users.size());
        Set<Id> republish = new Set<Id>();
        logs.addAll(reviewPage(users, republish));

        String nextToken = GoogleDirectoryClient.nextPageToken(listed);
        Boolean lastPage = String.isBlank(nextToken);
        Boolean truncated = !lastPage && page >= MAX_PAGES;

        if (lastPage) {
            logs.addAll(reviewContacts(republish));
        }
        if (truncated) {
            logs.add(finding('sweepTruncated', null,
                'Stopped after ' + page + ' pages (' + totals.get('users') + ' users).',
                'Developer Edition limits a Queueable chain to ' + MAX_PAGES + ' jobs. The end-of-sweep checks were skipped.', true));
        }
        List<String> publishErrors = publish(new List<Id>(republish));
        if (!publishErrors.isEmpty()) {
            logs.add(finding('publishFailed', null,
                'Sync requests for ' + publishErrors.size() + ' of ' + republish.size() + ' Contacts',
                String.join(publishErrors, '; ') + '. Those repairs did not start.', true));
        }
        if (lastPage || truncated) {
            logs.add(new Directory_Sync_Log__c(
                Operation__c = 'Sweep',
                Success__c = true,
                Request_Summary__c = 'Sweep ' + (truncated ? 'truncated' : 'complete') + ': ' + page + (page == 1 ? ' page, ' : ' pages, ') + totals.get('users') + ' users.',
                Response_Summary__c = 'Repaired (sync requested): ' + tally('repaired') + '. Reported: ' + tally('reported') + '.'
            ));
        }

        insert logs;

        if (!lastPage && !truncated && !Test.isRunningTest()) {
            DirectorySyncSweep nextJob = new DirectorySyncSweep(nextToken, page + 1, seen, totals);
            nextJob.injectedSettings = injectedSettings;
            System.enqueueJob(nextJob);
        }
    }

    /** Publishes a sync request per Contact. Returns one message per failure. */
    private static List<String> publish(List<Id> contactIds) {
        List<String> errors = new List<String>();
        if (contactIds.isEmpty()) {
            return errors;
        }
        republishedIds.addAll(contactIds);
        if (!publishEvents) {
            if (forcePublishError != null) {
                for (Id cid : contactIds) {
                    errors.add(cid + ': ' + forcePublishError);
                }
            }
            return errors;
        }
        List<Directory_Sync_Request__e> events = new List<Directory_Sync_Request__e>();
        for (Id cid : contactIds) {
            events.add(new Directory_Sync_Request__e(Contact_Id__c = cid));
        }
        List<Database.SaveResult> results = EventBus.publish(events);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error e = results[i].getErrors().isEmpty() ? null : results[i].getErrors()[0];
                errors.add(contactIds[i] + ': ' + (e == null ? 'unknown error' : e.getStatusCode() + ' ' + e.getMessage()));
            }
        }
        return errors;
    }

    /** Checks each Google user on this page against the Contacts in scope. */
    private List<Directory_Sync_Log__c> reviewPage(List<Object> users, Set<Id> republish) {
        List<Directory_Sync_Log__c> rows = new List<Directory_Sync_Log__c>();
        Map<Id, Contact> contacts = contactsFor(users);

        for (Object o : users) {
            Map<String, Object> u = (Map<String, Object>) o;
            String googleId = (String) u.get('id');
            String email = (String) u.get('primaryEmail');
            String ou = (String) u.get('orgUnitPath');
            Boolean suspended = u.get('suspended') == true;
            String sfId = salesforceId(u);
            Boolean inTree = ou == TREE_ROOT || (ou != null && ou.startsWith(TREE_ROOT + '/'));
            String who = email + ' (' + googleId + ') in ' + ou + (suspended ? ', suspended' : '');

            if (sfId != null) {
                seen.add(sfId);
            }
            if (sfId == null) {
                if (inTree) {
                    rows.add(finding('unmanagedInTree', null, who, 'No salesforce_id: not created by the sync.', true));
                }
                continue;
            }
            if (!inTree) {
                rows.add(finding('outOfTree', null, who, 'Carries salesforce_id ' + sfId + ' outside ' + TREE_ROOT + '.', true));
                continue;
            }
            Contact c = contacts.get(toId(sfId));
            if (c == null) {
                rows.add(finding('orphan', null, who, 'salesforce_id ' + sfId + ' matches no Contact in scope.', true));
                continue;
            }

            Directory_Status_Mapping__mdt mapping = DirectorySyncConfig.mappingFor(c.Lifecycle_Status__c);
            String target = mapping == null ? null : mapping.Target_State__c;
            if (target != 'Active' && target != 'Suspended') {
                continue;
            }
            List<String> problems = new List<String>();
            if ((target == 'Suspended') != suspended) {
                problems.add('expected ' + (target == 'Suspended' ? 'suspended' : 'active'));
            }
            if (String.isNotBlank(mapping.Target_OU__c) && ou != mapping.Target_OU__c) {
                problems.add('expected OU ' + mapping.Target_OU__c);
            }
            if (c.Google_User_Id__c != googleId) {
                problems.add('Contact records Google ID ' + c.Google_User_Id__c);
            }
            if (!problems.isEmpty()) {
                rows.add(finding('drift', c.Id, who,
                    'Status "' + c.Lifecycle_Status__c + '": ' + String.join(problems, '; ') + '.', false));
                republish.add(c.Id);
            }
        }
        return rows;
    }

    /** End of sweep: Contacts that should have an account but none was seen. */
    private List<Directory_Sync_Log__c> reviewContacts(Set<Id> republish) {
        List<Directory_Sync_Log__c> rows = new List<Directory_Sync_Log__c>();
        for (Contact c : [
            SELECT Id, Lifecycle_Status__c, Google_User_Id__c, Google_Account_Status__c
            FROM Contact
            WHERE Lifecycle_Status__c != null
            LIMIT 10000
        ]) {
            if (seen.contains(String.valueOf(c.Id)) || seen.contains(String.valueOf(c.Id).left(15))) {
                continue;
            }
            Directory_Status_Mapping__mdt mapping = DirectorySyncConfig.mappingFor(c.Lifecycle_Status__c);
            String target = mapping == null ? null : mapping.Target_State__c;
            String who = 'Contact ' + c.Id + ' (status "' + c.Lifecycle_Status__c + '")';

            if (String.isNotBlank(c.Google_User_Id__c)) {
                if (target == 'Active' || target == 'Suspended') {
                    rows.add(finding('missingAccount', c.Id, who,
                        'Contact records Google ID ' + c.Google_User_Id__c + ', but no Google user carries its salesforce_id.', true));
                }
            } else if (target == 'Active' && String.isBlank(c.Google_Account_Status__c)) {
                rows.add(finding('neverProvisioned', c.Id, who, 'Status calls for an account and none was ever attempted.', false));
                republish.add(c.Id);
            }
        }
        return rows;
    }

    private Map<Id, Contact> contactsFor(List<Object> users) {
        Set<Id> ids = new Set<Id>();
        for (Object o : users) {
            Id cid = toId(salesforceId((Map<String, Object>) o));
            if (cid != null) {
                ids.add(cid);
            }
        }
        if (ids.isEmpty()) {
            return new Map<Id, Contact>();
        }
        return new Map<Id, Contact>([
            SELECT Id, Lifecycle_Status__c, Google_User_Id__c
            FROM Contact
            WHERE Id IN :ids
        ]);
    }

    private Directory_Sync_Log__c finding(String kind, Id contactId, String who, String detail, Boolean report) {
        add(report ? 'reported' : 'repaired', 1);
        return new Directory_Sync_Log__c(
            Operation__c = 'Sweep',
            Contact__c = contactId,
            Success__c = false,
            Error_Reason__c = kind,
            Alert_Status__c = report ? 'Pending' : null,
            Request_Summary__c = who,
            Response_Summary__c = detail + (report
                ? ' Report only; nothing was changed.'
                : ' Sync requested; the job will repair it.')
        );
    }

    @TestVisible
    private static String salesforceId(Map<String, Object> user) {
        Object ext = user == null ? null : user.get('externalIds');
        if (!(ext instanceof List<Object>)) {
            return null;
        }
        for (Object item : (List<Object>) ext) {
            if (item instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) item;
                if (m.get('customType') == 'salesforce_id' && m.get('value') != null) {
                    return String.valueOf(m.get('value'));
                }
            }
        }
        return null;
    }

    private static Id toId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            Id candidate = Id.valueOf(raw);
            return candidate.getSobjectType() == Contact.SObjectType ? candidate : null;
        } catch (StringException e) {
            return null;
        }
    }

    private void add(String key, Integer n) {
        totals.put(key, tally(key) + n);
    }

    private Integer tally(String key) {
        Integer v = totals.get(key);
        return v == null ? 0 : v;
    }
}
