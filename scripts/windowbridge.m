#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>

static int (*connection)(void);
static CFArrayRef (*managed)(int);
static CFArrayRef (*windowSpaces)(int,int,CFArrayRef);
static int64_t (*bridgeOperation)(id);
static AXError (*axWindowID)(AXUIElementRef,CGWindowID *);
static AXUIElementRef (*remoteElement)(CFDataRef);
static int cid;
static NSMutableDictionary *tokenCache;
static NSString *cachePath;

// Resolve SkyLight's local bridge symbol, as used by current yabai.
// Source: https://github.com/asmvik/yabai/blob/master/src/misc/macho_dlsym.h
static void *localSymbol(const char *wanted) {
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);
        if (!name || !strstr(name,"/SkyLight.framework/")) continue;
        const struct mach_header_64 *h=(const void *)_dyld_get_image_header(i);
        const struct segment_command_64 *link=NULL;
        const struct symtab_command *table=NULL;
        const uint8_t *p=(const uint8_t *)(h+1);
        for (uint32_t j=0;j<h->ncmds;j++) {
            const struct load_command *lc=(const void *)p;
            if (lc->cmd==LC_SYMTAB) table=(const void *)lc;
            if (lc->cmd==LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname,SEG_LINKEDIT)) link=(const void *)lc;
            p+=lc->cmdsize;
        }
        if (!link || !table) continue;
        uintptr_t base=_dyld_get_image_vmaddr_slide(i)+link->vmaddr-link->fileoff;
        const struct nlist_64 *symbols=(const void *)(base+table->symoff);
        const char *strings=(const void *)(base+table->stroff);
        for (uint32_t j=0;j<table->nsyms;j++) if (symbols[j].n_un.n_strx<table->strsize && !strcmp(strings+symbols[j].n_un.n_strx,wanted)) return (void *)(symbols[j].n_value+_dyld_get_image_vmaddr_slide(i));
    }
    return NULL;
}

static void fail(NSString *message) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"ok":@NO,@"error":message} options:0 error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    exit(1);
}
static NSArray *spaces(uint32_t wid) {
    CFArrayRef value=windowSpaces(cid,7,(__bridge CFArrayRef)@[@(wid)]);
    return value ? CFBridgingRelease(value) : @[];
}
static NSArray *displays(void) {
    CFArrayRef value=managed(cid);
    return value ? CFBridgingRelease(value) : @[];
}
static BOOL userSpace(NSNumber *sid) {
    for (NSDictionary *d in displays()) for (NSDictionary *s in d[@"Spaces"]) if ([(s[@"ManagedSpaceID"] ?: s[@"id64"]) isEqual:sid] && [s[@"type"] intValue]==0) return YES;
    return NO;
}
static NSArray *windows(void) {
    return CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,kCGNullWindowID)) ?: @[];
}
static NSDictionary *bounds(uint32_t wid) {
    for (NSDictionary *w in windows()) if ([w[(id)kCGWindowNumber] unsignedIntValue]==wid) return w[(id)kCGWindowBounds];
    return @{};
}
static BOOL awaitGeometry(uint32_t wid,NSDictionary *wanted,NSDictionary *previous,double timeout) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        NSDictionary *actual=bounds(wid);BOOL same=YES,changed=NO;
        for (NSString *key in wanted) {
            if (!actual[key] || fabs([actual[key] doubleValue]-[wanted[key] doubleValue])>2) same=NO;
            if (previous[key] && actual[key] && fabs([actual[key] doubleValue]-[previous[key] doubleValue])>1) changed=YES;
        }
        if (same || changed) return YES;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    } while (deadline.timeIntervalSinceNow>0);
    return NO;
}
static NSString *bundle(NSDictionary *window) {
    return [NSRunningApplication runningApplicationWithProcessIdentifier:[window[(id)kCGWindowOwnerPID] intValue]].bundleIdentifier ?: @"";
}
static BOOL regular(NSDictionary *w) {
    NSDictionary *b=w[(id)kCGWindowBounds];
    return [w[(id)kCGWindowLayer] intValue]==0 && [b[@"Width"] doubleValue]>200 && [b[@"Height"] doubleValue]>100 && [w[(id)kCGWindowAlpha] doubleValue]>0;
}
static NSDictionary *context(void) {
    NSMutableArray *active=[NSMutableArray array];
    for (NSDictionary *d in displays()) [active addObject:d[@"Current Space"][@"ManagedSpaceID"] ?: @0];
    NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
    return @{@"activeSpaces":active,@"frontPID":@(front.processIdentifier),@"frontApp":front.bundleIdentifier ?: @""};
}
static BOOL appHidden(NSRunningApplication *app,BOOL hidden) {
    AXUIElementRef element=AXUIElementCreateApplication(app.processIdentifier);
    AXError status=AXUIElementSetAttributeValue(element,kAXHiddenAttribute,hidden ? kCFBooleanTrue:kCFBooleanFalse);
    CFRelease(element);
    return status==kAXErrorSuccess;
}
static BOOL appHasWindowOnSpaces(NSArray *windowList, NSString *appID, NSArray *spaceIDs, BOOL visibleOnly) {
    NSSet *active = [NSSet setWithArray:spaceIDs];
    for (NSDictionary *window in windowList) {
        if (!regular(window) || ![bundle(window) isEqualToString:appID]) continue;
        if (visibleOnly && ![window[(id)kCGWindowIsOnscreen] boolValue]) continue;
        uint32_t windowID = [window[(id)kCGWindowNumber] unsignedIntValue];
        if ([active intersectsSet:[NSSet setWithArray:spaces(windowID)]]) return YES;
    }
    return NO;
}
static AXUIElementRef findAX(pid_t pid,uint32_t wid) {
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    CFTypeRef array=NULL;
    AXError e=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&array);
    CFRelease(app);
    AXUIElementRef result=NULL;
    if (e==kAXErrorSuccess && array) for (id element in (__bridge NSArray *)array) {
        uint32_t candidate=0;
        if (axWindowID((__bridge AXUIElementRef)element,&candidate)==kAXErrorSuccess && candidate==wid) { result=(AXUIElementRef)CFRetain((__bridge AXUIElementRef)element);break; }
    }
    if (array) CFRelease(array);
    if (result || !remoteElement) return result;
    NSString *pidKey=[@(pid) stringValue],*windowKey=[@(wid) stringValue];
    NSMutableDictionary *cached=[tokenCache[pidKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    uint8_t bytes[20]={0};uint32_t framework=0x636f636f;
    memcpy(bytes,&pid,4);memcpy(bytes+8,&framework,4);
    if (cached[windowKey]) {
        uint64_t element=[cached[windowKey] unsignedLongLongValue];memcpy(bytes+12,&element,8);
        CFDataRef data=CFDataCreate(NULL,bytes,20);AXUIElementRef candidate=remoteElement(data);CFRelease(data);
        uint32_t actual=0;
        if (candidate && axWindowID(candidate,&actual)==0 && actual==wid) return candidate;
        if (candidate) CFRelease(candidate);
        [cached removeObjectForKey:windowKey];
    }
    // Inactive-space windows are omitted from AXWindows. Resolve only this
    // authorized application's window roles; retain IDs, never UI contents.
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];
    for (uint64_t element=0;element<0x7fff && deadline.timeIntervalSinceNow>0;element++) {
        memcpy(bytes+12,&element,8);CFDataRef data=CFDataCreate(NULL,bytes,20);
        AXUIElementRef candidate=remoteElement(data);CFRelease(data);
        if (!candidate) continue;
        CFTypeRef role=NULL;AXUIElementCopyAttributeValue(candidate,kAXRoleAttribute,&role);
        uint32_t actual=0;
        if (role && CFEqual(role,kAXWindowRole) && axWindowID(candidate,&actual)==0 && actual) {
            cached[[@(actual) stringValue]]=@(element);
            if (actual==wid) result=candidate;
        }
        if (role) CFRelease(role);
        if (!result) CFRelease(candidate);else break;
    }
    tokenCache[pidKey]=cached;
    NSData *saved=[NSJSONSerialization dataWithJSONObject:tokenCache options:0 error:nil];
    [saved writeToFile:cachePath atomically:YES];
    return result;
}
static NSDictionary *screenFrame(NSDictionary *display) {
    NSString *uuid=display[@"Display Identifier"];
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID did=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef u=CGDisplayCreateUUIDFromDisplayID(did);
        NSString *s=CFBridgingRelease(CFUUIDCreateString(NULL,u));
        CFRelease(u);
        if (![s isEqual:uuid] && ![uuid isEqual:@"Main"]) continue;
        NSRect f=screen.visibleFrame;
        double top=CGDisplayBounds(CGMainDisplayID()).size.height;
        return @{@"x":@(f.origin.x),@"y":@(top-NSMaxY(f)),@"width":@(f.size.width),@"height":@(f.size.height)};
    }
    return @{};
}
int main(int argc,const char **argv) { @autoreleasepool {
    void *lib=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    connection=dlsym(lib,"SLSMainConnectionID");managed=dlsym(lib,"SLSCopyManagedDisplaySpaces");windowSpaces=dlsym(lib,"SLSCopySpacesForWindows");
    bridgeOperation=dlsym(lib,"SLSPerformAsynchronousBridgedWindowManagementOperation");
    if (!bridgeOperation) bridgeOperation=localSymbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    axWindowID=dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    remoteElement=dlsym(RTLD_DEFAULT,"_AXUIElementCreateWithRemoteToken");
    NSString *cacheDir=[NSHomeDirectory() stringByAppendingPathComponent:@".cache/codex-workspace-layout"];
    [NSFileManager.defaultManager createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    cachePath=[cacheDir stringByAppendingPathComponent:@"ax-tokens.json"];
    tokenCache=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:cachePath] ?: [NSData data] options:NSJSONReadingMutableContainers error:nil] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!connection || !managed || !windowSpaces) fail(@"Window metadata interfaces unavailable");
    cid=connection();
    NSData *input=[NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class]) fail(@"Expected a JSON request on stdin");
    NSArray *ws=windows();
    NSMutableDictionary *output=[@{@"ok":@YES,@"context":context(),@"accessibility":@(AXIsProcessTrusted()),@"bridgedMoveAvailable":@(bridgeOperation!=NULL && NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation")!=Nil)} mutableCopy];
    if ([request[@"command"] isEqual:@"snapshot"]) {
        NSMutableArray *ss=[NSMutableArray array],*ww=[NSMutableArray array];
        int index=0;
        for (NSDictionary *d in displays()) for (NSDictionary *s in d[@"Spaces"]) {
            NSNumber *sid=s[@"ManagedSpaceID"] ?: s[@"id64"];
            NSUInteger count=0;
            for (NSDictionary *w in ws) if (regular(w) && [spaces([w[(id)kCGWindowNumber] unsignedIntValue]) containsObject:sid]) count++;
            [ss addObject:@{@"index":@(++index),@"id":sid,@"type":s[@"type"] ?: @0,@"count":@(count),@"display":d[@"Display Identifier"] ?: @"",@"frame":screenFrame(d)}];
        }
        NSArray *apps=request[@"apps"] ?: @[];
        for (NSDictionary *w in ws) {
            NSString *app=bundle(w);
            if ((![apps containsObject:app] && ![request[@"ids"] containsObject:w[(id)kCGWindowNumber]]) || !regular(w)) continue;
            NSMutableDictionary *v=[@{@"id":w[(id)kCGWindowNumber],@"pid":w[(id)kCGWindowOwnerPID],@"app":app,@"spaces":spaces([w[(id)kCGWindowNumber] unsignedIntValue]),@"bounds":w[(id)kCGWindowBounds]} mutableCopy];
            if ([request[@"titles"] boolValue]) v[@"title"]=w[(id)kCGWindowName] ?: @"";
            [ww addObject:v];
        }
        output[@"spaces"]=ss;output[@"windows"]=ww;
    } else if ([request[@"command"] isEqual:@"open"]) {
        NSString *appID=request[@"app"];NSNumber *destination=request[@"toSpace"];
        if ([appID isEqual:@"com.tencent.xinWeChat"]) fail(@"WeChat is protected");
        if (!userSpace(destination) || !bridgeOperation || !NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation")) fail(@"Background workspace movement is unavailable for this destination");
        NSArray *activeSpaces = context()[@"activeSpaces"];
        if ([activeSpaces containsObject:destination]) fail(@"Background open requires an inactive target workspace");
        NSURL *application=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:appID];
        if (!application) fail(@"Requested application is not installed");
        NSRunningApplication *running=[NSRunningApplication runningApplicationsWithBundleIdentifier:appID].firstObject;
        if (running.active) fail(@"Requested application is in use; background open will not hide or take over it");
        BOOL wasHidden=running.hidden;
        NSMutableSet *old=[NSMutableSet set];for (NSDictionary *w in ws) if ([bundle(w) isEqual:appID]) [old addObject:w[(id)kCGWindowNumber]];
        NSMutableArray *urls=[NSMutableArray array];for (NSString *file in request[@"files"]) [urls addObject:[NSURL fileURLWithPath:file]];
        if (!urls.count) fail(@"No documents requested");
        if (running && !wasHidden) {
            if (appHasWindowOnSpaces(ws, appID, activeSpaces, YES)) {
                fail(@"Requested application has a visible window on an active workspace");
            }
            if (!appHidden(running, YES)) fail(@"Application could not be kept hidden during background document creation");
        }
        NSWorkspaceOpenConfiguration *config=NSWorkspaceOpenConfiguration.configuration;
        config.activates=NO;config.hides=YES;config.addsToRecentItems=NO;
        __block BOOL completed=NO;__block NSError *openError=nil;__block NSRunningApplication *openedApp=nil;
        [NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:application configuration:config completionHandler:^(NSRunningApplication *app,NSError *error){openedApp=app;openError=error;completed=YES;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:12];
        NSMutableArray *created=[NSMutableArray array];
        while (deadline.timeIntervalSinceNow>0) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            [created removeAllObjects];
            for (NSDictionary *w in windows()) if (regular(w) && [bundle(w) isEqual:appID] && ![old containsObject:w[(id)kCGWindowNumber]]) [created addObject:w[(id)kCGWindowNumber]];
            if (completed && (openError || created.count >= urls.count)) break;
        }
        if (!completed || openError || created.count < urls.count) {
            NSString *message = openError ? openError.localizedDescription : @"Expected new document windows did not appear. An already open file may need to be placed by window ID";
            if (running && !wasHidden && completed &&
                !appHasWindowOnSpaces(windows(), appID, context()[@"activeSpaces"], NO) &&
                appHidden(running, NO)) {
                fail(message);
            }
            fail([message stringByAppendingString:@". The target application may still be hidden"]);
        }
        if (!bridgeOperation) fail(@"Background workspace movement unavailable; application remains hidden");
        id cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        id allocated=((id(*)(id,SEL))objc_msgSend)(cls,sel_registerName("alloc"));
        id operation=((id(*)(id,SEL,id,uint64_t))objc_msgSend)(allocated,sel_registerName("initWithWindows:spaceID:"),created,[destination unsignedLongLongValue]);
        bridgeOperation(operation);
        for (NSNumber *wid in created) {
            NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2];
            while (![spaces(wid.unsignedIntValue) isEqual:@[destination]] && end.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            if (![spaces(wid.unsignedIntValue) isEqual:@[destination]]) fail(@"New window was not placed in its target workspace; application remains hidden");
        }
        if (!wasHidden && !appHidden((running ?: openedApp),NO)) fail(@"New windows were placed but application could not be unhidden");
        output[@"newWindows"]=created;output[@"afterContext"]=context();
    } else if ([request[@"command"] isEqual:@"apply"]) {
        NSArray *changes=request[@"windows"];
        NSMutableDictionary *found=[NSMutableDictionary dictionary];
        for (NSDictionary *w in ws) found[w[(id)kCGWindowNumber]]=w;
        for (NSDictionary *change in changes) {
            NSDictionary *w=found[change[@"id"]];
            if (!w || !regular(w) || ![bundle(w) isEqual:change[@"app"]] || ![w[(id)kCGWindowOwnerPID] isEqual:change[@"pid"]]) fail(@"Window identity changed; no action taken");
            if ([bundle(w) isEqual:@"com.tencent.xinWeChat"]) fail(@"WeChat is protected");
            if (change[@"toSpace"] && !userSpace(change[@"toSpace"])) fail(@"Destination is not an existing ordinary workspace");
            if (change[@"fromSpace"] && ![spaces([change[@"id"] unsignedIntValue]) isEqual:@[change[@"fromSpace"]]]) fail(@"Source workspace changed; no action taken");
            if (change[@"frame"] && (!AXIsProcessTrusted() || !axWindowID)) fail(@"Accessibility permission is unavailable for background resizing");
            if (change[@"toSpace"] && (!bridgeOperation || !NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation"))) fail(@"Bridged workspace movement unavailable");
        }
        NSMutableArray *results=[NSMutableArray array];
        for (NSDictionary *change in changes) {
            uint32_t wid=[change[@"id"] unsignedIntValue];
            NSNumber *dest=change[@"toSpace"];
            if (dest && ![spaces(wid) isEqual:@[dest]]) {
                id cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
                id allocated=((id(*)(id,SEL))objc_msgSend)(cls,sel_registerName("alloc"));
                id operation=((id(*)(id,SEL,id,uint64_t))objc_msgSend)(allocated,sel_registerName("initWithWindows:spaceID:"),@[change[@"id"]],[dest unsignedLongLongValue]);
                bridgeOperation(operation);
                NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
                while (![spaces(wid) isEqual:@[dest]] && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
                if (![spaces(wid) isEqual:@[dest]]) fail([NSString stringWithFormat:@"Workspace move did not complete for window %u",wid]);
            }
            NSDictionary *f=change[@"frame"];
            if (f) {
                AXUIElementRef target=findAX([change[@"pid"] intValue],wid);
                if (!target) fail(@"Target window is unavailable to Accessibility");
                CGPoint p=CGPointMake([f[@"x"] doubleValue],[f[@"y"] doubleValue]);
                CGSize z=CGSizeMake([f[@"width"] doubleValue],[f[@"height"] doubleValue]);
                AXValueRef pv=AXValueCreate(kAXValueCGPointType,&p),sv=AXValueCreate(kAXValueCGSizeType,&z);
                NSDictionary *original=bounds(wid),*size=@{@"Width":@(z.width),@"Height":@(z.height)};
                AXError a=AXUIElementSetAttributeValue(target,kAXSizeAttribute,sv);
                awaitGeometry(wid,size,original,.18);
                AXError b=AXUIElementSetAttributeValue(target,kAXPositionAttribute,pv);
                awaitGeometry(wid,@{@"X":@(p.x),@"Y":@(p.y)},nil,.4);
                AXError c=AXUIElementSetAttributeValue(target,kAXSizeAttribute,sv);
                NSDictionary *goal=@{@"X":@(p.x),@"Y":@(p.y),@"Width":@(z.width),@"Height":@(z.height)};
                BOOL finalOK=awaitGeometry(wid,goal,nil,.35);
                if (!finalOK && !a && !b && !c) {
                    // After opening, the app can constrain the first size to
                    // the old origin. Reposition the settled frame, then size.
                    b=AXUIElementSetAttributeValue(target,kAXPositionAttribute,pv);
                    awaitGeometry(wid,@{@"X":@(p.x),@"Y":@(p.y)},nil,.5);
                    c=AXUIElementSetAttributeValue(target,kAXSizeAttribute,sv);
                    finalOK=awaitGeometry(wid,goal,nil,1);
                }
                CFRelease(pv);CFRelease(sv);CFRelease(target);
                if (a || b || c) fail([NSString stringWithFormat:@"Window resize rejected: %d/%d/%d",a,b,c]);
                if (!finalOK) fail([NSString stringWithFormat:@"Window %u did not reach its requested geometry (application minimum size or delayed update); actual=%@",wid,bounds(wid)]);
            }
            [results addObject:@{@"id":@(wid),@"spaces":spaces(wid),@"bounds":bounds(wid)}];
        }
        output[@"results"]=results;output[@"afterContext"]=context();
    } else fail(@"Unknown command");
    NSData *data=[NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
}}
