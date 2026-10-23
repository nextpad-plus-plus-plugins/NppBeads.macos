#import "BeadsProjectScanner.h"

@implementation BeadsProject
@end

@implementation BeadsProjectScanner

+ (BOOL)isUsableBeadsDir:(NSString *)beadsDir {
    if (beadsDir.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:beadsDir isDirectory:&isDir] || !isDir) return NO;
    NSString *jsonl = [beadsDir stringByAppendingPathComponent:@"issues.jsonl"];
    NSString *db    = [beadsDir stringByAppendingPathComponent:@"beads.db"];
    // bd ≥1.x keeps the real data in an embedded Dolt directory and (since
    // bd 1.3) only writes issues.jsonl on explicit export — a Dolt-only
    // workspace is fully usable through the bd backend.
    NSString *dolt  = [beadsDir stringByAppendingPathComponent:@"embeddeddolt"];
    BOOL doltIsDir  = NO;
    BOOL hasDolt    = [fm fileExistsAtPath:dolt isDirectory:&doltIsDir] && doltIsDir;
    return [fm fileExistsAtPath:jsonl] || [fm fileExistsAtPath:db] || hasDolt;
}

+ (nullable BeadsProject *)findProjectFromPath:(nullable NSString *)filePath {
    if (filePath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    // Start from the file's containing directory; if the input is
    // already a directory, use it directly.
    BOOL isDir = NO;
    NSString *dir = filePath;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir]) return nil;
    if (!isDir) dir = [dir stringByDeletingLastPathComponent];

    NSString *home = NSHomeDirectory();
    NSUInteger depth = 0;
    const NSUInteger kMaxDepth = 40;  // sanity stop

    while (dir.length > 1 && depth++ < kMaxDepth) {
        NSString *candidate = [dir stringByAppendingPathComponent:@".beads"];
        if ([self isUsableBeadsDir:candidate]) {
            BeadsProject *p = [[BeadsProject alloc] init];
            p.beadsDir    = candidate;
            p.projectRoot = dir;
            NSString *jsonl = [candidate stringByAppendingPathComponent:@"issues.jsonl"];
            NSString *db    = [candidate stringByAppendingPathComponent:@"beads.db"];
            // jsonlPath is the EXPECTED location (bd export target) even when
            // the file doesn't exist yet — Dolt-only workspaces create it on
            // the first export, and consumers tolerate a missing file.
            p.jsonlPath = jsonl;
            if ([fm fileExistsAtPath:db])    p.dbPath    = db;
            return p;
        }
        // Stop at $HOME. A project outside $HOME is unusual; we refuse
        // to escalate to '/' to avoid inspecting irrelevant trees.
        if ([dir isEqualToString:home]) return nil;
        NSString *parent = [dir stringByDeletingLastPathComponent];
        if ([parent isEqualToString:dir]) return nil;  // hit root
        dir = parent;
    }
    return nil;
}

+ (nullable BeadsProject *)projectFromBeadsDir:(NSString *)beadsDir {
    if (beadsDir.length == 0) return nil;
    if (![self isUsableBeadsDir:beadsDir]) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    BeadsProject *p = [[BeadsProject alloc] init];
    p.beadsDir    = [beadsDir stringByStandardizingPath];
    p.projectRoot = [p.beadsDir stringByDeletingLastPathComponent];
    NSString *jsonl = [p.beadsDir stringByAppendingPathComponent:@"issues.jsonl"];
    NSString *db    = [p.beadsDir stringByAppendingPathComponent:@"beads.db"];
    p.jsonlPath = jsonl;   // expected location; may not exist yet (Dolt-only)
    if ([fm fileExistsAtPath:db])    p.dbPath    = db;
    return p;
}

+ (nullable BeadsProject *)projectFromRoot:(NSString *)projectRoot {
    if (projectRoot.length == 0) return nil;
    NSString *beadsDir = [[projectRoot stringByStandardizingPath]
                          stringByAppendingPathComponent:@".beads"];
    return [self projectFromBeadsDir:beadsDir];
}

+ (NSArray<BeadsProject *> *)discoverUniqueProjectsFromPaths:(NSArray<NSString *> *)paths
                                                         max:(NSUInteger)max {
    if (paths.count == 0 || max == 0) return @[];
    NSMutableArray<BeadsProject *> *out = [NSMutableArray arrayWithCapacity:max];
    // Dedupe by the .beads/ path itself (standardized) — two different
    // file paths often resolve to the same project.
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *p in paths) {
        if (out.count >= max) break;
        BeadsProject *proj = [self findProjectFromPath:p];
        if (!proj || proj.beadsDir.length == 0) continue;
        NSString *key = [proj.beadsDir stringByStandardizingPath];
        if (!key || [seen containsObject:key]) continue;
        [seen addObject:key];
        [out addObject:proj];
    }
    return out;
}

@end
