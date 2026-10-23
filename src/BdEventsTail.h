// BdEventsTail — live-sync via `bd events tail --since N --follow`
// (bd >= 1.3 with the per-workspace events journal enabled).
//
// Replaces BeadsPoll's 2-second `bd list` fork-and-diff with ONE
// long-lived bd process that emits a JSON Lines record for every
// committed mutation. We use the records as change TRIGGERS (the panel
// re-broadcasts through its existing reload path); per-record model
// patching can come later. Delivery is ~1s after a write (bd's --follow
// polls its journal internally) — same ballpark as the old poll's worst
// case, at a tiny fraction of the cost.
//
// Lifecycle mirrors BeadsPoll (start/stop/pause/resume) so BeadsPanel
// can treat either as its live-sync source:
//   - pause() doesn't kill the process; records keep updating lastSeq
//     and set a pending flag, flushed as one onChange on resume().
//   - stop() terminates the child and silences all callbacks.
//   - If the child dies on its own it is restarted (backoff, 2 tries,
//     resuming from lastSeq). After that — or when bd reports the
//     journal disabled — onBroken fires once so the owner can fall
//     back to polling.
//
// Checkpointing is the OWNER's job: set sinceSeq before -start (0 =
// full replay, bounded by bd's 7-day/100k retention) and persist
// lastSeq wherever you like. A sinceSeq below the retention floor makes
// bd exit non-zero ("truncated"); the restart path retries from the
// highest seq seen, and onBroken is the final fallback.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BdEventsTail : NSObject

/** Fired on main, coalesced (~250 ms) over bursts of records. */
@property (nonatomic, copy, nullable) void (^onChange)(void);

/** Fired on main, at most once per -start cycle, when the feed cannot
    continue (process kept dying, or bd says the journal is disabled).
    The owner should fall back to BeadsPoll. */
@property (nonatomic, copy, nullable) void (^onBroken)(NSString *reason);

/** Checkpoint to resume from; set BEFORE -start. 0 replays the whole
    retained journal. */
@property (nonatomic, assign) uint64_t sinceSeq;

/** Highest seq seen so far (persist this as the next sinceSeq). */
@property (nonatomic, readonly) uint64_t lastSeq;

/** Diagnostics. Main thread. */
@property (nonatomic, readonly) NSUInteger recordCount;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) BOOL isRunning;

- (instancetype)initWithBdPath:(NSString *)bdPath
                    projectDir:(NSString *)projectDir NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
- (void)stop;
- (void)pause;
- (void)resume;

@end

NS_ASSUME_NONNULL_END
