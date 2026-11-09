/**
 * Result of one Directory API call: status, raw and parsed body, and the
 * Google error reason when the call failed. Retry decisions key on the
 * reason, not the status code, because a 403 can mean either "forbidden"
 * (never retry) or "quotaExceeded" (retry with backoff).
 */
public inherited sharing class DirectoryResult {

    private static final Set<String> RETRYABLE_REASONS = new Set<String>{
        'quotaExceeded', 'userRateLimitExceeded', 'rateLimitExceeded',
        'backendError', 'internalError', 'calloutException',
        'RESOURCE_EXHAUSTED', 'UNAVAILABLE'
    };
    private static final Set<Integer> RETRYABLE_STATUSES = new Set<Integer>{ 429, 500, 502, 503, 504 };

    public Integer statusCode { get; private set; }
    public String rawBody { get; private set; }
    public Map<String, Object> body { get; private set; }
    public String errorReason { get; private set; }
    public String errorMessage { get; private set; }
    public Boolean dryRun { get; private set; }

    public DirectoryResult(Integer statusCode, String rawBody) {
        this.statusCode = statusCode;
        this.rawBody = rawBody;
        this.dryRun = false;
        this.body = new Map<String, Object>();
        if (String.isNotBlank(rawBody)) {
            try {
                Object parsed = JSON.deserializeUntyped(rawBody);
                if (parsed instanceof Map<String, Object>) {
                    this.body = (Map<String, Object>) parsed;
                }
            } catch (JSONException e) {
                // Non-JSON body: keep rawBody, leave body empty.
            }
        }
        if (!isSuccess()) {
            parseError();
        }
    }

    /** A write that was skipped because dry run is on. */
    public static DirectoryResult dryRunResult() {
        DirectoryResult r = new DirectoryResult(200, '{"dryRun":true,"note":"Write skipped; no request sent to Google."}');
        r.dryRun = true;
        return r;
    }

    /** The request never got a response (timeout, connection failure). */
    public static DirectoryResult calloutFailure(String message) {
        DirectoryResult r = new DirectoryResult(0, null);
        r.errorReason = 'calloutException';
        r.errorMessage = message;
        return r;
    }

    public Boolean isSuccess() {
        return statusCode != null && statusCode >= 200 && statusCode < 300;
    }

    public Boolean isNotFound() {
        return statusCode == 404;
    }

    public Boolean isConflict() {
        return statusCode == 409;
    }

    public Boolean isRetryable() {
        if (isSuccess()) {
            return false;
        }
        return RETRYABLE_REASONS.contains(errorReason) || RETRYABLE_STATUSES.contains(statusCode);
    }

    /**
     * Classifies a reason string after the response is gone. Accepts a Google
     * reason ("rateLimitExceeded") or the "http" + status form ("http503")
     * that callers record when Google sent no reason.
     */
    public static Boolean isRetryableReason(String reason) {
        if (String.isBlank(reason)) {
            return false;
        }
        if (RETRYABLE_REASONS.contains(reason)) {
            return true;
        }
        String digits = reason.removeStart('http');
        if (digits != reason && digits.isNumeric()) {
            return RETRYABLE_STATUSES.contains(Integer.valueOf(digits));
        }
        return false;
    }

    public String getString(String key) {
        Object v = body.get(key);
        return v == null ? null : String.valueOf(v);
    }

    private void parseError() {
        Object e = body.get('error');
        if (!(e instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> err = (Map<String, Object>) e;
        if (err.get('message') != null) {
            errorMessage = String.valueOf(err.get('message'));
        }
        Object errors = err.get('errors');
        if (errors instanceof List<Object> && !((List<Object>) errors).isEmpty()) {
            Object first = ((List<Object>) errors)[0];
            if (first instanceof Map<String, Object>) {
                Object reason = ((Map<String, Object>) first).get('reason');
                errorReason = reason == null ? null : String.valueOf(reason);
            }
        }
        if (errorReason == null && err.get('status') != null) {
            errorReason = String.valueOf(err.get('status'));
        }
    }
}
