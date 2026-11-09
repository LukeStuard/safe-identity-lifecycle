/**
 * Routed HttpCalloutMock for the Directory API.
 *
 * - Routes are keyed by method and path (query string ignored).
 * - Routing the same key more than once queues responses: each call takes
 *   the next one, and the last is reused once the queue is down to one.
 * - A path ending in '*' matches by prefix, e.g. route('GET', '/users/*', ...).
 *   Exact routes win over prefix routes.
 * - Any request with no matching route throws UnexpectedCalloutException,
 *   which the client does not catch, so an unplanned callout fails the test.
 * - Every request is recorded for assertions on what was actually sent.
 */
@IsTest
public class DirectoryMock implements HttpCalloutMock {

    private final Map<String, List<List<Object>>> routes = new Map<String, List<List<Object>>>();
    public final List<HttpRequest> requests = new List<HttpRequest>();

    public DirectoryMock route(String method, String path, Integer status, String body) {
        String key = method + ' ' + path;
        if (!routes.containsKey(key)) {
            routes.put(key, new List<List<Object>>());
        }
        routes.get(key).add(new List<Object>{ status, body });
        return this;
    }

    public HttpResponse respond(HttpRequest req) {
        requests.add(req);
        String path = req.getEndpoint().substringAfter('/admin/directory/v1').substringBefore('?');
        String key = req.getMethod() + ' ' + path;
        List<List<Object>> queue = routes.get(key);
        if (queue == null) {
            for (String candidate : routes.keySet()) {
                if (candidate.endsWith('*') && key.startsWith(candidate.removeEnd('*'))) {
                    queue = routes.get(candidate);
                    break;
                }
            }
        }
        if (queue == null || queue.isEmpty()) {
            throw new UnexpectedCalloutException('DirectoryMock has no route for ' + key);
        }
        List<Object> next = queue.size() > 1 ? queue.remove(0) : queue[0];
        HttpResponse res = new HttpResponse();
        res.setStatusCode((Integer) next[0]);
        if (next[1] != null) {
            res.setHeader('Content-Type', 'application/json');
            res.setBody((String) next[1]);
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
