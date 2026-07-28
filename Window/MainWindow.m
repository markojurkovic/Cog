//
//  MainWindow.m
//  Cog
//
//  Created by Vincent Spader on 2/22/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "MainWindow.h"

#import "AppController.h"

#import <CogAudio/AudioPlayer.h>

// NOTICE! We bury first time defaults that should depend on whether the install is fresh or not here
// so that they get created correctly depending on the situation.

// For instance, for the first option to get this treatment, we want time stretching to stay enabled
// for existing installations, but disable itself by default on new installs, to spare processing.

void showSentryConsent(NSWindow *window) {
	BOOL askedConsent = [[NSUserDefaults standardUserDefaults] boolForKey:@"sentryAskedConsent"];
	if(!askedConsent) {
		[window orderFront:window];

		NSAlert *alert = [NSAlert new];
		[alert setMessageText:NSLocalizedString(@"SentryConsentTitle", @"")];
		[alert setInformativeText:NSLocalizedString(@"SentryConsentText", @"")];
		[alert addButtonWithTitle:NSLocalizedString(@"ConsentNo", @"")];
		[alert addButtonWithTitle:NSLocalizedString(@"ConsentYes",@"")];

		[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
			if(returnCode == NSAlertSecondButtonReturn) {
				[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"sentryConsented"];
			}
		}];
		
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"sentryAskedConsent"];
	}
}

@implementation MainWindow

- (id)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)windowStyle backing:(NSBackingStoreType)bufferingType defer:(BOOL)deferCreation {
	self = [super initWithContentRect:contentRect styleMask:windowStyle backing:bufferingType defer:deferCreation];
	if(self) {
		[self setExcludedFromWindowsMenu:YES];
		[self setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
	}
	return self;
}

- (void)awakeFromNib {
	[super awakeFromNib];

	outputFormatField.stringValue = NSLocalizedString(@"Audio: —", @"No active audio output information");
	outputFormatField.toolTip = NSLocalizedString(@"No active audio output.", @"No active audio output tooltip");
	outputFormatField.accessibilityLabel = NSLocalizedString(@"Audio output status", @"Audio output status accessibility label");
	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(coreAudioOutputFormatDidChange:)
	                                             name:CogCoreAudioOutputFormatDidChangeNotification
	                                           object:nil];

	[playlistView setNextResponder:self];

	if(![[NSUserDefaults standardUserDefaults] boolForKey:@"miniMode"]) {
		showSentryConsent(self);
	}
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self
	                                                name:CogCoreAudioOutputFormatDidChangeNotification
	                                              object:nil];
}

- (void)coreAudioOutputFormatDidChange:(NSNotification *)notification {
	NSString *formatDescription = notification.userInfo[CogCoreAudioOutputFormatDescriptionKey];
	NSString *statusFormatDescription = notification.userInfo[CogCoreAudioOutputStatusFormatDescriptionKey];
	NSString *sourceFormatDescription = notification.userInfo[CogCoreAudioSourceFormatDescriptionKey];
	NSString *virtualFormatDescription = notification.userInfo[CogCoreAudioVirtualFormatDescriptionKey];
	NSString *deviceFormatDescription = notification.userInfo[CogCoreAudioDeviceFormatDescriptionKey];
	if(formatDescription.length) {
		outputFormatSource = notification.object;
		NSNumber *losslessValue = notification.userInfo[CogCoreAudioSignalIntegrityLosslessKey];
		NSString *integrityDescription = losslessValue == nil ?
		                                     NSLocalizedString(@"Unknown", @"Unknown Cog signal-integrity state") :
		                                     ([losslessValue boolValue] ?
		                                          NSLocalizedString(@"Bit perfect", @"Bit-perfect Cog signal-integrity state") :
		                                          NSLocalizedString(@"Modified", @"Modified Cog signal-integrity state"));
		NSString *integrityDetails = notification.userInfo[CogCoreAudioSignalIntegrityDetailsKey];
		if(!integrityDetails.length) {
			integrityDetails = NSLocalizedString(@"Source sample information is not available.", @"Unknown Cog signal-integrity details");
		}
		NSString *deviceDescription = deviceFormatDescription.length ? deviceFormatDescription :
		                                                                 NSLocalizedString(@"Unavailable", @"Physical device format unavailable");
		NSString *virtualDescription = virtualFormatDescription.length ? virtualFormatDescription :
		                                                                   NSLocalizedString(@"Unavailable", @"Core Audio virtual format unavailable");
		NSString *sourceDescription = sourceFormatDescription.length ? sourceFormatDescription :
		                                                                  NSLocalizedString(@"Unavailable", @"Decoded source format unavailable");
		const BOOL exclusiveTransport = [notification.userInfo[CogCoreAudioExclusiveTransportKey] boolValue];
		NSString *transportStatus = exclusiveTransport ?
		                                NSLocalizedString(@" · Exclusive", @"Exclusive audio transport status") : @"";
		outputFormatField.stringValue = [NSString stringWithFormat:NSLocalizedString(@"%@ · %@%@", @"Signal integrity, Cog output format, and exclusive transport status"),
		                                                               integrityDescription,
		                                                               statusFormatDescription.length ? statusFormatDescription : formatDescription,
		                                                               transportStatus];
		NSString *transportDetails = exclusiveTransport ?
		                                 NSLocalizedString(@"Exclusive", @"Exclusive transport tooltip value") :
		                                 NSLocalizedString(@"Shared", @"Shared audio transport tooltip value");
		outputFormatField.toolTip = [NSString stringWithFormat:NSLocalizedString(@"%@\n%@\n\nSource: %@\nCog output: %@\nTransport: %@\nCore Audio: %@\nDevice: %@\n\nFormats are reported by Core Audio; later driver or hardware processing is not shown.", @"Detailed audio source and output tooltip"),
		                                                            integrityDescription,
		                                                            integrityDetails,
		                                                            sourceDescription,
		                                                            formatDescription,
		                                                            transportDetails,
		                                                            virtualDescription,
		                                                            deviceDescription];
	} else if(!notification.object || notification.object == outputFormatSource) {
		// An old output can finish stopping after its replacement has already
		// published the same format. Ignore that stale clear instead of replacing
		// the active format with a dash during track transitions.
		outputFormatSource = nil;
		outputFormatField.stringValue = NSLocalizedString(@"Audio: —", @"No active audio output information");
		outputFormatField.toolTip = NSLocalizedString(@"No active audio output.", @"No active audio output tooltip");
	}
}

- (void)focusSearch:(id)sender {
	[self makeFirstResponder:searchField];
	NSRange range = NSMakeRange(0, searchField.stringValue.length);
	NSText *editor = searchField.currentEditor;
	if(editor) {
		editor.selectedRange = range;
	}
}

- (IBAction)openSearch:(id)sender {
	[self focusSearch:sender];
	// hack
	NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.125
													  target:self
													selector:@selector(focusSearch:)
													userInfo:nil
													 repeats:NO];
	[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

@end
