# Storage browser

Details → Storage scans the selected local folder when first opened, then reuses the
snapshot until Scan is pressed. Open drills into a folder; Up and the folder picker
change scope. Rows are ranked by reported allocated bytes, with logical bytes shown
separately. The largest 100 observed immediate children are displayed.

Each scan runs at background CPU and disk priority, for at most 60,000 entries and
six seconds between filesystem calls. A child subtree gets at most 4,000 entries.
Cancelled, inaccessible, excluded and bounded subtrees are partial (`≥`); unknown
sizes show `—`. OS filesystem calls themselves cannot be interrupted. Remote mounts,
symlinks, cloud placeholders, repository/worktree markers, common build directories
and application/library packages are excluded. No Full Disk Access or helper is
requested. Reveal in Finder remains available for excluded items.

Allocated bytes are filesystem reports, not an estimate of space recovered. Sparse
files can have much smaller allocated than logical sizes. Hardlinks are counted
once per scan by device/inode; subsequent occurrences are unknown partial rows or
partial subtree totals. APFS clone sharing, snapshots and purgeable space prevent
these figures from representing exclusive reclaimable bytes.

Review shows the full path and an explicit choice. Cancel is the default Return
action. Only individual, unchanged, locally present files owned by the current
user under Downloads, Desktop, Documents, Movies, Music or Pictures are eligible.
Directories, hardlinks, locked files, developer trees and library packages remain
browse/reveal only. The app rechecks identity and open-file state before coordinated
operations and fails closed if the in-use check cannot complete.

Move to Trash uses macOS Trash, never permanent deletion or Empty Trash. Compress
Copy accepts nonempty text/log/data exports up to 4 GB, checks available space,
creates a private ZIP, verifies it with `unzip -t`, and publishes without overwriting
an existing file. It keeps the original, so compression itself frees no space.
Failed or cancelled archives remove only the app's own private temporary workspace.
Review and operations are cancelled when Details closes, the user leaves Storage,
or the Mac sleeps. Completion never opens a window.

`Tests/test_storage.m` uses disposable files and injected Trash transport.
`Tests/test_storage_ui.m` exercises the actual AppKit browser and mocked review
choices without presenting a window or touching real Trash. The optional native
render harness can be retained using `GLANCEBAR_STORAGE_HARNESS_OUT` with `tests.sh`.
