// Copyright (c) 2015 Sift Science. All rights reserved.

@import Foundation;

#import "SFMetrics.h"
#import "SFUtil.h"

#import "SFEventFileStore.h"
#import "SFEventFileStore+Internal.h"

static NSString * const SFEventFileName = @"events";
static NSString * const SFEventFilePattern = @"^events-(\\d+)$";

@implementation SFEventFileStore {
    NSString *_eventDirPath;
    NSString *_currentEventFilePath;

    // Cache the opened file handle so that we don't have to open it every time.
    NSFileHandle *_currentEventFile;

    NSRegularExpression *_eventFileNameRegex;

    NSFileManager *_manager;

    // Acquire these locks by the declaration order.
    NSObject *_currentEventFileLock;
    NSObject *_eventFilesLock;
}

- (instancetype)initWithEventDirPath:(NSString *)eventDirPath {
    self = [super init];
    if (self) {
        NSError *error;

        _eventDirPath = eventDirPath;
        _currentEventFilePath = [_eventDirPath stringByAppendingPathComponent:SFEventFileName];

        _currentEventFile = nil;

        _eventFileNameRegex = [NSRegularExpression regularExpressionWithPattern:SFEventFilePattern options:0 error:&error];
        if (error) {
            SFDebug(@"Could not construct regex due to %@", [error localizedDescription]);
            self = nil;
            return nil;
        }

        _manager = [NSFileManager defaultManager];

        SFDebug(@"Create event dir \"%@\"", _eventDirPath);
        if (![_manager createDirectoryAtPath:_eventDirPath withIntermediateDirectories:YES attributes:nil error:&error]) {
            SFDebug(@"Could not create event dir \"%@\" due to %@", _eventDirPath, [error localizedDescription]);
            [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreDirCreationError];
            self = nil;
            return nil;
        }

        _currentEventFileLock = [NSObject new];
        _eventFilesLock = [NSObject new];
    }
    return self;
}

- (BOOL)writeCurrentEventFileWithBlock:(BOOL (^)(NSFileHandle *))block {
    @synchronized(_currentEventFileLock) {
        return block([self currentEventFile]);
    }
}

- (void)removeCurrentEventFile {
    @synchronized(_currentEventFileLock) {
        [self closeCurrentEventFile];

        NSError *error;
        if (![_manager removeItemAtPath:_currentEventFilePath error:&error]) {
            SFDebug(@"Could not remove the current event file \"%@\" due to %@", _currentEventFilePath, [error localizedDescription]);
            [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreFileRemovalError];
        }
    }
}

- (BOOL)accessEventFilesWithBlock:(BOOL (^)(NSFileManager *manager, NSArray *eventFilePaths))block {
    @synchronized(_eventFilesLock) {
        return block(_manager, [self eventFilePaths]);
    }
}

- (BOOL)accessAllEventFilesWithBlock:(BOOL (^)(NSFileManager *manager, NSString *currentEventFilePath, NSArray *eventFilePaths))block {
    @synchronized(_currentEventFileLock) {
        @synchronized(_eventFilesLock) {
            return block(_manager, _currentEventFilePath, [self eventFilePaths]);
        }
    }
}

- (BOOL)rotateCurrentEventFile {
    @synchronized(_currentEventFileLock) {
        @synchronized(_eventFilesLock) {
            if (![_manager isWritableFileAtPath:_currentEventFilePath]) {
                return YES;   // Nothing to rotate...
            }

            NSArray *eventFilePaths = [self eventFilePaths];
            if (!eventFilePaths) {
                return NO;
            }

            int largestIndex = -1;
            if (eventFilePaths.count > 0) {
                largestIndex = [self eventFileIndex:[[eventFilePaths lastObject] lastPathComponent]];
            }
            NSString *newEventFileName = [NSString stringWithFormat:@"%@-%d", SFEventFileName, (largestIndex + 1)];
            NSString *newEventFilePath = [_eventDirPath stringByAppendingPathComponent:newEventFileName];

            // Close the current event file handle before rotating it.
            [self closeCurrentEventFile];

            NSError *error;
            if (![_manager moveItemAtPath:_currentEventFilePath toPath:newEventFilePath error:&error]) {
                SFDebug(@"Could not rotate the current event file \"%@\" to \"%@\" due to %@", _currentEventFilePath, newEventFilePath, [error localizedDescription]);
                [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreFileRotationError];
                return NO;
            }

            SFDebug(@"The current event file is rotated to \"%@\"", newEventFilePath);
            [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreFileRotationSuccess];
            return YES;
        }
    }
}

- (BOOL)removeEventDir {
    @synchronized(_currentEventFileLock) {
        @synchronized(_eventFilesLock) {
            [self closeCurrentEventFile];

            NSError *error;
            if (![_manager removeItemAtPath:_eventDirPath error:&error]) {
                SFDebug(@"Could not remove event dir \"%@\" due to %@", _eventDirPath, [error localizedDescription]);
                [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreDirRemovalError];
                return NO;
            }
            return YES;
        }
    }
}

// NOTE: You _must_ acquire respective locks before calling methods below.

- (NSFileHandle *)currentEventFile {
    if (!_currentEventFile) {
        SFDebug(@"Open the current event file \"%@\"", _currentEventFilePath);

        if (![_manager isWritableFileAtPath:_currentEventFilePath]) {
            if (![_manager createFileAtPath:_currentEventFilePath contents:nil attributes:nil]) {
                SFDebug(@"Could not create \"%@\"", _currentEventFilePath);
                [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreFileCreationError];
                return nil;
            }
        }

        _currentEventFile = [NSFileHandle fileHandleForWritingAtPath:_currentEventFilePath];
        if (!_currentEventFile) {
            SFDebug(@"Could not open \"%@\" for writing", _currentEventFilePath);
            [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreFileOpenError];
            return nil;
        }

        [_currentEventFile seekToEndOfFile];
    }
    return _currentEventFile;
}

- (void)closeCurrentEventFile {
    if (_currentEventFile) {
        [_currentEventFile closeFile];
        _currentEventFile = nil;
    }
}

- (NSArray *)eventFilePaths {
    NSError *error;
    NSArray *fileNames = [_manager contentsOfDirectoryAtPath:_eventDirPath error:&error];
    if (!fileNames) {
        SFDebug(@"Could not list contents of directory \"%@\" due to %@", _eventDirPath, [error localizedDescription]);
        [[SFMetrics sharedInstance] count:SFMetricsKeyEventFileStoreDirListingError];
        return nil;
    }

    fileNames = [fileNames filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id fileName, NSDictionary *bindings) {
        return [self eventFileIndex:fileName] >= 0;
    }]];

    // Sort file names by the event file index (_not_ by alphabetic order).
    fileNames = [fileNames sortedArrayUsingComparator:^NSComparisonResult(NSString *fileName1, NSString *fileName2) {
        return [self eventFileIndex:fileName1] - [self eventFileIndex:fileName2];
    }];

    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:fileNames.count];
    for (NSString *fileName in fileNames) {
        [paths addObject:[_eventDirPath stringByAppendingPathComponent:fileName]];
    }
    return paths;
}

- (int)eventFileIndex:(NSString *)eventFileName {
    NSTextCheckingResult *match = [_eventFileNameRegex firstMatchInString:eventFileName options:0 range:NSMakeRange(0, eventFileName.length)];
    if (!match) {
        return -1;
    }
    NSString *number = [eventFileName substringWithRange:[match rangeAtIndex:1]];
    return number.intValue;
}

@end
