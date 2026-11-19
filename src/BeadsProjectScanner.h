// BeadsProjectScanner — locates `.beads/` directories in the user's
// open workspace. Strategy (Phase 1):
//   1. Walk up from the active file's directory looking for a sibling
//      `.beads/` folder. Stops at $HOME or filesystem root, whichever
//      comes first (prevents scanning e.g. /).
//   2. (Stubbed for future phases) also consult Folder-as-Workspace
//      roots — needs a host API we don't yet have. For now the walk-up
//      from the active file is the only entry point.
//
// A "valid" .beads/ is a directory that contains either:
//   - `issues.jsonl`  (lightweight path — always present after `bd sync`)
//   - `beads.db`       (Dolt DB — heavier path; tracked for Phase 3)
//
// We do NOT require both; either signal is enough.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BeadsProject : NSObject
// Absolute path to the `.beads` directory.
@property (nonatomic, copy) NSString *beadsDir;
// Absolute path to `issues.jsonl` (may be nil if not yet synced).
@property (nonatomic, copy, nullable) NSString *jsonlPath;
// Absolute path to `beads.db` (may be nil — Dolt path is Phase 3).
@property (nonatomic, copy, nullable) NSString *dbPath;
// Repo/project root (parent of .beads/).
@property (nonatomic, copy) NSString *projectRoot;

// Remote read-only project (nppmac-0th). When remoteSpec is set the
// project has NO local filesystem presence: beadsDir/projectRoot carry
// the canonical spec string (stable identity for dedupe/MRU/Keychain),
// jsonlPath/dbPath are nil, and the panel fetches issues.jsonl over
// HTTPS (RemoteJsonlFetcher) instead of probing bd or watching files.
@property (nonatomic, copy, nullable) NSString *remoteSpec;
// Short human label for the chip/status bar, e.g. "owner/repo @ main".
@property (nonatomic, copy, nullable) NSString *remoteDisplay;
- (BOOL)isRemote;
@end

@interface BeadsProjectScanner : NSObject

// Walks up from `filePath` (or its containing dir if it is a directory)
// until a `.beads/` sibling is found OR the walk hits a stop boundary.
// Returns nil if no project is in scope.
+ (nullable BeadsProject *)findProjectFromPath:(nullable NSString *)filePath;

// Validate that a given .beads/ actually has something we can read.
+ (BOOL)isUsableBeadsDir:(NSString *)beadsDir;

// Phase 4: project switcher support.

// Build a BeadsProject directly from a .beads/ directory path (e.g. the
// one a user chose via NSOpenPanel). Returns nil if the dir doesn't
// satisfy isUsableBeadsDir:. projectRoot is the parent of beadsDir.
+ (nullable BeadsProject *)projectFromBeadsDir:(NSString *)beadsDir;

// Build a BeadsProject from a project-root directory (the parent of
// `.beads/`). Convenience for loading from persisted `nppbeads.recentProjects`
// entries. Returns nil if the root has no usable .beads/.
+ (nullable BeadsProject *)projectFromRoot:(NSString *)projectRoot;

// Build a remote read-only project (nppmac-0th) from a canonical spec
// (see RemoteJsonlFetcher.specForInput:…). No filesystem validation —
// reachability is discovered by the first fetch.
+ (nullable BeadsProject *)remoteProjectWithSpec:(NSString *)spec
                                         display:(nullable NSString *)display;

// Walk UP from each input path (file or directory), collect the unique
// .beads/ ancestors found, and materialize a BeadsProject for each.
// Deduplicates by beadsDir absolute path. Input paths that can't be
// resolved or that don't have a .beads/ ancestor are silently skipped.
// Caller-capped — nothing is returned beyond the first `max` projects.
+ (NSArray<BeadsProject *> *)discoverUniqueProjectsFromPaths:(NSArray<NSString *> *)paths
                                                       max:(NSUInteger)max;

@end

NS_ASSUME_NONNULL_END
