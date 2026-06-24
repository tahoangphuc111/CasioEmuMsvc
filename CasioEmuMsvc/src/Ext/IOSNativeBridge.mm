#ifdef IOS
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>

// Include the header we just made
#include "iOSNativeBridge.h"

// Singleton to act as the UIDocumentPickerDelegate
@interface iOSNativeBridge : NSObject <UIDocumentPickerDelegate>
+ (instancetype)sharedInstance;
@end

@implementation iOSNativeBridge

+ (instancetype)sharedInstance {
    static iOSNativeBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[iOSNativeBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
        onAppCreate();
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - App Lifecycle Observers

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    onAppResume();
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    onAppPause();
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    onAppBackground();
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    onAppForeground();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    onAppTerminate();
}



// Get the root view controller to present dialogs
- (UIViewController*)rootViewController {
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
    
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window.rootViewController;
        }
    }
    
    return scene.windows.firstObject.rootViewController;
}

#pragma mark - System Dialogs (File & Folder Pickers)


float getSafeTop() {
    if (@available(iOS 11.0, *)) {
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        return window.safeAreaInsets.top;
    }
    return 20.0f;
}

- (void)openFileDialog {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *documentTypes = @[(NSString *)kUTTypeItem]; // Equivalent to setType("/")
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:documentTypes inMode:UIDocumentPickerModeOpen];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [[self rootViewController] presentViewController:picker animated:YES completion:nil];
    });
}

- (void)saveFileDialog:(NSString*)preferredName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *documentTypes = @[(NSString *)kUTTypeItem];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:documentTypes inMode:UIDocumentPickerModeExportToService];
        picker.delegate = self;
        if (@available(iOS 11.0, *)) {
            picker.allowsContentCreation = YES;
        }
        [[self rootViewController] presentViewController:picker animated:YES completion:nil];
    });
}

- (void)openFolderDialog {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *documentTypes = @[(NSString *)kUTTypeFolder];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:documentTypes inMode:UIDocumentPickerModeOpen];
        picker.delegate = self;
        [[self rootViewController] presentViewController:picker animated:YES completion:nil];
    });
}

- (void)saveFolderDialog {
    // iOS doesn't distinguish between open/save folder, just open a folder picker
    [self openFolderDialog];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    
    NSURL *url = urls.firstObject;
    [url startAccessingSecurityScopedResource]; // Required for iOS file access
    
    NSString *path = url.path;
    
    // Check if it's a directory (Folder)
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
    BOOL isDir = (attrs.fileType == NSFileTypeDirectory);
    
    if (isDir) {
        if (controller.documentPickerMode == UIDocumentPickerModeOpen) {
            onFolderSelected(path.UTF8String);
        } else {
            onFolderSaved(path.UTF8String);
        }
    } else {
        // It's a file, read the data
        NSData *fileData = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (fileData && !error) {
            if (controller.documentPickerMode == UIDocumentPickerModeOpen) {
                onFileSelected(path.UTF8String, (const unsigned char*)fileData.bytes, (int)fileData.length);
            } else {
                onFileSaved(path.UTF8String);
            }
        } else {
            onImportFailed();
        }
    }
    
    [url stopAccessingSecurityScopedResource];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // User cancelled the dialog
    onImportFailed();
}

@end

#pragma mark - C++ Bridge Functions

void nativeVibrate(long milliseconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // iOS doesn't support exact ms vibration like Android.
        // We map the duration to Human Interface Guidelines Haptics
        if (milliseconds < 100) {
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [generator impactOccurred];
        } else if (milliseconds < 300) {
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [generator impactOccurred];
        } else {
            // Long vibrations usually indicate errors/notifications
            UINotificationFeedbackGenerator *generator = [[UINotificationFeedbackGenerator alloc] init];
            [generator notificationOccurred:UINotificationFeedbackTypeError];
        }
    });
}

void onNativeCrash(const char* message) {
    NSString *msg = [NSString stringWithUTF8String:message];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Crash Detected"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *copyAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            // Copy to clipboard
            [UIPasteboard generalPasteboard].string = msg;
            
            // Exit cleanly
            exit(0);
        }];
        
        UIAlertAction *closeAction = [UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
            exit(0);
        }];
        
        [alert addAction:copyAction];
        [alert addAction:closeAction];
        
        [[iOSNativeBridge sharedInstance].rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

void openFileDialog() {
    [[iOSNativeBridge sharedInstance] openFileDialog];
}

void saveFileDialog(const char* preferredName) {
    NSString *name = preferredName ? [NSString stringWithUTF8String:preferredName] : @"Untitled";
    [[iOSNativeBridge sharedInstance] saveFileDialog:name];
}

void openFolderDialog() {
    [[iOSNativeBridge sharedInstance] openFolderDialog];
}

void saveFolderDialog() {
    [[iOSNativeBridge sharedInstance] saveFolderDialog];
}

typedef struct FontHeader {
    int32_t fVersion;
    uint16_t fNumTables;
    uint16_t fSearchRange;
    uint16_t fEntrySelector;
    uint16_t fRangeShift;
} FontHeader;

typedef struct TableEntry {
    uint32_t fTag;
    uint32_t fCheckSum;
    uint32_t fOffset;
    uint32_t fLength;
} TableEntry;

static uint32_t CalcTableCheckSum(const uint32_t *table, uint32_t numberOfBytesInTable) {
    uint32_t sum = 0;
    uint32_t nLongs = (numberOfBytesInTable + 3) / 4;
    while (nLongs-- > 0) {
       sum += CFSwapInt32HostToBig(*table++);
    }
    return sum;
}

extern "C" bool getIOSFontData(const char* fontName, unsigned char** outData, int* outLength) {
    @autoreleasepool {
        NSString *nameStr = [NSString stringWithUTF8String:fontName];
        UIFont *uiFont = [UIFont fontWithName:nameStr size:14.0];
        if (!uiFont) {
            return false;
        }
        
        CGFontRef cgFont = CTFontCopyGraphicsFont((__bridge CTFontRef)uiFont, NULL);
        if (!cgFont) {
            return false;
        }
        
        CFArrayRef tags = CGFontCopyTableTags(cgFont);
        if (!tags) {
            CFRelease(cgFont);
            return false;
        }
        
        CFIndex tableCount = CFArrayGetCount(tags);
        if (tableCount == 0) {
            CFRelease(tags);
            CFRelease(cgFont);
            return false;
        }
        
        size_t totalSize = sizeof(FontHeader) + sizeof(TableEntry) * tableCount;
        BOOL containsCFFTable = NO;
        
        // First pass: calculate total size
        for (CFIndex index = 0; index < tableCount; ++index) {
            uint32_t aTag = (uint32_t)(uintptr_t)CFArrayGetValueAtIndex(tags, index);
            if (aTag == 'CFF ') {
                containsCFFTable = YES;
            }
            
            CFDataRef tableDataRef = CGFontCopyTableForTag(cgFont, aTag);
            if (tableDataRef != NULL) {
                totalSize += (CFDataGetLength(tableDataRef) + 3) & ~3;
                CFRelease(tableDataRef);
            }
        }
        
        unsigned char *stream = (unsigned char *)malloc(totalSize);
        if (!stream) {
            CFRelease(tags);
            CFRelease(cgFont);
            return false;
        }
        
        memset(stream, 0, totalSize);
        char* dataStart = (char*)stream;
        char* dataPtr = dataStart;
        
        // compute font header entries
        uint16_t entrySelector = 0;
        uint16_t searchRange = 1;
        
        while (searchRange < tableCount >> 1) {
            entrySelector++;
            searchRange <<= 1;
        }
        searchRange <<= 4;
        
        uint16_t rangeShift = (tableCount << 4) - searchRange;
        
        // write font header
        FontHeader* offsetTable = (FontHeader*)dataPtr;
        offsetTable->fVersion = containsCFFTable ? CFSwapInt32HostToBig(0x4F54544F) : CFSwapInt32HostToBig(0x00010000);
        offsetTable->fNumTables = CFSwapInt16HostToBig((uint16_t)tableCount);
        offsetTable->fSearchRange = CFSwapInt16HostToBig((uint16_t)searchRange);
        offsetTable->fEntrySelector = CFSwapInt16HostToBig((uint16_t)entrySelector);
        offsetTable->fRangeShift = CFSwapInt16HostToBig((uint16_t)rangeShift);
        
        dataPtr += sizeof(FontHeader);
        
        // write table directory
        TableEntry* entry = (TableEntry*)dataPtr;
        dataPtr += sizeof(TableEntry) * tableCount;
        
        for (CFIndex index = 0; index < tableCount; ++index) {
            uint32_t aTag = (uint32_t)(uintptr_t)CFArrayGetValueAtIndex(tags, index);
            CFDataRef tableDataRef = CGFontCopyTableForTag(cgFont, aTag);
            if (tableDataRef != NULL) {
                size_t tableSize = CFDataGetLength(tableDataRef);
                memcpy(dataPtr, CFDataGetBytePtr(tableDataRef), tableSize);
                
                entry->fTag = CFSwapInt32HostToBig((uint32_t)aTag);
                entry->fCheckSum = CFSwapInt32HostToBig(CalcTableCheckSum((uint32_t *)dataPtr, (uint32_t)tableSize));
                
                uint32_t offset = (uint32_t)(dataPtr - dataStart);
                entry->fOffset = CFSwapInt32HostToBig(offset);
                entry->fLength = CFSwapInt32HostToBig((uint32_t)tableSize);
                
                dataPtr += (tableSize + 3) & ~3;
                ++entry;
                CFRelease(tableDataRef);
            }
        }
        
        CFRelease(tags);
        CFRelease(cgFont);
        
        *outData = stream;
        *outLength = (int)totalSize;
        return true;
    }
}

#endif