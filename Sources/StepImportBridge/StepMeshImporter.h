#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ exception boundary around the OpenCascade importer.
@interface StepMeshImporter : NSObject

/// `startingSimplificationLevel` skips straight to a coarser tessellation for a
/// source already predicted not to fit at full quality. Reactive coarsening
/// still applies on top of it, so a level chosen too low is corrected — it just
/// costs a wasted mesh pass, which is exactly what the prediction avoids.
+ (nullable NSData *)importFileAtPath:(NSString *)path
                        maxTriangles:(NSUInteger)maxTriangles
                   relativeDeflection:(double)relativeDeflection
                   minimumDeflection:(double)minimumDeflection
                   maximumDeflection:(double)maximumDeflection
          startingSimplificationLevel:(NSUInteger)startingSimplificationLevel
                              metrics:(NSDictionary<NSString *, id> * _Nullable * _Nullable)metrics
                                error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
