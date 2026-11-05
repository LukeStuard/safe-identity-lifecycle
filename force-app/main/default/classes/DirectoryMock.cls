/**
 * Routed HttpCalloutMock for the Directory API.
 * Routes are keyed by method and path (query string ignored). Any request
 * with no matching route throws UnexpectedCalloutException, which the client
 * does not catch, so an unplanned callout fails the test loudly.
 * Every request is recorded for assertions on what was actually sent.
 */
@IsTest
public class DirectoryMock implements HttpCalloutMock {

    private final Map<String, List<Object>> routes = new Map<String, List<Object>>();
    public final List<HttpRequest> requests = new List<HttpRequest>();

    public DirectoryMock route(String method, String path, Integer status, String body) {
        routes.put(method + ' ' + path, new List<Object>{ status, body });
        return this;
    }

    public HttpResponse respond(HttpRequest req) {
        requests.add(req);
        String path = req.getEndpoint().substringAfter('/admin/directory/v1').substringBefore('?');
        String key = req.getMethod() + ' ' + path;
        List<Object> route = routes.get(key);
        if (route == null) {
            throw new UnexpectedCalloutException('DirectoryMock has no route for ' + key);
        }
        HttpResponse res = new HttpResponse();
        res.setStatusCode((Integer) route[0]);
        if (route[1] != null) {
            res.setHeader('Content-Type', 'application/json');
            res.setBody((String) route[1]);
        }
        return res;
    }

    /** A Google-style error body. */
    public static String error(Integer code, String reason, String message) {
        return JSON.serialize(new Map<String, Object>{
            'error' => new Map<String, Object>{
                'code' => code,
                'message' => message,
                'errors' => new List<Object>{
                    new Map<String, Object>{ 'domain' => 'global', 'reason' => reason, 'message' => message }
                }
            }
        });
    }

    /** Simulates a timeout or connection failure. */
    public class Failing implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new CalloutException('Read timed out');
        }
    }

    public class UnexpectedCalloutException extends Exception {}
}
