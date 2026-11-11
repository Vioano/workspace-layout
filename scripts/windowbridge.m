#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <sys/resource.h>

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
    @throw [NSException exceptionWithName:@"WindowBridgeError" reason:message userInfo:nil];
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
    // A stream can wait on stdin while AppKit activation notifications queue.
    // Ask Process Manager for the current PID rather than treating the
    // NSWorkspace notification cache as a synchronous foreground observation.
    ProcessSerialNumber psn={0,0};pid_t frontPID=0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus first=GetFrontProcess(&psn);
    OSStatus second=first==noErr ? GetProcessPID(&psn,&frontPID) : first;
#pragma clang diagnostic pop
    NSRunningApplication *front=second==noErr ? [NSRunningApplication runningApplicationWithProcessIdentifier:frontPID] : nil;
    return @{@"activeSpaces":active,@"frontPID":@(second==noErr ? frontPID : 0),@"frontApp":front.bundleIdentifier ?: @"",@"front_source":@"process_manager",@"front_status":@(second)};
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
static NSDictionary *describeAX(AXUIElementRef element, int depth) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"AXRole", @"AXSubrole", @"AXTitle", @"AXValue", @"AXEnabled"]) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(element, (__bridge CFStringRef)name, &value) == kAXErrorSuccess && value) {
            if (CFGetTypeID(value) == CFStringGetTypeID() || CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID()) result[name] = (__bridge id)value;
            CFRelease(value);
        }
    }
    if (depth > 0) {
        CFTypeRef children = NULL;
        if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
            NSMutableArray *items = [NSMutableArray array];
            for (id child in (__bridge NSArray *)children) {
                if (items.count >= 30) break;
                [items addObject:describeAX((__bridge AXUIElementRef)child, depth - 1)];
            }
            result[@"children"] = items;
            CFRelease(children);
        }
    }
    return result;
}
static AXUIElementRef findDialogButton(AXUIElementRef element, NSString *title, int depth) {
    CFTypeRef role = NULL, name = NULL;
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role);
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute, &name);
    BOOL matches = role && name && CFEqual(role, kAXButtonRole) && [(__bridge id)name isEqual:title];
    if (role) CFRelease(role);
    if (name) CFRelease(name);
    if (matches) return (AXUIElementRef)CFRetain(element);
    if (depth <= 0) return NULL;
    CFTypeRef children = NULL;
    AXUIElementRef found = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        for (id child in (__bridge NSArray *)children) {
            found = findDialogButton((__bridge AXUIElementRef)child, title, depth - 1);
            if (found) break;
        }
        CFRelease(children);
    }
    return found;
}
static void initializeBridge(void) {
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
}
static NSDictionary *handleRequest(NSData *input) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class]) fail(@"Expected a JSON request on stdin");
    NSArray *ws=windows();
    NSMutableDictionary *output=[@{@"ok":@YES,@"context":context(),@"accessibility":@(AXIsProcessTrusted()),@"bridgedMoveAvailable":@(bridgeOperation!=NULL && NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation")!=Nil)} mutableCopy];
    if ([request[@"command"] isEqual:@"snapshot"]) {
        NSMutableArray *ss=[NSMutableArray array],*ww=[NSMutableArray array];
        NSMutableDictionary *membership=[NSMutableDictionary dictionary],*counts=[NSMutableDictionary dictionary],*appIDs=[NSMutableDictionary dictionary],*appNames=[NSMutableDictionary dictionary];
        for (NSDictionary *w in ws) {
            NSNumber *wid=w[(id)kCGWindowNumber];
            NSArray *owned=spaces(wid.unsignedIntValue);
            membership[wid]=owned;
            if (regular(w)) for (NSNumber *sid in owned) counts[sid]=@([counts[sid] unsignedIntegerValue]+1);
        }
        int index=0;
        for (NSDictionary *d in displays()) for (NSDictionary *s in d[@"Spaces"]) {
            NSNumber *sid=s[@"ManagedSpaceID"] ?: s[@"id64"];
            NSUInteger count=[counts[sid] unsignedIntegerValue];
            [ss addObject:@{@"index":@(++index),@"id":sid,@"type":s[@"type"] ?: @0,@"count":@(count),@"display":d[@"Display Identifier"] ?: @"",@"frame":screenFrame(d)}];
        }
        NSArray *apps=request[@"apps"] ?: @[];
        BOOL allMetadata = [request[@"all_windows_metadata"] boolValue];
        NSUInteger order = 0;
        for (NSDictionary *w in ws) {
            NSNumber *pid=w[(id)kCGWindowOwnerPID];
            NSString *app=appIDs[pid];
            if (!app) {
                NSRunningApplication *owner=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
                app=owner.bundleIdentifier ?: @"";appIDs[pid]=app;
                appNames[pid]=owner.localizedName ?: w[(id)kCGWindowOwnerName] ?: @"";
            }
            NSUInteger zOrder = order++;
            if (!allMetadata && (![apps containsObject:app] && ![request[@"ids"] containsObject:w[(id)kCGWindowNumber]])) continue;
            if (!allMetadata && !regular(w)) continue;
            NSDictionary *rect = w[(id)kCGWindowBounds];
            if ([rect[@"Width"] doubleValue] <= 0 || [rect[@"Height"] doubleValue] <= 0) continue;
            NSMutableDictionary *v=[@{@"id":w[(id)kCGWindowNumber],@"pid":w[(id)kCGWindowOwnerPID],@"app":app,@"spaces":membership[w[(id)kCGWindowNumber]] ?: @[],@"bounds":w[(id)kCGWindowBounds]} mutableCopy];
            v[@"app_name"]=appNames[pid] ?: @"";
            v[@"owner_name"]=w[(id)kCGWindowOwnerName] ?: @"";
            v[@"z_order"] = @(zOrder);
            v[@"layer"] = w[(id)kCGWindowLayer] ?: @0;
            v[@"on_screen"] = @([w[(id)kCGWindowIsOnscreen] boolValue]);
            v[@"alpha"] = w[(id)kCGWindowAlpha] ?: @0;
            v[@"window_type"] = regular(w) ? @"ordinary" : @"panel_or_system";
            v[@"window_type_source"] = @"window_server_geometry_and_layer";
            if ([request[@"titles"] boolValue]) v[@"title"]=w[(id)kCGWindowName] ?: @"";
            [ww addObject:v];
        }
        output[@"spaces"]=ss;output[@"windows"]=ww;
    } else if ([request[@"command"] isEqual:@"inspect_window"] || [request[@"command"] isEqual:@"press_dialog_button"]) {
        uint32_t wid = [request[@"id"] unsignedIntValue];
        pid_t pid = [request[@"pid"] intValue];
        NSDictionary *match = nil;
        for (NSDictionary *w in ws) if ([w[(id)kCGWindowNumber] unsignedIntValue] == wid) match = w;
        if (!match || [match[(id)kCGWindowOwnerPID] intValue] != pid || ![bundle(match) isEqual:request[@"app"]] || [bundle(match) isEqual:@"com.tencent.xinWeChat"]) fail(@"Task window identity did not match");
        AXUIElementRef target = findAX(pid, wid);
        if (!target) fail(@"Task window is unavailable to Accessibility");
        if ([request[@"command"] isEqual:@"press_dialog_button"]) {
            CFTypeRef subrole = NULL;
            AXUIElementCopyAttributeValue(target, kAXSubroleAttribute, &subrole);
            BOOL dialog = subrole && CFEqual(subrole, kAXDialogSubrole);
            if (subrole) CFRelease(subrole);
            if (!dialog) fail(@"Target is not a task dialog");
            AXUIElementRef button = findDialogButton(target, request[@"title"], 5);
            if (!button) fail(@"Requested dialog button was not found");
            AXError status = AXUIElementPerformAction(button, kAXPressAction);
            CFRelease(button);
            if (status) fail(@"Task dialog action failed");
            output[@"action"] = @"pressed_named_dialog_button";
            output[@"afterContext"] = context();
        } else output[@"window"] = describeAX(target, 5);
        CFRelease(target);
    } else if ([request[@"command"] isEqual:@"bind_process"]) {
        pid_t pid = [request[@"pid"] intValue];
        NSString *appID = request[@"app"];
        NSNumber *destination = request[@"toSpace"];
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app || ![app.bundleIdentifier isEqualToString:appID] || [appID isEqualToString:@"com.tencent.xinWeChat"]) fail(@"Process identity is unavailable or protected");
        if ([output[@"context"][@"front_status"] intValue] != noErr) fail(@"Current foreground identity is unavailable; no process binding submitted");
        if ([output[@"context"][@"frontPID"] intValue] == pid || !userSpace(destination)) fail(@"Process binding requires an inactive process and an ordinary destination Space");
        for (NSDictionary *window in ws) {
            if ([window[(id)kCGWindowOwnerPID] intValue] != pid || !regular(window)) continue;
            NSArray *current = spaces([window[(id)kCGWindowNumber] unsignedIntValue]);
            if (current.count && ![current isEqual:@[destination]]) fail(@"Process has an existing window in another Space");
        }
        Class operationClass = NSClassFromString(@"SLSBridgedProcessAssignToSpaceOperation");
        SEL initializer = sel_registerName("initWithProcess:spaceID:");
        if (!bridgeOperation || ![operationClass instancesRespondToSelector:initializer]) fail(@"Process Space binding is unavailable");
        id allocated = ((id(*)(id,SEL))objc_msgSend)(operationClass, sel_registerName("alloc"));
        id operation = ((id(*)(id,SEL,int,uint64_t))objc_msgSend)(allocated, initializer, pid, destination.unsignedLongLongValue);
        bridgeOperation(operation);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        output[@"binding"] = @{@"pid":@(pid),@"space_id":destination,@"state":@"submitted",@"future_window_verified":@NO};
        output[@"afterContext"] = context();
    } else if ([request[@"command"] isEqual:@"open"]) {
        fail(@"Generic document opening is disabled: use a controlled application adapter with workspace binding before window creation");
    } else if ([request[@"command"] isEqual:@"apply"]) {
        if ([output[@"context"][@"front_status"] intValue] != noErr) fail(@"Current foreground identity is unavailable; no window changes sent");
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
            if (![context() isEqual:output[@"context"]]) fail(@"Foreground context changed during the batch; remaining window changes were not sent. Read current state before continuing");
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
                if (![context() isEqual:output[@"context"]]) { CFRelease(pv);CFRelease(sv);CFRelease(target);fail(@"Foreground context changed after resizing; remaining changes were not sent"); }
                AXError b=AXUIElementSetAttributeValue(target,kAXPositionAttribute,pv);
                awaitGeometry(wid,@{@"X":@(p.x),@"Y":@(p.y)},nil,.4);
                if (![context() isEqual:output[@"context"]]) { CFRelease(pv);CFRelease(sv);CFRelease(target);fail(@"Foreground context changed after positioning; remaining changes were not sent"); }
                AXError c=AXUIElementSetAttributeValue(target,kAXSizeAttribute,sv);
                NSDictionary *goal=@{@"X":@(p.x),@"Y":@(p.y),@"Width":@(z.width),@"Height":@(z.height)};
                BOOL finalOK=awaitGeometry(wid,goal,nil,.35);
                if (!finalOK && !a && !b && !c) {
                    if (![context() isEqual:output[@"context"]]) { CFRelease(pv);CFRelease(sv);CFRelease(target);fail(@"Foreground context changed before geometry correction; remaining changes were not sent"); }
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
    return output;
}
static void writeResult(NSDictionary *result, BOOL pretty) {
    struct rusage usage;getrusage(RUSAGE_SELF,&usage);
    NSMutableDictionary *measured=[result mutableCopy];
    double cpu=usage.ru_utime.tv_sec+usage.ru_stime.tv_sec+(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6;
    measured[@"helper_usage"]=@{@"pid":@(getpid()),@"cpu_seconds":@(cpu),@"max_rss_bytes":@(usage.ru_maxrss)};
    result=measured;
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:pretty ? NSJSONWritingPrettyPrinted : 0 error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}
int main(int argc,const char **argv) { @autoreleasepool {
    @try { initializeBridge(); }
    @catch (NSException *error) { writeResult(@{@"ok":@NO,@"error":error.reason ?: @"Native initialization failed"},NO);return 1; }
    if (argc == 2 && !strcmp(argv[1], "--stream")) {
        char *line=NULL;size_t capacity=0;ssize_t length;
        while ((length=getline(&line,&capacity,stdin))>0) { @autoreleasepool {
            @try { writeResult(handleRequest([NSData dataWithBytes:line length:length]),NO); }
            @catch (NSException *error) { writeResult(@{@"ok":@NO,@"error":error.reason ?: @"Native request failed"},NO); }
        }}
        free(line);return 0;
    }
    @try {
        writeResult(handleRequest([NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile]),YES);
        return 0;
    } @catch (NSException *error) {
        writeResult(@{@"ok":@NO,@"error":error.reason ?: @"Native request failed"},NO);
        return 1;
    }
}}
