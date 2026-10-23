// BdCommandRunner — thin, testable NSTask wrapper around the `bd` CLI.
//
// Phase 3's bedrock: every CRUD surface (create/update/close/dep add/…)
// routes through here. Design matches what we learned live-testing
// against bd 1.0.2 on 2026-04-23 (see memory/nppbeads_phase3_cli_contract.md).
//
// Design constraints:
//   1. Shell out synchronously on a background queue; never block main.
//   2. Always pass `--json`. Return parsed JSON directly (id, typed).
//   3. `bd show --json` returns an ARRAY even for one ID — unwrap here
//      so callers always get the one-object case.
//   4. bd writes often emit non-fatal "dolt auto-push failed" stderr
//      noise when the Dolt remote needs auth. When exitCode == 0 we
//      classify those as `warnings` not `error` so the UI can show a
//      single subtle pill instead of panicking.
//   5. Honor `--skip-hooks` on any command that could trigger the
//      pre-commit -> bd export deadlock we hit during init.
//   6. Short read-cache (750 ms for list, 250 ms for show) — same as
//      vscode-beads and compatible with bd's internal FlushManager
//      5-second debounce.
//   7. `BEADS_ACTOR=NppBeads/<user>` forced into subprocess env so audit
//      trails attribute mutations to this plugin.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────
//  Result type — every call returns this. Callers branch on ok.
// ─────────────────────────────────────────────────────────────────────
@interface BdResult : NSObject
/** True iff the subprocess exited 0 AND there was no JSON parse error. */
@property (nonatomic, readonly) BOOL              ok;
/** Raw exit status. 0 on success, non-zero on bd-reported failure. */
@property (nonatomic, readonly) int               exitCode;
/** Parsed JSON from stdout. NSArray or NSDictionary or nil. */
@property (nonatomic, readonly, nullable) id      json;
/** Top-level error message (from stderr JSON or our own parse failure).
    nil when ok == YES. UI-displayable. */
@property (nonatomic, readonly, nullable) NSString *errorMessage;
/** Non-fatal warnings from stderr — typically "dolt auto-push failed".
    Always empty when exitCode != 0 (those get promoted to errorMessage). */
@property (nonatomic, readonly) NSArray<NSString *> *warnings;
/** Raw stdout/stderr for diagnostics. Not meant for UI. */
@property (nonatomic, readonly, nullable) NSString *rawStdout;
@property (nonatomic, readonly, nullable) NSString *rawStderr;
/** Wall-clock duration of the subprocess in seconds (for diagnostics). */
@property (nonatomic, readonly) NSTimeInterval    elapsed;
/** Command line used, for diagnostics (args only, no env). */
@property (nonatomic, readonly, copy) NSArray<NSString *> *argv;
@end

// Error-classification helpers for common bd patterns. The UI layer
// uses these to offer specific follow-up actions (Force-close, etc.).
typedef NS_ENUM(NSInteger, BdErrorKind) {
    BdErrorKindNone           = 0,  // ok == YES
    BdErrorKindBlockedByDeps  = 1,  // "cannot close <id>: blocked by open issues [...]"
    BdErrorKindNotFound       = 2,  // "issue not found" / similar
    BdErrorKindAlreadyClaimed = 3,  // `bd update --claim` when someone else holds it
    BdErrorKindCycle          = 4,  // dep add refused because of cycle
    BdErrorKindLocked         = 5,  // Dolt/file-lock contention
    BdErrorKindBdMissing      = 6,  // which bd failed; no binary
    BdErrorKindNotInProject   = 7,  // bd ran outside a .beads/ project
    BdErrorKindGeneric        = 99, // catch-all
};

@interface BdResult (Classification)
@property (nonatomic, readonly) BdErrorKind errorKind;
/** When errorKind == BdErrorKindBlockedByDeps, the list of blocker IDs. */
@property (nonatomic, readonly) NSArray<NSString *> *blockerIds;
@end

// ─────────────────────────────────────────────────────────────────────
//  The runner
// ─────────────────────────────────────────────────────────────────────
@interface BdCommandRunner : NSObject

/** Project's working directory (folder that owns `.beads/`). Required —
    all `bd` calls execute with this as cwd so `bd` discovers the right
    project automatically. */
@property (nonatomic, copy, readonly) NSString *projectDir;

/** Resolved absolute path to the `bd` binary, or nil when missing.
    Populated by -probe. */
@property (nonatomic, copy, readonly, nullable) NSString *bdPath;

/** `bd version` output parsed out, e.g. "1.0.2". nil when unknown. */
@property (nonatomic, copy, readonly, nullable) NSString *bdVersion;

/** Actor string passed to every invocation via BEADS_ACTOR env. Default
    "NppBeads/<$USER>". Users may want to override for agent attribution. */
@property (nonatomic, copy) NSString *actor;

/** Phase 3.5 — controls whether `--sandbox` is prepended to every bd
    call. Default: YES (sandbox on → bd auto-push disabled → ~100× faster
    writes on projects without working non-interactive git auth, which
    is the common case). Users with working git auth who actually want
    dolt auto-sync can set this to NO from the overflow menu — it's
    persisted per-project in NppBeadsAutoPushProjects defaults. */
@property (nonatomic, assign) BOOL useSandbox;

- (instancetype)initWithProjectDir:(NSString *)projectDir NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ─────────────────────────────────────────────────────────────────────
//  One-shot probe: is bd installed + does this dir have a usable project?
//  Cheap (runs `bd version` + `bd info` once). Result cached on self.
//  Completion fires on main. Re-run via -probeWithCompletion:refresh:YES.
- (void)probeWithCompletion:(void (^)(BOOL bdPresent, BOOL projectReady))done;
- (void)probeWithCompletion:(void (^)(BOOL bdPresent, BOOL projectReady))done
                    refresh:(BOOL)forceRefresh;

// ─────────────────────────────────────────────────────────────────────
//  Events feed (bd >= 1.3) — version gate + per-workspace journal config.

/** True when the probed bd version has `bd events tail` (>= 1.3).
    Valid only after -probeWithCompletion: has resolved. */
- (BOOL)supportsEventsFeed;

/** `bd config get events-journal` → YES iff it prints "true".
    Completion fires on main. */
- (void)fetchEventsJournalEnabled:(void (^)(BOOL enabled))done;

/** `bd config set events-journal true` — writes the project's
    .beads/config.yaml (which may be git-tracked; the UI warns first).
    Completion fires on main. */
- (void)enableEventsJournalWithCompletion:(void (^)(BdResult *res))done;

// ─────────────────────────────────────────────────────────────────────
//  Read commands — cached (750 ms list, 250 ms show).
// ─────────────────────────────────────────────────────────────────────

/** `bd list --all --json` — every issue, incl. closed (matches our UI needs). */
- (void)listAllIssuesWithCompletion:(void (^)(BdResult *res))done;

/** `bd show <id> --json` — single-object unwrap from bd's array response.
    `BdResult.json` is NSDictionary (or nil on failure). */
- (void)showIssue:(NSString *)issueId
       completion:(void (^)(BdResult *res))done;

/** `bd ready --json` — next-actionable items (not blocked, open). */
- (void)readyWithCompletion:(void (^)(BdResult *res))done;

// ─────────────────────────────────────────────────────────────────────
//  Write commands — never cached; ALL invalidate the read cache on success.
// ─────────────────────────────────────────────────────────────────────

/** `bd create "<title>" -t <type> -p <priority> -d "<desc>" --json`.
    Any of type/priority/description may be nil.
    BdResult.json is NSDictionary (unwrapped from bd's array). */
- (void)createIssueWithTitle:(NSString *)title
                        type:(nullable NSString *)issueType
                    priority:(nullable NSNumber *)priority
                 description:(nullable NSString *)description
                      labels:(nullable NSArray<NSString *> *)labels
                  completion:(void (^)(BdResult *res))done;

/** `bd update <id> [flags] --json`. Fields that are nil are omitted.
    `addLabels` and `removeLabels` become `--add-label` / `--remove-label`. */
- (void)updateIssue:(NSString *)issueId
              title:(nullable NSString *)title
        description:(nullable NSString *)description
             status:(nullable NSString *)status
           priority:(nullable NSNumber *)priority
               type:(nullable NSString *)issueType
           assignee:(nullable NSString *)assignee
          addLabels:(nullable NSArray<NSString *> *)addLabels
       removeLabels:(nullable NSArray<NSString *> *)removeLabels
         completion:(void (^)(BdResult *res))done;

/** Atomic claim — only primitive in bd that refuses a conflicting write.
    Sets status=in_progress + assignee=actor. BdErrorKindAlreadyClaimed on
    conflict. */
- (void)claimIssue:(NSString *)issueId
        completion:(void (^)(BdResult *res))done;

/** `bd close <id> --reason "<r>" --json`. reason may be nil. */
- (void)closeIssue:(NSString *)issueId
            reason:(nullable NSString *)reason
             force:(BOOL)force
        completion:(void (^)(BdResult *res))done;

/** `bd reopen <id> --reason "<r>" --json`. */
- (void)reopenIssue:(NSString *)issueId
             reason:(nullable NSString *)reason
         completion:(void (^)(BdResult *res))done;

/** `bd dep add <dependent> <dependency> --type <type> --json`. */
- (void)addDependencyFromIssue:(NSString *)dependentId
                      toIssue:(NSString *)dependencyId
                         type:(NSString *)depType
                   completion:(void (^)(BdResult *res))done;

/** `bd dep remove <dependent> <dependency> --json`. */
- (void)removeDependencyFromIssue:(NSString *)dependentId
                         toIssue:(NSString *)dependencyId
                      completion:(void (^)(BdResult *res))done;

/** Phase 3.5 — `bd delete <id> --json`. Destructive; caller confirms. */
- (void)deleteIssue:(NSString *)issueId
         completion:(void (^)(BdResult *res))done;

/** Phase 3.5 — `bd update <id> --unassign --json`. Separate method rather
    than a sentinel on updateIssue because bd's --unassign is a flag, not
    a value for --assignee. */
- (void)unassignIssue:(NSString *)issueId
           completion:(void (^)(BdResult *res))done;

/** Phase 6 — `bd comment <id> --stdin --json` with the body text piped
    via stdin so special chars + multi-line markdown survive (bd 1.0.2
    interface; the old `comment add … --body-file=-` was removed).
    Empty body is rejected client-side (bd would also reject). */
- (void)addCommentToIssue:(NSString *)issueId
                     body:(NSString *)body
               completion:(void (^)(BdResult *res))done;

// ─────────────────────────────────────────────────────────────────────
//  Cache control
// ─────────────────────────────────────────────────────────────────────
/** Clear the read cache. Called automatically after every successful
    write; exposed so callers can force freshness (e.g. refresh button). */
- (void)invalidateCache;

@end

NS_ASSUME_NONNULL_END
