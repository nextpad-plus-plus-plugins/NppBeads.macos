#import "BeadIdIndicator.h"

// Minimal Scintilla constants we need. Duplicating here (rather than
// pulling in Scintilla.h) keeps compile-time noise down — the plugin
// already links via the host's _sendMessage, it doesn't depend on
// the Scintilla API for its own types.
#define SCI_INDICSETSTYLE       2080
#define SCI_INDICSETFORE        2082
#define SCI_SETINDICATORCURRENT 2500
#define SCI_INDICATORFILLRANGE  2504
#define SCI_INDICATORCLEARRANGE 2505
#define SCI_GETLENGTH           2006
#define SCI_GETFIRSTVISIBLELINE 2152
#define SCI_LINESONSCREEN       2370
#define SCI_GETLINECOUNT        2154
#define SCI_POSITIONFROMLINE    2167
#define SCI_SETSEARCHFLAGS      2198
#define SCI_SETTARGETRANGE      2686
#define SCI_GETTARGETSTART      2191   // after search: start of match (byte)
#define SCI_GETTARGETEND        2193   // end (byte, exclusive)
#define SCI_SEARCHINTARGET      2197
#define SCI_DOCLINEFROMVISIBLE  2221

#define INDIC_TEXTFORE          17
#define SCFIND_REGEXP           0x00200000
#define SCFIND_CXX11REGEX       0x00800000

// Default indicator slot for LEGACY hosts (NPPM_GETBOOKMARKID == 24), where
// the host paints Mark styles on 9-13 and inc-search on 28, and 25 is free.
// Hosts with the remapped Windows-parity layout (NPPM_GETBOOKMARKID == 20)
// own 25 as Mark style 1; there NppBeads.mm overrides `indicatorSlot` with a
// slot from NPPM_ALLOCATEINDICATOR at NPPN_READY, before any paint.
static const int kBeadIndicatorLegacy = 25;

// Link-style color for matched bead ids. Scintilla color format is
// 0x00BBGGRR (no alpha). #2563eb (Tailwind blue-600) → BGR 0xEB6325.
static const int kBeadLinkColor = 0xEB6325;

@implementation BeadIdMatch
@end

@implementation BeadIdIndicator {
    BeadIdSendMessageFn _send;
    NSArray<BeadIdMatch *> *_cache;
    BOOL   _stylesInstalled;      // per-handle; reset on handle change
    BOOL   _rescanPending;        // coalesce debounced calls
    NSUInteger _rescanCount;      // diagnostics only
}

- (instancetype)initWithSendMessage:(BeadIdSendMessageFn)send {
    NSAssert(send != NULL, @"BeadIdIndicator needs a send function");
    if ((self = [super init])) {
        _send  = send;
        _prefix = @"bd-";
        _cache = @[];
        _indicatorSlot = kBeadIndicatorLegacy;
    }
    return self;
}

- (void)setIndicatorSlot:(int)slot {
    if (_indicatorSlot == slot) return;
    _indicatorSlot = slot;
    _stylesInstalled = NO;   // style the new slot on next paint
}

- (void)setPrefix:(NSString *)prefix {
    NSString *p = [[prefix stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if (p.length == 0) p = @"bd-";
    _prefix = p;
    // Prefix changed → invalidate cache + rescan next opportunity.
    _cache = @[];
    [self scheduleRescan];
}

- (void)setScintillaHandle:(uintptr_t)h {
    if (_scintillaHandle == h) return;
    _scintillaHandle = h;
    _stylesInstalled = NO;   // re-install on next paint against new handle
    _cache = @[];            // cache was for the old doc
}

- (NSArray<BeadIdMatch *> *)currentMatches {
    return _cache ?: @[];
}

// ────────────────────────────────────────────────────────────────────
//  Rescan scheduling
// ────────────────────────────────────────────────────────────────────

- (void)scheduleRescan {
    if (_scintillaHandle == 0) return;
    if (_rescanPending) return;
    _rescanPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        s->_rescanPending = NO;
        // Wrap in @try @catch so any NSException raised inside the
        // scan path (Scintilla send-message reentrancy, downstream
        // plugin reactions, NSMutableData edge cases, etc.) gets
        // logged instead of escaping the dispatched block. An
        // exception that escapes a dispatch_after block bypasses
        // every @try in the host's plugin manager and propagates up
        // to NSApplication.run, which on this build calls abort()
        // (two confirmed crashes with this exact stack trace —
        // SIGABRT via objc_exception_rethrow on the main thread —
        // when a JSONL file inside .beads/ is browsed while the
        // panel is open).
        @try {
            [s rescanNow];
        } @catch (NSException *e) {
            NSLog(@"[NppBeads] BeadIdIndicator.rescanNow trapped NSException: "
                  @"name=%@ reason=%@ userInfo=%@",
                  e.name, e.reason, e.userInfo);
        }
    });
}

- (void)rescanNow {
    if (_scintillaHandle == 0) return;
    uintptr_t h = _scintillaHandle;

    [self _installStylesIfNeeded];

    // Visible window, widened ±50 lines to keep scroll / wrap / fold
    // noise out of the scan-then-paint loop. A 1 MB file's worst case
    // is scanning ~4 KB which is sub-millisecond.
    intptr_t firstVisible = _send(h, SCI_GETFIRSTVISIBLELINE, 0, 0);
    intptr_t onScreen     = _send(h, SCI_LINESONSCREEN, 0, 0);
    intptr_t totalLines   = _send(h, SCI_GETLINECOUNT, 0, 0);

    // First/last DOC line — convert visible→doc so folded sections are
    // handled correctly (visible line N is a DOC line SCI_DOCLINEFROMVISIBLE).
    intptr_t docFirst = _send(h, SCI_DOCLINEFROMVISIBLE,
                              (uintptr_t)MAX((intptr_t)0, firstVisible - 50), 0);
    intptr_t docLast  = _send(h, SCI_DOCLINEFROMVISIBLE,
                              (uintptr_t)(firstVisible + onScreen + 50), 0);
    if (docLast < docFirst) docLast = docFirst;
    if (docLast >= totalLines) docLast = totalLines;

    intptr_t startByte = _send(h, SCI_POSITIONFROMLINE, (uintptr_t)docFirst, 0);
    intptr_t endByte   = (docLast >= totalLines)
                       ? _send(h, SCI_GETLENGTH, 0, 0)
                       : _send(h, SCI_POSITIONFROMLINE, (uintptr_t)docLast, 0);
    if (startByte < 0) startByte = 0;
    if (endByte < startByte) endByte = startByte;

    // Clear the indicator in the scan window before repainting — ensures
    // stale matches (e.g. user deleted a bead id) disappear. Clearing
    // OUTSIDE the window is intentionally skipped to keep the indicator
    // persistent across scrolls (no flicker).
    _send(h, SCI_SETINDICATORCURRENT, (uintptr_t)_indicatorSlot, 0);
    _send(h, SCI_INDICATORCLEARRANGE, (uintptr_t)startByte,
          (intptr_t)(endByte - startByte));

    // Search loop with Scintilla's C++11 regex.
    NSMutableArray<BeadIdMatch *> *matches = [NSMutableArray array];
    NSString *pattern = [NSString stringWithFormat:@"\\b%@[a-z0-9]+(\\.\\d+)*\\b",
                         [self _escapedPrefix]];
    const char *patUtf8 = [pattern UTF8String];
    intptr_t patLen = (intptr_t)strlen(patUtf8);

    _send(h, SCI_SETSEARCHFLAGS,
          (uintptr_t)(SCFIND_REGEXP | SCFIND_CXX11REGEX), 0);

    intptr_t cursor = startByte;
    const intptr_t kMaxMatches = 4096;   // absurd-file sanity stop
    NSUInteger safety = 0;
    while (cursor < endByte && safety++ < kMaxMatches) {
        _send(h, SCI_SETTARGETRANGE, (uintptr_t)cursor, (intptr_t)endByte);
        intptr_t found = _send(h, SCI_SEARCHINTARGET,
                               (uintptr_t)patLen, (intptr_t)patUtf8);
        if (found < 0) break;   // -1 = not found; -2 = invalid regex
        intptr_t mStart = _send(h, SCI_GETTARGETSTART, 0, 0);
        intptr_t mEnd   = _send(h, SCI_GETTARGETEND,   0, 0);
        if (mEnd <= mStart) break;

        // Paint.
        _send(h, SCI_INDICATORFILLRANGE, (uintptr_t)mStart,
              (intptr_t)(mEnd - mStart));

        // Extract the matched text for the cache (only the id itself;
        // start a tiny SCI_GETTEXTRANGEFULL or just read via
        // SCI_GETCHARAT loop — latter avoids an Sci_TextRangeFull struct).
        NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)(mEnd - mStart)];
        char *out = (char *)buf.mutableBytes;
        for (intptr_t i = 0; i < mEnd - mStart; i++) {
            out[i] = (char)_send(h, 2007 /* SCI_GETCHARAT */, (uintptr_t)(mStart + i), 0);
        }
        NSString *id_ = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if (id_.length) {
            BeadIdMatch *m = [[BeadIdMatch alloc] init];
            m.startByte = mStart;
            m.endByte   = mEnd;
            m.beadId    = id_;
            [matches addObject:m];
        }

        if (mEnd == cursor) cursor = mEnd + 1;   // guard against zero-length match loop
        else                cursor = mEnd;
    }

    _cache = [matches copy];
    _rescanCount++;
}

- (void)clearAll {
    if (_scintillaHandle == 0) return;
    uintptr_t h = _scintillaHandle;
    [self _installStylesIfNeeded];
    intptr_t len = _send(h, SCI_GETLENGTH, 0, 0);
    _send(h, SCI_SETINDICATORCURRENT, (uintptr_t)_indicatorSlot, 0);
    _send(h, SCI_INDICATORCLEARRANGE, 0, len);
    _cache = @[];
}

// ────────────────────────────────────────────────────────────────────
//  Query
// ────────────────────────────────────────────────────────────────────

- (NSString *)beadIdAtPosition:(intptr_t)byteOffset {
    // Binary search on _cache by startByte, then confirm the position
    // falls inside the matched range.
    NSArray<BeadIdMatch *> *cache = _cache;
    NSInteger lo = 0, hi = (NSInteger)cache.count - 1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) >> 1;
        BeadIdMatch *m = cache[mid];
        if (byteOffset < m.startByte)       hi = mid - 1;
        else if (byteOffset >= m.endByte)   lo = mid + 1;
        else                                return m.beadId;
    }
    return nil;
}

// ────────────────────────────────────────────────────────────────────
//  Private
// ────────────────────────────────────────────────────────────────────

- (void)_installStylesIfNeeded {
    if (_stylesInstalled || _scintillaHandle == 0) return;
    uintptr_t h = _scintillaHandle;
    _send(h, SCI_INDICSETSTYLE, (uintptr_t)_indicatorSlot, INDIC_TEXTFORE);
    _send(h, SCI_INDICSETFORE,  (uintptr_t)_indicatorSlot, (intptr_t)kBeadLinkColor);
    _stylesInstalled = YES;
}

// Regex special chars in the prefix get escaped so custom prefixes
// don't break the pattern. bd's default "bd-" is safe as-is but this
// future-proofs for whatever the user configures.
- (NSString *)_escapedPrefix {
    NSMutableString *out = [NSMutableString stringWithCapacity:_prefix.length + 2];
    NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString:
                               @"\\.^$|?*+()[]{}"];
    for (NSUInteger i = 0; i < _prefix.length; i++) {
        unichar c = [_prefix characterAtIndex:i];
        if ([special characterIsMember:c]) [out appendString:@"\\"];
        [out appendFormat:@"%C", c];
    }
    return out;
}

@end
