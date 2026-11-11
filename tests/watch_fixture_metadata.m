// Samples only fixture geometry and global foreground/Space metadata. No pixels.
#define main imported_windowbridge_main
#include "../scripts/windowbridge.m"
#undef main
int main(int argc,const char **argv){@autoreleasepool{
 if(argc!=3)return 2;
 NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] options:0 error:nil];
 NSString *stop=[NSString stringWithUTF8String:argv[2]];NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *record in [manifest[@"records"] arrayByAddingObjectsFromArray:manifest[@"popups"]?:@[]])[ids addObject:record[@"id"]];
 void *lib=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
 connection=dlsym(lib,"SLSMainConnectionID");managed=dlsym(lib,"SLSCopyManagedDisplaySpaces");windowSpaces=dlsym(lib,"SLSCopySpacesForWindows");cid=connection();
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:180];
 while(deadline.timeIntervalSinceNow>0 && ![NSFileManager.defaultManager fileExistsAtPath:stop]){@autoreleasepool{
  NSMutableArray *records=[NSMutableArray array];
  for(NSDictionary *w in windows())if([ids containsObject:w[(id)kCGWindowNumber]])[records addObject:@{@"id":w[(id)kCGWindowNumber],@"spaces":spaces([w[(id)kCGWindowNumber] unsignedIntValue]),@"bounds":w[(id)kCGWindowBounds],@"alpha":w[(id)kCGWindowAlpha]?:@0}];
  NSDictionary *sample=@{@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"context":context(),@"windows":records};
  puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
 }}return 0;
}}