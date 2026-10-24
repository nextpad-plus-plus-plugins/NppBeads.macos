// BeadIdIndicator — Phase 5 editor integration.
//
// Scans the active editor's visible range for bead-id tokens matching
// `\b<prefix>-[a-z0-9]+(\.\d+)*\b`, paints a Scintilla indicator
// (INDIC_TEXTFORE — link-style text-color) on each match, and caches
// {byte_start, byte_end, id} triples so callers can answer "what bead
// is under this cursor position?" in O(log N).
//
// Owns no state beyond the cache + target scintilla handle. NppBeads.mm
// drives lifecycle:
//   - `setScintillaHandle:` on NPPN_BUFFERACTIVATED (new editor active)
//   - `scheduleRescan` on SCN_MODIFIED (insert/delete) — debounced
//   - `rescanNow` on NPPN_BUFFERACTIVATED after the handle switch
//   - `clearAll` on panel unbind / project clear
//
// Scintilla regex is used (SCFIND_REGEXP | SCFIND_CXX11REGEX) so positions
// are byte-accurate against the doc's UTF-8 buffer — no UTF-16 conversion
// dance. Works for files with arbitrary unicode content because bead ids
// themselves are always ASCII.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BeadIdMatch : NSObject
@property (nonatomic, assign) intptr_t startByte;
@property (nonatomic, assign) intptr_t endByte;     // exclusive
@property (nonatomic, copy)   NSString *beadId;
@end

// Signature matches NppData._sendMessage — used to SCI_* the Scintilla
// handle. We take a function pointer so we don't depend on the plugin
// headers here (keeps this class a clean native unit).
typedef intptr_t (*BeadIdSendMessageFn)(uintptr_t handle, uint32_t msg,
                                         uintptr_t wParam, intptr_t lParam);

@interface BeadIdIndicator : NSObject

/** Default "bd-". Setters standardize + rescan. */
@property (nonatomic, copy) NSString *prefix;

/** Currently-active scintilla handle (0 = none → everything becomes a
    no-op). Changes on NPPN_BUFFERACTIVATED. Changing it clears the cache
    but does NOT clear indicators on the old handle — the buffer-switch
    already hides them; clearing would race with the host rerouting. */
@property (nonatomic, assign) uintptr_t scintillaHandle;

/** Scintilla indicator slot to paint on. Defaults to 25, which is free on
    legacy hosts (NPPM_GETBOOKMARKID == 24). On hosts with the remapped
    Windows-parity ID layout (NPPM_GETBOOKMARKID == 20) slot 25 is the host's
    Mark-style-1 indicator, so NppBeads.mm resolves a slot from
    NPPM_ALLOCATEINDICATOR at NPPN_READY and sets it here before any paint. */
@property (nonatomic, assign) int indicatorSlot;

- (instancetype)initWithSendMessage:(BeadIdSendMessageFn)send NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Debounced rescan (150 ms coalesce). Safe to spam from SCN_* handlers. */
- (void)scheduleRescan;

/** Immediate rescan. Use when debouncing is wasteful (buffer switch). */
- (void)rescanNow;

/** Remove every indicator from the current doc. Call on project unbind /
    plugin shutdown. No-op when scintillaHandle == 0. */
- (void)clearAll;

/** O(log N) query over the last rescan's cache. Returns nil when the
    byte position isn't inside a known match. */
- (nullable NSString *)beadIdAtPosition:(intptr_t)byteOffset;

/** Immutable snapshot of the last rescan. Mostly useful for diagnostics
    and for "N matches visible" kinds of UI (tab color coding, etc.). */
- (NSArray<BeadIdMatch *> *)currentMatches;

@end

NS_ASSUME_NONNULL_END
