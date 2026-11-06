HttpRequest r = new HttpRequest();
r.setEndpoint('callout:Google_Directory_API/admin/directory/v1/users?domain=shuraku.org&maxResults=1');
r.setMethod('GET');
HttpResponse res = new Http().send(r);
System.debug('VERIFY ' + res.getStatusCode());