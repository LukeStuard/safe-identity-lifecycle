@IsTest
private class WelcomeEmailTest {

    @IsTest
    static void buildsMessage() {
        Messaging.SingleEmailMessage m = WelcomeEmail.build('Jane', 'jane.doe@shuraku.org', 'Temp-Pass-123', 'jane.personal@example.com', null);
        Assert.areEqual('Your Shuraku University Student Account', m.getSubject());
        Assert.areEqual('jane.personal@example.com', m.getToAddresses()[0]);
        String body = m.getPlainTextBody();
        Assert.isTrue(body.startsWith('Hi Jane,'));
        Assert.isTrue(body.contains('Username: jane.doe@shuraku.org'));
        Assert.isTrue(body.contains('Temporary password: Temp-Pass-123'));
        Assert.isTrue(body.contains('Sign in at: https://accounts.google.com'));
        Assert.isFalse(body.contains('—'), 'No em-dashes');
    }

    @IsTest
    static void resetMessageIsWordedAsAReset() {
        Messaging.SingleEmailMessage m = WelcomeEmail.buildReset('Jane', 'jane.doe@shuraku.org', 'New-Pass-456', 'jane.personal@example.com', null);
        Assert.areEqual('Your Shuraku University Student Account: New Temporary Password', m.getSubject());
        String body = m.getPlainTextBody();
        Assert.isTrue(body.contains('A new temporary password has been set'), body);
        Assert.isFalse(body.contains('Your student account is ready.'), body);
        Assert.isTrue(body.contains('Username: jane.doe@shuraku.org'));
        Assert.isTrue(body.contains('Temporary password: New-Pass-456'));
        Assert.isFalse(body.contains('—'), 'No em-dashes');
    }

    @IsTest
    static void blankFirstNameGetsPlainGreeting() {
        Assert.isTrue(WelcomeEmail.body('  ', 'u@shuraku.org', 'p').startsWith('Hi,'));
    }

    @IsTest
    static void sendsAndReportsSuccess() {
        Messaging.SingleEmailMessage m = WelcomeEmail.build('Jane', 'jane.doe@shuraku.org', 'p', 'jane.personal@example.com', null);
        Assert.isNull(WelcomeEmail.send(m, false));
        Assert.areEqual('Simulated send failure.', WelcomeEmail.send(m, true));
    }

    @IsTest
    static void logNeverHoldsThePassword() {
        Directory_Sync_Log__c ok = WelcomeEmail.log(null, 'jane.personal@example.com', 'jane.doe@shuraku.org', null);
        Assert.isTrue(ok.Success__c);
        Assert.areEqual('Sent', ok.Response_Summary__c);
        Assert.areEqual('To jane.personal@example.com for jane.doe@shuraku.org', ok.Request_Summary__c);

        Directory_Sync_Log__c failed = WelcomeEmail.log(null, 'a@example.com', 'u@shuraku.org', 'Bounced');
        Assert.isFalse(failed.Success__c);
        Assert.areEqual('emailFailed', failed.Error_Reason__c);
    }
}
