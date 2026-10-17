// Included inside Controller. Scans are explicit bounded snapshots; no startup crawl.
- (BOOL)storageTabSelected {
    NSTabViewController *tabs = [_detailsWindow.contentViewController isKindOfClass:NSTabViewController.class]
        ? (NSTabViewController *)_detailsWindow.contentViewController : nil;
    return [tabs.tabView.selectedTabViewItem.identifier isEqual:@"storage"];
}
- (BOOL)storageBusy { return _storageScan != nil || _storageCleanupProgress != nil; }
- (void)cancelStorage {
    _storageGeneration++;
    _storageScan.cancelled = YES;
    [_storageCleanupProgress cancel];
    if (_storageReviewAlert.window.sheetParent)
        [_storageReviewAlert.window.sheetParent endSheet:_storageReviewAlert.window returnCode:NSAlertFirstButtonReturn];
}
- (NSDictionary *)performStorageScan:(GBStorageScan *)scan path:(NSString *)path {
    return [scan scanPath:path entryLimit:60000 seconds:6];
}
- (void)requestStorageScan {
    if ([self storageBusy] || _terminating) return;
    if (!_storagePath) _storagePath = NSHomeDirectory().stringByResolvingSymlinksInPath;
    _storageNotice = nil;
    NSString *path = _storagePath;
    GBStorageScan *scan = [GBStorageScan new]; _storageScan = scan;
    NSUInteger generation = _storageGeneration;
    [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSDictionary *result = [self performStorageScan:scan path:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_storageScan != scan) return;
            self->_storageScan = nil;
            if (self->_terminating) return;
            if (generation == self->_storageGeneration) self->_storageResult = result;
            else self->_storageNotice = @"Scan cancelled";
            [self refreshVisibleSurfaces];
        });
    });
}
- (void)requestStorageScanIfNeeded { if (!_storageResult) [self requestStorageScan]; }
- (void)scanStorage:(id)sender {
    (void)sender;
    if ([self storageBusy]) { [self cancelStorage]; _storageNotice = @"Cancelling…"; [self refreshVisibleSurfaces]; }
    else [self requestStorageScan];
}
- (void)openStoragePath:(NSString *)path {
    if ([self storageBusy] || !path.length) return;
    _storagePath = path; _storageResult = nil; _storageGeneration++;
    [self requestStorageScan];
}
- (void)chooseStorageScope:(NSPopUpButton *)sender { [self openStoragePath:sender.selectedItem.representedObject]; }
- (void)upStorage:(id)sender { (void)sender; [self openStoragePath:(_storagePath ?: NSHomeDirectory()).stringByDeletingLastPathComponent]; }
- (NSDictionary *)storageEntry:(NSString *)path {
    for (NSDictionary *entry in _storageResult[@"rows"]) if ([entry[@"path"] isEqual:path]) return entry;
    return nil;
}
- (void)openStorageFolder:(NSButton *)sender {
    NSDictionary *entry = [self storageEntry:sender.identifier];
    if ([entry[@"isDirectory"] boolValue] && !entry[@"protectedReason"] && ![entry[@"isLink"] boolValue]) [self openStoragePath:entry[@"path"]];
}
- (void)revealStorage:(NSButton *)sender {
    NSDictionary *entry = [self storageEntry:sender.identifier];
    if (entry) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:entry[@"path"]]]];
}
- (NSString *)storageOpenFileReason:(NSString *)path { return GBStorageOpenFileReason(path); }
- (NSString *)storageHomeDirectory { return NSHomeDirectory().stringByResolvingSymlinksInPath; }
- (void)presentStorageReview:(NSAlert *)alert completion:(void (^)(NSModalResponse))completion {
    _storageReviewAlert = alert;
    [alert beginSheetModalForWindow:_detailsWindow completionHandler:^(NSModalResponse response) {
        self->_storageReviewAlert = nil; completion(response);
    }];
}
- (NSDictionary *)performStorageCleanup:(NSDictionary *)entry compress:(BOOL)compress progress:(NSProgress *)progress {
    GBStorageOpenCheck check = ^NSString *(NSString *path) {
        return progress.cancelled ? @"Cancelled; file kept." : [self storageOpenFileReason:path];
    };
    NSString *home = [self storageHomeDirectory];
    return compress ? GBStorageCompress(entry,home,check,^BOOL { return progress.cancelled; })
                    : GBStorageTrash(entry,home,check,nil);
}
- (void)runStorageCleanup:(NSDictionary *)entry compress:(BOOL)compress {
    if ([self storageBusy] || _terminating || !_detailsWindow.isVisible || ![self storageTabSelected]) return;
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1]; _storageCleanupProgress = progress;
    _storageNotice = compress ? @"Creating ZIP copy…" : @"Moving to Trash…";
    [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSDictionary *result = [self performStorageCleanup:entry compress:compress progress:progress];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_storageCleanupProgress = nil;
            if (self->_terminating) return;
            self->_storageNotice = result[@"error"] ?: result[@"message"];
            // Preserve the message and mark the old snapshot stale. Rescan is explicit.
            self->_storageResult = nil;
            [self refreshVisibleSurfaces];
        });
    });
}
- (void)reviewStorage:(NSButton *)sender {
    NSDictionary *entry = [self storageEntry:sender.identifier];
    if (!entry || [self storageBusy] || _storageReviewAlert || !_detailsWindow.isVisible) return;
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1]; _storageCleanupProgress = progress;
    NSUInteger generation = _storageGeneration;
    _storageNotice = @"Checking file…"; [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSString *home = [self storageHomeDirectory];
        NSString *reason = GBStorageCleanupReason(entry,home,NO);
        if (!reason && !progress.cancelled) reason = [self storageOpenFileReason:entry[@"path"]];
        NSString *compressReason = GBStorageCleanupReason(entry,home,YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_storageCleanupProgress = nil; self->_storageNotice = nil;
            [self refreshVisibleSurfaces];
            if (self->_terminating || progress.cancelled || generation != self->_storageGeneration ||
                !self->_detailsWindow.isVisible || ![self storageTabSelected]) return;
            NSAlert *alert = [NSAlert new]; alert.messageText = entry[@"name"] ?: @"Review file";
            NSString *sizes = [NSString stringWithFormat:@"Allocated %@ · logical %@",entry[@"allocatedBytes"] ? CompactByteCount([entry[@"allocatedBytes"] unsignedLongLongValue]) : @"—",entry[@"logicalBytes"] ? CompactByteCount([entry[@"logicalBytes"] unsignedLongLongValue]) : @"—"];
            NSString *consequences = @"Move to Trash is recoverable and does not free space until you empty Trash yourself. APFS sharing can reduce space recovered.";
            if (!compressReason) consequences = [consequences stringByAppendingString:@" Compress Copy creates a verified ZIP and keeps the original; it uses additional space."];
            alert.informativeText = [NSString stringWithFormat:@"%@\n\n%@\n%@",entry[@"path"],sizes,
                reason ?: consequences];
            [alert addButtonWithTitle:@"Cancel"]; // Return and Escape never authorize cleanup.
            alert.buttons.firstObject.keyEquivalent = @"\r";
            BOOL canTrash = !reason, canCompress = !reason && !compressReason;
            if (canTrash) [alert addButtonWithTitle:@"Move to Trash"].keyEquivalent = @"";
            if (canCompress) [alert addButtonWithTitle:@"Compress Copy"].keyEquivalent = @"";
            [self presentStorageReview:alert completion:^(NSModalResponse response) {
                if (generation != self->_storageGeneration || self->_terminating) return;
                if (canTrash && response == NSAlertSecondButtonReturn) [self runStorageCleanup:entry compress:NO];
                else if (canCompress && response == NSAlertThirdButtonReturn) [self runStorageCleanup:entry compress:YES];
            }];
        });
    });
}
- (CGFloat)addStorageBrowserTo:(NSView *)root y:(CGFloat)y {
    CGFloat width=kDetailW, pad=24; BOOL busy=[self storageBusy];
    NSString *path=_storagePath ?: NSHomeDirectory().stringByResolvingSymlinksInPath;
    y += 12;
    NSPopUpButton *scope=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(pad,y,170,28) pullsDown:NO];
    NSArray *names=@[@"Home",@"Downloads",@"Desktop",@"Documents",@"Movies",@"Music",@"Pictures",@"Library",@"Applications"];
    BOOL matched=NO;
    for (NSString *name in names) {
        NSString *candidate=[name isEqual:@"Applications"] ? @"/Applications" : [name isEqual:@"Home"] ? NSHomeDirectory().stringByResolvingSymlinksInPath : [NSHomeDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:name];
        [scope addItemWithTitle:name]; scope.lastItem.representedObject=candidate;
        if ([candidate isEqual:path]) { [scope selectItem:scope.lastItem]; matched=YES; }
    }
    if (!matched) { [scope addItemWithTitle:path.lastPathComponent.length ? path.lastPathComponent : @"/"]; scope.lastItem.representedObject=path; [scope selectItem:scope.lastItem]; }
    scope.target=self; scope.action=@selector(chooseStorageScope:); scope.enabled=!busy;
    scope.accessibilityIdentifier=@"details.storage.scope"; scope.accessibilityLabel=@"Folder to scan"; [root addSubview:scope];
    NSButton *up=[NSButton buttonWithTitle:@"Up" target:self action:@selector(upStorage:)];
    up.frame=NSMakeRect(pad+178,y,56,28); up.enabled=!busy && ![path isEqual:@"/"];
    up.accessibilityIdentifier=@"details.storage.up"; [root addSubview:up];
    NSButton *scan=[NSButton buttonWithTitle:busy ? @"Cancel" : @"Scan" target:self action:@selector(scanStorage:)];
    scan.frame=NSMakeRect(width-pad-84,y,84,28); scan.accessibilityIdentifier=@"details.storage.scan"; [root addSubview:scan];
    y += 34;
    NSTextField *folder=[self detailText:[path stringByAbbreviatingWithTildeInPath] font:[NSFont systemFontOfSize:12.5] color:NSColor.secondaryLabelColor frame:NSMakeRect(pad,y,width-2*pad,18) align:NSTextAlignmentLeft identifier:@"details.storage.path" in:root];
    folder.lineBreakMode=NSLineBreakByTruncatingMiddle; folder.selectable=YES;
    y += 24;
    NSString *status=_storageNotice;
    if (!status) {
        if (_storageScan) status=@"Scanning… · bounded snapshot";
        else if (_storageResult[@"error"]) status=_storageResult[@"error"];
        else if (_storageResult) {
            NSDateFormatter *clock=[NSDateFormatter new]; clock.dateFormat=@"HH:mm";
            NSString *time=[clock stringFromDate:[NSDate dateWithTimeIntervalSince1970:[_storageResult[@"capturedAt"] doubleValue]]];
            status=[NSString stringWithFormat:@"%@ · %@%lu entries · %lu skipped · %lu inaccessible",time,[_storageResult[@"partial"] boolValue] ? @"partial · " : @"",(unsigned long)[_storageResult[@"entries"] unsignedIntegerValue],(unsigned long)[_storageResult[@"skipped"] unsignedIntegerValue],(unsigned long)[_storageResult[@"errors"] unsignedIntegerValue]];
        } else status=@"Scan a folder to find its largest items";
    }
    [self addDetailStatus:status to:root y:&y width:width];
    [self detailText:@"APFS shared blocks may repeat · not space recovered · ≥ partial" font:[NSFont systemFontOfSize:11.5] color:NSColor.secondaryLabelColor frame:NSMakeRect(pad,y,width-2*pad,18) align:NSTextAlignmentLeft identifier:@"details.storage.legend" in:root];
    y += 26;
    CGFloat nameW=width-382, allocatedX=width-348, logicalX=width-262, actionX=width-172, revealX=width-58;
    NSArray *titles=@[@"Item",@"Allocated",@"Logical"];
    CGFloat xs[]={pad,allocatedX,logicalX}, ws[]={nameW,78,78};
    for (NSUInteger col=0;col<3;col++) [self detailText:titles[col] font:[NSFont systemFontOfSize:12.5] color:NSColor.secondaryLabelColor frame:NSMakeRect(xs[col],y,ws[col],18) align:col ? NSTextAlignmentRight : NSTextAlignmentLeft identifier:[@"details.storage.heading." stringByAppendingString:titles[col]] in:root];
    y += 24;
    NSArray *rows=_storageResult[@"rows"] ?: @[]; NSUInteger index=0;
    for (NSDictionary *entry in rows) {
        if (index++ >= 100) break;
        NSString *prefix=[@"details.storage.item." stringByAppendingString:entry[@"path"]];
        NSTextField *name=[self detailText:entry[@"name"] font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium] color:NSColor.labelColor frame:NSMakeRect(pad,y,nameW,18) align:NSTextAlignmentLeft identifier:[prefix stringByAppendingString:@".name"] in:root];
        name.lineBreakMode=NSLineBreakByTruncatingMiddle; name.accessibilityHelp=entry[@"path"];
        NSString *kind=entry[@"protectedReason"] ?: entry[@"problem"] ?: ([entry[@"isDirectory"] boolValue] ? @"Folder" : ( [entry[@"path"] pathExtension].length ? [[entry[@"path"] pathExtension] uppercaseString] : @"File"));
        [self detailText:kind font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor frame:NSMakeRect(pad,y+18,nameW,15) align:NSTextAlignmentLeft identifier:[prefix stringByAppendingString:@".kind"] in:root];
        for (NSUInteger col=1;col<3;col++) {
            NSNumber *bytes=entry[col==1 ? @"allocatedBytes" : @"logicalBytes"];
            NSString *value=bytes ? [NSString stringWithFormat:@"%@%@",[entry[@"partial"] boolValue] ? @"≥" : @"",CompactByteCount(bytes.unsignedLongLongValue)] : @"—";
            [self detailText:value font:[NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular] color:NSColor.labelColor frame:NSMakeRect(xs[col],y+7,ws[col],18) align:NSTextAlignmentRight identifier:[prefix stringByAppendingFormat:@".%lu",(unsigned long)col] in:root];
        }
        BOOL directory=[entry[@"isDirectory"] boolValue], protected=entry[@"protectedReason"] != nil || [entry[@"isLink"] boolValue];
        NSButton *action=[NSButton buttonWithTitle:directory ? @"Open" : @"Review…" target:self action:directory ? @selector(openStorageFolder:) : @selector(reviewStorage:)];
        action.frame=NSMakeRect(actionX,y+2,104,28); action.identifier=entry[@"path"]; action.enabled=!busy && !protected;
        action.accessibilityIdentifier=[prefix stringByAppendingString:@".action"]; action.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",action.title,entry[@"name"]]; [root addSubview:action];
        NSButton *reveal=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.up.forward.square" accessibilityDescription:@"Reveal in Finder"] target:self action:@selector(revealStorage:)];
        reveal.frame=NSMakeRect(revealX,y+2,32,28); reveal.bordered=NO; reveal.identifier=entry[@"path"];
        reveal.accessibilityIdentifier=[prefix stringByAppendingString:@".reveal"]; reveal.accessibilityLabel=[NSString stringWithFormat:@"Reveal %@ in Finder",entry[@"name"]]; [root addSubview:reveal];
        y += 40;
    }
    if (rows.count > 100) [self addDetailStatus:[NSString stringWithFormat:@"Largest 100 of %lu items shown",(unsigned long)rows.count] to:root y:&y width:width];
    else if (_storageResult && !rows.count && !_storageResult[@"error"])
        [self addDetailStatus:[_storageResult[@"partial"] boolValue] ? @"No items measured in this partial scan" : @"Folder is empty" to:root y:&y width:width];
    return y;
}
