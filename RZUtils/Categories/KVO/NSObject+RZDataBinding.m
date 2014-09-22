//
//  NSObject+RZDataBinding.m
//
//  Created by Rob Visentin on 9/17/14.

// Copyright 2014 Raizlabs and other contributors
// http://raizlabs.com/
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

@import ObjectiveC.runtime;
@import ObjectiveC.message;

#import "NSObject+RZDataBinding.h"

@class RZDBObserverContainer;
@class RZDBObserver;

// public change keys
NSString* const kRZDBChangeKeyObject  = @"RZDBChangeObject";
NSString* const kRZDBChangeKeyOld     = @"RZDBChangeOld";
NSString* const kRZDBChangeKeyNew     = @"RZDBChangeNew";
NSString* const kRZDBChangeKeyKeyPath = @"RZDBChangeKeyPath";

// private change keys
static NSString* const kRZDBChangeKeyIsPrior  = @"RZDBChangeIsPrior";
static NSString* const kRZDBChangeKeyBoundKey = @"RZDBChangeBoundKey";

static void* const kRZDBKVOContext = (void *)&kRZDBKVOContext;

#define RZDBNotNull(obj) ((obj) != nil && ![(obj) isEqual:[NSNull null]])

#pragma mark - RZDataBinding_Private interface

@interface NSObject (RZDataBinding_Private)

- (NSMutableArray *)_rz_registeredObservers;
- (void)_rz_addTarget:(id)target action:(SEL)action boundKey:(NSString *)boundKey forKeyPath:(NSString *)keyPath withOptions:(NSKeyValueObservingOptions)options;
- (void)_rz_removeTarget:(id)target action:(SEL)action boundKey:(NSString *)boundKey forKeyPath:(NSString *)keyPath;
- (void)_rz_observeBoundKeyChange:(NSDictionary *)change;

- (RZDBObserverContainer *)_rz_dependentObservers;

@end

#pragma mark - RZDBObserver interface

@interface RZDBObserver : NSObject;

@property (assign, nonatomic) __unsafe_unretained NSObject *observedObject;
@property (copy, nonatomic) NSString *keyPath;
@property (assign, nonatomic) NSKeyValueObservingOptions observationOptions;

@property (weak, nonatomic) id target;
@property (assign, nonatomic) SEL action;
@property (copy, nonatomic) NSString *boundKey;

- (instancetype)initWithObservedObject:(NSObject *)observedObject keyPath:(NSString *)keyPath observationOptions:(NSKeyValueObservingOptions)observingOptions;

- (void)setTarget:(id)target action:(SEL)action boundKey:(NSString *)boundKey;

- (void)invalidate;

@end

#pragma mark - RZDBObserverContainer interface

@interface RZDBObserverContainer : NSObject

@property (strong, nonatomic) NSPointerArray *observers;

- (void)addObserver:(RZDBObserver *)observer;
- (void)removeObserver:(RZDBObserver *)observer;

@end

#pragma mark - RZDataBinding implementation

@implementation NSObject (RZDataBinding)

- (void)rz_addTarget:(id)target action:(SEL)action forKeyPathChange:(NSString *)keyPath
{
    [self rz_addTarget:target action:action forKeyPathChange:keyPath callImmediately:NO];
}

- (void)rz_addTarget:(id)target action:(SEL)action forKeyPathChange:(NSString *)keyPath callImmediately:(BOOL)callImmediately
{
    NSParameterAssert(target);
    NSParameterAssert(action);
    
    NSKeyValueObservingOptions observationOptions = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld;
    
    if ( callImmediately ) {
        observationOptions |= NSKeyValueObservingOptionInitial;
    }
    
    [self _rz_addTarget:target action:action boundKey:nil forKeyPath:keyPath withOptions:observationOptions];
}

- (void)rz_removeTarget:(id)target action:(SEL)action forKeyPathChange:(NSString *)keyPath
{
    [self _rz_removeTarget:target action:action boundKey:nil forKeyPath:keyPath];
}

- (void)rz_bindKey:(NSString *)key toKeyPath:(NSString *)foreignKeyPath ofObject:(id)object
{
    NSParameterAssert(key);
    NSParameterAssert(foreignKeyPath);
    
    if ( object != nil ) {
        [self willChangeValueForKey:key];
        
        @try {
            [self setValue:[object valueForKeyPath:foreignKeyPath] forKey:key];
        }
        @catch (NSException *exception) {
            NSLog(@"RZDataBinding failed to bind key:%@ to key path:%@ of object:%@. Reason: %@", key, foreignKeyPath, [object description], exception.reason);
            @throw exception;
        }
        
        [self didChangeValueForKey:key];
        
        [object _rz_addTarget:self action:@selector(_rz_observeBoundKeyChange:) boundKey:key forKeyPath:foreignKeyPath withOptions:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionPrior];
    }
}

- (void)rz_unbindKey:(NSString *)key fromKeyPath:(NSString *)foreignKeyPath ofObject:(id)object
{
    [object _rz_removeTarget:self action:@selector(_rz_observeBoundKeyChange:) boundKey:key forKeyPath:foreignKeyPath];
}

@end

#pragma mark - RZDataBinding_Private implementation

@implementation NSObject (RZDataBinding_Private)

- (NSMutableArray *)_rz_registeredObservers
{
    NSMutableArray *registeredObservers = objc_getAssociatedObject(self, _cmd);
    
    if ( registeredObservers == nil ) {
        registeredObservers = [NSMutableArray array];
        objc_setAssociatedObject(self, _cmd, registeredObservers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    return registeredObservers;
}

- (void)_rz_addTarget:(id)target action:(SEL)action boundKey:(NSString *)boundKey forKeyPath:(NSString *)keyPath withOptions:(NSKeyValueObservingOptions)options
{
    NSMutableArray *registeredObservers = [self _rz_registeredObservers];
    
    RZDBObserver *observer = [[RZDBObserver alloc] initWithObservedObject:self keyPath:keyPath observationOptions:options];
    
    [registeredObservers addObject:observer];
    [[target _rz_dependentObservers] addObserver:observer];
    
    [observer setTarget:target action:action boundKey:boundKey];
}

- (void)_rz_removeTarget:(id)target action:(SEL)action boundKey:(NSString *)boundKey forKeyPath:(NSString *)keyPath
{
    NSMutableArray *registeredObservers = [self _rz_registeredObservers];
    
    [[registeredObservers copy] enumerateObjectsUsingBlock:^(RZDBObserver *observer, NSUInteger idx, BOOL *stop) {
        BOOL targetsEqual = (target == observer.target);
        BOOL actionsEqual = (action == NULL || action == observer.action);
        BOOL boundKeysEqual = (boundKey == observer.boundKey || [boundKey isEqualToString:observer.boundKey]);
        BOOL keyPathsEqual = [keyPath isEqualToString:observer.keyPath];
        
        BOOL allEqual = (targetsEqual && actionsEqual && boundKeysEqual && keyPathsEqual);
        
        if ( allEqual ) {
            [[target _rz_dependentObservers] removeObserver:observer];
            [registeredObservers removeObject:observer];
        }
    }];
}

- (void)_rz_observeBoundKeyChange:(NSDictionary *)change
{
    NSString *boundKey = change[kRZDBChangeKeyBoundKey];
    
    if ( boundKey != nil ) {
        if ( [change[kRZDBChangeKeyIsPrior] boolValue] ) {
            [self willChangeValueForKey:boundKey];
        }
        else {
            [self setValue:change[kRZDBChangeKeyNew] forKey:boundKey];
            [self didChangeValueForKey:boundKey];
        }
    }
}

- (RZDBObserverContainer *)_rz_dependentObservers
{
    RZDBObserverContainer *dependentObservers = objc_getAssociatedObject(self, _cmd);
    
    if ( dependentObservers == nil ) {
        dependentObservers = [[RZDBObserverContainer alloc] init];
        objc_setAssociatedObject(self, _cmd, dependentObservers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    return dependentObservers;
}

@end

#pragma mark - RZDBObserver implementation

@implementation RZDBObserver

- (instancetype)initWithObservedObject:(NSObject *)observedObject keyPath:(NSString *)keyPath observationOptions:(NSKeyValueObservingOptions)observingOptions
{
    self = [super init];
    if ( self != nil ) {
        self.observedObject = observedObject;
        self.keyPath = keyPath;
        self.observationOptions = observingOptions;
    }
    
    return self;
}

- (void)setTarget:(id)target action:(SEL)action boundKey:(NSString *)boundKey
{
    self.target = target;
    self.action = action;
    self.boundKey = boundKey;
    
    [self.observedObject addObserver:self forKeyPath:self.keyPath options:self.observationOptions context:kRZDBKVOContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( context == kRZDBKVOContext ) {
        if ( self.target != nil && self.action != NULL ) {
            NSMethodSignature *signature = [self.target methodSignatureForSelector:self.action];
            
            if ( signature.numberOfArguments > 2 ) {
                NSDictionary *changeDict = [self changeDictForKVOChange:change];
                ((void(*)(id, SEL, id))objc_msgSend)(self.target, self.action, changeDict);
            }
            else {
                ((void(*)(id, SEL))objc_msgSend)(self.target, self.action);
            }
        }
        else {
            // This case should never be reached, but if it is, cleanup and recover.
            [self invalidate];
        }
    }
}

- (NSDictionary *)changeDictForKVOChange:(NSDictionary *)kvoChange
{
    NSMutableDictionary *changeDict = [NSMutableDictionary dictionary];
    
    if ( self.observedObject != nil ) {
        changeDict[kRZDBChangeKeyObject] = self.observedObject;
    }
    
    if ( RZDBNotNull(kvoChange[NSKeyValueChangeOldKey]) ) {
        changeDict[kRZDBChangeKeyOld] = kvoChange[NSKeyValueChangeOldKey];
    }
    
    if ( RZDBNotNull(kvoChange[NSKeyValueChangeNewKey]) ) {
        changeDict[kRZDBChangeKeyNew] = kvoChange[NSKeyValueChangeNewKey];
    }
    
    if ( self.keyPath != nil ) {
        changeDict[kRZDBChangeKeyKeyPath] = self.keyPath;
    }
    
    if ( RZDBNotNull(kvoChange[NSKeyValueChangeNotificationIsPriorKey]) ) {
        changeDict[kRZDBChangeKeyIsPrior] = kvoChange[NSKeyValueChangeNotificationIsPriorKey];
    }
    
    if ( self.boundKey != nil ) {
        changeDict[kRZDBChangeKeyBoundKey] = self.boundKey;
    }
    
    return [changeDict copy];
}

- (void)invalidate
{
    [[self.target _rz_dependentObservers] removeObserver:self];
    [[self.observedObject _rz_registeredObservers] removeObject:self];
    
    @try {
        [self.observedObject removeObserver:self forKeyPath:self.keyPath context:kRZDBKVOContext];
    }
    @catch (NSException *exception) {}
    
    self.observedObject = nil;
    self.target = nil;
}

- (void)dealloc
{
    @try {
        [self.observedObject removeObserver:self forKeyPath:self.keyPath context:kRZDBKVOContext];
    }
    @catch (NSException *exception) {}
}

@end

#pragma mark - RZDBObserverContainer implementation

@implementation RZDBObserverContainer

- (instancetype)init
{
    self = [super init];
    if ( self != nil ) {
        self.observers = [NSPointerArray pointerArrayWithOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality)];
    }
    return self;
}

- (void)addObserver:(RZDBObserver *)observer
{
    [self.observers addPointer:(__bridge void *)(observer)];
}

- (void)removeObserver:(RZDBObserver *)observer
{
    __block NSUInteger observerIndex = NSNotFound;
    [[self.observers allObjects] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ( obj == observer ) {
            observerIndex = idx;
            *stop = YES;
        }
    }];
    
    if ( observerIndex != NSNotFound ) {
        [self.observers removePointerAtIndex:observerIndex];
    }
}

- (void)dealloc
{
    [self.observers compact];
    
    [[self.observers allObjects] enumerateObjectsUsingBlock:^(RZDBObserver *observer, NSUInteger idx, BOOL *stop) {
        [observer invalidate];
    }];
}

@end