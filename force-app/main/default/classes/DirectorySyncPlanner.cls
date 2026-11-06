/**
 * Decides what Google should look like for a Contact and what it would take
 * to get there. Pure logic: no callouts, no DML, no queries.
 *
 * Target states (Directory_Status_Mapping__mdt):
 *   Active    - account exists, not suspended, in the status's OU
 *   Suspended - account suspended, in the Inactive OU, no program or term groups
 *   None      - no action
 */
public inherited sharing class DirectorySyncPlanner {

    public class Plan {
        public String action;
        public String reason;
        public String errorReason;
        public List<String> steps = new List<String>();

        public Directory_Sync_Log__c toLog(Id contactId, String status, Directory_Status_Mapping__mdt mapping) {
            return toLog(contactId, status, mapping, true);
        }

        public Directory_Sync_Log__c toLog(Id contactId, String status, Directory_Status_Mapping__mdt mapping, Boolean dryRun) {
            String target = mapping == null
                ? 'no mapping'
                : mapping.Target_State__c + (String.isBlank(mapping.Target_OU__c) ? '' : ' in ' + mapping.Target_OU__c);
            String detail = action + (String.isBlank(reason) ? '' : ': ' + reason);
            if (!steps.isEmpty()) {
                detail += '\n- ' + String.join(steps, '\n- ');
            }
            return new Directory_Sync_Log__c(
                Contact__c = contactId,
                Operation__c = 'Plan',
                Success__c = action != 'ERROR',
                Dry_Run__c = dryRun == true,
                Error_Reason__c = errorReason,
                Request_Summary__c = 'Status "' + status + '" -> ' + target,
                Response_Summary__c = detail
            );
        }
    }

    public static Plan plan(String status, Directory_Status_Mapping__mdt mapping, DirectoryResult lookup) {
        Plan p = new Plan();

        if (mapping == null) {
            return finish(p, 'NONE', 'No status mapping for "' + status + '"; fails closed.');
        }
        String target = mapping.Target_State__c;
        if (String.isBlank(target) || target == 'None') {
            return finish(p, 'NONE', 'Status maps to no Google action.');
        }
        if (lookup == null || !lookup.isSuccess()) {
            p.errorReason = lookup == null ? 'noLookup' : lookup.errorReason;
            return finish(p, 'ERROR', 'Google lookup failed; no decision made.');
        }
        if (GoogleDirectoryClient.userCount(lookup) > 1) {
            p.errorReason = 'multipleMatches';
            return finish(p, 'ERROR', 'More than one Google user carries this Salesforce ID; resolve by hand.');
        }

        Map<String, Object> user = GoogleDirectoryClient.firstUser(lookup);
        Boolean exists = user != null;
        Boolean suspended = exists && user.get('suspended') == true;
        String currentOu = exists ? (String) user.get('orgUnitPath') : null;
        String targetOu = mapping.Target_OU__c;

        if (target == 'Active') {
            if (!exists) {
                p.steps.add('Create user in ' + targetOu);
                p.steps.add('Store Salesforce ID as externalId (salesforce_id)');
                p.steps.add('Send welcome email');
                return finish(p, 'CREATE', null);
            }
            if (suspended) {
                p.steps.add('Reactivate');
            }
            if (String.isNotBlank(targetOu) && currentOu != targetOu) {
                p.steps.add('Move from ' + currentOu + ' to ' + targetOu);
            }
            if (p.steps.isEmpty()) {
                return finish(p, 'NONE', 'Already active in ' + currentOu + '.');
            }
            return finish(p, suspended ? 'REACTIVATE' : 'MOVE', null);
        }

        if (target == 'Suspended') {
            if (!exists) {
                return finish(p, 'NONE', 'No Google account exists; nothing to suspend.');
            }
            if (!suspended) {
                p.steps.add('Suspend');
                p.steps.add('Remove program and term groups');
            }
            if (String.isNotBlank(targetOu) && currentOu != targetOu) {
                p.steps.add('Move from ' + currentOu + ' to ' + targetOu);
            }
            if (p.steps.isEmpty()) {
                return finish(p, 'NONE', 'Already suspended in ' + currentOu + '.');
            }
            return finish(p, 'SUSPEND', null);
        }

        p.errorReason = 'unknownTargetState';
        return finish(p, 'ERROR', 'Unknown target state "' + target + '".');
    }

    private static Plan finish(Plan p, String action, String reason) {
        p.action = action;
        p.reason = reason;
        return p;
    }
}
