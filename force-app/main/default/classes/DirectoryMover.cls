/**
 * Mover path for active accounts: OU moves and managed group membership.
 * Callouts only; the job writes results to the Contact and logs afterward.
 *
 * Membership is keyed on the immutable Google user ID. "Already a member"
 * (409) on add and "not a member" (404) on remove count as success, so a
 * retried job converges instead of failing.
 */
public inherited sharing class DirectoryMover {

    public class Result {
        public Boolean success = true;
        public String errorReason;
        public String errorMessage;
        public List<String> notes = new List<String>();

        public void fail(DirectoryResult r) {
            success = false;
            if (errorReason == null) {
                errorReason = r.errorReason != null ? r.errorReason : 'http' + r.statusCode;
                errorMessage = r.errorMessage;
            }
        }
    }

    public static void moveIfNeeded(
        String googleUserId,
        String currentOu,
        String targetOu,
        GoogleDirectoryClient client,
        Result result
    ) {
        if (String.isBlank(targetOu) || targetOu == currentOu) {
            return;
        }
        DirectoryResult r = client.updateUser(googleUserId, new Map<String, Object>{ 'orgUnitPath' => targetOu }, 'Move');
        if (r.isSuccess()) {
            result.notes.add('Moved to ' + targetOu + '.');
        } else {
            result.fail(r);
        }
    }

    /**
     * Brings managed group membership in line with the desired set.
     * knownEmpty skips the membership read for an account created in this run.
     */
    public static void syncGroups(
        String googleUserId,
        Set<String> desired,
        Set<String> managed,
        Boolean knownEmpty,
        GoogleDirectoryClient client,
        Result result
    ) {
        Set<String> current = new Set<String>();
        if (knownEmpty != true) {
            DirectoryResult listed = client.listMemberships(googleUserId);
            if (!listed.isSuccess()) {
                result.fail(listed);
                return;
            }
            current = GoogleDirectoryClient.groupEmails(listed);
        }

        DirectoryGroupPlanner.Diff d = DirectoryGroupPlanner.diff(desired, current, managed);
        if (d.isEmpty()) {
            if (knownEmpty != true) {
                result.notes.add('Groups already match.');
            }
            return;
        }
        for (String g : d.toAdd) {
            DirectoryResult r = client.addMember(g, googleUserId);
            if (r.isSuccess() || r.isConflict()) {
                result.notes.add('Added to ' + g + '.');
            } else {
                result.fail(r);
            }
        }
        for (String g : d.toRemove) {
            DirectoryResult r = client.removeMember(g, googleUserId);
            if (r.isSuccess() || r.isNotFound()) {
                result.notes.add('Removed from ' + g + '.');
            } else {
                result.fail(r);
            }
        }
    }
}
