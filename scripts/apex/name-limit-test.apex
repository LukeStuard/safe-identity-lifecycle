Id cid = [SELECT Id FROM Contact LIMIT 1].Id;
GoogleDirectoryClient c = new GoogleDirectoryClient(cid, 'shuraku.org', false);

for (Integer n : new List<Integer>{ 41, 60, 61 }) {
    String family = 'Abcdefghij'.repeat(7).left(n);
    DirectoryResult r = c.createUser(new Map<String, Object>{
        'primaryEmail' => 'namelimit.' + n + '@shuraku.org',
        'name' => new Map<String, Object>{ 'givenName' => 'Name', 'familyName' => family },
        'password' => EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
        'changePasswordAtNextLogin' => true,
        'suspended' => true,
        'orgUnitPath' => '/Demo Students/Inactive'
    });
    Integer stored = null;
    if (r.isSuccess() && r.body.get('name') instanceof Map<String, Object>) {
        Object f = ((Map<String, Object>) r.body.get('name')).get('familyName');
        stored = f == null ? null : String.valueOf(f).length();
    }
    System.debug('NAMELIMIT ' + n + ' -> ' + r.statusCode + ' ' + r.errorReason + ' | ' + r.errorMessage + ' | stored=' + stored);
}