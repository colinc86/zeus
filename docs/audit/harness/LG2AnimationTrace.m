// Temporary LG2 diagnostic, enabled only for isolated attribution runs.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
static IMP originalRun;
static atomic_int count;
static void tracedRun(id object, SEL selector) {
    int index = atomic_fetch_add(&count, 1);
    fprintf(stderr, "LG2_NATIVE_ANIMATION %d %s\n", index, object_getClassName(object));
    ((void (*)(id, SEL))originalRun)(object, selector);
}
__attribute__((constructor)) static void installLG2Trace(void) {
    if (getenv("ZEUS_TEST_LG2_NO_WINDOW_ANIMATIONS")) {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"NSAutomaticWindowAnimationsEnabled": @NO}];
    }
    if (!getenv("ZEUS_TEST_LG2_TRACE")) return;
    Method method = class_getInstanceMethod(NSAnimation.class, sel_registerName("_runBlocking"));
    if (method) originalRun = method_setImplementation(method, (IMP)tracedRun);
}
