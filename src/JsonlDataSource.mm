#import "JsonlDataSource.h"

@implementation JsonlDataSource {
    NSString            *_cachedText;     // raw file contents
    NSArray<NSDictionary *> *_cachedIssues;  // parsed rows
    BOOL                 _loaded;
    // Counters computed alongside parse so status bar doesn't re-iterate.
    NSUInteger           _cntOpen, _cntBlocked, _cntClosed;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedText   = @"";
        _cachedIssues = @[];
    }
    return self;
}

- (void)bindToPath:(NSString *)path {
    if (_jsonlPath == path || [_jsonlPath isEqualToString:path]) return;
    _jsonlPath = [path copy];
    _fedExternally = NO;   // fresh project → file is the truth until told otherwise
    [self reload];
}

- (void)reload {
    if (_fedExternally) return;   // adopted (Dolt-exported) text is current
    _loaded       = NO;
    _cachedText   = @"";
    _cachedIssues = @[];
    _cntOpen      = 0;
    _cntBlocked   = 0;
    _cntClosed    = 0;
}

- (void)adoptRawText:(NSString *)text {
    _loaded = YES;
    [self _ingestText:(text ?: @"")];
}

- (void)_loadIfNeeded {
    if (_loaded) return;
    _loaded = YES;  // set first so a parse failure doesn't re-loop

    NSString *path = self.jsonlPath;
    if (path.length == 0) return;

    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:&readErr];
    if (!data) {
        NSLog(@"[NppBeads] JSONL read failed: %@ → %@", path, readErr.localizedDescription);
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        // Lossy fallback so we don't lose the whole file to one bad byte.
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!text) text = @"";
    [self _ingestText:text];
}

// Shared by the file path and adoptRawText: — parse + recount.
- (void)_ingestText:(NSString *)text {
    _cachedText = text;
    _cntOpen = 0; _cntBlocked = 0; _cntClosed = 0;

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) return;
        NSData *lineData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        if (!lineData) return;
        NSError *jerr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:lineData
                                                 options:0
                                                   error:&jerr];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            if (jerr) {
                NSLog(@"[NppBeads] JSONL line skipped (parse error): %@",
                      jerr.localizedDescription);
            }
            return;
        }
        [rows addObject:obj];
    }];
    _cachedIssues = [rows copy];

    // Count statuses once.
    for (NSDictionary *r in _cachedIssues) {
        NSString *s = r[@"status"];
        if (![s isKindOfClass:[NSString class]]) continue;
        if ([s isEqualToString:@"closed"])      _cntClosed++;
        else if ([s isEqualToString:@"blocked"]) _cntBlocked++;
        else                                     _cntOpen++;
    }
}

- (NSString *)rawText   { [self _loadIfNeeded]; return _cachedText ?: @""; }
- (NSArray<NSDictionary *> *)issues { [self _loadIfNeeded]; return _cachedIssues ?: @[]; }
- (NSUInteger)issueCount       { [self _loadIfNeeded]; return _cachedIssues.count; }
- (NSUInteger)openIssueCount   { [self _loadIfNeeded]; return _cntOpen; }
- (NSUInteger)blockedIssueCount{ [self _loadIfNeeded]; return _cntBlocked; }
- (NSUInteger)closedIssueCount { [self _loadIfNeeded]; return _cntClosed; }

#pragma mark - BeadsDataSource protocol

- (NSString *)backendLabel { return @"read-only (JSONL)"; }
- (BOOL)writable           { return NO; }
- (void)invalidateCache    { [self reload]; }

// Build a BeadsDataSourceErrorReadOnly NSError for write attempts.
static NSError *readOnlyError(void) {
    return [NSError errorWithDomain:BeadsDataSourceErrorDomain
                               code:BeadsDataSourceErrorReadOnly
                           userInfo:@{
        NSLocalizedDescriptionKey:
          @"Read-only JSONL backend. Install `bd` to enable editing.",
    }];
}

- (void)listAllIssuesWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError *))done {
    NSArray *arr = [self issues];
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(arr, nil); });
}

- (void)showIssue:(NSString *)issueId
       completion:(void (^)(NSDictionary *, NSError *))done {
    NSArray *arr = [self issues];
    NSDictionary *hit = nil;
    for (NSDictionary *d in arr) {
        if ([d[@"id"] isEqualToString:issueId]) { hit = d; break; }
    }
    if (!hit) {
        NSError *e = [NSError errorWithDomain:BeadsDataSourceErrorDomain
                                         code:BeadsDataSourceErrorNotFound
                                     userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"Issue %@ not in JSONL", issueId]}];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, e); });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(hit, nil); });
}

// Every write → ReadOnly.
- (void)createIssueWithTitle:(NSString *)t type:(NSString *)y priority:(NSNumber *)p
                 description:(NSString *)d labels:(NSArray<NSString *> *)l
                  completion:(void (^)(NSDictionary *, NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, readOnlyError()); });
}
- (void)updateIssue:(NSString *)i title:(NSString *)t description:(NSString *)d
             status:(NSString *)s priority:(NSNumber *)p type:(NSString *)y
           assignee:(NSString *)a addLabels:(NSArray<NSString *> *)al
       removeLabels:(NSArray<NSString *> *)rl
         completion:(void (^)(NSDictionary *, NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, readOnlyError()); });
}
- (void)claimIssue:(NSString *)i completion:(void (^)(NSDictionary *, NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, readOnlyError()); });
}
- (void)closeIssue:(NSString *)i reason:(NSString *)r force:(BOOL)f
        completion:(void (^)(NSDictionary *, NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, readOnlyError()); });
}
- (void)reopenIssue:(NSString *)i reason:(NSString *)r
         completion:(void (^)(NSDictionary *, NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, readOnlyError()); });
}
- (void)addDependencyFromIssue:(NSString *)a toIssue:(NSString *)b type:(NSString *)t
                   completion:(void (^)(NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(readOnlyError()); });
}
- (void)removeDependencyFromIssue:(NSString *)a toIssue:(NSString *)b
                      completion:(void (^)(NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(readOnlyError()); });
}
- (void)deleteIssue:(NSString *)i completion:(void (^)(NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(readOnlyError()); });
}
- (void)unassignIssue:(NSString *)i
           completion:(void (^)(NSDictionary *, NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, readOnlyError()); });
}
- (void)addCommentToIssue:(NSString *)i body:(NSString *)b
               completion:(void (^)(NSError *))done {
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(readOnlyError()); });
}

@end
