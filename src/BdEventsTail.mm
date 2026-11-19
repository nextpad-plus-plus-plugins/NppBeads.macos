#import "BdEventsTail.h"

#import <libproc.h>
#import <signal.h>
#import <sys/sysctl.h>

// All mutable state is confined to the MAIN queue. NSTask handlers run on
// arbitrary queues and hop to main before touching anything.

// ─────────────────────────────────────────────────────────────────────
//  Orphan sweep (nppmac-8n1). The spawned child lives in its own process
//  group, so nothing kills it when this process dies abruptly (crash,
//  force-quit, SIGKILL) — it would tail the workspace journal forever,
//  holding the DB gate locks and burning CPU/RAM. We persist each child's
//  pid per workspace and, on the next spawn for that workspace, reap any
//  previous child that is still alive.

static NSString *tailPidDefaultsKey(NSString *projectDir) {
    return [@"NppBeadsEventsTailPid." stringByAppendingString:
            projectDir.stringByStandardizingPath];
}

// True only when `pid` is alive, has been orphaned to launchd (ppid 1),
// and runs the bd/beads executable. The triple check makes a false kill
// effectively impossible: a recycled pid fails the exe test, and a live
// sibling shell's healthy tailer fails the ppid test (its parent is that
// shell, not launchd).
static BOOL isOrphanedBdProcess(pid_t pid) {
    if (pid <= 1 || kill(pid, 0) != 0) return NO;
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return NO;
    if (kp.kp_eproc.e_ppid != 1) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    NSString *exe = [NSString stringWithUTF8String:path].lastPathComponent;
    return [exe isEqualToString:@"bd"] || [exe isEqualToString:@"beads"];
}

@implementation BdEventsTail {
    NSString       *_bdPath;
    NSString       *_projectDir;
    NSTask         *_task;           // current child; identity-gates stale handlers
    NSMutableData  *_stdoutBuf;      // partial-line accumulator (main only)
    NSMutableString *_stderrTail;    // last stderr text for diagnostics
    BOOL            _stopping;       // user-initiated stop — silence handlers
    BOOL            _paused;
    BOOL            _pendingChange;  // record arrived while paused
    BOOL            _changeScheduled;// debounce latch
    BOOL            _brokenFired;    // onBroken at most once per start cycle
    NSUInteger      _restartCount;
    uint64_t        _lastSeq;
    NSUInteger      _recordCount;
}

- (instancetype)initWithBdPath:(NSString *)bdPath projectDir:(NSString *)projectDir {
    if (!(self = [super init])) return nil;
    NSAssert(bdPath.length && projectDir.length, @"BdEventsTail needs bdPath + projectDir");
    _bdPath = [bdPath copy];
    _projectDir = [projectDir copy];
    return self;
}

- (void)dealloc { [self stop]; }

- (uint64_t)lastSeq         { return _lastSeq; }
- (NSUInteger)recordCount   { return _recordCount; }
- (BOOL)isPaused            { return _paused; }
- (BOOL)isRunning           { return _task.isRunning; }

- (void)start {
    if (_task) return;                 // already running
    _stopping = NO;
    _brokenFired = NO;
    _restartCount = 0;
    if (_lastSeq < _sinceSeq) _lastSeq = _sinceSeq;
    [self _spawn];
}

- (void)stop {
    _stopping = YES;
    NSTask *t = _task;
    _task = nil;
    if (t) {
        // Detach handlers BEFORE terminate so no late hop references us.
        ((NSPipe *)t.standardOutput).fileHandleForReading.readabilityHandler = nil;
        ((NSPipe *)t.standardError).fileHandleForReading.readabilityHandler = nil;
        t.terminationHandler = nil;
        if (t.isRunning) [t terminate];
    }
    _stdoutBuf = nil;
    _changeScheduled = NO;
    _pendingChange = NO;
}

- (void)pause  { _paused = YES; }
- (void)resume {
    if (!_paused) return;
    _paused = NO;
    if (_pendingChange) {
        _pendingChange = NO;
        if (self.onChange) self.onChange();
    }
}

// ─────────────────────────────────────────────────────────────────────
- (void)_spawn {
    // Reap a tailer leaked by a previous run of this workspace (crash /
    // force-quit path — the clean path is shutdownLiveSync). Must happen
    // BEFORE launching the new child so we can never match it.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *pidKey = tailPidDefaultsKey(_projectDir);
    pid_t prev = (pid_t)[ud integerForKey:pidKey];
    if (prev > 0 && isOrphanedBdProcess(prev)) {
        NSLog(@"[NppBeads] reaping orphaned events tail from a previous run (pid=%d)", prev);
        kill(prev, SIGTERM);
    }

    uint64_t since = MAX(_lastSeq, _sinceSeq);
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:_bdPath];
    task.arguments = @[@"events", @"tail",
                       [NSString stringWithFormat:@"--since=%llu", since],
                       @"--follow"];
    task.currentDirectoryURL = [NSURL fileURLWithPath:_projectDir];
    NSMutableDictionary *env =
        [[NSProcessInfo processInfo].environment mutableCopy];
    env[@"BEADS_ACTOR"] = [NSString stringWithFormat:@"NppBeads/%@", NSUserName()];
    task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = errPipe;

    _stdoutBuf  = [NSMutableData data];
    _stderrTail = [NSMutableString string];

    __weak typeof(self) weakSelf = self;
    outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *chunk = fh.availableData;
        if (!chunk.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s || s->_stopping || s->_task != task) return;
            [s _consumeStdout:chunk];
        });
    };
    errPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *chunk = fh.availableData;
        if (!chunk.length) return;
        NSString *text = [[NSString alloc] initWithData:chunk
                                               encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s || s->_stopping || s->_task != task) return;
            [s->_stderrTail appendString:text];
            if (s->_stderrTail.length > 2000) {
                [s->_stderrTail deleteCharactersInRange:
                    NSMakeRange(0, s->_stderrTail.length - 2000)];
            }
            // Journal switched off (or was never on): bd tells us on
            // stderr. The feed is blind from here — hand over to polling.
            if ([s->_stderrTail rangeOfString:@"journal is disabled"].location
                    != NSNotFound) {
                [s _breakWithReason:@"events journal is disabled"];
            }
        });
    };
    task.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = weakSelf;
            if (!s || s->_stopping || s->_task != t) return;
            [s _childExited:t.terminationStatus];
        });
    };

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        NSLog(@"[NppBeads] events tail failed to launch: %@", err);
        [self _breakWithReason:err.localizedDescription ?: @"launch failed"];
        return;
    }
    _task = task;
    // Record the child for the next run's orphan sweep. Deliberately NOT
    // cleared in -stop: a stale entry is harmless (the sweep's alive/
    // orphan/exe checks reject it), but keeping it covers a terminate
    // that never lands.
    [ud setInteger:task.processIdentifier forKey:pidKey];
    NSLog(@"[NppBeads] events tail started (since=%llu, pid=%d)",
          since, task.processIdentifier);
}

- (void)_consumeStdout:(NSData *)chunk {
    [_stdoutBuf appendData:chunk];
    // Split complete lines off the buffer; keep the partial remainder.
    const char *bytes = (const char *)_stdoutBuf.bytes;
    NSUInteger len = _stdoutBuf.length, lineStart = 0;
    BOOL sawRecord = NO;
    for (NSUInteger i = 0; i < len; i++) {
        if (bytes[i] != '\n') continue;
        if (i > lineStart) {
            NSData *line = [_stdoutBuf subdataWithRange:
                            NSMakeRange(lineStart, i - lineStart)];
            if ([self _consumeRecordLine:line]) sawRecord = YES;
        }
        lineStart = i + 1;
    }
    if (lineStart > 0) {
        [_stdoutBuf replaceBytesInRange:NSMakeRange(0, lineStart)
                              withBytes:NULL length:0];
    }
    if (sawRecord) [self _scheduleChange];
}

- (BOOL)_consumeRecordLine:(NSData *)line {
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        // Not a record. bd prints a human "note:" when the journal is off;
        // catch it on stdout too (stderr has its own detector).
        NSString *text = [[NSString alloc] initWithData:line
                                               encoding:NSUTF8StringEncoding];
        if ([text rangeOfString:@"journal is disabled"].location != NSNotFound) {
            [self _breakWithReason:@"events journal is disabled"];
        }
        return NO;
    }
    NSNumber *seq = ((NSDictionary *)obj)[@"seq"];
    if (![seq isKindOfClass:[NSNumber class]]) return NO;
    uint64_t s = seq.unsignedLongLongValue;
    if (s > _lastSeq) _lastSeq = s;
    _recordCount++;
    _restartCount = 0;                 // a real record proves the feed is healthy
    return YES;
}

// Coalesce bursts (a close cascading blocked-state updates arrives as
// several records in one journal poll) into a single onChange.
- (void)_scheduleChange {
    if (_paused) { _pendingChange = YES; return; }
    if (_changeScheduled) return;
    _changeScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        s->_changeScheduled = NO;
        if (s->_stopping) return;
        if (s->_paused) { s->_pendingChange = YES; return; }
        if (s.onChange) s.onChange();
    });
}

- (void)_childExited:(int)status {
    NSLog(@"[NppBeads] events tail exited (status=%d, restarts=%lu) — %@",
          status, (unsigned long)_restartCount,
          [_stderrTail length] ? _stderrTail : @"(no stderr)");
    _task = nil;
    if (_restartCount >= 2) {
        [self _breakWithReason:
            [NSString stringWithFormat:@"tail kept exiting (status %d)", status]];
        return;
    }
    _restartCount++;
    NSTimeInterval delay = 1.0 * _restartCount;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) s = weakSelf;
        if (!s || s->_stopping || s->_task) return;
        [s _spawn];
    });
}

- (void)_breakWithReason:(NSString *)reason {
    if (_brokenFired) return;
    _brokenFired = YES;           // set synchronously — one break per cycle
    // Defer the teardown one runloop tick: this can be reached from inside
    // _consumeStdout's buffer loop, and stop() releases that very buffer.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        void (^cb)(NSString *) = s.onBroken;
        [s stop];
        s->_stopping = NO;        // leave the object restartable
        if (cb) cb(reason);
    });
}

@end
