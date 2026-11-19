// RemoteJsonlFetcher — read-only live sync for REMOTE beads projects
// (nppmac-0th). Periodically GETs a repo's `.beads/issues.jsonl` over
// HTTPS (NSURLSession, ETag/If-None-Match conditional polling, ~60 s) and
// hands fresh text to the panel, which pours it into JsonlDataSource via
// adoptRawText:/fedExternally — the same pipeline dolt-priority render
// uses. No bd, no git, no local clone, no child processes.
//
// GitHub URL strategy:
//   no token → https://raw.githubusercontent.com/{o}/{r}/{branch}/.beads/issues.jsonl
//   token    → https://api.github.com/repos/{o}/{r}/contents/.beads/issues.jsonl?ref={branch}
//              with `Accept: application/vnd.github.raw+json` and
//              `Authorization: Bearer <token>`. The token is a fine-grained
//              PAT with Contents: Read-only (Option A per nppmac-0th);
//              authenticated conditional GETs that 304 don't count against
//              GitHub's rate limit.
// Self-hosted forges (nppmac-iik): a repo-page URL shaped like
// {scheme}://{host}[:port]/{owner}/{repo} auto-derives the Gitea/Forgejo
// raw layout ({repo}/raw/branch/{branch}/.beads/issues.jsonl); any other
// http(s) URL is fetched as-is (GitLab: paste its raw URL directly). A
// token, when present, is sent as Authorization: Bearer — Gitea accepts
// that form. http:// is allowed: ATS exempts IP-literal/.local hosts and
// still blocks public-hostname http inside the apps on its own.
//
// Tokens live ONLY in the login Keychain (service "NppBeads Remote",
// account = the connection spec). Never in NSUserDefaults, never logged.
//
// All callbacks fire on the MAIN queue. pause/resume follow the same
// window-key contract as BeadsPoll/BdEventsTail.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RemoteJsonlFetcher : NSObject

// ── Spec parsing ─────────────────────────────────────────────────────
// Turn user input — "owner/repo", "github.com/owner/repo",
// "https://github.com/owner/repo(.git)", a self-hosted forge repo URL
// ("http(s)://host[:port]/owner/repo"), or a direct http(s) URL to a raw
// issues.jsonl — plus an optional branch (default "main") into the
// canonical connection spec: "github.com/{o}/{r}@{branch}" for GitHub,
// the (possibly derived) absolute raw URL string otherwise. The spec is the stable identity:
// Keychain account, MRU dedupe key, and BeadsProject.remoteSpec.
// Returns nil when the input can't be understood. outDisplay receives a
// short human label ("owner/repo @ main", or the URL's host + file).
+ (nullable NSString *)specForInput:(NSString *)input
                             branch:(nullable NSString *)branch
                            display:(NSString * _Nullable __autoreleasing * _Nullable)outDisplay;

// ── Keychain (login keychain; service "NppBeads Remote", acct = spec) ─
+ (void)storeToken:(nullable NSString *)token forSpec:(NSString *)spec; // nil/empty deletes
+ (nullable NSString *)tokenForSpec:(NSString *)spec;

// ── Polling ──────────────────────────────────────────────────────────
- (instancetype)initWithSpec:(NSString *)spec token:(nullable NSString *)token;

/** Fires on every 200 whose body differs from the last delivery (ETag +
    content-length gate). The string is the raw JSONL text. */
@property (nonatomic, copy, nullable) void (^onText)(NSString *jsonl);
/** Fires on auth/network/HTTP failures. Polling continues regardless. */
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
/** Sticky human-readable failure ("authorization failed (HTTP 401)…");
    nil again after the next successful fetch. For the status bar. */
@property (nonatomic, readonly, nullable) NSString *lastError;

- (void)start;    // immediate fetch, then every 60 s
- (void)stop;     // idempotent; cancels the timer + in-flight task
- (void)pause;    // window not key — ticks are skipped (latched)
- (void)resume;   // catch-up fetch now if a tick was skipped while paused
- (void)kick;     // user hit Refresh — fetch immediately

@end

NS_ASSUME_NONNULL_END
