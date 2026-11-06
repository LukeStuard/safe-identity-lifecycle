/**
 * Reads integration configuration from Custom Metadata.
 * Tests can substitute settings through settingsOverride.
 */
public inherited sharing class DirectorySyncConfig {

    @TestVisible
    private static Directory_Sync_Setting__mdt settingsOverride;

    private static Map<String, Directory_Status_Mapping__mdt> mappingsByStatus;

    public static Directory_Sync_Setting__mdt settings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        Directory_Sync_Setting__mdt s = Directory_Sync_Setting__mdt.getInstance('Default');
        if (s == null) {
            throw new ConfigException('Directory_Sync_Setting__mdt record "Default" is missing.');
        }
        return s;
    }

    public static Boolean isEnabled() {
        return settings().Enabled__c == true;
    }

    /** The mapping for a status, or null. A missing mapping fails closed. */
    public static Directory_Status_Mapping__mdt mappingFor(String status) {
        if (String.isBlank(status)) {
            return null;
        }
        if (mappingsByStatus == null) {
            mappingsByStatus = new Map<String, Directory_Status_Mapping__mdt>();
            for (Directory_Status_Mapping__mdt m : Directory_Status_Mapping__mdt.getAll().values()) {
                mappingsByStatus.put(m.Status__c, m);
            }
        }
        return mappingsByStatus.get(status);
    }

    public class ConfigException extends Exception {}
}
