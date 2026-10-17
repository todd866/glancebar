# Automatic Storage ranking

Details → Storage shows the largest observed items across home, Applications,
Library, Shared and mounted local volumes. Downloads, Movies and other personal
folders are seeded first, then the wider scan continues automatically. No folder
selection or manual drill-down is needed. Results arrive progressively and remain
cached while Details is closed. Refresh starts a new pass; Pause/Resume preserves
its traversal position. Passes refresh after 30 minutes, with a private local cache
retained for up to 24 hours across app restarts. Refreshes publish new leaders and progress throughout the pass. Previously
measured leaders remain available with a `~` cached-size marker until rechecked;
completion retires stale entries. Progress is cached every 30 seconds even when
previous measurements are retained.

The default list ranks individual ordinary files and protected aggregates such as
repositories, application bundles and photo libraries by allocated bytes. It does
not show the protected aggregate's internal files as separate cleanup targets.
Folders is a separate ranking: parent and child totals intentionally overlap.
Each row displays its path and both allocated and logical size. `≥` marks an
incomplete aggregate. Unavailable paths and exclusions make coverage partial;
these are the largest **observed** entries, not a claim that inaccessible or
cloud-only data was measured. No Full Disk Access or helper is requested.

Traversal uses background CPU priority, temporary throttled disk policy, at most
12 open directory streams and resumable slices (350 ms or 3,000 entries, followed
by a one-second pause on AC; 150 ms/1,200 entries and two seconds on battery). A pass
is bounded to 5,000,000 entries and 500,000 directories, without a total-time
cutoff that would repeatedly truncate large homes. OS filesystem calls cannot be
interrupted. The app pauses indexing during sleep and at 40% or less on battery,
or while power is unknown; AC resumes it. Closing Details does not stop indexing.
Only metadata is read. Symlinks, remote mounts, dataless files, CloudStorage,
Mobile Documents and Trash are excluded. Protected developer/app/library trees
are measured read-only and presented as aggregates with Reveal actions.

Allocated bytes are filesystem reports, not exclusive reclaimable space. Sparse
files can have much smaller allocated than logical sizes. Hardlinks are counted
once by device/inode. APFS clone sharing, snapshots and purgeable space prevent a
sum of these numbers from predicting how much free space cleanup will recover.
Folder sums include regular-file blocks; directory metadata is not included.

Trash is the explicit one-click action for individual unchanged locally present
files owned by the current user under Downloads, Desktop, Documents, Movies,
Music or Pictures. There is no second confirmation. Directories, hardlinks,
locked files, developer trees and library packages offer Reveal. Before moving a
file, the app rechecks its identity and open-file state with coordinated access;
unknown or active files fail closed with a reason. No permanent deletion or Empty
Trash action exists. A verified Trash move offers Undo for the latest move in
this app session. Undo requires the same trashed file and original parent folder,
and restores atomically without overwriting an existing path.

The row's ellipsis offers Compress Copy for supported text/log/data exports up to
4 GB. It checks available space, creates and verifies a private ZIP, and publishes
without overwriting another file. The original remains; compression itself frees
no space. Cache files are local only, with directory mode 0700/file mode 0600.
Rendering does no filesystem access; all traversal, cache and cleanup work runs
on a single background queue. Progressive updates rank only changed folders and protected groups against the
previous top 100. They do not repeatedly copy or sort the entire growing index.
A branch deeper than 64 path components is skipped without stopping other roots.
Resource ceilings finish with an explicit “Scan limit reached” state.
Completion never opens a window.

Tests use disposable filesystem fixtures for global ranking, protected aggregate
boundaries, overlapping roots, sparse files, hardlinks, pause/resume, unavailable
paths, cache validation, direct Trash and safe Undo. AppKit UI tests render actual
views offscreen in light/dark at 600/840 points without presenting windows. The
popover latency harness measures the production handler to a mocked presentation
request and native offscreen paint; it does not measure the onscreen compositor.
