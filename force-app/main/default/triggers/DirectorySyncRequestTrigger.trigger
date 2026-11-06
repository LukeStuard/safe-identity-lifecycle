trigger DirectorySyncRequestTrigger on Directory_Sync_Request__e (after insert) {
    DirectorySyncRequestHandler.handle(Trigger.new);
}
