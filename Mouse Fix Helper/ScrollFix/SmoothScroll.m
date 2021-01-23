//
// --------------------------------------------------------------------------
// SmoothScroll.m
// Created for: Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by: Noah Nuebling in 2019
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "SmoothScroll.h"
#import "ScrollUtility.h"

#import "AppDelegate.h"
#import "QuartzCore/CoreVideo.h"
//#import <HIServices/AXUIElement.h>
#import "ModifierInputReceiver.h"
#import "../Config/ConfigFileInterface_HelperApp.h"

#import "MouseInputReceiver.h"
#import "DeviceManager.h"
#import "Utility_HelperApp.h"
#import "TouchSimulator.h"

//#import "Mouse_Fix_Helper-Swift.h"


//@class AppOverrides;
//@interface AppOverrides : NSObject
//- (AppOverrides *)returnSwiftObject;
//- (NSString *)getBundleIdFromMouseLocation:(CGEventRef)event;
//@end


@interface SmoothScroll ()

@end

@implementation SmoothScroll



#pragma mark - Globals

# pragma mark properties


// whenever relevantDevicesAreAttached or isEnabled are changed, MomentumScrolls class method startOrStopDecide is called. Start or stop decide will start / stop momentum scroll and set _isRunning

static BOOL _isEnabled;
+ (BOOL)isEnabled {

    
    return _isEnabled;
}
+ (void)setIsEnabled:(BOOL)B {
    _isEnabled = B;
}

static BOOL _isRunning;
+ (BOOL)isRunning {
    return _isRunning;
}

# pragma mark enum

typedef enum {
    kMFPhaseStart       =   1,
    kMFPhaseWheel       =   2,
    kMFPhaseMomentum    =   4,
    kMFPhaseEnd         =   8,
} MFScrollPhase;

#pragma mark config

// fast scroll
double          _fastScrollExponentialBase          =   0;
int             _scrollSwipeThreshold_Ticks        =   0;
int             _fastScrollThreshold_Swipes        =   0;
double          _consecutiveScrollTickMaxIntervall  =   0;
double          _consecutiveScrollSwipeMaxIntervall =   0;

// wheel phase
static int64_t  _pxStepSize;
static double   _msPerStep;
static int      _scrollDirection; // TODO: Make this type MFScrollDirection enumeration where kMFinverted = -1 and kMFnormal = 1 or sth like that.
static double   _accelerationForScrollQueue;
// momentum phase
static double   _frictionCoefficient;
static double   _frictionDepth;
static int      _nOfOnePixelScrollsMax;
// objects
static CVDisplayLinkRef _displayLink    =   nil;
static CFMachPortRef    _eventTap       =   nil;
static CGEventSourceRef _eventSource    =   nil;

#pragma mark dynamic

// fast scroll
static BOOL     _lastTickWasPartOfSwipe             =   NO;
static int      _consecutiveScrollTickCounter       =   0;
static NSTimer  *_consecutiveScrollTickTimer        =   NULL;
static int      _consecutiveScrollSwipeCounter      =   0;
static NSTimer  *_consecutiveScrollSwipeTimer       =   NULL;

// any phase
static int32_t  _pixelsToScroll;
static int      _scrollPhase;
static BOOL     _horizontalScrollModifierIsPressed;
static BOOL     _magnificationModifierIsPressed;
static NSString *_bundleIdentifierOfAppWhichCausesOverride;
static CGDirectDisplayID *_displaysUnderMousePointer;
static int _previousPhase;                              // which phase was active the last time that displayLinkCallback was called
// wheel phase
static int64_t  _pixelScrollQueue           =   0;
static double   _msLeftForScroll            =   0;
    // scroll direction change
static long long _previousScrollDeltaAxis1;
    // (app overrides)
static CGPoint _previousMouseLocation;
static AXUIElementRef _systemWideAXUIElement;

// momentum phase
static double   _pxPerMsVelocity        =   0;
static int      _onePixelScrollsCounter =   0;

static long long  _lastScrollTime  =  -1;

#pragma mark - Interface

static void resetDynamicGlobals() {
    _horizontalScrollModifierIsPressed    =   NO;
    _scrollPhase                        =   kMFPhaseWheel;
    _pixelScrollQueue                   =   0;
    _msLeftForScroll                    =   0;
    _pxPerMsVelocity                    =   0;
    _onePixelScrollsCounter             =   0;
}


+ (void)configureWithPxPerStep:(int)px
                     msPerStep:(int)ms
                      friction:(float)f
               scrollDirection:(MFScrollDirection)d
{
    _pxStepSize                         =   px;
    _msPerStep                          =   ms;
    _frictionCoefficient                =   f;
            _frictionDepth = 1; // TODO: Implement this in the config file.
    _scrollDirection                    =   d;
    
    _accelerationForScrollQueue               = 1.1;
    
    _nOfOnePixelScrollsMax              =   2;
    
    _fastScrollExponentialBase          =   1.05; // 1.05 //1.125 //1.0625 // 1.09375
    _scrollSwipeThreshold_Ticks        =   4; // 3
    _fastScrollThreshold_Swipes        =   3;
    _consecutiveScrollTickMaxIntervall     =   0.13; // == _msPerStep/1000 // oldval:0.03
    _consecutiveScrollSwipeMaxIntervall    =   0.5;
    
}

//AppOverrides *_appOverrides;
+ (void)load_Manual {
    [SmoothScroll start];
    [SmoothScroll stop];
    
    _systemWideAXUIElement = AXUIElementCreateSystemWide();
//    _appOverrides = [AppOverrides new];
}

+ (void)startOrStopDecide {
    
    NSLog(@"Momentum start or stop");
    
    setConfigVariablesForActiveApp();
    
    if ([DeviceManager relevantDevicesAreAttached] && _isEnabled) {
        if (_isRunning == FALSE) {
            
            [SmoothScroll start];
            [ModifierInputReceiver start];
        }
    } else {
        if (_isRunning == TRUE) {
            [SmoothScroll stop];
//            [ModifierInputReceiver stop]; // TODO: TODO: Stop ModifierInputReceiver when appropriate (After sorting out activity states of SmoothScroll.m)
        }
    }
}
    

+ (void)start {
    
    NSLog(@"MomentumScroll started");
    
    _isRunning = TRUE;
    
    resetDynamicGlobals();
    
    
    if (_eventTap == nil) {
        CGEventMask mask = CGEventMaskBit(kCGEventScrollWheel);
        _eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, eventTapCallback, NULL);
        NSLog(@"_eventTap: %@", _eventTap);
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(runLoopSource);
        CGEventTapEnable(_eventTap, true);
    }
    
    // the eventTap sometimes breaks when replugging in the mouse too quickly. I don't know if this helps
//    @try {
//        CGEventTapEnable(_eventTap, true);
//    } @finally {
//    }
    if (_displayLink == nil) {
        CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
        CVDisplayLinkSetOutputCallback(_displayLink, displayLinkCallback, nil);
        _displaysUnderMousePointer = malloc(sizeof(CGDirectDisplayID) * 3);
    }
    if (_eventSource == nil) {
        _eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    }
    
    CGDisplayRemoveReconfigurationCallback(Handle_displayReconfiguration, NULL); // don't know if necesssary
    CGDisplayRegisterReconfigurationCallback(Handle_displayReconfiguration, NULL);
    
}

+ (void)stop {
    
    NSLog(@"MomentumScroll stopped");
    
    _isRunning = FALSE;
    
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = nil;
    } if (_eventTap) {
//        CGEventTapEnable(_eventTap, false);
//        CFRelease(_eventTap);
//        _eventTap = nil;
    } if (_eventSource) {
        CFRelease(_eventSource);
        _eventSource = nil;
    }
    
     CGDisplayRemoveReconfigurationCallback(Handle_displayReconfiguration, NULL);
}

+ (void)horizontalScrolling:(BOOL)B {
    _horizontalScrollModifierIsPressed = B;
}
+ (void)magnificationScrolling:(BOOL)B {
    
    if (_magnificationModifierIsPressed && !B) {
//        if (_scrollPhase != kMFPhaseEnd) {
            [TouchSimulator postEventWithMagnification:0.0 phase:kIOHIDEventPhaseEnded];
//            [TouchSimulator postEventWithMagnification:0.0 phase:kIOHIDEventPhaseBegan];
//            [TouchSimulator postEventWithMagnification:0.0 phase:kIOHIDEventPhaseEnded];
//        }
    } else if (!_magnificationModifierIsPressed && B) {
//        if (_scrollPhase == kMFPhaseMomentum || _scrollPhase == kMFPhaseWheel) {
            [TouchSimulator postEventWithMagnification:0.0 phase:kIOHIDEventPhaseBegan];
//        }
    }
    _magnificationModifierIsPressed = B;
}

+ (void)temporarilyDisable:(BOOL)B {
    if (B) {
        if (_isRunning) {
            [SmoothScroll stop];
        }
    } else {
        [SmoothScroll startOrStopDecide];
    }
}



#pragma mark - Run Loop

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    
    
//    NSLog(@"scrollPhase: %lld", CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase));
//    NSLog(@"momentumPhase: %lld", CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase));
    
    
    
//        CFTimeInterval ts = CACurrentMediaTime();
//            NSLog(@"event tap bench: %f", CACurrentMediaTime() - ts);
    
    
    // return non-scroll-wheel events unaltered
    
    long long   isPixelBased            =   CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
    long long   scrollPhase             =   CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase);
    long long   scrollDeltaAxis1        =   CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    long long   scrollDeltaAxis2        =   CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
    
    if ( (isPixelBased != 0) || (scrollDeltaAxis1 == 0) || (scrollDeltaAxis2 != 0) || (scrollPhase != 0)) { // adding scrollphase here is untested
        
        // scroll event doesn't come from a simple scroll wheel or doesn't contain the data we need to use
        return event;
    }
    
    
    // check if Mouse Location changed
    
    Boolean mouseMoved = FALSE;
    CGPoint mouseLocation = CGEventGetLocation(event);
    if (![ScrollUtility point:mouseLocation isAboutTheSameAs:_previousMouseLocation threshold:10]) {
        mouseMoved = TRUE;
    }
    _previousMouseLocation = mouseLocation;
    
    // send event (for non-smooth scrolling)
    
    if (_isEnabled == FALSE) {
        if (mouseMoved == TRUE) {
            setConfigVariablesForActiveApp();
        }
        if (_scrollDirection == -1) {
            event = [ScrollUtility invertScrollEvent:event direction:_scrollDirection];
        }
        if (_magnificationModifierIsPressed) { //TODO: TODO: Consider acitvating displayLink to send magnification events instead (After sorting out activity states of SmoothScroll.m)
            [TouchSimulator postEventWithMagnification:CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1)/200.0 phase:kIOHIDEventPhaseChanged];
            return nil;
        } else {
            return event;
        }
    }

    // check if Scrolling Direction changed
    
    Boolean newScrollDirection = FALSE;
    long long currTimeInMilliseconds = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    
    if ( ![ScrollUtility sameSign_n:scrollDeltaAxis1 m:_previousScrollDeltaAxis1] ) {
        if ( _lastScrollTime > (currTimeInMilliseconds - 700) ) {
//            NSLog(@"Spurious change of direction avoided");
            return nil;
        }
        else {
            newScrollDirection = TRUE;
        }
    }
    _previousScrollDeltaAxis1 = scrollDeltaAxis1;
    _lastScrollTime = currTimeInMilliseconds;
    
    
    // update global vars

    
    if (_scrollPhase != kMFPhaseWheel) {
        _onePixelScrollsCounter  =   0;
        _pxPerMsVelocity        =   0;
        _pixelScrollQueue = 0;
    }
    if (_scrollPhase == kMFPhaseMomentum) {
        _scrollPhase = kMFPhaseWheel;
    } else if (_scrollPhase == kMFPhaseEnd) {
        _scrollPhase = kMFPhaseStart;
    }
    
    if (newScrollDirection) {
    
        _pixelScrollQueue = 0;
        _pixelsToScroll = 0;
        _pxPerMsVelocity = 0;
    };
    
    
    
    
//    _pxStepSize = 100;
    
    _msLeftForScroll = _msPerStep;
    if (scrollDeltaAxis1 > 0) {
        _pixelScrollQueue += _pxStepSize * _scrollDirection;
    }
    else if (scrollDeltaAxis1 < 0) {
        _pixelScrollQueue -= _pxStepSize * _scrollDirection;
    }
    
    
    if (_consecutiveScrollSwipeCounter > _fastScrollThreshold_Swipes) {
        _pixelScrollQueue = _pixelScrollQueue * pow(_fastScrollExponentialBase, (int32_t)_consecutiveScrollSwipeCounter - _fastScrollThreshold_Swipes);
    }
    
    
    
    // recognize consecutive scroll ticks as "scroll swipes"
        // activate fast scrolling after a number of consecutive "scroll swipes"
        // do other stuff based on "scroll swipes"
    
    if (newScrollDirection) {
        _consecutiveScrollTickCounter = 0;
        _consecutiveScrollSwipeCounter = 0;
        [_consecutiveScrollTickTimer invalidate];
        [_consecutiveScrollSwipeTimer invalidate];
        
    };
    
    if ([_consecutiveScrollTickTimer isValid]) {
        _consecutiveScrollTickCounter += 1;
        
        // stuff you wanna do on every tick, except the first one (for each series of consecutive scroll ticks)
        
                // accelerate
        _pixelScrollQueue = _pixelScrollQueue * _accelerationForScrollQueue;
        
    } else {
        
        // stuff you only wanna do on the first tick of each series of consecutive scroll ticks
        
        if (CVDisplayLinkIsRunning(_displayLink) == FALSE) {
            CVDisplayLinkStart(_displayLink);
        }
        
        if (mouseMoved) {
            //set app overrides
            setConfigVariablesForActiveApp();
            
            // set diplaylink to the display that is actally being scrolled - not sure if this is necessary, because having the displaylink at 30fps on a 30fps display looks just as horrible as having the display link on 60fps, if not worse
            @try {
                setDisplayLinkToDisplayUnderMousePointer(event);
            } @catch (NSException *e) {
                NSLog(@"Error while trying to set display link to display under mouse pointer: %@", [e reason]);
            }
        }
        
    }
    
    // reset the scrolltickTimer
    [_consecutiveScrollTickTimer invalidate];
    _consecutiveScrollTickTimer = [NSTimer scheduledTimerWithTimeInterval:_consecutiveScrollTickMaxIntervall target:[SmoothScroll class] selector:@selector(Handle_ConsecutiveScrollTickCallback:) userInfo:NULL repeats:NO];
    
    
    if (_consecutiveScrollTickCounter < _scrollSwipeThreshold_Ticks) {
        _lastTickWasPartOfSwipe = NO;
    } else {
        // stuff you wanna do on every tick after the scroll swipe started
        // (nothing here)
        
        if (_lastTickWasPartOfSwipe == NO) {
            // stuff you wanna do once per swipe, when it starts
            
            _lastTickWasPartOfSwipe = YES;

            _consecutiveScrollSwipeCounter  += 1;
            [_consecutiveScrollSwipeTimer invalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ // TODO: TODO: is executing on the main thread here necessary / useful?
                _consecutiveScrollSwipeTimer = [NSTimer scheduledTimerWithTimeInterval:_consecutiveScrollSwipeMaxIntervall target:[SmoothScroll class] selector:@selector(Handle_ConsecutiveScrollSwipeCallback:) userInfo:NULL repeats:NO];
            });
        }
    }
    
    
    
    return nil;
}

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext) {
    
    
//    NSLog(@"display Link CALLBACK");
    
//    CFTimeInterval ts = CACurrentMediaTime();
    
    
//    _pixelsToScroll  = 0;
    
    double   msBetweenFrames = CVDisplayLinkGetActualOutputVideoRefreshPeriod(_displayLink) * 1000;
//    if (msBetweenFrames != 16.674562) {
//        NSLog(@"frameTimeHike: %fms", msBetweenFrames);
//    }
    CVTime msBetweenFramesNominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(_displayLink);
    msBetweenFrames =
    ( ((double)msBetweenFramesNominal.timeValue) / ((double)msBetweenFramesNominal.timeScale) ) * 1000;
    
    
# pragma mark Wheel Phase
    if (_scrollPhase == kMFPhaseWheel || _scrollPhase == kMFPhaseStart) {
        
        
        _pixelsToScroll = round( (_pixelScrollQueue/_msLeftForScroll) * msBetweenFrames );
        
        _pixelScrollQueue   -=  _pixelsToScroll;
        _msLeftForScroll    -=  msBetweenFrames;
        
        if ( (_msLeftForScroll <= 0) || (_pixelScrollQueue == 0) ) {
            
            _msLeftForScroll    =   0;
            _pixelScrollQueue   =   0;
            
            _scrollPhase = kMFPhaseMomentum;
            _pxPerMsVelocity = (_pixelsToScroll / msBetweenFrames);
            
        }
        
    }
    
# pragma mark Momentum Phase
    else if (_scrollPhase == kMFPhaseMomentum) {
        
        
        
        // very smooth
//        _frictionDepth = 0.5;
//        _frictionCoefficient = 0.7;

    
        
        _pixelsToScroll = round(_pxPerMsVelocity * msBetweenFrames);
        
        double oldVel = _pxPerMsVelocity;
        double newVel = oldVel - [ScrollUtility signOf:oldVel] * pow(fabs(oldVel), _frictionDepth) * (_frictionCoefficient/100) * msBetweenFrames;
        
        
        _pxPerMsVelocity = newVel;
        if ( ((newVel < 0) && (oldVel > 0)) || ((newVel > 0) && (oldVel < 0)) ) {
            _pxPerMsVelocity = 0;
        }
        
        
        
        if (_pixelsToScroll == 0 || _pxPerMsVelocity == 0) {
            _scrollPhase = kMFPhaseEnd;
        }
        
    }
    
    if (abs(_pixelsToScroll) == 1) { // TODO: TODO: Why is this outside of the momentum phase if block
        _onePixelScrollsCounter += 1;
        if (_onePixelScrollsCounter > _nOfOnePixelScrollsMax) {
            _scrollPhase = kMFPhaseEnd;
            _onePixelScrollsCounter = 0;
        }
    }
    
    
    
# pragma mark Send Event
    
    if (_magnificationModifierIsPressed) {
        [TouchSimulator postEventWithMagnification:_pixelsToScroll/800.0 phase:kIOHIDEventPhaseChanged];
    } else {
        
        CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(_eventSource, kCGScrollEventUnitPixel, 1, 0);
        // CGEventSourceSetPixelsPerLine(_eventSource, 1);
        // it might be a cool idea to diable scroll acceleration and then try to make the scroll events line based (kCGScrollEventUnitPixel)
        
//        if (_scrollPhase >= kMFPhaseMomentum) {
//            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, _scrollPhase >> 1); // shifting bits so that values match up with appropriate NSEventPhase values.
//        } else {
//            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, _scrollPhase);
//        }
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, 0);
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventMomentumPhase, 0);
        
        
        // set pixels
        
        if (_horizontalScrollModifierIsPressed == FALSE) {
    //        if (_scrollPhase == kMFWheelPhase) {
    //            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventDeltaAxis1, [Utility_HelperApp signOf:_pixelsToScroll]);
    //        }
        
            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventDeltaAxis1, _pixelsToScroll / 8);
            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventPointDeltaAxis1, _pixelsToScroll);
        } else if (_horizontalScrollModifierIsPressed == TRUE) {
    //        if (_scrollPhase == kMFWheelPhase) {
    //            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventDeltaAxis2, [Utility_HelperApp signOf:_pixelsToScroll]);
    //        }
            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventDeltaAxis2, _pixelsToScroll / 8);
            CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventPointDeltaAxis2, _pixelsToScroll);
        }

        
        CGEventPost(kCGSessionEventTap, scrollEvent);
        CFRelease(scrollEvent);
        
    //<<<<<<< Updated upstream
    //=======
    //<<<<<<< HEAD
    ////     set phases
    ////         the native "scrollPhase" is roughly equivalent to my "wheelPhase"
    //
    //    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventMomentumPhase, kCGMomentumScrollPhaseNone);
    //
    //
    //
    //    NSLog(@"intern scrollphase: %d", _scrollPhase);
    //    if (_scrollPhase == kMFWheelPhase) {
    //        if (_previousPhase == kMFWheelPhase) {
    //                CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, 2);
    //        } else {
    //                CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, 1);
    //        }
    //    }
    //    if (_scrollPhase == kMFMomentumPhase) {
    //        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, 2);
    //    }
    //
    ////    NSLog(@"scrollPhase: %lld", CGEventGetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase));
    ////    NSLog(@"momentumPhase: %lld \n", CGEventGetIntegerValueField(scrollEvent, kCGScrollWheelEventMomentumPhase));
    //
    //=======
    //>>>>>>> 519321477a37764c0b95076d91d80f5238284af3
    //>>>>>>> Stashed changes
        
    }
    
    
#pragma mark Other
    
    if (_scrollPhase == kMFPhaseEnd) {
        CVDisplayLinkStop(displayLink);
        return 0;
    }
    
    if (_scrollPhase == kMFPhaseStart) {
        _scrollPhase = kMFPhaseWheel;
    }
//    _previousPhase = _scrollPhase;
    
    
    
//    NSLog(@"dispLink bench: %f", CACurrentMediaTime() - ts);
    
    return 0;
}


#pragma mark - helper functions

#pragma mark app exceptions

// CLEAN: maybe put this into ConfigFileInterface_HelperApp
static void setConfigVariablesForActiveApp() {
    
 
    // get App under mouse pointer
    
    
    
//CFTimeInterval ts = CACurrentMediaTime();
    
    
    // 1. Even slower
    
//    CGEventRef fakeEvent = CGEventCreate(NULL);
//    CGPoint mouseLocation = CGEventGetLocation(fakeEvent);
//    CFRelease(fakeEvent);
    
//    NSInteger winNUnderMouse = [NSWindow windowNumberAtPoint:(NSPoint)mouseLocation belowWindowWithWindowNumber:0];
//    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListExcludeDesktopElements | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
////    NSLog(@"windowList: %@", windowList);
//    int windowPID = 0;
//    for (int i = 0; i < CFArrayGetCount(windowList); i++) {
//        CFDictionaryRef w = CFArrayGetValueAtIndex(windowList, i);
//        int winN;
//        CFNumberGetValue(CFDictionaryGetValue(w, CFSTR("kCGWindowNumber")), kCFNumberIntType, &winN);
//        if (winN == winNUnderMouse) {
//            CFNumberGetValue(CFDictionaryGetValue(w, CFSTR("kCGWindowOwnerPID")), kCFNumberIntType, &windowPID);
//        }
//    }
//    NSRunningApplication *appUnderMousePointer = [NSRunningApplication runningApplicationWithProcessIdentifier:windowPID];
//    NSString *bundleIdentifierOfScrolledApp_New = appUnderMousePointer.bundleIdentifier;
  
    
    // 2. very slow - but basically the way MOS does it, and MOS is fast somehow
    
//    CGEventRef fakeEvent = CGEventCreate(NULL);
//    CGPoint mouseLocation = CGEventGetLocation(fakeEvent);
//    CFRelease(fakeEvent);

//    if (_previousMouseLocation.x == mouseLocation.x && _previousMouseLocation.y == mouseLocation.y) {
//        return;
//    }
//    _previousMouseLocation = mouseLocation;
//
//    AXUIElementRef elementUnderMousePointer;
//    AXUIElementCopyElementAtPosition(_systemWideAXUIElement, mouseLocation.x, mouseLocation.y, &elementUnderMousePointer);
//    pid_t elementUnderMousePointerPID;
//    AXUIElementGetPid(elementUnderMousePointer, &elementUnderMousePointerPID);
//    NSRunningApplication *appUnderMousePointer = [NSRunningApplication runningApplicationWithProcessIdentifier:elementUnderMousePointerPID];
//
//    @try {
//        CFRelease(elementUnderMousePointer);
//    } @finally {}
//    NSString *bundleIdentifierOfScrolledApp_New = appUnderMousePointer.bundleIdentifier;
    
    
    
//     3. fast, but only get info about frontmost application
    
    NSString *bundleIdentifierOfScrolledApp_New = [NSWorkspace.sharedWorkspace frontmostApplication].bundleIdentifier;
    
    
    
    // 4. swift copied from MOS - should be fast and gathers info on app under mouse pointer - I couldn't manage to import the Swift code though :/
    
//    CGEventRef fakeEvent = CGEventCreate(NULL);
//    NSString *bundleIdentifierOfScrolledApp_New = [_appOverrides getBundleIdFromMouseLocation:fakeEvent];
//    CFRelease(fakeEvent);
    
    

    
    
    // if app under mouse pointer changed, adjust settings
    
    if ([_bundleIdentifierOfAppWhichCausesOverride isEqualToString:bundleIdentifierOfScrolledApp_New] == FALSE) {
        
        
        NSDictionary *config = [ConfigFileInterface_HelperApp config];
        NSDictionary *overrides = [config objectForKey:@"AppOverrides"];
        
        // get default settings
        NSDictionary *defaultScrollSettings = [config objectForKey:@"ScrollSettings"];
        BOOL enabledDefault;
        NSArray *valuesDefault;
        enabledDefault = [[defaultScrollSettings objectForKey:@"enabled"] boolValue];
        valuesDefault = [defaultScrollSettings objectForKey:@"values"];
        
        // get app specific settings
        NSDictionary *appOverrideScrollSettings;
        for (NSString *b in overrides.allKeys) {
            if ([bundleIdentifierOfScrolledApp_New containsString:b]) {
                appOverrideScrollSettings = [[overrides objectForKey: b] objectForKey:@"ScrollSettings"];
            }
        }
        _bundleIdentifierOfAppWhichCausesOverride = bundleIdentifierOfScrolledApp_New;
        
        BOOL enabledApp;
        NSArray *valuesApp;
        enabledApp = [[appOverrideScrollSettings objectForKey:@"enabled"] boolValue];
        valuesApp = [appOverrideScrollSettings objectForKey:@"values"];
        
        if (!appOverrideScrollSettings) {
            _isEnabled                          =   enabledDefault;
            _pxStepSize                         =   [[valuesDefault objectAtIndex:0] intValue];
            _msPerStep                          =   [[valuesDefault objectAtIndex:1] intValue];
            _frictionCoefficient                =   [[valuesDefault objectAtIndex:2] floatValue];
            _scrollDirection                    =   [[valuesDefault objectAtIndex:3] intValue];
        } else {
            _isEnabled                          =   enabledApp;
            _pxStepSize                         =   [[valuesApp objectAtIndex:0] intValue];
            _msPerStep                          =   [[valuesApp objectAtIndex:1] intValue];
            _frictionCoefficient                =   [[valuesApp objectAtIndex:2] floatValue];
            if ([[valuesApp objectAtIndex:3] intValue] == 0) {
                _scrollDirection                =   [[valuesDefault objectAtIndex:3] intValue];
            } else {
                _scrollDirection                =   [[valuesApp objectAtIndex:3] intValue];
            }
        }
        
        [SmoothScroll startOrStopDecide];
    }

    
//    NSLog(@"override bench: %f", CACurrentMediaTime() - ts);
}

#pragma mark fast scroll

+ (void)Handle_ConsecutiveScrollSwipeCallback:(NSTimer *)timer {
    _consecutiveScrollSwipeCounter = 0;
    [timer invalidate];
}
+ (void)Handle_ConsecutiveScrollTickCallback:(NSTimer *)timer {
    _consecutiveScrollTickCounter = 0;
    [timer invalidate];
}

#pragma mark display link

static void Handle_displayReconfiguration(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    if ( (flags & kCGDisplayAddFlag) || (flags & kCGDisplayRemoveFlag) ) {
        NSLog(@"display added / removed");
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
        CVDisplayLinkSetOutputCallback(_displayLink, displayLinkCallback, nil);
    }
}
static void setDisplayLinkToDisplayUnderMousePointer(CGEventRef event) {
    
    CGPoint mouseLocation = CGEventGetLocation(event);
    CGDirectDisplayID *newDisplaysUnderMousePointer = malloc(sizeof(CGDirectDisplayID) * 3);
    uint32_t matchingDisplayCount;
    CGGetDisplaysWithPoint(mouseLocation, 2, newDisplaysUnderMousePointer, &matchingDisplayCount);
    
    if (matchingDisplayCount >= 1) {
        if (newDisplaysUnderMousePointer[0] != _displaysUnderMousePointer[0]) {
            _displaysUnderMousePointer = newDisplaysUnderMousePointer;
            //sets dsp to the master display if _displaysUnderMousePointer[0] is part of the mirror set
            CGDirectDisplayID dsp = CGDisplayPrimaryDisplay(_displaysUnderMousePointer[0]);
            CVDisplayLinkSetCurrentCGDisplay(_displayLink, dsp);
        }
    } else if (matchingDisplayCount > 1) {
        NSLog(@"more than one display for current mouse position");
        
    } else if (matchingDisplayCount == 0) {
        NSException *e = [NSException exceptionWithName:NSInternalInconsistencyException reason:@"there are 0 diplays under the mouse pointer" userInfo:NULL];
        @throw e;
    }
    
    free(newDisplaysUnderMousePointer);
    
}


@end




// (in Handle_eventTapCallback) change settings, when app under mouse pointer changes
/*
static void setConfigVariablesForAppUnderMousePointer() {
 
    // get App under mouse pointer
    
    CGEventRef fakeEvent = CGEventCreate(NULL);
    CGPoint mouseLocation = CGEventGetLocation(fakeEvent);
    CFRelease(fakeEvent);
    
    AXUIElementRef elementUnderMousePointer;
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), mouseLocation.x, mouseLocation.y, &elementUnderMousePointer);
    pid_t elementUnderMousePointerPID;
    AXUIElementGetPid(elementUnderMousePointer, &elementUnderMousePointerPID);
    NSRunningApplication *appUnderMousePointer = [NSRunningApplication runningApplicationWithProcessIdentifier:elementUnderMousePointerPID];
    
    // if app under mouse pointer changed, adjust settings
    
    if ([_bundleIdentifierOfScrolledApp isEqualToString:[appUnderMousePointer bundleIdentifier]] == FALSE) {
        
        NSLog(@"changing Scroll Settings");
        
        AppDelegate *delegate = [NSApp delegate];
        NSDictionary *config = [delegate configDictFromFile];
        NSDictionary *overrides = [config objectForKey:@"AppOverrides"];
        NSDictionary *scrollOverrideForAppUnderMousePointer = [[overrides objectForKey:
                                                                [appUnderMousePointer bundleIdentifier]]
                                                               objectForKey:@"ScrollSettings"];
        BOOL enabled;
        NSArray *values;
        if (scrollOverrideForAppUnderMousePointer) {
            enabled = [[scrollOverrideForAppUnderMousePointer objectForKey:@"enabled"] boolValue];
            values = [scrollOverrideForAppUnderMousePointer objectForKey:@"values"];
        }
        else {
            NSDictionary *defaultScrollSettings = [config objectForKey:@"ScrollSettings"];
            enabled = [[defaultScrollSettings objectForKey:@"enabled"] boolValue];
            values = [defaultScrollSettings objectForKey:@"values"];
        }
        _isEnabled                          =   enabled;
        _pxStepSize                         =   [[values objectAtIndex:0] intValue];
        _msPerScroll                        =   [[values objectAtIndex:1] intValue];
        _frictionCoefficient                =   [[values objectAtIndex:2] floatValue];
    }
    
    _bundleIdentifierOfScrolledApp = [appUnderMousePointer bundleIdentifier];
}
 */


// (in Handle_displayLinkCallback) stop displayLink when app under mouse pointer changes mid scroll
/*
 CGEventRef fakeEvent = CGEventCreate(NULL);
 CGPoint mouseLocation = CGEventGetLocation(fakeEvent);
 CFRelease(fakeEvent);
 AXUIElementRef elementUnderMousePointer;
 AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), mouseLocation.x, mouseLocation.y, &elementUnderMousePointer);
 pid_t elementUnderMousePointerPID;
 AXUIElementGetPid(elementUnderMousePointer, &elementUnderMousePointerPID);
 NSRunningApplication *appUnderMousePointer = [NSRunningApplication runningApplicationWithProcessIdentifier:elementUnderMousePointerPID];
 
 if ( !([_bundleIdentifierOfScrolledApp isEqualToString:[appUnderMousePointer bundleIdentifier]]) ) {
 resetDynamicGlobals();
 CVDisplayLinkStop(_displayLink);
 return 0;
 }
 */
