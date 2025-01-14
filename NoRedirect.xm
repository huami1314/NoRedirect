@import Foundation;
@import UIKit;

#import <libSandy.h>
#import <HBLog.h>

@interface BSProcessHandle : NSObject
@property (getter=isValid, nonatomic, assign, readonly) BOOL valid;
@property (nonatomic, assign, readonly) int pid;
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@end

@interface SBApplicationProcessState : NSObject
@property (nonatomic, assign, readonly) int pid;
@property (getter=isRunning, nonatomic, assign, readonly) BOOL running;
@property (getter=isForeground, nonatomic, assign, readonly) BOOL foreground;
@end

@interface SBApplication : NSObject
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, strong, readonly) SBApplicationProcessState *processState;
@end

@interface SBApplicationSceneEntity : NSObject
@property (nonatomic, strong, readonly) SBApplication *application;
@property (nonatomic, copy, readonly) NSSet *actions;
@end

@interface SBWorkspaceApplicationSceneTransitionContext : NSObject
- (void)setBackground:(BOOL)arg1;
@end

@interface SBWorkspaceTransitionRequest : NSObject
@property (nonatomic, copy, readonly) NSString *eventLabel;
@property (nonatomic, copy, readonly) NSSet<SBApplicationSceneEntity *> *toApplicationSceneEntities;
@property (nonatomic, copy, readonly) NSSet<SBApplicationSceneEntity *> *fromApplicationSceneEntities;
@property (nonatomic, strong, readonly) BSProcessHandle *originatingProcess;
@property (nonatomic, strong, readonly) SBWorkspaceApplicationSceneTransitionContext *applicationContext;
- (void)declineWithReason:(id)arg1;
@end

@interface SBApplicationInfo : NSObject
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@end

@interface UIViewController (NoRedirect)
- (NSString *)_hostApplicationBundleIdentifier;
@end

@interface _SFBrowserContentViewController : UIViewController
- (void)_dismiss;
@end

static BOOL gEnabled = YES;
static BOOL gRecordingEnabled = NO;
static BOOL gIsSafariViewService = NO;

static NSSet<NSString *> *gForbiddenLaunchSources = nil;
static NSSet<NSString *> *gForbiddenLaunchDestinations = nil;

static NSSet<NSString *> *gForbiddenLaunchSourcesForAppStore = nil;
static NSSet<NSString *> *gForbiddenLaunchSourcesForSafariServices = nil;

static NSSet<NSString *> *gUseHandledSimulationSources = nil;

// %@->%@
static NSSet<NSString *> *gCustomAllowedMappings = nil;
static NSSet<NSString *> *gCustomForbiddenMappings = nil;

static void ReloadPrefs(void) {
    static NSUserDefaults *prefs = nil;
    if (!prefs) {
        if (gIsSafariViewService) {
            prefs = [[NSUserDefaults alloc] initWithSuiteName:@"/var/mobile/Library/Preferences/com.82flex.noredirectprefs.plist"];
        } else {
            prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.noredirectprefs"];
        }
    }

    NSDictionary *settings = [prefs dictionaryRepresentation];

    gEnabled = settings[@"IsEnabled"] ? [settings[@"IsEnabled"] boolValue] : YES;
    gRecordingEnabled = settings[@"IsRecordingEnabled"] ? [settings[@"IsRecordingEnabled"] boolValue] : NO;
    HBLogDebug(@"Enabled: %@, Recording Enabled: %@", gEnabled ? @"YES" : @"NO", gRecordingEnabled ? @"YES" : @"NO");

    NSMutableSet *forbiddenLaunchSources = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"IsBlockedFromLaunchingOthers/"] && [settings[key] boolValue]) {
            NSString *appId = [key substringFromIndex:29];
            [forbiddenLaunchSources addObject:appId];
        }
    }
    gForbiddenLaunchSources = [forbiddenLaunchSources copy];
    HBLogDebug(@"Forbidden Launch Sources: %@", forbiddenLaunchSources);

    NSMutableSet *forbiddenLaunchDestinations = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"IsBlockedFromBeingLaunched/"] && [settings[key] boolValue]) {
            NSString *appId = [key substringFromIndex:27];
            [forbiddenLaunchDestinations addObject:appId];
        }
    }
    gForbiddenLaunchDestinations = [forbiddenLaunchDestinations copy];
    HBLogDebug(@"Forbidden Launch Destinations: %@", forbiddenLaunchDestinations);

    NSMutableSet *forbiddenLaunchSourcesForAppStore = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"IsBlockedFromLaunchingAppStore/"] && [settings[key] boolValue]) {
            NSString *appId = [key substringFromIndex:31];
            [forbiddenLaunchSourcesForAppStore addObject:appId];
        }
    }
    gForbiddenLaunchSourcesForAppStore = [forbiddenLaunchSourcesForAppStore copy];
    HBLogDebug(@"Forbidden Launch Sources for App Store: %@", forbiddenLaunchSourcesForAppStore);

    NSMutableSet *forbiddenLaunchSourcesForSafariServices = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"IsBlockedFromLaunchingSafari/"] && [settings[key] boolValue]) {
            NSString *appId = [key substringFromIndex:29];
            [forbiddenLaunchSourcesForSafariServices addObject:appId];
        }
    }
    gForbiddenLaunchSourcesForSafariServices = [forbiddenLaunchSourcesForSafariServices copy];
    HBLogDebug(@"Forbidden Launch Sources for Safari Services: %@", forbiddenLaunchSourcesForSafariServices);

    NSMutableSet *customAllowedMappings = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"CustomBypassedApplications/"]) {
            NSString *srcId = [key substringFromIndex:27];
            NSArray *destIds = settings[key];
            if ([destIds isKindOfClass:[NSArray class]]) {
                for (NSString *destId in destIds) {
                    [customAllowedMappings addObject:[NSString stringWithFormat:@"%@->%@", destId, srcId]];
                }
            }
        }
    }
    gCustomAllowedMappings = [customAllowedMappings copy];
    HBLogDebug(@"Custom Allowed Mappings: %@", customAllowedMappings);

    NSMutableSet *customForbiddenMappings = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"CustomBlockedApplications/"]) {
            NSString *srcId = [key substringFromIndex:26];
            NSArray *destIds = settings[key];
            if ([destIds isKindOfClass:[NSArray class]]) {
                for (NSString *destId in destIds) {
                    [customForbiddenMappings addObject:[NSString stringWithFormat:@"%@->%@", srcId, destId]];
                }
            }
        }
    }
    gCustomForbiddenMappings = [customForbiddenMappings copy];
    HBLogDebug(@"Custom Forbidden Mappings: %@", customForbiddenMappings);

    NSMutableSet *useHandledSimulationSources = [NSMutableSet set];
    for (NSString *key in settings) {
        if ([key hasPrefix:@"ShouldSimulateSuccess/"] && [settings[key] boolValue]) {
            NSString *appId = [key substringFromIndex:22];
            [useHandledSimulationSources addObject:appId];
        }
    }
    gUseHandledSimulationSources = [useHandledSimulationSources copy];
    HBLogDebug(@"Use Handled Simulation Sources: %@", useHandledSimulationSources);
}

static BOOL ShouldDeclineRequest(NSString *srcId, NSString *destId) {
    HBLogDebug(@"Checking if %@ should be allowed to launch %@", srcId, destId);

    if (!srcId || !destId) {
        HBLogError(@"-> Invalid source or destination");
        return NO;
    }

    if (!gEnabled) {
        HBLogDebug(@"-> NoRedirect is disabled");
        return NO;
    }

    NSString *mapping = [NSString stringWithFormat:@"%@->%@", srcId, destId];
    if ([gCustomAllowedMappings containsObject:mapping]) {
        HBLogDebug(@"-> Custom mapping %@ is allowed", mapping);
        return NO;
    }

    if ([gForbiddenLaunchSources containsObject:srcId]) {
        HBLogDebug(@"-> %@ is forbidden from launching others", srcId);
        return YES;
    }

    if ([gForbiddenLaunchDestinations containsObject:destId]) {
        HBLogDebug(@"-> %@ is forbidden from being launched", destId);
        return YES;
    }

    if (([destId isEqualToString:@"com.apple.AppStore"] || [destId isEqualToString:@"com.apple.ios.StoreKitUIService"]) && [gForbiddenLaunchSourcesForAppStore containsObject:srcId]) {
        HBLogDebug(@"-> %@ is forbidden from launching App Store", srcId);
        return YES;
    }

    if (([destId isEqualToString:@"com.apple.mobilesafari"] || [destId isEqualToString:@"com.apple.SafariViewService"]) && [gForbiddenLaunchSourcesForSafariServices containsObject:srcId]) {
        HBLogDebug(@"-> %@ is forbidden from launching Safari Services", srcId);
        return YES;
    }

    if ([gCustomForbiddenMappings containsObject:mapping]) {
        HBLogDebug(@"-> Custom mapping %@ is forbidden", mapping);
        return YES;
    }

    HBLogDebug(@"-> Allowed");
    return NO;
}

static void RecordRequest(NSString *srcId, NSString *destId, BOOL declined) {
    if (!gRecordingEnabled) {
        return;
    }
}

%group NoRedirectPrimary

%hook SBMainWorkspace

- (BOOL)_canExecuteTransitionRequest:(id)arg1 forExecution:(BOOL)arg2 {
    HBLogDebug(@"Checking if transition request can be executed: %@", arg1);

    if (![arg1 isKindOfClass:%c(SBMainWorkspaceTransitionRequest)]) {
        return %orig;
    }

    SBWorkspaceTransitionRequest *request = (SBWorkspaceTransitionRequest *)arg1;
    NSString *eventLabel = request.eventLabel;
    if (eventLabel) {
        HBLogDebug(@"Event Label: %@", eventLabel);

        BOOL isEligibleForDecline = [eventLabel containsString:@"OpenApplication"] && [eventLabel containsString:@"ForRequester"];
        if (!isEligibleForDecline) {
            return %orig;
        }
    }

    SBApplicationSceneEntity *fromEntity = request.fromApplicationSceneEntities.anyObject;
    id fromAction = fromEntity.actions.anyObject;
    if (fromAction) {
        HBLogDebug(@"From Action: %@", fromAction);

        BOOL isEligibleForDecline = [fromAction isKindOfClass:%c(UIOpenURLAction)];
        if (!isEligibleForDecline) {
            return %orig;
        }
    }

    SBApplicationSceneEntity *toEntity = request.toApplicationSceneEntities.anyObject;
    NSString *fromAppId = fromEntity.application.bundleIdentifier ?: request.originatingProcess.bundleIdentifier;
    NSString *toAppId = toEntity.application.bundleIdentifier;
    if (ShouldDeclineRequest(fromAppId, toAppId)) {
        RecordRequest(fromAppId, toAppId, YES);

        if ([gUseHandledSimulationSources containsObject:fromAppId]) {
            BOOL isStoreKitUI = [toAppId isEqualToString:@"com.apple.ios.StoreKitUIService"];
            if (isStoreKitUI) {
                [request declineWithReason:@"No Redirect (Handled)"];
                return NO;
            }

            BOOL isSafariUI = [toAppId isEqualToString:@"com.apple.SafariViewService"];
            if (isSafariUI) {
                HBLogDebug(@"Redirecting to Safari View Services (Fallback)");
                return %orig;
            }

            [request.applicationContext setBackground:YES];
            return %orig;
        }

        [request declineWithReason:@"No Redirect"];
        return NO;
    }

    RecordRequest(fromAppId, toAppId, NO);
    return %orig;
}

%end

%end

%group NoRedirectSafari

%hook _SFBrowserContentViewController

- (void)viewWillAppear:(BOOL)arg1 {
    %orig;

    NSString *fromAppId = [self _hostApplicationBundleIdentifier];
    NSString *toAppId = @"com.apple.SafariViewService";
    if (ShouldDeclineRequest(fromAppId, toAppId)) {
        if ([gUseHandledSimulationSources containsObject:fromAppId]) {
            HBLogDebug(@"Dismissed Safari View Services (Handled)");
            [self _dismiss];
        }
    }
}

%end

%end

%ctor {
    NSString *processName = [[NSProcessInfo processInfo] processName];

#if !TARGET_OS_SIMULATOR
    if ([processName isEqualToString:@"SafariViewService"]) {
        int ret = libSandy_applyProfile("NoRedirectSafari");
        if (ret == kLibSandyErrorXPCFailure) {
            HBLogError(@"Failed to apply libSandy profile");
            return;
        }
        gIsSafariViewService = YES;
    }
#endif

    ReloadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), 
        NULL, 
        (CFNotificationCallback)ReloadPrefs, 
        CFSTR("com.82flex.noredirectprefs/saved"), 
        NULL, 
        CFNotificationSuspensionBehaviorCoalesce
    );

    if ([processName isEqualToString:@"SpringBoard"]) {
        %init(NoRedirectPrimary);
    } else if ([processName isEqualToString:@"SafariViewService"]) {
        %init(NoRedirectSafari);
    }
}