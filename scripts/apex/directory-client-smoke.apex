Id cid = [SELECT Id FROM Contact LIMIT 1].Id;
GoogleDirectoryClient c = new GoogleDirectoryClient(cid, 'shuraku.org', false);
String pw = EncodingUtil.convertToHex(Crypto.generateAesKey(128));

DirectoryResult created = c.createUser(new Map<String, Object>{
    'primaryEmail' => 'smoke.test@shuraku.org',
    'name' => new Map<String, Object>{ 'givenName' => 'Smoke', 'familyName' => 'Test' },
    'password' => pw,
    'changePasswordAtNextLogin' => true,
    'orgUnitPath' => '/Demo Students/Admitted',
    'externalIds' => new List<Object>{ new Map<String, Object>{ 'type' => 'custom', 'customType' => 'salesforce_id', 'value' => 'SMOKE-TEST' } }
});
String gid = created.getString('id');
System.debug('SMOKE create ' + created.statusCode + ' id=' + gid);

DirectoryResult added = c.addMember('smoke-test@shuraku.org', gid);
System.debug('SMOKE addMember ' + added.statusCode + ' ' + added.errorReason);

DirectoryResult moved = c.updateUser(gid, new Map<String, Object>{ 'orgUnitPath' => '/Demo Students/Inactive', 'suspended' => true }, 'Suspend');
System.debug('SMOKE suspend+move ' + moved.statusCode + ' ' + moved.errorReason);

DirectoryResult removed = c.removeMember('smoke-test@shuraku.org', gid);
System.debug('SMOKE removeMember ' + removed.statusCode + ' ' + removed.errorReason);

insert c.getPendingLogs();
System.debug('SMOKE logs inserted ' + c.getPendingLogs().size());