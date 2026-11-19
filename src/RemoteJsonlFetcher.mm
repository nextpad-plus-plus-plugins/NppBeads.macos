#import "RemoteJsonlFetcher.h"

#import <Security/Security.h>

// All mutable state is confined to the MAIN queue; NSURLSession
// completions hop to main and are generation-gated so a stale response
// can never land after stop/rebind.

static NSString * const kKeychainService = @"NppBeads Remote";
static const NSTimeInterval kPollInterval = 60.0;

@implementation RemoteJsonlFetcher {
    NSString          *_spec;
    NSString          *_token;        // nil = anonymous
    NSURLRequest      *_baseRequest;  // built once; If-None-Match added per fetch
    NSString          *_etag;
    NSUInteger         _lastLength;   // belt-and-braces change gate
    dispatch_source_t  _timer;
    NSURLSessionDataTask *_task;
    NSUInteger         _generation;   // bumped on stop; gates completions
    BOOL               _paused;
    BOOL               _pendingTick;  // a tick fired while paused
    NSString          *_lastError;
}

@synthesize lastError = _lastError;

// ─────────────────────────────────────────────────────────────────────
//  Spec parsing
// ─────────────────────────────────────────────────────────────────────

// "owner/repo" from assorted GitHub shapes; nil when not GitHub-like.
static BOOL parseGitHubOwnerRepo(NSString *input,
                                 NSString *__autoreleasing *owner,
                                 NSString *__autoreleasing *repo) {
    NSString *s = input;
    for (NSString *prefix in @[@"https://", @"http://"]) {
        if ([s.lowercaseString hasPrefix:prefix]) { s = [s substringFromIndex:prefix.length]; break; }
    }
    for (NSString *host in @[@"www.github.com/", @"github.com/"]) {
        if ([s.lowercaseString hasPrefix:host]) { s = [s substringFromIndex:host.length]; break; }
    }
    if ([s.lowercaseString hasSuffix:@".git"]) s = [s substringToIndex:s.length - 4];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"/"];
    if (parts.count != 2 || parts[0].length == 0 || parts[1].length == 0) return NO;
    // Owner/repo charsets are tight; anything URL-ish here means the
    // input wasn't a GitHub repo reference after all.
    if ([parts[0] containsString:@":"] || [parts[0] containsString:@"@"]) return NO;
    if (owner) *owner = parts[0];
    if (repo)  *repo  = parts[1];
    return YES;
}

+ (NSString *)specForInput:(NSString *)input
                    branch:(NSString *)branch
                   display:(NSString *__autoreleasing *)outDisplay {
    NSString *in = [input stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (in.length == 0) return nil;
    NSString *br = [branch stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (br.length == 0) br = @"main";

    NSString *owner = nil, *repo = nil;
    if (parseGitHubOwnerRepo(in, &owner, &repo)) {
        if (outDisplay) *outDisplay = [NSString stringWithFormat:@"%@/%@ @ %@", owner, repo, br];
        return [NSString stringWithFormat:@"github.com/%@/%@@%@", owner, repo, br];
    }

    // Self-hosted forge or direct raw URL (nppmac-iik). http:// is
    // accepted: ATS does not apply to IP-literal or .local hosts (it
    // still blocks public-hostname http inside the apps on its own), and
    // LAN git servers are exactly where plain http lives.
    NSString *lower = in.lowercaseString;
    if ([lower hasPrefix:@"https://"] || [lower hasPrefix:@"http://"]) {
        if ([lower hasSuffix:@".git"]) in = [in substringToIndex:in.length - 4];
        NSURL *url = [NSURL URLWithString:in];
        if (!url || url.host.length == 0 || url.path.length < 2) return nil;
        NSString *hostPort = url.port
            ? [NSString stringWithFormat:@"%@:%@", url.host, url.port]
            : url.host;
        // Repo-page URL — exactly /owner/repo, no query, not a file —
        // derives the Gitea/Forgejo raw layout:
        //   {scheme}://{host}/{owner}/{repo}/raw/branch/{branch}/.beads/issues.jsonl
        // The derived raw URL becomes the spec, so fetching, Bearer auth
        // and Keychain identity ride the existing direct-URL machinery.
        // (GitLab's /-/raw/ layout differs — paste its raw URL directly.)
        NSArray<NSString *> *parts =
            [[url.path stringByTrimmingCharactersInSet:
              [NSCharacterSet characterSetWithCharactersInString:@"/"]]
             componentsSeparatedByString:@"/"];
        BOOL looksLikeFile = [url.lastPathComponent.lowercaseString hasSuffix:@".jsonl"];
        if (parts.count == 2 && parts[0].length && parts[1].length &&
            url.query.length == 0 && !looksLikeFile) {
            NSString *brEnc = [br stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLPathAllowedCharacterSet]];
            if (outDisplay) *outDisplay = [NSString stringWithFormat:@"%@/%@/%@ @ %@",
                                           hostPort, parts[0], parts[1], br];
            return [NSString stringWithFormat:
                    @"%@://%@/%@/%@/raw/branch/%@/.beads/issues.jsonl",
                    url.scheme, hostPort, parts[0], parts[1], brEnc];
        }
        // Anything else: a direct link to the raw file, fetched as-is.
        if (outDisplay) *outDisplay = [NSString stringWithFormat:@"%@ (%@)",
                                       url.host, url.lastPathComponent];
        return url.absoluteString;
    }
    return nil;
}

// Build the fetch request for a spec. Exposed via initWithSpec:.
static NSURLRequest *requestForSpec(NSString *spec, NSString *token) {
    NSURL *url = nil;
    BOOL isGitHub = [spec hasPrefix:@"github.com/"];
    if (isGitHub) {
        NSString *rest = [spec substringFromIndex:@"github.com/".length];
        NSRange at = [rest rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location == NSNotFound) return nil;
        NSString *ownerRepo = [rest substringToIndex:at.location];
        NSString *branch    = [rest substringFromIndex:at.location + 1];
        if (ownerRepo.length == 0 || branch.length == 0) return nil;
        NSCharacterSet *pathOK = [NSCharacterSet URLPathAllowedCharacterSet];
        NSString *orEnc = [ownerRepo stringByAddingPercentEncodingWithAllowedCharacters:pathOK];
        NSString *brEnc = [branch stringByAddingPercentEncodingWithAllowedCharacters:pathOK];
        if (token.length) {
            NSString *brQ = [branch stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
            url = [NSURL URLWithString:[NSString stringWithFormat:
                   @"https://api.github.com/repos/%@/contents/.beads/issues.jsonl?ref=%@",
                   orEnc, brQ]];
        } else {
            url = [NSURL URLWithString:[NSString stringWithFormat:
                   @"https://raw.githubusercontent.com/%@/%@/.beads/issues.jsonl",
                   orEnc, brEnc]];
        }
    } else {
        url = [NSURL URLWithString:spec];
    }
    if (!url) return nil;

    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:30.0];
    // Generic client name only — never user details (api.github.com
    // requires SOME User-Agent).
    [req setValue:@"NppBeads" forHTTPHeaderField:@"User-Agent"];
    if (isGitHub && token.length) {
        [req setValue:@"application/vnd.github.raw+json" forHTTPHeaderField:@"Accept"];
        [req setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    }
    if (token.length) {
        [req setValue:[@"Bearer " stringByAppendingString:token]
            forHTTPHeaderField:@"Authorization"];
    }
    return req;
}

// ─────────────────────────────────────────────────────────────────────
//  Keychain — token storage. The token is the ONLY secret; it never
//  touches NSUserDefaults or logs.
// ─────────────────────────────────────────────────────────────────────

static NSMutableDictionary *keychainQueryForSpec(NSString *spec) {
    return [@{(__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kKeychainService,
              (__bridge id)kSecAttrAccount: spec} mutableCopy];
}

+ (void)storeToken:(NSString *)token forSpec:(NSString *)spec {
    if (spec.length == 0) return;
    SecItemDelete((__bridge CFDictionaryRef)keychainQueryForSpec(spec));
    if (token.length == 0) return;    // empty = "no token" = delete only
    NSMutableDictionary *add = keychainQueryForSpec(spec);
    add[(__bridge id)kSecValueData] = [token dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st != errSecSuccess) {
        NSLog(@"[NppBeads] remote: keychain store failed (OSStatus %d)", (int)st);
    }
}

+ (NSString *)tokenForSpec:(NSString *)spec {
    if (spec.length == 0) return nil;
    NSMutableDictionary *q = keychainQueryForSpec(spec);
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    if (st != errSecSuccess || !out) return nil;
    NSData *data = CFBridgingRelease(out);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// ─────────────────────────────────────────────────────────────────────
//  Polling
// ─────────────────────────────────────────────────────────────────────

- (instancetype)initWithSpec:(NSString *)spec token:(NSString *)token {
    if (!(self = [super init])) return nil;
    _spec  = [spec copy];
    _token = [token copy];
    _baseRequest = requestForSpec(_spec, _token);
    return self;
}

- (void)start {
    if (_timer) return;
    if (!_baseRequest) {
        _lastError = @"malformed remote spec";
        if (self.onError) self.onError(_lastError);
        return;
    }
    __weak typeof(self) weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    dispatch_get_main_queue());
    dispatch_source_set_timer(_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
        (uint64_t)(kPollInterval * NSEC_PER_SEC),
        5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        if (s->_paused) { s->_pendingTick = YES; return; }
        [s _fetch];
    });
    dispatch_resume(_timer);
    [self _fetch];
}

- (void)stop {
    _generation++;                 // orphan any in-flight completion
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    [_task cancel];
    _task = nil;
}

- (void)pause  { _paused = YES; }
- (void)resume {
    if (!_paused) return;
    _paused = NO;
    if (_pendingTick) { _pendingTick = NO; [self _fetch]; }
}

- (void)kick {
    if (_paused) { _pendingTick = YES; return; }
    [self _fetch];
}

- (void)_fetch {
    if (_task || !_baseRequest) return;        // one in flight at a time
    NSMutableURLRequest *req = [_baseRequest mutableCopy];
    if (_etag.length) [req setValue:_etag forHTTPHeaderField:@"If-None-Match"];

    NSUInteger gen = _generation;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s || s->_generation != gen) return;
            s->_task = nil;
            [s _handleData:data response:(NSHTTPURLResponse *)resp error:err];
        });
    }];
    _task = task;
    [task resume];
}

- (void)_handleData:(NSData *)data
           response:(NSHTTPURLResponse *)http
              error:(NSError *)err {
    if (err) {
        if (err.code == NSURLErrorCancelled) return;
        [self _fail:[NSString stringWithFormat:@"network error — %@",
                     err.localizedDescription]];
        return;
    }
    NSInteger code = http.statusCode;
    if (code == 304) { _lastError = nil; return; }        // unchanged
    if (code == 401 || code == 403) {
        [self _fail:[NSString stringWithFormat:
            @"authorization failed (HTTP %ld) — check the access token", (long)code]];
        return;
    }
    if (code == 404) {
        [self _fail:@"not found (HTTP 404) — wrong repo/branch, no "
                     ".beads/issues.jsonl, or a private repo without a token"];
        return;
    }
    if (code != 200 || !data) {
        [self _fail:[NSString stringWithFormat:@"fetch failed (HTTP %ld)", (long)code]];
        return;
    }
    _lastError = nil;
    _etag = [http valueForHTTPHeaderField:@"ETag"];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                  ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]
                  ?: @"";
    // Without an ETag (some forges), gate on length so an identical body
    // doesn't thrash the webview every minute.
    if (_etag.length == 0 && text.length == _lastLength && _lastLength > 0) return;
    _lastLength = text.length;
    if (self.onText) self.onText(text);
}

- (void)_fail:(NSString *)message {
    _lastError = message;
    if (self.onError) self.onError(message);
}

@end
