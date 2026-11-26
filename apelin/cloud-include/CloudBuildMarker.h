#pragma once
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
static const char *APSNCloudBuildMarker(void) {
    static const char *marker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char anchor = 0;
        Dl_info info;
        if (dladdr(&anchor, &info) && info.dli_fname) {
            NSString *directory = [@(info.dli_fname) stringByDeletingLastPathComponent];
            NSString *value = [NSString stringWithContentsOfFile:
                [directory stringByAppendingPathComponent:@"APSNoSuggestions.build-id"]
                encoding:NSUTF8StringEncoding error:nil];
            if (value.length) marker = strdup([[value stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet] UTF8String]);
        }
        if (!marker) marker = "cloud-marker-missing";
    });
    return marker;
}
#undef APELIN_BUILD_ID
#define APELIN_BUILD_ID APSNCloudBuildMarker()
