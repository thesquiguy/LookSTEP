#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ exception boundary around the OpenCascade importer.
@interface StepMeshImporter : NSObject

+ (nullable NSData *)importFileAtPath:(NSString *)path
                        maxTriangles:(NSUInteger)maxTriangles
                   relativeDeflection:(double)relativeDeflection
                   minimumDeflection:(double)minimumDeflection
                   maximumDeflection:(double)maximumDeflection
                              metrics:(NSDictionary<NSString *, id> * _Nullable * _Nullable)metrics
                                error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
