trigger DirectorySyncRequestTrigger on Directory_Sync_Request__e (after insert) {
    Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
    m.setOrgWideEmailAddressId('0D2fj0000008qmD');
    m.setToAddresses(new String[]{ 'lstua001@ucr.edu' });
    m.setSubject('Check 3: PE trigger email');
    m.setPlainTextBody('Running user: ' + UserInfo.getUserName());
    Messaging.SendEmailResult[] r = Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ m }, false);
    System.debug('CHECK3 success=' + r[0].isSuccess() + ' errors=' + r[0].getErrors());
}