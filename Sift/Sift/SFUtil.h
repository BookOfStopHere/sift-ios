// Copyright (c) 2015 Sift Science. All rights reserved.

@import Foundation;

#ifdef NDEBUG
#define SFDebug(...)
#else
#define SFDebug(...) NSLog(__VA_ARGS__)
#endif

NSString *SFCacheDirPath(void);
