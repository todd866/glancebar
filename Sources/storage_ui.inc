// Included inside Controller. All traversal, cache I/O and cleanup stay on one
// background queue. Rendering consumes only immutable snapshots.
- (BOOL)storageTabSelected {
    NSTabViewController *tabs=[_detailsWindow.contentViewController isKindOfClass:NSTabViewController.class] ? (id)_detailsWindow.contentViewController : nil;
    return [tabs.tabView.selectedTabViewItem.identifier isEqual:@"storage"];
}
- (NSString *)storageHomeDirectory { return NSHomeDirectory().stringByResolvingSymlinksInPath; }
- (NSString *)storageCacheDirectory { return [[self storageHomeDirectory] stringByAppendingPathComponent:@"Library/Caches/com.iantodd.glancebar/storage"]; }
- (NSArray *)storageRoots { return GBStorageDefaultRoots([self storageHomeDirectory]); }
- (BOOL)storagePowerPermitsWork { return _bat.valid && (_bat.acConnected || _bat.percent>40); }
- (BOOL)storageBusy { return _storageCleanupProgress!=nil; }
- (void)cancelStorage {
    _storageGeneration++; _storageIndex.paused=YES; [_storageCleanupProgress cancel];
}
- (void)refreshStorageSurface {
    if (!_detailsWindow.isVisible || ![self storageTabSelected]) return;
    NSTabViewController *tabs=(id)_detailsWindow.contentViewController;
    NSTabViewItem *item=tabs.tabView.selectedTabViewItem;
    NSScrollView *fresh=[self storageDetailsView]; NSRect frame=item.view.frame;
    if(ReconcileViewTree(item.view,fresh)){item.view.frame=frame;return;}
    CGFloat offset=[item.view isKindOfClass:NSScrollView.class] ? ((NSScrollView *)item.view).contentView.bounds.origin.y : 0;
    item.view=fresh;
    [fresh.contentView scrollToPoint:NSMakePoint(0,MIN(offset,MAX(0,NSHeight(fresh.documentView.frame)-NSHeight(fresh.contentView.bounds))))];
    [fresh reflectScrolledClipView:fresh.contentView];
}
- (NSDictionary *)storageVisibleSnapshot:(NSDictionary *)snapshot {
    if(!_storageBlocked.count)return snapshot;
    NSMutableDictionary *result=[snapshot mutableCopy];NSMutableArray *rows=[NSMutableArray array];
    for(NSDictionary *entry in snapshot[@"rows"]){
        if(_storageBlocked[entry[@"path"]]){NSMutableDictionary *row=[entry mutableCopy];row[@"action"]=@"reveal";row[@"cleanupReason"]=_storageBlocked[entry[@"path"]];[rows addObject:row];}
        else [rows addObject:entry];
    }
    result[@"rows"]=rows;return result;
}
- (void)requestStorageScanIfNeeded {
    if(_terminating || _storageSleeping)return;
    if(!_storageQueue)_storageQueue=dispatch_queue_create("com.iantodd.glancebar.storage",dispatch_queue_attr_make_with_autorelease_frequency(dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_BACKGROUND,0),DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    if(!_storageCacheLoaded){
        if(_storageCacheLoading)return;
        _storageCacheLoading=YES;
        dispatch_async(_storageQueue,^{
            NSDictionary *cached=GBStorageLoadCache([self storageCacheDirectory],[self storageHomeDirectory]);
            dispatch_async(dispatch_get_main_queue(),^{
                self->_storageCacheLoaded=YES;self->_storageCacheLoading=NO;
                if(self->_terminating)return;
                if(!self->_storageResult && cached)self->_storageResult=cached;
                [self refreshStorageSurface]; [self requestStorageScanIfNeeded];
            });
        });
        return;
    }
    BOOL allowed=[self storagePowerPermitsWork] && !_storagePaused && !_storageCleanupProgress;
    _storageIndex.paused=!allowed;
    if(!allowed || _storageSliceRunning)return;
    double now=NSDate.date.timeIntervalSince1970;
    if(_storageFinished && now-_storageLastStart<1800)return;
    _storageSliceRunning=YES;
    BOOL fresh=(!_storageIndex || _storageFinished);
    if(fresh){_storageFinished=NO;_storageLastStart=now;_storageRetainSnapshot=[_storageResult[@"rows"] count]>0;_storageProgress=nil;}
    NSUInteger generation=_storageGeneration;
    if(fresh){
        dispatch_async(_storageQueue,^{
            GBStorageIndex *index=[[GBStorageIndex alloc] initWithRoots:[self storageRoots] home:[self storageHomeDirectory]];
            dispatch_async(dispatch_get_main_queue(),^{
                self->_storageSliceRunning=NO;
                if(self->_terminating || generation!=self->_storageGeneration)return;
                self->_storageIndex=index;[self requestStorageScanIfNeeded];
            });
        });
        return;
    }
    GBStorageIndex *index=_storageIndex;
    BOOL onAC=_bat.valid && _bat.acConnected, retainSnapshot=_storageRetainSnapshot;
    dispatch_async(_storageQueue,^{
        NSDictionary *snapshot=[index advanceForSeconds:onAC ? .35 : .15 entries:onAC ? 3000 : 1200];
        BOOL finished=index.finished;
        double tick=NSDate.date.timeIntervalSince1970;
        if(finished || (!retainSnapshot && tick-self->_storageLastCache>30)){GBStorageSaveCache(snapshot,[self storageCacheDirectory],[self storageHomeDirectory]);self->_storageLastCache=tick;}
        dispatch_async(dispatch_get_main_queue(),^{
            self->_storageSliceRunning=NO;
            if(self->_terminating || generation!=self->_storageGeneration)return;
            self->_storageFinished=finished;self->_storageProgress=snapshot;
            if(finished)self->_storageLastStart=NSDate.date.timeIntervalSince1970;
            // A refresh keeps the previous ranking until the replacement pass ends.
            // Otherwise early small files would displace known large cached items.
            if((!self->_storageRetainSnapshot || finished) && ([snapshot[@"rows"] count] || finished || !self->_storageResult))
                self->_storageResult=[self storageVisibleSnapshot:snapshot];
            if(finished)self->_storageRetainSnapshot=NO;
            [self refreshStorageSurface];
            if(!finished)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(onAC ? 1 : 2)*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self requestStorageScanIfNeeded];});
        });
    });
}
- (void)scanStorage:(id)sender {
    (void)sender;
    if(_storageFinished){_storageLastStart=0;_storageNotice=nil;[_storageBlocked removeAllObjects];}
    else _storagePaused=!_storagePaused;
    _storageIndex.paused=_storagePaused;
    [self refreshStorageSurface]; [self requestStorageScanIfNeeded];
}
- (void)chooseStorageMode:(NSSegmentedControl *)sender { _storageFolders=sender.selectedSegment==1; [self refreshStorageSurface]; }
- (NSDictionary *)storageEntry:(NSString *)path {
    for(NSDictionary *entry in _storageResult[_storageFolders ? @"folders" : @"rows"])if([entry[@"path"] isEqual:path])return entry;
    return nil;
}
- (void)revealStorage:(NSButton *)sender {
    NSDictionary *entry=[self storageEntry:sender.identifier];
    if(entry)[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:entry[@"path"]]]];
}
- (NSString *)storageOpenFileReason:(NSString *)path { return GBStorageOpenFileReason(path); }
- (NSDictionary *)performStorageCleanup:(NSDictionary *)entry compress:(BOOL)compress progress:(NSProgress *)progress {
    GBStorageOpenCheck check=^NSString *(NSString *path){return progress.cancelled ? @"Cancelled; file kept." : [self storageOpenFileReason:path];};
    return compress ? GBStorageCompress(entry,[self storageHomeDirectory],check,^BOOL{return progress.cancelled;}) : GBStorageTrash(entry,[self storageHomeDirectory],check,nil);
}
- (void)runStorageCleanup:(NSDictionary *)entry compress:(BOOL)compress {
    if([self storageBusy] || _terminating || !_detailsWindow.isVisible || ![self storageTabSelected])return;
    if(!compress && ![entry[@"action"] isEqual:@"trash"])return;
    if(!_storageQueue)_storageQueue=dispatch_queue_create("com.iantodd.glancebar.storage",dispatch_queue_attr_make_with_autorelease_frequency(dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_BACKGROUND,0),DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    _storageIndex.paused=YES;
    NSProgress *progress=[NSProgress progressWithTotalUnitCount:1];_storageCleanupProgress=progress;
    _storageNotice=compress ? @"Creating ZIP copy…" : @"Moving to Trash…"; [self refreshStorageSurface];
    GBStorageIndex *index=_storageIndex;
    NSDictionary *visibleSnapshot=_storageResult;
    dispatch_async(_storageQueue,^{
        NSDictionary *result=[self performStorageCleanup:entry compress:compress progress:progress];
        NSMutableDictionary *updated=nil;
        if(!result[@"error"] && !compress){
            [index removeFile:entry];
            updated=[visibleSnapshot mutableCopy];
            NSMutableArray *rows=[NSMutableArray array];
            for(NSDictionary *row in visibleSnapshot[@"rows"])if(![row[@"path"] isEqual:entry[@"path"]])[rows addObject:row];
            updated[@"rows"]=rows;
            NSMutableArray *folders=[NSMutableArray array];
            for(NSDictionary *folder in visibleSnapshot[@"folders"]){
                NSMutableDictionary *row=[folder mutableCopy];
                if([entry[@"path"] hasPrefix:[row[@"path"] stringByAppendingString:@"/"]])
                    for(NSString *key in @[@"allocatedBytes",@"logicalBytes"])row[key]=@(MAX(0,[row[key] longLongValue]-[entry[key] longLongValue]));
                [folders addObject:row];
            }
            updated[@"folders"]=folders;
            GBStorageSaveCache(updated,[self storageCacheDirectory],[self storageHomeDirectory]);
        }
        dispatch_async(dispatch_get_main_queue(),^{
            self->_storageCleanupProgress=nil;
            if(self->_terminating)return;
            self->_storageNotice=result[@"error"] ?: result[@"message"];
            if(result[@"error"] && !compress){
                if(!self->_storageBlocked)self->_storageBlocked=[NSMutableDictionary dictionary];
                self->_storageBlocked[entry[@"path"]]=result[@"error"];
                self->_storageResult=[self storageVisibleSnapshot:self->_storageResult];
            }
            if(!result[@"error"] && !compress){
                self->_storageUndo=result[@"undoToken"] ? result : nil;
                self->_storageResult=updated;
            }
            [self refreshStorageSurface];[self requestStorageScanIfNeeded];
        });
    });
}
- (void)trashStorage:(NSButton *)sender { NSDictionary *entry=[self storageEntry:sender.identifier];if(entry)[self runStorageCleanup:entry compress:NO]; }
- (void)compressStorage:(NSMenuItem *)sender { NSDictionary *entry=[self storageEntry:sender.representedObject];if(entry)[self runStorageCleanup:entry compress:YES]; }
- (void)storageMore:(NSButton *)sender {
    NSDictionary *entry=[self storageEntry:sender.identifier];if(!entry)return;
    NSMenu *menu=[NSMenu new];
    NSMenuItem *reveal=[menu addItemWithTitle:@"Reveal in Finder" action:@selector(revealStorage:) keyEquivalent:@""];
    reveal.target=self;reveal.identifier=entry[@"path"];reveal.image=[self menuSymbol:@"arrow.up.forward.square"];
    if([entry[@"logicalBytes"] unsignedLongLongValue]>0 && [entry[@"logicalBytes"] unsignedLongLongValue]<=4ULL*1024*1024*1024 &&
       [@[@"txt",@"log",@"csv",@"tsv",@"json",@"jsonl",@"ndjson",@"xml",@"md",@"sql",@"rtf"] containsObject:[entry[@"path"] pathExtension].lowercaseString]){
        NSMenuItem *item=[menu addItemWithTitle:@"Compress Copy" action:@selector(compressStorage:) keyEquivalent:@""];
        item.target=self;item.representedObject=entry[@"path"];item.image=[self menuSymbol:@"doc.zipper"];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(sender.bounds)) inView:sender];
}
- (void)undoStorage:(id)sender {
    (void)sender;if(!_storageUndo || [self storageBusy])return;
    NSDictionary *record=_storageUndo;_storageUndo=nil;_storageIndex.paused=YES;
    _storageCleanupProgress=[NSProgress progressWithTotalUnitCount:1];_storageNotice=@"Restoring…";[self refreshStorageSurface];
    dispatch_async(_storageQueue,^{
        NSDictionary *result=GBStorageRestore(record,[self storageHomeDirectory]);
        dispatch_async(dispatch_get_main_queue(),^{
            self->_storageCleanupProgress=nil;if(self->_terminating)return;
            self->_storageNotice=result[@"error"] ?: result[@"message"];
            if(result[@"error"])self->_storageUndo=record;
            else {self->_storageFinished=YES;self->_storageLastStart=0;}
            [self refreshStorageSurface];[self requestStorageScanIfNeeded];
        });
    });
}
- (CGFloat)addStorageBrowserTo:(NSView *)root y:(CGFloat)y {
    CGFloat width=kDetailW,pad=24;BOOL busy=[self storageBusy];y+=12;
    NSSegmentedControl *mode=[NSSegmentedControl segmentedControlWithLabels:@[@"Largest items",@"Folders"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(chooseStorageMode:)];
    mode.frame=NSMakeRect(pad,y,230,26);mode.selectedSegment=_storageFolders ? 1 : 0;mode.accessibilityIdentifier=@"details.storage.mode";[root addSubview:mode];
    NSString *buttonTitle=_storageFinished ? @"Refresh" : _storagePaused ? @"Resume" : @"Pause";
    NSButton *scan=[NSButton buttonWithTitle:buttonTitle target:self action:@selector(scanStorage:)];
    scan.frame=NSMakeRect(width-pad-84,y,84,26);scan.enabled=!busy;scan.accessibilityIdentifier=@"details.storage.scan";[root addSubview:scan];y+=32;
    NSString *state=_storagePaused ? @"Paused" : ![self storagePowerPermitsWork] ? @"Paused for battery" : _storageFinished ? ([_storageResult[@"limited"] boolValue] ? @"Partial scan" : @"Updated") : @"Updating";
    NSDateFormatter *clock=[NSDateFormatter new];clock.dateFormat=@"HH:mm";
    NSString *stamp=_storageResult[@"capturedAt"] ? [clock stringFromDate:[NSDate dateWithTimeIntervalSince1970:[_storageResult[@"capturedAt"] doubleValue]]] : @"";
    if(_storageFinished && [_storageResult[@"partial"] boolValue] && ![_storageResult[@"limited"] boolValue])state=@"Updated · partial";
    NSDictionary *progress=_storageProgress ?: _storageResult;
    NSString *status=_storageNotice ?: [NSString stringWithFormat:@"%@%@ %@ · %@ entries · %@ unavailable",state,_storageRetainSnapshot ? @" · cached" : @"",stamp,progress[@"entries"] ?: @0,progress[@"errors"] ?: @0];
    [self detailText:status font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor frame:NSMakeRect(pad,y,width-2*pad-(_storageUndo ? 70 : 0),18) align:NSTextAlignmentLeft identifier:@"details.storage.status" in:root];
    if(_storageUndo){NSButton *undo=[NSButton buttonWithTitle:@"Undo" target:self action:@selector(undoStorage:)];undo.frame=NSMakeRect(width-pad-64,y-4,64,26);undo.enabled=!busy;undo.accessibilityIdentifier=@"details.storage.undo";[root addSubview:undo];}y+=22;
    NSString *legend=_storageFolders ? @"Folder totals overlap · parent folders include their contents" : @"Home, apps, Library & local volumes · APFS shared blocks may overlap";
    [self detailText:legend font:[NSFont systemFontOfSize:11.5] color:NSColor.secondaryLabelColor frame:NSMakeRect(pad,y,width-2*pad,18) align:NSTextAlignmentLeft identifier:@"details.storage.legend" in:root];y+=24;
    CGFloat nameW=width-326,allocatedX=width-292,logicalX=width-208,actionX=width-122;
    NSArray *titles=@[@"Item",@"Allocated",@"Logical"];CGFloat xs[]={pad,allocatedX,logicalX},ws[]={nameW,78,78};
    for(NSUInteger col=0;col<3;col++)[self detailText:titles[col] font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor frame:NSMakeRect(xs[col],y,ws[col],18) align:col ? NSTextAlignmentRight : NSTextAlignmentLeft identifier:[@"details.storage.heading." stringByAppendingString:titles[col]] in:root];y+=24;
    NSArray *rows=_storageResult[_storageFolders ? @"folders" : @"rows"] ?: @[];
    for(NSDictionary *entry in rows){
        NSString *prefix=[@"details.storage.item." stringByAppendingString:entry[@"path"]];
        NSTextField *name=[self detailText:entry[@"name"] font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium] color:NSColor.labelColor frame:NSMakeRect(pad,y,nameW,18) align:NSTextAlignmentLeft identifier:[prefix stringByAppendingString:@".name"] in:root];name.lineBreakMode=NSLineBreakByTruncatingMiddle;name.accessibilityHelp=entry[@"cleanupReason"] ?: entry[@"protectedReason"];
        NSString *path=[entry[@"path"] stringByAbbreviatingWithTildeInPath];
        NSTextField *location=[self detailText:path font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor frame:NSMakeRect(pad,y+18,nameW,16) align:NSTextAlignmentLeft identifier:[prefix stringByAppendingString:@".path"] in:root];location.lineBreakMode=NSLineBreakByTruncatingMiddle;location.accessibilityLabel=entry[@"path"];
        for(NSUInteger col=1;col<3;col++){
            NSString *value=[NSString stringWithFormat:@"%@%@",[entry[@"partial"] boolValue] ? @"≥" : @"",CompactByteCount([entry[col==1 ? @"allocatedBytes" : @"logicalBytes"] unsignedLongLongValue])];
            [self detailText:value font:[NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular] color:NSColor.labelColor frame:NSMakeRect(xs[col],y+7,ws[col],18) align:NSTextAlignmentRight identifier:[prefix stringByAppendingFormat:@".%lu",(unsigned long)col] in:root];
        }
        BOOL trash=!_storageFolders && [entry[@"action"] isEqual:@"trash"];
        NSButton *action=[NSButton buttonWithTitle:trash ? @"Trash" : @"Reveal" target:self action:trash ? @selector(trashStorage:) : @selector(revealStorage:)];
        action.frame=NSMakeRect(actionX,y+2,76,28);action.identifier=entry[@"path"];action.enabled=!busy;action.accessibilityIdentifier=[prefix stringByAppendingString:@".action"];action.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",action.title,entry[@"path"]];[root addSubview:action];
        if(trash){NSButton *more=[NSButton buttonWithTitle:@"…" target:self action:@selector(storageMore:)];more.frame=NSMakeRect(width-pad-20,y+2,20,28);more.bordered=NO;more.identifier=entry[@"path"];more.enabled=!busy;more.accessibilityLabel=@"File actions";more.accessibilityIdentifier=[prefix stringByAppendingString:@".more"];[root addSubview:more];}
        y+=42;
    }
    if(!rows.count)[self addDetailStatus:_storageFinished ? @"No files measured with current access" : @"Finding the largest items…" to:root y:&y width:width];
    return y;
}
