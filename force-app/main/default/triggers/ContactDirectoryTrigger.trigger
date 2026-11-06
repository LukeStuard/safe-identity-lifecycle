trigger ContactDirectoryTrigger on Contact (after update) {
    ContactDirectoryTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
}
