/**
 * Decides which managed Google groups a Contact belongs in. Pure logic.
 *
 * A Directory_Group_Mapping__mdt record applies when every filled-in key
 * (Program, Term) matches the Contact; a blank key matches anything. A record
 * with no keys at all is ignored. Only groups named in these records are
 * "managed": the integration never adds to or removes from any other group.
 */
public inherited sharing class DirectoryGroupPlanner {

    public class Diff {
        public Set<String> toAdd = new Set<String>();
        public Set<String> toRemove = new Set<String>();

        public Boolean isEmpty() {
            return toAdd.isEmpty() && toRemove.isEmpty();
        }
    }

    public static List<Directory_Group_Mapping__mdt> allMappings() {
        return Directory_Group_Mapping__mdt.getAll().values();
    }

    public static Set<String> managed(List<Directory_Group_Mapping__mdt> rows) {
        Set<String> emails = new Set<String>();
        for (Directory_Group_Mapping__mdt row : rows) {
            if (String.isNotBlank(row.Group_Email__c)) {
                emails.add(row.Group_Email__c.toLowerCase());
            }
        }
        return emails;
    }

    public static Set<String> desired(String program, String term, List<Directory_Group_Mapping__mdt> rows) {
        Set<String> emails = new Set<String>();
        for (Directory_Group_Mapping__mdt row : rows) {
            Boolean hasKey = String.isNotBlank(row.Program__c) || String.isNotBlank(row.Term__c);
            if (!hasKey || String.isBlank(row.Group_Email__c)) {
                continue;
            }
            Boolean programMatches = String.isBlank(row.Program__c) || row.Program__c == program;
            Boolean termMatches = String.isBlank(row.Term__c) || row.Term__c == term;
            if (programMatches && termMatches) {
                emails.add(row.Group_Email__c.toLowerCase());
            }
        }
        return emails;
    }

    /** Adds what is missing; removes managed groups that no longer apply. Unmanaged groups are never touched. */
    public static Diff diff(Set<String> desired, Set<String> current, Set<String> managed) {
        Diff d = new Diff();
        for (String g : desired) {
            if (!current.contains(g)) {
                d.toAdd.add(g);
            }
        }
        for (String g : current) {
            if (managed.contains(g) && !desired.contains(g)) {
                d.toRemove.add(g);
            }
        }
        return d;
    }
}
