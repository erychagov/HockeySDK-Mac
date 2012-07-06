/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *         Kent Sutherland
 *
 * Copyright (c) 2012 HockeyApp, Bit Stadium GmbH.
 * Copyright (c) 2011 Andreas Linde & Kent Sutherland.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "BITCrashReportManager.h"
#import "BITCrashReportUI.h"
#import <sys/sysctl.h>
#import <CrashReporter/CrashReporter.h>
#import <HockeySDK/HockeySDK.h>
#import "BITCrashReportTextFormatter.h"
#import <objc/runtime.h>

#define SDK_NAME @"HockeySDK-Mac"
#define SDK_VERSION @"0.9.5"

/**
 * @internal
 *
 * The overridden version of sendEvent: in NSApplication
 */
@class NSEvent;

@interface NSObject (HockeySDK_PrivateAdditions)
- (void)hockeysdk_catching_sendEvent: (NSEvent *) theEvent;
@end

@implementation NSObject (HockeySDK_PrivateAdditions)

- (void)hockeysdk_catching_sendEvent:(NSEvent *)theEvent {
  @try {
    /* In a swizzled method, calling the swizzled selector actually calls the
     original method. */
    [self hockeysdk_catching_sendEvent:theEvent];
  } @catch (NSException *exception) {
    (NSGetUncaughtExceptionHandler())(exception);
  }
}

@end


@interface BITCrashReportManager (private)
- (NSString *)applicationName;
- (NSString *)applicationVersionString;
- (NSString *)applicationVersion;

- (BOOL)trapRunLoopExceptions;

- (void)handleCrashReport;
- (BOOL)hasPendingCrashReport;
- (void)cleanCrashReports;
- (NSString *)extractAppUUIDs:(PLCrashReport *)report;

- (void)postXML:(NSString*)xml;
- (void)searchCrashLogFile:(NSString *)path;

- (void)returnToMainApplication;
@end


@implementation BITCrashReportManager

@synthesize exceptionInterceptionEnabled = _exceptionInterceptionEnabled;
@synthesize delegate = _delegate;
@synthesize appIdentifier = _appIdentifier;
@synthesize companyName = _companyName;
@synthesize autoSubmitCrashReport = _autoSubmitCrashReport;

#pragma mark - Init

+ (BITCrashReportManager *)sharedCrashReportManager {
  static BITCrashReportManager *crashReportManager = nil;
  
  if (crashReportManager == nil) {
    crashReportManager = [[BITCrashReportManager alloc] init];
  }
  
  return crashReportManager;
}

- (id)init {
  if ((self = [super init])) {
    _exceptionInterceptionEnabled = NO;
    _serverResult = HockeyCrashReportStatusUnknown;
    _crashReportUI = nil;
    _fileManager = [[NSFileManager alloc] init];
    
    _crashIdenticalCurrentVersion = YES;
    _submissionURL = @"https://rink.hockeyapp.net/";
    
    _crashFile = nil;
    _crashFiles = nil;
    
    self.delegate = nil;
    self.companyName = @"";
    
    NSString *testValue = nil;
    testValue = [[NSUserDefaults standardUserDefaults] stringForKey:kHockeySDKCrashReportActivated];
    if (testValue) {
      _crashReportActivated = [[NSUserDefaults standardUserDefaults] boolForKey:kHockeySDKCrashReportActivated];
    } else {
      _crashReportActivated = YES;
      [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES] forKey:kHockeySDKCrashReportActivated];
    }
  }
  return self;
}

- (void)dealloc {
  _delegate = nil;

  [_companyName release]; _companyName = nil;

  [_fileManager release]; _fileManager = nil;

  [_crashFile release]; _crashFile = nil;
  
  [_crashFiles release]; _crashFiles = nil;
  [_crashesDir release]; _crashesDir = nil;
  
  [_crashReportUI release]; _crashReportUI= nil;
  
  [super dealloc];
}


#pragma mark - Private

/**
 * Swizzle -[NSApplication sendEvent:] to capture exceptions in the run loop.
 */
- (BOOL)trapRunLoopExceptions {
  Class cls = NSClassFromString(@"NSApplication");
  
  if (!cls)
    return NO;
  
  SEL origSel = @selector(sendEvent:), altSel = @selector(hockeysdk_catching_sendEvent:);
  Method origMethod = class_getInstanceMethod(cls, origSel),
  altMethod = class_getInstanceMethod(cls, altSel);
  
  if (!origMethod || !altMethod)
    return NO;
  
  class_addMethod(cls, origSel, class_getMethodImplementation(cls, origSel), method_getTypeEncoding(origMethod));
  class_addMethod(cls, altSel, class_getMethodImplementation(cls, altSel), method_getTypeEncoding(altMethod));
  method_exchangeImplementations(class_getInstanceMethod(cls, origSel), class_getInstanceMethod(cls, altSel));
  return YES;
}


- (void)cleanCrashReports {
  NSError *error = NULL;
  
  for (NSUInteger i=0; i < [_crashFiles count]; i++) {		
    [_fileManager removeItemAtPath:[_crashFiles objectAtIndex:i] error:&error];
    [_fileManager removeItemAtPath:[[_crashFiles objectAtIndex:i] stringByAppendingString:@".meta"] error:&error];
  }
  [_crashFiles removeAllObjects];
  
  [[NSUserDefaults standardUserDefaults] setObject:nil forKey:kHockeySDKApprovedCrashReports];
  [[NSUserDefaults standardUserDefaults] synchronize];    
}

- (NSString *)modelVersion {
  NSString * modelString  = nil;
  int        modelInfo[2] = { CTL_HW, HW_MODEL };
  size_t     modelSize;
  
  if (sysctl(modelInfo,
             2,
             NULL,
             &modelSize,
             NULL, 0) == 0) {
    void * modelData = malloc(modelSize);
    
    if (modelData) {
      if (sysctl(modelInfo,
                 2,
                 modelData,
                 &modelSize,
                 NULL, 0) == 0) {
        modelString = [NSString stringWithUTF8String:modelData];
      }
      
      free(modelData);
    }
  }
  
  return modelString;
}

- (NSString *)extractAppUUIDs:(PLCrashReport *)report {  
  NSMutableString *uuidString = [NSMutableString string];
  NSArray *uuidArray = [BITCrashReportTextFormatter arrayOfAppUUIDsForCrashReport:report];
  
  for (NSDictionary *element in uuidArray) {
    if ([element objectForKey:kCNSBinaryImageKeyUUID] && [element objectForKey:kCNSBinaryImageKeyArch] && [element objectForKey:kCNSBinaryImageKeyUUID]) {
      [uuidString appendFormat:@"<uuid type=\"%@\" arch=\"%@\">%@</uuid>",
       [element objectForKey:kCNSBinaryImageKeyType],
       [element objectForKey:kCNSBinaryImageKeyArch],
       [element objectForKey:kCNSBinaryImageKeyUUID]
       ];
    }
  }
  
  return uuidString;
}

- (void)returnToMainApplication {
  if (self.delegate != nil && [self.delegate respondsToSelector:@selector(showMainApplicationWindow)]) {
    [self.delegate showMainApplicationWindow];
  } else {
    NSLog(@"ERROR: Required BITCrashReportManagerDelegate is not set!");
  }
}

- (void)startManager {
  BOOL returnToApp = NO;
  
  if ([self hasPendingCrashReport]) {
    NSError* error = nil;
    NSString *crashReport = nil;

    _crashFile = [_crashFiles lastObject];
    NSData *crashData = [NSData dataWithContentsOfFile: _crashFile];
    PLCrashReport *report = [[[PLCrashReport alloc] initWithData:crashData error:&error] autorelease];
    crashReport = [BITCrashReportTextFormatter stringValueForCrashReport:report withTextFormat:PLCrashReportTextFormatiOS];

    if (crashReport && !error) {        
      NSString *log = @"";
      
      if (_delegate && [_delegate respondsToSelector:@selector(crashReportApplicationLog)]) {
        log = [_delegate crashReportApplicationLog];
      }

      if (!self.autoSubmitCrashReport && [self hasNonApprovedCrashReports]) {
        _crashReportUI = [[BITCrashReportUI alloc] initWithManager:self
                                                   crashReportFile:_crashFile
                                                       crashReport:crashReport
                                                        logContent:log
                                                       companyName:_companyName
                                                   applicationName:[self applicationName]];
        
        [_crashReportUI askCrashReportDetails];
      } else {
        [self sendReportCrash:crashReport crashDescription:nil];
      }
    } else {
      if (![self hasNonApprovedCrashReports]) {
        [self performSendingCrashReports];
      } else {
        returnToApp = YES;
      }
    }
  } else {
    returnToApp = YES;
  }
  
  if (returnToApp)
    [self returnToMainApplication];
}


#pragma mark - PLCrashReporter based

- (BOOL)hasNonApprovedCrashReports {
  NSDictionary *approvedCrashReports = [[NSUserDefaults standardUserDefaults] dictionaryForKey: kHockeySDKApprovedCrashReports];
  
  if (!approvedCrashReports || [approvedCrashReports count] == 0) return YES;
  
  for (NSUInteger i=0; i < [_crashFiles count]; i++) {
    NSString *filename = [_crashFiles objectAtIndex:i];
    
    if (![approvedCrashReports objectForKey:filename]) return YES;
  }
  
  return NO;
}

- (BOOL)hasPendingCrashReport {
  if (!_crashReportActivated) return NO;
  
  _crashFiles = [[NSMutableArray alloc] init];
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  _crashesDir = [[NSString stringWithFormat:@"%@", [[paths objectAtIndex:0] stringByAppendingPathComponent:@"/crashes/"]] retain];
  
  if (![_fileManager fileExistsAtPath:_crashesDir]) {
    NSDictionary *attributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedLong: 0755] forKey: NSFilePosixPermissions];
    NSError *theError = NULL;
    
    [_fileManager createDirectoryAtPath:_crashesDir withIntermediateDirectories: YES attributes: attributes error: &theError];
  }
  
  PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
  NSError *error = NULL;
  
  // Check if we previously crashed
  if ([crashReporter hasPendingCrashReport]) {
    [self handleCrashReport];
  }
  
  // Enable the Crash Reporter
  if (![crashReporter enableCrashReporterAndReturnError:&error])
    NSLog(@"Warning: Could not enable crash reporter: %@", error);
  
  /* Enable run-loop exception trapping if requested */
  if (_exceptionInterceptionEnabled) {
    if (![self trapRunLoopExceptions])
      NSLog(@"Warning: Could not enable run-loop exception trapping!");
  }
  
  if ([_crashFiles count] == 0 && [_fileManager fileExistsAtPath: _crashesDir]) {
    NSString *file = nil;
    NSError *error = NULL;
    
    NSDirectoryEnumerator *dirEnum = [_fileManager enumeratorAtPath: _crashesDir];
    
    while ((file = [dirEnum nextObject])) {
      NSDictionary *fileAttributes = [_fileManager attributesOfItemAtPath:[_crashesDir stringByAppendingPathComponent:file] error:&error];
      if ([[fileAttributes objectForKey:NSFileSize] intValue] > 0 && ![file isEqualToString:@".DS_Store"] && ![file hasSuffix:@".meta"]) {
        [_crashFiles addObject:[_crashesDir stringByAppendingPathComponent: file]];
      }
    }
  }
  
  if ([_crashFiles count] > 0)
    return YES;
  else
    return NO;
}


#pragma mark - Crash Report Processing

- (void)cancelReport {
  [self cleanCrashReports];
  [self returnToMainApplication];
}

- (void)performSendingCrashReports {
  NSMutableDictionary *approvedCrashReports = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey: kHockeySDKApprovedCrashReports]];
  
  NSError *error = NULL;
		
  NSMutableString *crashes = nil;
  _crashIdenticalCurrentVersion = NO;
  
  for (NSUInteger i=0; i < [_crashFiles count]; i++) {
    NSString *filename = [_crashFiles objectAtIndex:i];
    NSData *crashData = [NSData dataWithContentsOfFile:filename];
		
    if ([crashData length] > 0) {
      PLCrashReport *report = [[[PLCrashReport alloc] initWithData:crashData error:&error] autorelease];
			
      if (report == nil) {
        HockeySDKLog(@"ERROR: Could not parse crash report");
        continue;
      }
      
      NSString *crashLogString = [BITCrashReportTextFormatter stringValueForCrashReport:report withTextFormat:PLCrashReportTextFormatiOS];
                     
      if ([report.applicationInfo.applicationVersion compare:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]] == NSOrderedSame) {
        _crashIdenticalCurrentVersion = YES;
      }
			
      if (crashes == nil) {
        crashes = [NSMutableString string];
      }
      
      NSMutableDictionary *metaDict = [NSKeyedUnarchiver unarchiveObjectWithFile:[_crashFile stringByAppendingString:@".meta"]];
      
      NSString *userid = [metaDict valueForKey:@"userid"] ?: @"";
      NSString *contact = [metaDict valueForKey:@"contact"] ?: @"";
      NSString *log = [metaDict valueForKey:@"log"] ?: @"";
      NSString *description = [metaDict valueForKey:@"description"] ?: @"";
      
      if ([log length] > 0) {
        if ([description length] > 0) {
          description = [NSString stringWithFormat:@"%@\n\nLog:\n%@", description, log];
        } else {
          description = [NSString stringWithFormat:@"Log:\n%@", log];
        }
      }
      
      [crashes appendFormat:@"<crash><applicationname>%s</applicationname><uuids>%@</uuids><bundleidentifier>%@</bundleidentifier><systemversion>%@</systemversion><senderversion>%@</senderversion><version>%@</version><platform>%@</platform><userid>%@</userid><contact>%@</contact><description><![CDATA[%@]]></description><log><![CDATA[%@]]></log></crash>",
       [[self applicationName] UTF8String],
       [self extractAppUUIDs:report],
       report.applicationInfo.applicationIdentifier,
       report.systemInfo.operatingSystemVersion,
       [self applicationVersion],
       report.applicationInfo.applicationVersion,
       [self modelVersion],
       userid,
       contact,
       [description stringByReplacingOccurrencesOfString:@"]]>" withString:@"]]" @"]]><![CDATA[" @">" options:NSLiteralSearch range:NSMakeRange(0,description.length)],
       [crashLogString stringByReplacingOccurrencesOfString:@"]]>" withString:@"]]" @"]]><![CDATA[" @">" options:NSLiteralSearch range:NSMakeRange(0,crashLogString.length)]
                       ];

      // store this crash report as user approved, so if it fails it will retry automatically
      [approvedCrashReports setObject:[NSNumber numberWithBool:YES] forKey:[_crashFiles objectAtIndex:i]];
    } else {
      // we cannot do anything with this report, so delete it
      [_fileManager removeItemAtPath:filename error:&error];
      [_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.meta", filename] error:&error];
    }
  }
	
  [[NSUserDefaults standardUserDefaults] setObject:approvedCrashReports forKey:kHockeySDKApprovedCrashReports];
  [[NSUserDefaults standardUserDefaults] synchronize];
  
  if (crashes != nil) {
    [self postXML:[NSString stringWithFormat:@"<crashes>%@</crashes>", crashes]];
  }

  // Only return to main application, if crash is send
  // Scenario: Crash on app start would never be send!
  
  [self returnToMainApplication];
}

- (void)sendReportCrash:(NSString*)crashFile crashDescription:(NSString *)crashDescription {
  // add notes and delegate results to the latest crash report
  
  NSMutableDictionary *metaDict = [[[NSMutableDictionary alloc] init] autorelease];
  NSString *userid = @"";
  NSString *contact = @"";
  NSString *log = @"";
  
  if (!crashDescription) crashDescription = @"";
  [metaDict setValue:crashDescription forKey:@"description"];
  
  if (_delegate != nil && [_delegate respondsToSelector:@selector(crashReportUserID)]) {
    userid = [self.delegate crashReportUserID] ?: @"";
    [metaDict setValue:userid forKey:@"userid"];
  }
  
  if (_delegate != nil && [_delegate respondsToSelector:@selector(crashReportContact)]) {
    contact = [self.delegate crashReportContact] ?: @"";
    [metaDict setValue:contact forKey:@"contact"];
  }
  
  if (_delegate != nil && [_delegate respondsToSelector:@selector(crashReportApplicationLog)]) {
    log = [self.delegate crashReportApplicationLog] ?: @"";
    [metaDict setValue:log forKey:@"log"];
  }
  
  [NSKeyedArchiver archiveRootObject:metaDict toFile:[NSString stringWithFormat:@"%@.meta", _crashFile]];    
  
  [self performSendingCrashReports];
}


#pragma mark - Networking

- (void)postXML:(NSString*)xml {
  NSMutableURLRequest *request = nil;
  NSString *boundary = @"----FOO";
  
  request = [NSMutableURLRequest requestWithURL:
             [NSURL URLWithString:[NSString stringWithFormat:@"%@api/2/apps/%@/crashes?sdk=%@&sdk_version=%@&feedbackEnabled=no",
                                   _submissionURL,
                                   [self.appIdentifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding],
                                   SDK_NAME,
                                   SDK_VERSION
                                   ]
              ]];
  
  [request setValue:SDK_NAME forHTTPHeaderField:@"User-Agent"];
  [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
  [request setTimeoutInterval: 15];
  [request setHTTPMethod:@"POST"];
  NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
  [request setValue:contentType forHTTPHeaderField:@"Content-type"];
  
  NSMutableData *postBody =  [NSMutableData data];  
  [postBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  if (self.appIdentifier) {
    [postBody appendData:[@"Content-Disposition: form-data; name=\"xml\"; filename=\"crash.xml\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [postBody appendData:[[NSString stringWithFormat:@"Content-Type: text/xml\r\n\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
  } else {
    [postBody appendData:[@"Content-Disposition: form-data; name=\"xmlstring\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  }
  [postBody appendData:[xml dataUsingEncoding:NSUTF8StringEncoding]];
  [postBody appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  [request setHTTPBody:postBody];
  
  _serverResult = HockeyCrashReportStatusUnknown;
  _statusCode = 200;
  
  NSHTTPURLResponse *response = nil;
  NSError *error = nil;
  
  NSData *responseData = nil;
  responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
  _statusCode = [response statusCode];
  
  if (_statusCode >= 200 && _statusCode < 400 && responseData != nil && [responseData length] > 0) {
    [self cleanCrashReports];

    // HockeyApp uses PList XML format
    NSMutableDictionary *response = [NSPropertyListSerialization propertyListFromData:responseData
                                                                     mutabilityOption:NSPropertyListMutableContainersAndLeaves
                                                                               format:nil
                                                                     errorDescription:NULL];
    HockeySDKLog(@"Received API response: %@", response);
    _serverResult = (HockeyCrashReportStatus)[[response objectForKey:@"status"] intValue];
  }
}


#pragma mark - GetterSetter

- (NSString *)applicationName {
  NSString *applicationName = [[[NSBundle mainBundle] localizedInfoDictionary] valueForKey: @"CFBundleExecutable"];
  
  if (!applicationName)
    applicationName = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleExecutable"];
  
  return applicationName;
}


- (NSString*)applicationVersionString {
  NSString* string = [[[NSBundle mainBundle] localizedInfoDictionary] valueForKey: @"CFBundleShortVersionString"];
  
  if (!string)
    string = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleShortVersionString"];
  
  return string;
}

- (NSString *)applicationVersion {
  NSString* string = [[[NSBundle mainBundle] localizedInfoDictionary] valueForKey: @"CFBundleVersion"];
  
  if (!string)
    string = [[[NSBundle mainBundle] infoDictionary] valueForKey: @"CFBundleVersion"];
  
  return string;
}


#pragma mark - PLCrashReporter

//
// Called to handle a pending crash report.
//
- (void)handleCrashReport {
  PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
  NSError *error = NULL;
	
  // check if the next call ran successfully the last time
  if (_analyzerStarted == 0) {
    // mark the start of the routine
    _analyzerStarted = 1;
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:_analyzerStarted] forKey:kHockeySDKAnalyzerStarted];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // Try loading the crash report
    NSData *crashData = [[[NSData alloc] initWithData:[crashReporter loadPendingCrashReportDataAndReturnError: &error]] autorelease];
    
    NSString *cacheFilename = [NSString stringWithFormat: @"%.0f", [NSDate timeIntervalSinceReferenceDate]];
    
    if (crashData == nil) {
      HockeySDKLog(@"Warning: Could not load crash report: %@", error);
    } else {
      [crashData writeToFile:[_crashesDir stringByAppendingPathComponent: cacheFilename] atomically:YES];
    }
  }
	
  // Purge the report
  // mark the end of the routine
  _analyzerStarted = 0;
  [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:_analyzerStarted] forKey:kHockeySDKAnalyzerStarted];
  [[NSUserDefaults standardUserDefaults] synchronize];
  
  [crashReporter purgePendingCrashReport];
  return;
}

@end