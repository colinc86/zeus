#import <AppKit/AppKit.h>

// Test-bundle startup, before any Swift Testing fixture creates a window.
// Register (never persist) this AppKit default: show/hide transform animations
// otherwise occupy one blocking dispatch worker each while the console is locked.
// To exercise real window motion, select a single test with
// TEST_RUNNER_ZEUS_TEST_WINDOW_ANIMATIONS=1. Ordinary layout/AX tests stay static.
__attribute__((constructor)) static void configureZeusTestHost(void) {
    if (!getenv("ZEUS_TEST_WINDOW_ANIMATIONS")) {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{@"NSAutomaticWindowAnimationsEnabled": @NO}];
    }
}
