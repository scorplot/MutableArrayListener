//
//  NSMutableArray+Listener.h
//  Pods
//
//  Created by aruisi on 2017/7/7.
//
//

#import <Foundation/Foundation.h>
#import "NSMutableArrayListenerDelegate.h"
#import "MutableArrayListener.h"
@interface NSMutableArray (Listener)

@property(nonatomic,weak)id<NSMutableArrayListenerDelegate> delegate;

/**
 add Listener

 @param listener listener
 */
-(void)addListener:(MutableArrayListener* )listener;

/**
 remove listener

 @param listener listener
 */
-(void)removeListener:(MutableArrayListener * )listener;
@end

/**
 create a copy array mirror to the array, make all change operation in main thread,
 Users should guarantee the array did not changes in two thread at same time.
 
 @param array the array which to be copy
 @return the array which copied
 */
NSArray * MakeMainThreadCopyOfArray(NSArray * array);
