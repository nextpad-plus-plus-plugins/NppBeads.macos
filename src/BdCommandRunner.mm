#import "BdCommandRunner.h"
#import <sys/stat.h>

// ─────────────────────────────────────────────────────────────────────
//  Error classification — regexes pulled from live observation against
//  bd 1.0.2. Update cautiously; user UX hinges on these.
// ─────────────────────────────────────────────────────────────────────
//   "cannot close bd-abc: blocked by open issues [bd-def, bd-xyz]"
//   "(use --force to override)"
static NSRegularExpression *kRxBlockedBy;
//   "issue not found"  /  "no issue with id"
static NSRegularExpression *kRxNotFound;
//   "already claimed by <actor>"  /  "currently assigned to"
static NSRegularExpression *kRxAlreadyClaimed;
//   "cycle detected"  /  "would create cycle"
static NSRegularExpression *kRxCycle;
//   "database is locked"  /  "lock held"  /  "file lock"
static NSRegularExpression *kRxLocked;
//   "no beads database found"  /  "database name must not be empty"
//   /  "no beads configuration"
static NSRegularExpression *kRxNotInProject;
// auto-push stderr (non-fatal when exit == 0):
//   "dolt auto-push failed"  /  "git command failed (exit 128)"
//   /  "could not read Username for"  /  "force-with-lease=refs/dolt/data"
static NSRegularExpression *kRxAutoPushWarning;

static void initRegexesOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSRegularExpressionOptions opts = NSRegularExpressionCaseInsensitive;
        kRxBlockedBy       = [NSRegularExpression
            regularExpressionWithPattern:@"blocked by open issues \\[([^\\]]+)\\]"
                                 options:opts error:nil];
        kRxNotFound        = [NSRegularExpression
            regularExpressionWithPattern:@"issue not found|no issue with id|no issue found|not found: [a-z]+-"
                                 options:opts error:nil];
        kRxAlreadyClaimed  = [NSRegularExpression
            regularExpressionWithPattern:@"already claimed by|currently (?:assigned|claimed)"
                                 options:opts error:nil];
        kRxCycle           = [NSRegularExpression
            regularExpressionWithPattern:@"cycle detected|would create (?:a )?cycle|circular dependency"
                                 options:opts error:nil];
        kRxLocked          = [NSRegularExpression
            regularExpressionWithPattern:@"database is locked|lock (?:is )?held|file lock|could not acquire lock"
                                 options:opts error:nil];
        kRxNotInProject    = [NSRegularExpression
            regularExpressionWithPattern:@"no beads database found|database name must not be empty|no beads configuration"
                                 options:opts error:nil];
        kRxAutoPushWarning = [NSRegularExpression
            regularExpressionWithPattern:@"dolt auto-push failed|git command failed|could not read username for|force-with-lease=refs/dolt|Device not configured"
                                 options:opts error:nil];
    });
}

// ─────────────────────────────────────────────────────────────────────
//  BdResult
// ─────────────────────────────────────────────────────────────────────
@interface BdResult ()
@property (nonatomic, assign) BOOL              ok;
@property (nonatomic, assign) int               exitCode;
@property (nonatomic, strong, nullable) id      json;
@property (nonatomic, copy,   nullable) NSString *errorMessage;
@property (nonatomic, copy)             NSArray<NSString *> *warnings;
@property (nonatomic, copy,   nullable) NSString *rawStdout;
@property (nonatomic, copy,   nullable) NSString *rawStderr;
@property (nonatomic, assign) NSTimeInterval    elapsed;
@property (nonatomic, copy)             NSArray<NSString *> *argv;
@end

@implementation BdResult

- (instancetype)init {
    if ((self = [super init])) {
        _warnings = @[];
        _argv     = @[];
    }
    return self;
}

- (BdErrorKind)errorKind {
    if (self.ok) return BdErrorKindNone;
    NSString *s = [(self.errorMessage ?: self.rawStderr ?: @"") lowercaseString];
    if (s.length == 0) return BdErrorKindGeneric;
    initRegexesOnce();
    NSRange all = NSMakeRange(0, s.length);
    if ([kRxNotInProject   firstMatchInString:s options:0 range:all]) return BdErrorKindNotInProject;
    if ([kRxBlockedBy      firstMatchInString:s options:0 range:all]) return BdErrorKindBlockedByDeps;
    if ([kRxAlreadyClaimed firstMatchInString:s options:0 range:all]) return BdErrorKindAlreadyClaimed;
    if ([kRxCycle          firstMatchInString:s options:0 range:all]) return BdErrorKindCycle;
    if ([kRxLocked         firstMatchInString:s options:0 range:all]) return BdErrorKindLocked;
    if ([kRxNotFound       firstMatchInString:s options:0 range:all]) return BdErrorKindNotFound;
    return BdErrorKindGeneric;
}

- (NSArray<NSString *> *)blockerIds {
    if (self.errorKind != BdErrorKindBlockedByDeps) return @[];
    NSString *src = self.errorMessage ?: self.rawStderr ?: @"";
    initRegexesOnce();
    NSTextCheckingResult *m = [kRxBlockedBy firstMatchInString:src.lowercaseString
                                                       options:0
                                                         range:NSMakeRange(0, src.length)];
    if (!m || m.numberOfRanges < 2) return @[];
    NSString *inside = [src substringWithRange:[m rangeAtIndex:1]];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *piece in [inside componentsSeparatedByString:@","]) {
        NSString *trimmed = [piece stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) [out addObject:trimmed];
    }
    return out;
}
@end

// ─────────────────────────────────────────────────────────────────────
//  Private helpers
// ─────────────────────────────────────────────────────────────────────

// Find `bd` in PATH. We can't rely on NSProcessInfo.environment[@"PATH"] —
// Notepad++ when launched from Finder gets a minimal PATH that excludes
// /opt/homebrew/bin (where brew installs). So we walk a known list.
static NSString * _Nullable resolveBdBinary(void) {
    NSArray *candidates = @[
        @"/opt/homebrew/bin/bd",       // Apple Silicon brew
        @"/usr/local/bin/bd",          // Intel brew
        @"/usr/bin/bd",                // system
        [NSHomeDirectory() stringByAppendingPathComponent:@"bin/bd"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/bd"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"go/bin/bd"],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    // Last resort: try the process env PATH (works if user launches Npp
    // from a shell terminal that has brew in PATH).
    NSString *envPath = [[NSProcessInfo processInfo] environment][@"PATH"];
    if (envPath.length) {
        for (NSString *dir in [envPath componentsSeparatedByString:@":"]) {
            NSString *p = [dir stringByAppendingPathComponent:@"bd"];
            if ([fm isExecutableFileAtPath:p]) return p;
        }
    }
    return nil;
}

// Classify a stderr line as either auto-push warning (non-fatal) or
// real error. We scan line-by-line so mixed streams work.
static BOOL stderrLineIsAutoPushWarning(NSString *line) {
    if (line.length == 0) return YES;  // blanks are harmless
    initRegexesOnce();
    return [kRxAutoPushWarning firstMatchInString:line.lowercaseString
                                          options:0
                                            range:NSMakeRange(0, line.length)] != nil;
}

// Parse JSON from stdout. Accepts either array or object (bd's mix).
// Returns (json, nil) or (nil, errorMessage).
static id parseBdJson(NSString *stdoutStr, NSString **outError) {
    NSString *trimmed = [stdoutStr stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        if (outError) *outError = nil;   // empty is legitimate (close sometimes)
        return nil;
    }
    NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!parsed) {
        if (outError) *outError = [NSString stringWithFormat:@"JSON parse: %@",
                                   err.localizedDescription];
        return nil;
    }
    return parsed;
}

// If stderr is JSON (bd's --json error form), extract the `error` field.
// Otherwise return the first non-warning stderr line.
//
// bd's permissions warning looks like:
//   Warning: /path/to/.beads has permissions 0755 (recommended: 0700).
//   Run: chmod 700 /path/to/.beads
// The second line has no "Warning:" prefix, so we track whether we're
// still inside a warning block and skip subsequent continuation lines
// until we hit either a blank line or a genuinely new message.
static NSString * _Nullable extractStderrError(NSString *stderrStr) {
    NSString *trimmed = [stderrStr stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    // Try as JSON first
    NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([parsed isKindOfClass:[NSDictionary class]]) {
        NSString *msg = [(NSDictionary *)parsed objectForKey:@"error"];
        if ([msg isKindOfClass:[NSString class]] && msg.length) return msg;
    }
    // Fall back: walk lines, skipping warning blocks (prefix + continuations).
    BOOL inWarnBlock = NO;
    for (NSString *rawLine in [trimmed componentsSeparatedByString:@"\n"]) {
        NSString *t = [rawLine stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length == 0) { inWarnBlock = NO; continue; }
        if ([t hasPrefix:@"Warning:"] || [t hasPrefix:@"warning:"] ||
            [t hasPrefix:@"Hint:"]    || [t hasPrefix:@"Run:"]     ||
            [t hasPrefix:@"- "])       { inWarnBlock = YES; continue; }
        if (stderrLineIsAutoPushWarning(t)) { inWarnBlock = YES; continue; }
        if (inWarnBlock)                { continue; }
        return t;
    }
    // Everything was warnings — return nil so the caller falls through
    // to stdout-JSON or a synthetic "bd exited N" message.
    return nil;
}

static NSArray<NSString *> *collectStderrWarnings(NSString *stderrStr) {
    if (stderrStr.length == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [stderrStr componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (t.length == 0) continue;
        if (stderrLineIsAutoPushWarning(t)) [out addObject:t];
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────
//  Cache entry
// ─────────────────────────────────────────────────────────────────────
@interface BdCacheEntry : NSObject
@property (nonatomic, strong) BdResult *result;
@property (nonatomic, assign) NSTimeInterval expiresAt;
@end
@implementation BdCacheEntry @end

// ─────────────────────────────────────────────────────────────────────
//  BdCommandRunner impl
// ─────────────────────────────────────────────────────────────────────
@implementation BdCommandRunner {
    dispatch_queue_t _ioQueue;
    NSMutableDictionary<NSString *, BdCacheEntry *> *_cache;   // key = cmd joined
    dispatch_queue_t _cacheQueue;
    BOOL   _probed;
    BOOL   _projectReady;
}

- (instancetype)initWithProjectDir:(NSString *)projectDir {
    if ((self = [super init])) {
        _projectDir = [projectDir copy];
        _ioQueue = dispatch_queue_create("org.notepadplusplus.mac.NppBeads.bdrunner.io",
                                          DISPATCH_QUEUE_CONCURRENT);
        _cacheQueue = dispatch_queue_create("org.notepadplusplus.mac.NppBeads.bdrunner.cache",
                                             DISPATCH_QUEUE_CONCURRENT);
        _cache = [NSMutableDictionary dictionary];
        NSString *user = NSUserName() ?: @"user";
        _actor = [[NSString alloc] initWithFormat:@"NppBeads/%@", user];
        _useSandbox = YES;   // See BdCommandRunner.h useSandbox for rationale.
    }
    return self;
}

- (void)invalidateCache {
    dispatch_barrier_async(_cacheQueue, ^{ [self->_cache removeAllObjects]; });
}

// ─────────────────────────────────────────────────────────────────────
//  Low-level: execute an `bd` invocation. Synchronous (on our ioQueue).
// ─────────────────────────────────────────────────────────────────────
- (BdResult *)_execute:(NSArray<NSString *> *)args
                 stdin:(nullable NSString *)stdinText {
    return [self _execute:args stdin:stdinText expectsJson:YES];
}

// Variant that can skip JSON parsing — needed for `bd version` and
// `bd info` during probe (plain-text output).
- (BdResult *)_execute:(NSArray<NSString *> *)args
                 stdin:(nullable NSString *)stdinText
           expectsJson:(BOOL)expectsJson {
    BdResult *res = [[BdResult alloc] init];
    res.argv = args;

    NSString *bd = self.bdPath ?: resolveBdBinary();
    if (!bd) {
        res.errorMessage = @"bd binary not found in PATH";
        res.rawStderr = res.errorMessage;
        return res;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = bd;
    // `--sandbox` disables bd's dolt auto-push. Without it, every bd
    // read/write hangs for ~23s on projects where git push auth fails
    // non-interactively (the default state for fresh clones / private
    // repos with no credential helper). Running local-only is the
    // correct default for a plugin — users who want replication can
    // `bd sync` from a terminal.
    //
    // Phase 3.5: users who DO have working non-interactive git auth and
    // want auto-push can flip self.useSandbox = NO per project (wired
    // from NppBeadsAutoPushProjects defaults in BeadsPanel.bindProject:).
    NSMutableArray *finalArgs = [NSMutableArray arrayWithCapacity:args.count + 1];
    if (self.useSandbox) [finalArgs addObject:@"--sandbox"];
    [finalArgs addObjectsFromArray:args];
    task.arguments  = finalArgs;
    task.currentDirectoryURL = [NSURL fileURLWithPath:self.projectDir
                                           isDirectory:YES];

    // Build env: inherit, then force BEADS_ACTOR and LANG so non-UTF8
    // locales don't break bd's output.
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"BEADS_ACTOR"] = self.actor ?: @"NppBeads";
    if (!env[@"LANG"]) env[@"LANG"] = @"en_US.UTF-8";
    // Make sure PATH includes the common brew locations so any git hook
    // bd might invoke can find its helpers.
    NSString *path = env[@"PATH"] ?: @"";
    NSArray *injected = @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin"];
    for (NSString *p in injected) {
        if ([path rangeOfString:p].location == NSNotFound) {
            path = [NSString stringWithFormat:@"%@:%@", p, path];
        }
    }
    env[@"PATH"] = path;
    task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    NSPipe *inPipe  = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = errPipe;
    task.standardInput  = inPipe;

    NSDate *t0 = [NSDate date];
    NSError *launchErr = nil;
    @try {
        if (![task launchAndReturnError:&launchErr]) {
            res.errorMessage = [NSString stringWithFormat:@"bd launch failed: %@",
                                launchErr.localizedDescription ?: @"unknown"];
            return res;
        }
    } @catch (NSException *ex) {
        res.errorMessage = [NSString stringWithFormat:@"bd launch exception: %@", ex.reason];
        return res;
    }

    // Feed stdin if provided (for description via stdin, etc.).
    if (stdinText.length) {
        NSData *input = [stdinText dataUsingEncoding:NSUTF8StringEncoding];
        if (input) [[inPipe fileHandleForWriting] writeData:input];
    }
    [[inPipe fileHandleForWriting] closeFile];

    // Drain pipes in background so we don't deadlock on >64KB of output.
    __block NSMutableData *stdoutData = [NSMutableData data];
    __block NSMutableData *stderrData = [NSMutableData data];
    dispatch_semaphore_t stdoutDone = dispatch_semaphore_create(0);
    dispatch_semaphore_t stderrDone = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileHandle *fh = [outPipe fileHandleForReading];
        NSData *chunk;
        while ((chunk = [fh availableData]) && chunk.length) {
            [stdoutData appendData:chunk];
        }
        dispatch_semaphore_signal(stdoutDone);
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileHandle *fh = [errPipe fileHandleForReading];
        NSData *chunk;
        while ((chunk = [fh availableData]) && chunk.length) {
            [stderrData appendData:chunk];
        }
        dispatch_semaphore_signal(stderrDone);
    });

    [task waitUntilExit];
    dispatch_semaphore_wait(stdoutDone, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(stderrDone, DISPATCH_TIME_FOREVER);

    res.exitCode = task.terminationStatus;
    res.elapsed  = -[t0 timeIntervalSinceNow];
    res.rawStdout = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
    res.rawStderr = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];

    // Parse JSON only when the caller expects it — `bd version` / `bd info`
    // emit plain text and their "not valid JSON" shouldn't flip ok=NO.
    NSString *parseErr = nil;
    if (expectsJson) {
        res.json = parseBdJson(res.rawStdout ?: @"", &parseErr);
    }
    res.warnings = collectStderrWarnings(res.rawStderr ?: @"");

    // When bd exits non-zero with `--json`, the actual error lands on
    // stdout as `{"error": "…"}` (stderr only carries the permissions
    // warning). Pull it from there before falling back to stderr.
    NSString *stdoutJsonError = nil;
    if ([res.json isKindOfClass:[NSDictionary class]]) {
        id e = [(NSDictionary *)res.json objectForKey:@"error"];
        if ([e isKindOfClass:[NSString class]] && [(NSString *)e length]) {
            stdoutJsonError = e;
        }
    }

    if (res.exitCode == 0 && !parseErr && !stdoutJsonError) {
        res.ok = YES;
        res.errorMessage = nil;
    } else {
        res.ok = NO;
        res.errorMessage = stdoutJsonError ?: parseErr ?:
                           extractStderrError(res.rawStderr ?: @"") ?:
                           [NSString stringWithFormat:@"bd exited %d", res.exitCode];
    }
    // Trace every bd invocation — indispensable for diagnosing writes
    // that silently no-op (wrong cwd, stripped env, bd error we missed).
    NSString *argvStr = [args componentsJoinedByString:@" "];
    if (res.ok) {
        NSLog(@"[NppBeads] bd %@ → ok (exit=%d, %.2fs%@)", argvStr,
              res.exitCode, res.elapsed,
              res.warnings.count ? [NSString stringWithFormat:@", %lu warn",
                                    (unsigned long)res.warnings.count] : @"");
    } else {
        NSLog(@"[NppBeads] bd %@ → FAIL exit=%d err=%@ stderr=%@",
              argvStr, res.exitCode,
              res.errorMessage ?: @"(nil)",
              res.rawStderr.length ? res.rawStderr : @"(empty)");
    }
    return res;
}

// Cache wrapper: key is args joined by | plus a digest of bdPath.
- (nullable BdResult *)_cachedForKey:(NSString *)key ttl:(NSTimeInterval)ttl {
    __block BdResult *hit = nil;
    dispatch_sync(_cacheQueue, ^{
        BdCacheEntry *e = self->_cache[key];
        if (e && e.expiresAt > CFAbsoluteTimeGetCurrent()) hit = e.result;
    });
    return hit;
}

- (void)_cacheStore:(BdResult *)res key:(NSString *)key ttl:(NSTimeInterval)ttl {
    if (!res.ok) return;
    BdCacheEntry *e = [[BdCacheEntry alloc] init];
    e.result = res;
    e.expiresAt = CFAbsoluteTimeGetCurrent() + ttl;
    dispatch_barrier_async(_cacheQueue, ^{ self->_cache[key] = e; });
}

- (void)_runOnIoQueue:(dispatch_block_t)block {
    dispatch_async(_ioQueue, block);
}

// ─────────────────────────────────────────────────────────────────────
//  Probe
// ─────────────────────────────────────────────────────────────────────
- (void)probeWithCompletion:(void (^)(BOOL, BOOL))done {
    [self probeWithCompletion:done refresh:NO];
}

- (void)probeWithCompletion:(void (^)(BOOL, BOOL))done refresh:(BOOL)force {
    if (_probed && !force) {
        BOOL bdOk = self.bdPath != nil;
        BOOL ok   = _projectReady;
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(bdOk, ok); });
        return;
    }
    [self _runOnIoQueue:^{
        self->_bdPath = [resolveBdBinary() copy];
        if (!self->_bdPath) {
            self->_probed = YES;
            self->_projectReady = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, NO); });
            return;
        }
        // bd version (plain text, not JSON)
        BdResult *v = [self _execute:@[@"version"] stdin:nil expectsJson:NO];
        if (v.ok && v.rawStdout.length) {
            // Parse "bd version 1.0.2 (Homebrew)" → "1.0.2"
            NSRegularExpression *r = [NSRegularExpression
                regularExpressionWithPattern:@"version\\s+([0-9][\\w.\\-]+)"
                options:NSRegularExpressionCaseInsensitive error:nil];
            NSTextCheckingResult *m = [r firstMatchInString:v.rawStdout options:0
                                                     range:NSMakeRange(0, v.rawStdout.length)];
            if (m && m.numberOfRanges > 1) {
                self->_bdVersion = [[v.rawStdout substringWithRange:[m rangeAtIndex:1]] copy];
            }
        }
        // Project readiness — `bd info` (plain text) exits 0 on a usable project.
        BdResult *info = [self _execute:@[@"info"] stdin:nil expectsJson:NO];
        self->_projectReady = info.ok;
        self->_probed = YES;
        BOOL bdOk = YES, ready = self->_projectReady;
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(bdOk, ready); });
    }];
}

// ─────────────────────────────────────────────────────────────────────
//  Read commands
// ─────────────────────────────────────────────────────────────────────
- (void)listAllIssuesWithCompletion:(void (^)(BdResult *))done {
    NSString *key = @"list|--all";
    BdResult *hit = [self _cachedForKey:key ttl:0.75];
    if (hit) { dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(hit); }); return; }
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"list", @"--all", @"--json"] stdin:nil];
        if (r.ok) [self _cacheStore:r key:key ttl:0.75];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)showIssue:(NSString *)issueId completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    NSString *key = [NSString stringWithFormat:@"show|%@", issueId];
    BdResult *hit = [self _cachedForKey:key ttl:0.25];
    if (hit) { dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(hit); }); return; }
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"show", issueId, @"--json"] stdin:nil];
        // bd show --json returns an ARRAY even for a single id. Unwrap.
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)r.json;
            r.json = (arr.count > 0) ? arr.firstObject : nil;
        }
        if (r.ok && r.json == nil) {
            r.ok = NO;
            r.errorMessage = @"bd show returned empty — issue likely not found";
        }
        if (r.ok) [self _cacheStore:r key:key ttl:0.25];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)readyWithCompletion:(void (^)(BdResult *))done {
    NSString *key = @"ready";
    BdResult *hit = [self _cachedForKey:key ttl:0.75];
    if (hit) { dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(hit); }); return; }
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"ready", @"--json"] stdin:nil];
        if (r.ok) [self _cacheStore:r key:key ttl:0.75];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

// ─────────────────────────────────────────────────────────────────────
//  Write commands
// ─────────────────────────────────────────────────────────────────────
- (void)createIssueWithTitle:(NSString *)title
                        type:(nullable NSString *)issueType
                    priority:(nullable NSNumber *)priority
                 description:(nullable NSString *)description
                      labels:(nullable NSArray<NSString *> *)labels
                  completion:(void (^)(BdResult *))done {
    if (title.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"title is required";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"create", title, nil];
    if (issueType.length) { [args addObject:@"-t"]; [args addObject:issueType]; }
    if (priority)         { [args addObject:@"-p"]; [args addObject:priority.stringValue]; }
    // Description may contain newlines / shell chars — route via stdin.
    NSString *stdinText = nil;
    if (description.length) {
        if ([description containsString:@"\n"] ||
            [description rangeOfCharacterFromSet:
             [NSCharacterSet characterSetWithCharactersInString:@"\"$`\\"]].location != NSNotFound) {
            [args addObject:@"--body-file=-"];
            stdinText = description;
        } else {
            [args addObject:@"-d"]; [args addObject:description];
        }
    }
    for (NSString *l in labels) {
        if (l.length) { [args addObject:@"-l"]; [args addObject:l]; }
    }
    [args addObject:@"--json"];
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:args stdin:stdinText];
        // bd create returns an ARRAY; unwrap to single object for UI clarity.
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)r.json;
            if (a.count) r.json = a.firstObject;
        }
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)updateIssue:(NSString *)issueId
              title:(nullable NSString *)title
        description:(nullable NSString *)description
             status:(nullable NSString *)status
           priority:(nullable NSNumber *)priority
               type:(nullable NSString *)issueType
           assignee:(nullable NSString *)assignee
          addLabels:(nullable NSArray<NSString *> *)addLabels
       removeLabels:(nullable NSArray<NSString *> *)removeLabels
         completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"update", issueId, nil];
    if (title.length)       { [args addObject:@"--title"];       [args addObject:title]; }
    if (status.length)      { [args addObject:@"--status"];      [args addObject:status]; }
    if (priority)           { [args addObject:@"--priority"];    [args addObject:priority.stringValue]; }
    if (issueType.length)   { [args addObject:@"--type"];        [args addObject:issueType]; }
    if (assignee.length)    { [args addObject:@"--assignee"];    [args addObject:assignee]; }
    NSString *stdinText = nil;
    if (description != nil) {  // allow "" to clear
        if ([description containsString:@"\n"] ||
            [description rangeOfCharacterFromSet:
             [NSCharacterSet characterSetWithCharactersInString:@"\"$`\\"]].location != NSNotFound) {
            [args addObject:@"--description-file=-"];
            stdinText = description;
        } else {
            [args addObject:@"--description"]; [args addObject:description];
        }
    }
    if (addLabels.count)    {
        [args addObject:@"--add-label"];
        [args addObject:[addLabels componentsJoinedByString:@","]];
    }
    if (removeLabels.count) {
        [args addObject:@"--remove-label"];
        [args addObject:[removeLabels componentsJoinedByString:@","]];
    }
    [args addObject:@"--json"];
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:args stdin:stdinText];
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)r.json;
            if (a.count) r.json = a.firstObject;
        }
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)claimIssue:(NSString *)issueId completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"update", issueId, @"--claim", @"--json"] stdin:nil];
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)r.json;
            if (a.count) r.json = a.firstObject;
        }
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)closeIssue:(NSString *)issueId
            reason:(nullable NSString *)reason
             force:(BOOL)force
        completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"close", issueId, nil];
    if (force)         [args addObject:@"--force"];
    if (reason.length) { [args addObject:@"--reason"]; [args addObject:reason]; }
    [args addObject:@"--json"];
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:args stdin:nil];
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)r.json;
            if (a.count) r.json = a.firstObject;
        }
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)reopenIssue:(NSString *)issueId
             reason:(nullable NSString *)reason
         completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"reopen", issueId, nil];
    if (reason.length) { [args addObject:@"--reason"]; [args addObject:reason]; }
    [args addObject:@"--json"];
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:args stdin:nil];
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)r.json;
            if (a.count) r.json = a.firstObject;
        }
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)addDependencyFromIssue:(NSString *)dependentId
                      toIssue:(NSString *)dependencyId
                         type:(NSString *)depType
                   completion:(void (^)(BdResult *))done {
    if (dependentId.length == 0 || dependencyId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"dependentId and dependencyId both required";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    NSString *type = depType.length ? depType : @"blocks";
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"dep", @"add", dependentId, dependencyId,
                                        @"--type", type, @"--json"] stdin:nil];
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)removeDependencyFromIssue:(NSString *)dependentId
                         toIssue:(NSString *)dependencyId
                      completion:(void (^)(BdResult *))done {
    if (dependentId.length == 0 || dependencyId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"dependentId and dependencyId both required";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"dep", @"remove", dependentId, dependencyId,
                                        @"--json"] stdin:nil];
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)deleteIssue:(NSString *)issueId completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    [self _runOnIoQueue:^{
        // `bd delete` is irreversible and has no partial-failure mode in
        // 1.0.2 — either it deletes or it errors. The --force flag skips
        // the "are you sure?" interactive prompt that terminal bd shows;
        // we always pass it because our UI already confirmed with the user.
        BdResult *r = [self _execute:@[@"delete", issueId, @"--force", @"--json"]
                                stdin:nil];
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)unassignIssue:(NSString *)issueId completion:(void (^)(BdResult *))done {
    if (issueId.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = @"issueId is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    [self _runOnIoQueue:^{
        BdResult *r = [self _execute:@[@"update", issueId, @"--unassign", @"--json"]
                                stdin:nil];
        // bd update returns an array — unwrap for UI clarity.
        if (r.ok && [r.json isKindOfClass:[NSArray class]]) {
            NSArray *a = (NSArray *)r.json;
            if (a.count) r.json = a.firstObject;
        }
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

- (void)addCommentToIssue:(NSString *)issueId
                     body:(NSString *)body
               completion:(void (^)(BdResult *))done {
    if (issueId.length == 0 || body.length == 0) {
        BdResult *r = [[BdResult alloc] init];
        r.errorMessage = (issueId.length == 0) ? @"issueId is empty"
                                                : @"comment body is empty";
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
        return;
    }
    [self _runOnIoQueue:^{
        // bd 1.0.2 CLI: `bd comment <id> --stdin` — the singular `comment`
        // is itself the add shorthand (there is no `comment add` subcommand),
        // and the old `--body-file` flag no longer exists on it (that was the
        // "unknown flag: --body-file" failure). Routing the body via stdin
        // survives newlines, quotes, $, backticks, and anything else pasted.
        BdResult *r = [self _execute:@[@"comment", issueId,
                                        @"--stdin", @"--json"]
                                stdin:body];
        if (r.ok) [self invalidateCache];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r); });
    }];
}

@end
