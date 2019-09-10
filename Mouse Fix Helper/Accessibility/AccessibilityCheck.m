//
//  AccessibilityCheck.m
//  Mouse Fix Helper
//
//  Created by Noah Nübling on 02.09.19.
//  Copyright © 2019 Noah Nuebling. All rights reserved.
//

#import "AccessibilityCheck.h"

#import <AppKit/AppKit.h>
#import "../MessagePort/MessagePort_HelperApp.h"
#import "../DeviceManager/DeviceManager.h"
#import "../MessagePort/MessagePort_HelperApp.h"
#import "../Config/ConfigFileInterface_HelperApp.h"

@implementation AccessibilityCheck

+ (void)load {
    
    [MessagePort_HelperApp load_Manual];
    
    Boolean accessibilityEnabled = [self check];
    
    if (!accessibilityEnabled) {
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [MessagePort_HelperApp sendMessageToPrefPane:@"accessibilityDisabled"];
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if ([self check]) {
                
                [NSWorkspace.sharedWorkspace openFile:[[NSBundle bundleForClass:self.class].bundlePath stringByAppendingPathComponent:@"/../../../.."]];
                
                [NSApp terminate:NULL];
            }
        }];
            
    } else {
        [DeviceManager load_Manual];
        [ConfigFileInterface_HelperApp load_Manual];
    }
}
+ (Boolean)check {
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, NULL, NULL);
    CFDictionaryAddValue(options, kAXTrustedCheckOptionPrompt, kCFBooleanFalse);
    return AXIsProcessTrustedWithOptions(options);
}
@end