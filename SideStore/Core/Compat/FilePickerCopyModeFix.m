//
//  FilePickerCopyModeFix.m
//  SideStore
//
//  Sideloaded and containerised installs (LiveContainer, TrollStore-style
//  launchers, re-signed builds with unusual entitlements) can hand the app
//  document-picker URLs that it is not allowed to read, even after calling
//  -startAccessingSecurityScopedResource. SideStore only imports files, so force
//  the picker into copy mode and relocate anything that still ends up outside the
//  sandbox before the app reads it.
//
//  This reproduces the behaviour of the external "filepickerfix.dylib" tweak, so
//  the app works without injecting it.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char SideStoreOriginalPickedURLsKey;
static char SideStoreOriginalPickedURLKey;

static IMP SideStoreOriginalInitForOpening = NULL;
static IMP SideStoreOriginalInitWithDocumentTypes = NULL;
static IMP SideStoreOriginalSetDelegate = NULL;

static NSURL *SideStoreLocalCopyOfPickedURL(NSURL *url)
{
    if (!url.isFileURL) {
        return url;
    }

    NSString *home = NSHomeDirectory();
    NSString *path = url.path;
    if ([path isEqualToString:home] || [path hasPrefix:[home stringByAppendingString:@"/"]]) {
        return url;
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"SideStorePickedFiles" stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
    NSURL *destination = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:url.lastPathComponent]];

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *error = nil;
    BOOL copied = [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]
        && [fileManager copyItemAtURL:url toURL:destination error:&error];

    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }

    if (!copied) {
        NSLog(@"[SideStore] File picker: could not copy %@ into the sandbox: %@", url.lastPathComponent, error.localizedDescription);
        return url;
    }

    NSLog(@"[SideStore] File picker: using sandboxed copy of %@", url.lastPathComponent);
    return destination;
}

static IMP SideStoreOriginalImplementationForDelegate(Class cls, char *key)
{
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject(current, key);
        if (value) {
            return value.pointerValue;
        }
    }
    return NULL;
}

static void SideStorePickedDocumentURLs(id self, SEL _cmd, id picker, NSArray<NSURL *> *urls)
{
    IMP original = SideStoreOriginalImplementationForDelegate(object_getClass(self), &SideStoreOriginalPickedURLsKey);
    if (!original) {
        return;
    }

    NSMutableArray<NSURL *> *localized = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [localized addObject:SideStoreLocalCopyOfPickedURL(url)];
    }

    ((void (*)(id, SEL, id, NSArray *))original)(self, _cmd, picker, localized);
}

static void SideStorePickedDocumentURL(id self, SEL _cmd, id picker, NSURL *url)
{
    IMP original = SideStoreOriginalImplementationForDelegate(object_getClass(self), &SideStoreOriginalPickedURLKey);
    if (!original) {
        return;
    }

    ((void (*)(id, SEL, id, NSURL *))original)(self, _cmd, picker, SideStoreLocalCopyOfPickedURL(url));
}

static void SideStorePatchDelegateMethod(Class cls, SEL selector, IMP replacement, char *key)
{
    Method existing = class_getInstanceMethod(cls, selector);
    if (!existing || method_getImplementation(existing) == replacement) {
        return;
    }

    IMP previous = class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(existing));
    if (!previous) {
        previous = method_getImplementation(existing);
    }
    objc_setAssociatedObject(cls, key, [NSValue valueWithPointer:previous], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SideStoreSetDelegate(id self, SEL _cmd, id delegate)
{
    if (delegate) {
        Class cls = object_getClass(delegate);
        SideStorePatchDelegateMethod(cls, @selector(documentPicker:didPickDocumentsAtURLs:), (IMP)SideStorePickedDocumentURLs, &SideStoreOriginalPickedURLsKey);
        SideStorePatchDelegateMethod(cls, @selector(documentPicker:didPickDocumentAtURL:), (IMP)SideStorePickedDocumentURL, &SideStoreOriginalPickedURLKey);
    }
    ((void (*)(id, SEL, id))SideStoreOriginalSetDelegate)(self, _cmd, delegate);
}

static id SideStoreInitForOpeningContentTypes(id self, SEL _cmd, NSArray *types, BOOL asCopy)
{
    // Copy mode guarantees the returned URL is readable inside the app's sandbox.
    return ((id (*)(id, SEL, NSArray *, BOOL))SideStoreOriginalInitForOpening)(self, _cmd, types, YES);
}

static id SideStoreInitWithDocumentTypes(id self, SEL _cmd, NSArray *types, NSInteger mode)
{
    // Legacy picker: UIDocumentPickerModeOpen (0) -> UIDocumentPickerModeImport (1).
    // Numeric values are used to avoid referring to the deprecated enum.
    if (mode == 0) {
        mode = 1;
    }
    return ((id (*)(id, SEL, NSArray *, NSInteger))SideStoreOriginalInitWithDocumentTypes)(self, _cmd, types, mode);
}

__attribute__((constructor))
static void SideStoreInstallFilePickerCopyModeFix(void)
{
    Class pickerClass = UIDocumentPickerViewController.class;

    Method initForOpening = class_getInstanceMethod(pickerClass, @selector(initForOpeningContentTypes:asCopy:));
    if (initForOpening) {
        SideStoreOriginalInitForOpening = method_setImplementation(initForOpening, (IMP)SideStoreInitForOpeningContentTypes);
    }

    Method initWithDocumentTypes = class_getInstanceMethod(pickerClass, @selector(initWithDocumentTypes:inMode:));
    if (initWithDocumentTypes) {
        SideStoreOriginalInitWithDocumentTypes = method_setImplementation(initWithDocumentTypes, (IMP)SideStoreInitWithDocumentTypes);
    }

    Method setDelegate = class_getInstanceMethod(pickerClass, @selector(setDelegate:));
    if (setDelegate) {
        SideStoreOriginalSetDelegate = method_setImplementation(setDelegate, (IMP)SideStoreSetDelegate);
    }
}
