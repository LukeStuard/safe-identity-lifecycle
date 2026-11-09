/**
 * Daily trigger for the reconciliation sweep. Scheduled Apex cannot make
 * callouts and runs as whoever scheduled it, so this only publishes a sweep
 * request; the event subscriber starts the sweep as the integration user.
 *
 * Schedule once (8:23 AM, so the 9:07 alert digest reports any findings):
 *   System.schedule('Directory Sync Sweep', '0 23 8 * * ?', new DirectorySyncSweepSchedule());
 */
public with sharing class DirectorySyncSweepSchedule implements Schedulable {
    public void execute(SchedulableContext ctx) {
        DirectorySyncSweep.request();
    }
}
