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

	outputFormatField.stringValue = NSLocalizedString(@"Cog: — · App: — → Device: —", @"No active Cog signal-integrity or output format information");
	outputFormatField.toolTip = NSLocalizedString(@"Shows whether Cog preserves decoded source samples, followed by Cog's Core Audio handoff and the selected device's physical output stream.", @"Cog signal-integrity and output format tooltip");
	outputFormatField.accessibilityLabel = NSLocalizedString(@"Cog signal integrity and Core Audio output formats", @"Cog signal-integrity and output formats accessibility label");
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
		outputFormatField.stringValue = [NSString stringWithFormat:NSLocalizedString(@"Cog: %@ · App: %@ → Device: %@", @"Cog signal-integrity state, Core Audio client format, and physical device format"),
		                                                               integrityDescription,
		                                                               formatDescription,
		                                                               deviceDescription];
		outputFormatField.toolTip = [NSString stringWithFormat:NSLocalizedString(@"Cog signal path: %@\n%@\nCore Audio, driver, and hardware processing are not included.\n\nCog → Core Audio: %@\nDevice physical stream: %@", @"Detailed Cog signal-integrity and output format tooltip"),
		                                                            integrityDescription,
		                                                            integrityDetails,
		                                                            formatDescription,
		                                                            deviceDescription];
	} else if(!notification.object || notification.object == outputFormatSource) {
		// An old output can finish stopping after its replacement has already
		// published the same format. Ignore that stale clear instead of replacing
		// the active format with a dash during track transitions.
		outputFormatSource = nil;
		outputFormatField.stringValue = NSLocalizedString(@"Cog: — · App: — → Device: —", @"No active Cog signal-integrity or output format information");
		outputFormatField.toolTip = NSLocalizedString(@"Shows whether Cog preserves decoded source samples, followed by Cog's Core Audio handoff and the selected device's physical output stream.", @"Cog signal-integrity and output format tooltip");
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
