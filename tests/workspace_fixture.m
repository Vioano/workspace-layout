// Dedicated synthetic app. Every ordinary window and popup is created at alpha
// zero, verified in the prebound inactive Space, and only then revealed.
#define main imported_windowbridge_main
#include "../scripts/windowbridge.m"
#undef main

static NSString *auditPath;
static NSMutableDictionary *inputCounts;
static void auditEvent(NSString *kind, NSWindow *window) {
    NSMutableDictionary *event=[@{@"kind":kind,@"uptime":@(NSProcessInfo.processInfo.systemUptime),
                                  @"pid":@(getpid())} mutableCopy];
    if(window)event[@"window_id"]=@(window.windowNumber);
    if([kind hasSuffix:@"Down"]) {
        inputCounts[kind]=@([inputCounts[kind] unsignedIntegerValue]+1);
        event[@"count"]=inputCounts[kind];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:auditPath];
    [file seekToEndOfFile];[file writeData:data];[file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[file closeFile];
}
static void writeManifest(NSString *path, NSDictionary *value) {
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:path atomically:YES];
}
static BOOL targetInactive(uint64_t target) {
    return ![context()[@"activeSpaces"] containsObject:@(target)];
}
static NSDictionary *recordWindow(NSWindow *window) {
    return @{@"id":@(window.windowNumber),@"pid":@(getpid()),
             @"spaces":spaces((uint32_t)window.windowNumber)};
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=3)return 2;
    uint64_t target=strtoull(argv[1],NULL,10);
    NSString *path=[NSString stringWithUTF8String:argv[2]];
    auditPath=[path stringByAppendingString:@".events.jsonl"];
    [NSData.data writeToFile:auditPath atomically:YES];
    inputCounts=[NSMutableDictionary dictionary];
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    NSNotificationCenter *notifications=NSNotificationCenter.defaultCenter;
    for(NSNotificationName name in @[NSApplicationDidBecomeActiveNotification,NSApplicationDidResignActiveNotification,
                                     NSWindowDidBecomeKeyNotification,NSWindowDidResignKeyNotification]) {
        [notifications addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note){
            auditEvent(note.name,[note.object isKindOfClass:NSWindow.class] ? note.object : nil);
        }];
    }
    // Local monitors observe only events delivered to this synthetic app. Never
    // inspect characters, coordinates, or events destined for other apps.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskOtherMouseDown|NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) {
            auditEvent(event.type==NSEventTypeKeyDown ? @"keyDown" : @"mouseDown",event.window);
            return event;
        }];
    void *lib=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    connection=dlsym(lib,"SLSMainConnectionID");
    managed=dlsym(lib,"SLSCopyManagedDisplaySpaces");
    windowSpaces=dlsym(lib,"SLSCopySpacesForWindows");
    bridgeOperation=localSymbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    if(!connection||!managed||!windowSpaces||!bridgeOperation)return 3;
    cid=connection();
    if(!userSpace(@(target))||!targetInactive(target))return 3;
    NSDictionary *before=context();
    id cls=NSClassFromString(@"SLSBridgedProcessAssignToSpaceOperation");
    id allocated=((id(*)(id,SEL))objc_msgSend)(cls,sel_registerName("alloc"));
    id operation=((id(*)(id,SEL,int,uint64_t))objc_msgSend)(allocated,sel_registerName("initWithProcess:spaceID:"),getpid(),target);
    if(!operation)return 3;
    bridgeOperation(operation);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.08]];
    NSMutableArray *created=[NSMutableArray array],*records=[NSMutableArray array];
    for(int i=0;i<3;i++) {
        NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(50+30*i,100+20*i,600,500)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.title=[NSString stringWithFormat:@"Workspace benchmark %d",i+1];
        window.alphaValue=0;
        [window orderFront:nil];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.06]];
        NSDictionary *record=recordWindow(window);
        [records addObject:record];
        if(![record[@"spaces"] isEqual:@[@(target)]]||!targetInactive(target)) {
            writeManifest(path,@{@"ok":@NO,@"records":records});return 2;
        }
        [created addObject:window];
    }
    // A genuine separate floating panel tests future popup placement using the
    // same process binding. It does not activate or run an application modal loop.
    NSPanel *popup=[[NSPanel alloc]initWithContentRect:NSMakeRect(400,300,320,160)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:NO];
    popup.title=@"Owned popup placement test";
    popup.collectionBehavior=NSWindowCollectionBehaviorManaged;
    popup.hidesOnDeactivate=NO;
    popup.becomesKeyOnlyIfNeeded=YES;
    popup.level=NSModalPanelWindowLevel;
    popup.alphaValue=0;
    [popup orderFrontRegardless];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.06]];
    NSDictionary *popupRecord=recordWindow(popup);
    if(![popupRecord[@"spaces"] isEqual:@[@(target)]]||!targetInactive(target)) {
        writeManifest(path,@{@"ok":@NO,@"records":records,@"popups":@[popupRecord]});return 2;
    }
    [created addObject:popup];
    [NSApp setAccessibilityWindows:created];
    [NSApp setAccessibilityChildren:created];
    for(NSWindow *window in created)window.alphaValue=1;
    [NSApp unhideWithoutActivation];
    writeManifest(path,@{@"ok":@YES,@"records":records,@"popups":@[popupRecord],
        @"bundle_id":NSBundle.mainBundle.bundleIdentifier?:@"",@"target_space_id":@(target),
        @"context_before":before,@"context_after":context(),@"binding_verified_before_reveal":@YES});
    [NSApp run];return 0;
}}
