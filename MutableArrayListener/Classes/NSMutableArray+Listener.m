//
//  NSMutableArray+Listener.m
//  Pods
//
//  Created by aruisi on 2017/7/7.
//
//

#import "NSMutableArray+Listener.h"
#import <objc/runtime.h>
#import <pthread.h>
#import "CircleReferenceCheck.h"

dispatch_semaphore_t __semaphore;
static NSMutableDictionary<NSValue*,NSNumber*>* __tickCount;

static NSInteger increaseCount(){
    @synchronized (__tickCount) {
        if(!__tickCount){
            __tickCount =[NSMutableDictionary dictionary];
        }
        pthread_t pid = pthread_self();
        NSInteger number = [[__tickCount objectForKey:[NSValue valueWithPointer:(const void * _Nullable)(pid)] ]integerValue];
        number+=1;
        [__tickCount setObject:@(number) forKey:[NSValue valueWithPointer:(const void * _Nullable)(pid)]];
        return number;
    }
}
static void decreaseCount(){
    @synchronized (__tickCount) {
        pthread_t pid = pthread_self();
        NSInteger number = [[__tickCount objectForKey:[NSValue valueWithPointer:(const void * _Nullable)(pid)] ]integerValue];
        [__tickCount setObject:@(number-1) forKey:[NSValue valueWithPointer:(const void * _Nullable)(pid)]];
    }
}

typedef struct _weakKeyList{
    __weak id value;
    struct _weakKeyList *next;
} weakKeyList;

typedef struct _weakKeyMap{
    __weak id key;
    weakKeyList *list;
    struct _weakKeyMap *next;
} weakKeyMap;

weakKeyMap *__rootListener;
static __strong MutableArrayListener** getListeners(NSMutableArray *self) {
    __strong MutableArrayListener** result = nil;
    dispatch_semaphore_wait(__semaphore, DISPATCH_TIME_FOREVER);
    weakKeyMap *p = __rootListener;
    weakKeyList *p_list = nil;
    while (p) {
        if (p->key == self) {
            p_list = p->list;
            break;
        }
        p = p->next;
    }
        
    // cacle not nil listeners
    int count = 0;
    weakKeyList *tmp = p_list;
    while (tmp) {
        if (tmp->value) {
            count++;
        }
        tmp = tmp->next;
    }
        
    if (count > 0) {
        // result is nil tail array
        result = (__strong MutableArrayListener**)malloc(sizeof(id)*(count+1));
        count = 0;
        tmp = p_list;
        while (tmp) {
            id obj = tmp->value;
            if (obj) {
                result[count++] = obj;
            }
            tmp = tmp->next;
        }
        ((uintptr_t*)((void*)result))[count] = 0; // make tail is 0
    }
    dispatch_semaphore_signal(__semaphore);
    return result;
}

static void freeListeners(__strong MutableArrayListener** list) {
    if (list) {
        __strong MutableArrayListener** tmp = list;
        while(*tmp) {
            *tmp = nil;
            tmp++;
        }
        free(list);
    }
}

static void freeWeakList(weakKeyList* list) {
    weakKeyList *this = list;
    while(this) {
        weakKeyList *next = this->next;
        this->value = nil;
        free(this);
        this = next;
    }
}

static void addObserver(NSMutableArray *self, MutableArrayListener *observer) {
    if (observer) {
        dispatch_semaphore_wait(__semaphore, DISPATCH_TIME_FOREVER);
        // find or create a link for array
        weakKeyMap **_p = &__rootListener;
        weakKeyList **_p_list = nil;
        while (*_p) {
            if ((*_p)->key == self) {
                _p_list = &(*_p)->list;
                break;
            } else if ((*_p)->key == nil) {// remove null link
                freeWeakList((*_p)->list);
                weakKeyMap *next = (*_p)->next;
                free(*_p);
                *_p = next;
            }
            _p = &(*_p)->next;
        }
        if (*_p == nil) {// if not find node, create a node
            *_p = malloc(sizeof(weakKeyMap));
            memset((void*)(*_p), 0, sizeof(weakKeyMap));
            _p_list = &(*_p)->list;
            (*_p)->key = self;
        }
        
        // find the observer node
        while (*_p_list) {
            if ((*_p_list)->value == observer) {
                break;
            } else if ((*_p_list)->value == nil) {
                weakKeyList *next = (*_p_list)->next;
                free((*_p_list));
                *_p_list = next;
                continue;
            }
            _p_list = &(*_p_list)->next;
        }
        
        if (*_p_list == nil) { // if not find create a node save observer
            *_p_list = malloc(sizeof(weakKeyList));
            memset((void*)(*_p_list), 0, sizeof(weakKeyList));
            (*_p_list)->value = observer;
        }
        dispatch_semaphore_signal(__semaphore);
    }
}
static void removeObserver(NSMutableArray *self, MutableArrayListener *observer) {
    if (observer) {
        dispatch_semaphore_wait(__semaphore, DISPATCH_TIME_FOREVER);
        // find or create a link for array
        weakKeyMap **_p = &__rootListener;
        weakKeyList **_p_list = nil;
        while (*_p) {
            if ((*_p)->key == self) {
                _p_list = &(*_p)->list;
                break;
            } else if ((*_p)->key == nil) {// remove null link
                freeWeakList((*_p)->list);
                weakKeyMap *next = (*_p)->next;
                free(*_p);
                *_p = next;
            }
            _p = &(*_p)->next;
        }
        
        // find the observer node
        while (*_p_list) {
            if ((*_p_list)->value == observer) {
                (*_p_list)->value = nil;
                break;
            } else if ((*_p_list)->value == nil) {
                weakKeyList *next = (*_p_list)->next;
                free((*_p_list));
                *_p_list = next;
                continue;
            }
            _p_list = &(*_p_list)->next;
        }
        
        dispatch_semaphore_signal(__semaphore);
    }
}

#pragma mark  - remove

typedef void (*removeObjectAtIndex_IMP)(id self,SEL _cmd, NSUInteger index);
static removeObjectAtIndex_IMP origin_removeObjectAtIndex_IMP = nil;
static void replace_removeObjectAtIndex_IMP(id self, SEL _cmd ,NSUInteger index){
    
    NSMutableArray* array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        
        NSObject * object ;
        if (array.count > 0 && index<array.count) {
            object = [self objectAtIndex:index];
        }
        origin_removeObjectAtIndex_IMP(self,_cmd,index);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didDeleteObjects:@[object] atIndexes:[NSIndexSet indexSetWithIndex:index]];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didDeleteObjects) {
                        observer.didDeleteObjects(self, @[object], [NSIndexSet indexSetWithIndex:index]);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_removeObjectAtIndex_IMP(self,_cmd,index);
    }
    freeListeners(listeners);
}

#pragma mark - bath remove
typedef void (*removeObject_IMP)(id self,SEL _cmd,id anObject );
static removeObject_IMP origin_removeObject_IMP = nil;
static void replace_removeObject_IMP(id self,SEL _cmd ,id anObject){
    NSMutableArray * array  = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate) ]&& [array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * indexset = [self indexesOfObjectsPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([anObject isEqual:obj]) {
                return YES;
            }else{
                return NO;
            }
        }];
        origin_removeObject_IMP(self,_cmd,anObject);
        decreaseCount();

        if (number==1) {
            [array.delegate mutableArray:self didDeleteObjects:anObject?@[anObject]:nil atIndexes:indexset];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didDeleteObjects) {
                        observer.didDeleteObjects(self, anObject?@[anObject]:nil, indexset);
                        tmp++;
                    }
                }
            }
        }
    }else{
        origin_removeObject_IMP(self,_cmd,anObject);
    }
    freeListeners(listeners);
}

typedef void (*removeAllObjects_IMP)(id self,SEL _cmd );
static removeAllObjects_IMP origin_removeAllObjects_IMP = nil;
static void replace_removeAllObjects_IMP(id self,SEL _cmd){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_removeAllObjects_IMP(self,_cmd);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_removeAllObjects_IMP(self,_cmd);
    }
    freeListeners(listeners);
}

typedef void (*removeObject_inRange_IMP)(id self,SEL _cmd ,id anObject,NSRange range);
static removeObject_inRange_IMP origin_removeObject_inRange_IMP = nil;
static void replace_removeObject_inRange_IMP(id self,SEL _cmd,id anObject,NSRange range){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * indexset = [self indexesOfObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:range] options:NSEnumerationConcurrent passingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([anObject isEqual:obj]) {
                return YES;
            }else{
                return NO;
            }
        }];
        origin_removeObject_inRange_IMP(self,_cmd,anObject,range);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didDeleteObjects:@[anObject] atIndexes:indexset];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didDeleteObjects) {
                        observer.didDeleteObjects(self, @[anObject], indexset);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_removeObject_inRange_IMP(self,_cmd,anObject,range);
    }
    freeListeners(listeners);
}

typedef void (*removeObjectIdenticalTo_inRange_IMP)(id self,SEL _cmd ,id anObject, NSRange range);
static removeObjectIdenticalTo_inRange_IMP origin_removeObjectIdenticalTo_inRange_IMP = nil;
static void replace_removeObjectIdenticalTo_inRange_IMP(id self,SEL _cmd,id anObject,NSRange range){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * indexset = [self indexesOfObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:range] options:NSEnumerationConcurrent passingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([anObject isEqual:obj]) {
                return YES;
            }else{
                return NO;
            }
        }];
        origin_removeObjectIdenticalTo_inRange_IMP(self,_cmd,anObject,range);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didDeleteObjects:@[anObject] atIndexes:indexset];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didDeleteObjects) {
                        observer.didDeleteObjects(self, @[anObject], indexset);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_removeObjectIdenticalTo_inRange_IMP(self,_cmd,anObject,range);
    }
    freeListeners(listeners);
}

typedef void (*removeObjectIdenticalTo_IMP)(id self,SEL _cmd ,id anObject);
static removeObjectIdenticalTo_IMP origin_removeObjectIdenticalTo_IMP = nil;
static void replace_removeObjectIdenticalTo_IMP(id self,SEL _cmd,id anObject){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * indexset = [self indexesOfObjectsPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([anObject isEqual:obj]) {
                return YES;
            }else{
                return NO;
            }
        }];
        origin_removeObjectIdenticalTo_IMP(self,_cmd,anObject);
        decreaseCount();
        if (number==1) {
            if (indexset.count) {
                [array.delegate mutableArray:self didDeleteObjects:@[anObject] atIndexes:indexset];
                if (listeners) {
                    __strong MutableArrayListener **tmp = listeners;
                    __unsafe_unretained MutableArrayListener *observer = nil;
                    while ((observer = *tmp)) {
                        if (observer.didDeleteObjects) {
                            observer.didDeleteObjects(self, @[anObject], indexset);
                        }
                        tmp++;
                    }
                }
            }
       
        }
    }else{
        origin_removeObjectIdenticalTo_IMP(self,_cmd,anObject);
    }
    freeListeners(listeners);
}

typedef void (*removeObjectsInArray_IMP)(id self,SEL _cmd ,NSArray * otherArray);
static removeObjectsInArray_IMP origin_removeObjectsInArray_IMP = nil;
static void replace_removeObjectsInArray_IMP(id self,SEL _cmd,NSArray * otherArray){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * indexset = [self indexesOfObjectsPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([otherArray containsObject:obj]) {
                return YES;
            }else{
                return NO;
            }
        }];
        NSArray * deleteArray = [self objectsAtIndexes:indexset];
        origin_removeObjectsInArray_IMP(self,_cmd,otherArray);
        decreaseCount();
        if (number==1) {
            if (indexset.count) {
                [array.delegate mutableArray:self didDeleteObjects:deleteArray atIndexes:indexset];
                if (listeners) {
                    __strong MutableArrayListener **tmp = listeners;
                    __unsafe_unretained MutableArrayListener *observer = nil;
                    while ((observer = *tmp)) {
                        if (observer.didDeleteObjects) {
                            observer.didDeleteObjects(self, deleteArray, indexset);
                        }
                        tmp++;
                    }
                }
            }
           
        }
    }else{
        origin_removeObjectsInArray_IMP(self,_cmd,otherArray);
    }
    freeListeners(listeners);
}

typedef void (*removeObjectsInRange_IMP)(id self,SEL _cmd ,NSRange range);
static removeObjectsInRange_IMP origin_removeObjectsInRange_IMP = nil;
static void replace_removeObjectsInRange_IMP(id self,SEL _cmd,NSRange range){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * indexset = [NSIndexSet indexSetWithIndexesInRange:range ];
        NSIndexSet * arrayIndexSet = [array indexesOfObjectsPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            return YES;
        }];
        NSArray * deleteArray;
        if ([arrayIndexSet containsIndexesInRange:range]) {
            deleteArray= [self objectsAtIndexes:indexset];
        }
        origin_removeObjectsInRange_IMP(self,_cmd,range);
        decreaseCount();
        if (number==1) {
            if (indexset.count) {
                [array.delegate mutableArray:self didDeleteObjects:deleteArray atIndexes:indexset];
                if (listeners) {
                    __strong MutableArrayListener **tmp = listeners;
                    __unsafe_unretained MutableArrayListener *observer = nil;
                    while ((observer = *tmp)) {
                        if (observer.didDeleteObjects) {
                            observer.didDeleteObjects(self, deleteArray, indexset);
                        }
                        tmp++;
                    }
                }
            }
        }
    }else{
        origin_removeObjectsInRange_IMP(self,_cmd,range);
    }
    freeListeners(listeners);
}

typedef void (*removeObjectsAtIndexes_IMP)(id self,SEL _cmd ,NSIndexSet* indexes );
static removeObjectsAtIndexes_IMP origin_removeObjectsAtIndexes_IMP = nil;
static void replace_removeObjectsAtIndexes_IMP(id self,SEL _cmd,NSIndexSet * indexes){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didDeleteObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        NSIndexSet * arrayIndexSet = [array indexesOfObjectsPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            return YES;
        }];
        NSArray * deleteArray;
        if ([arrayIndexSet containsIndexes:indexes ]) {
            deleteArray= [self objectsAtIndexes:arrayIndexSet];
        }
        origin_removeObjectsAtIndexes_IMP(self,_cmd,indexes);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didDeleteObjects:deleteArray atIndexes:indexes];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didDeleteObjects) {
                        observer.didDeleteObjects(self, deleteArray , indexes);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_removeObjectsAtIndexes_IMP(self,_cmd,indexes);
    }
    freeListeners(listeners);
}


#pragma mark  - replace

typedef void (*replaceObjectAtIndex_withObject_IMP)(id self,SEL _cmd ,NSUInteger index ,id anObject);
static replaceObjectAtIndex_withObject_IMP origin_replaceObjectAtIndex_withObject_IMP = nil;
static void replace_replaceObjectAtIndex_withObject_IMP(id self,SEL _cmd,NSUInteger index ,id anObject){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:replaceObject:withObject:atIndex:)]) || listeners) {
        NSInteger number = increaseCount();
        id object;
        if (array.count>0 && index< array.count) {
            object= [self objectAtIndex:index];
        }
        origin_replaceObjectAtIndex_withObject_IMP(self,_cmd,index,anObject);
        decreaseCount();
        if (number==1) {
        [array.delegate mutableArray:self replaceObject:object withObject:anObject atIndex:index];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didReplaceObject) {
                        observer.didReplaceObject(self, object, anObject, index);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_replaceObjectAtIndex_withObject_IMP(self,_cmd,index,anObject);
    }
    freeListeners(listeners);
}

typedef void (*setObject_atIndexedSubscript_IMP)(id self,SEL _cmd ,id obj,NSUInteger index);
static setObject_atIndexedSubscript_IMP origin_setObject_atIndexedSubscript_IMP = nil;
static void replace_setObject_atIndexedSubscript_IMP(id self,SEL _cmd,id obj,NSUInteger index){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:replaceObject:withObject:atIndex:)]) || listeners) {
        NSInteger number = increaseCount();
        id object;
        if (array.count>0 && index< array.count) {
            object= [self objectAtIndex:index];
        }

        origin_setObject_atIndexedSubscript_IMP(self,_cmd,obj,index);
        decreaseCount();
        if (number==1) {
            
            if (!object&& index==0) {
                [array.delegate mutableArray:self didAddObjects:@[[array firstObject]] atIndexes:[NSIndexSet indexSetWithIndex:index]];
                if (listeners) {
                    __strong MutableArrayListener **tmp = listeners;
                    __unsafe_unretained MutableArrayListener *observer = nil;
                    while ((observer = *tmp)) {
                        if (observer.didAddObjects) {
                            observer.didAddObjects(self, @[[array firstObject]], [NSIndexSet indexSetWithIndex:index]);
                        }
                        tmp++;
                    }
                }
            }else{
                [array.delegate mutableArray:self replaceObject:object withObject:obj atIndex:index];
                if (listeners) {
                    __strong MutableArrayListener **tmp = listeners;
                    __unsafe_unretained MutableArrayListener *observer = nil;
                    while ((observer = *tmp)) {
                        if (observer.didReplaceObject) {
                            observer.didReplaceObject(self, object, obj, index);
                        }
                        tmp++;
                    }
                }
            }
        }
    } else {
        origin_setObject_atIndexedSubscript_IMP(self,_cmd,obj,index);
    }
    freeListeners(listeners);
}

typedef void (*replaceObjectsAtIndexes_withObjects_IMP)(id self,SEL _cmd ,NSIndexSet * indexes ,NSArray * objects);
static replaceObjectsAtIndexes_withObjects_IMP origin_replaceObjectsAtIndexes_withObjects_IMP = nil;
static void replace_replaceObjectsAtIndexes_withObjects_IMP(id self,SEL _cmd,NSIndexSet * indexes,NSArray * objects){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_replaceObjectsAtIndexes_withObjects_IMP(self,_cmd,indexes,objects);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_replaceObjectsAtIndexes_withObjects_IMP(self,_cmd,indexes,objects);
    }
    freeListeners(listeners);
}

typedef void (*replaceObjectsInRange_withObjectsFromArray_IMP)(NSMutableArray *self,SEL _cmd ,NSRange range ,NSArray * array);
static replaceObjectsInRange_withObjectsFromArray_IMP origin_replaceObjectsInRange_withObjectsFromArray_IMP = nil;
static void replace_replaceObjectsInRange_withObjectsFromArray_IMP(NSMutableArray *self,SEL _cmd,NSRange range,NSArray * array){
    NSMutableArray * arrayself = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([arrayself.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[arrayself.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_replaceObjectsInRange_withObjectsFromArray_IMP(self,_cmd,range,array);
        decreaseCount();
        if (number==1) {
            [arrayself.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_replaceObjectsInRange_withObjectsFromArray_IMP(self,_cmd,range,array);
    }
    freeListeners(listeners);
}

typedef void (*replaceObjectsInRange_withObjectsFromArray_range_IMP)(id self,SEL _cmd ,NSRange range,NSArray * otherArray,NSRange  otherRange);
static replaceObjectsInRange_withObjectsFromArray_range_IMP origin_replaceObjectsInRange_withObjectsFromArray_range_IMP = nil;
static void replace_replaceObjectsInRange_withObjectsFromArray_range_IMP(id self,SEL _cmd,NSRange range,NSArray * otherArray,NSRange otherRange){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_replaceObjectsInRange_withObjectsFromArray_range_IMP(self,_cmd,range,otherArray,otherRange);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_replaceObjectsInRange_withObjectsFromArray_range_IMP(self,_cmd,range,otherArray,otherRange);
    }
    freeListeners(listeners);
}


#pragma mark  - sort

typedef void (*sortUsingComparator_IMP)(id self,SEL _cmd ,NSComparator cmptr);
static sortUsingComparator_IMP origin_sortUsingComparator_IMP = nil;
static void replace_sortUsingComparator_IMP(id self,SEL _cmd,NSComparator cmptr){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_sortUsingComparator_IMP(self,_cmd,cmptr);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_sortUsingComparator_IMP(self,_cmd,cmptr);
    }
    freeListeners(listeners);
}

typedef void (*sortUsingSelector_IMP)(id self,SEL _cmd ,SEL comparator);
static sortUsingSelector_IMP origin_sortUsingSelector_IMP = nil;
static void replace_sortUsingSelector_IMP(id self,SEL _cmd,SEL comparator){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_sortUsingSelector_IMP(self,_cmd,comparator);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_sortUsingSelector_IMP(self,_cmd,comparator);
    }
    freeListeners(listeners);
}

typedef void (*sortUsingDescriptors_IMP)(id self,SEL _cmd ,NSArray * sortDescriptors);
static sortUsingDescriptors_IMP origin_sortUsingDescriptors_IMP = nil;
static void replace_sortUsingDescriptors_IMP(id self,SEL _cmd,NSArray * sortDescriptors){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_sortUsingDescriptors_IMP(self,_cmd,sortDescriptors);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_sortUsingDescriptors_IMP(self,_cmd,sortDescriptors);
    }
    freeListeners(listeners);
}

typedef void (*sortUsingFunction_context_IMP)(id self,SEL _cmd, NSInteger(*compare)(id  _Nonnull __strong, id  _Nonnull __strong , void * _Nullable),void(*context));
static sortUsingFunction_context_IMP origin_sortUsingFunction_context_IMP = nil;
static void replace_sortUsingFunction_context_IMP(id self,SEL _cmd, NSInteger(*compare)(id  _Nonnull __strong, id  _Nonnull __strong , void * _Nullable),void(*context)){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_sortUsingFunction_context_IMP(self,_cmd, compare,context);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_sortUsingFunction_context_IMP(self,_cmd, compare,context);
    }
    freeListeners(listeners);
}


typedef void (*sortWithOptions_usingComparator_IMP)(id self,SEL _cmd ,NSSortOptions opts,NSComparator cmptr);
static sortWithOptions_usingComparator_IMP origin_sortWithOptions_usingComparator_IMP = nil;
static void replace_sortWithOptions_usingComparator_IMP(id self,SEL _cmd,NSSortOptions opts,NSComparator cmptr){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_sortWithOptions_usingComparator_IMP(self,_cmd,opts,cmptr);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged: self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_sortWithOptions_usingComparator_IMP(self,_cmd,opts,cmptr);
    }
    freeListeners(listeners);
}

#pragma mark  - reset

typedef void (*setArray_IMP)(id self,SEL _cmd ,NSMutableArray * array);
static setArray_IMP origin_setArray_IMP = nil;
static void replace_setArray_IMP(id self,SEL _cmd,NSMutableArray * array){
    NSMutableArray * arrayself= self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([arrayself.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[arrayself.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_setArray_IMP(self,_cmd,array);
        decreaseCount();
        if (number==1) {
            [arrayself.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_setArray_IMP(self,_cmd,array);
    }
    freeListeners(listeners);
}

#pragma mark  - exchange

typedef void (*exchangeObjectAtIndex_withObjectAtIndex_IMP)(id self,SEL _cmd ,NSUInteger index1,NSUInteger index2);
static exchangeObjectAtIndex_withObjectAtIndex_IMP origin_exchangeObjectAtIndex_withObjectAtIndex_IMP = nil;
static void replace_exchangeObjectAtIndex_withObjectAtIndex_IMP(id self,SEL _cmd,NSUInteger index1,NSUInteger index2){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:exchangeObjectAtIndex:withObjectAtIndex:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_exchangeObjectAtIndex_withObjectAtIndex_IMP(self,_cmd,index1,index2);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self exchangeObjectAtIndex:index1 withObjectAtIndex:index2];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didExchangeIndex) {
                        observer.didExchangeIndex(self, index1, index2);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_exchangeObjectAtIndex_withObjectAtIndex_IMP(self,_cmd,index1,index2);
    }
    freeListeners(listeners);
}


#pragma mark - filter

typedef void (*filterUsingPredicate_IMP)(id self,SEL _cmd ,NSPredicate * predicate);
static filterUsingPredicate_IMP origin_filterUsingPredicate_IMP = nil;
static void replace_filterUsingPredicate_IMP(id self,SEL _cmd,NSPredicate * predicate){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArrayhasChanged:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_filterUsingPredicate_IMP(self,_cmd,predicate);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArrayhasChanged:self];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didChanged) {
                        observer.didChanged(self);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_filterUsingPredicate_IMP(self,_cmd,predicate);
    }
    freeListeners(listeners);
}


#pragma mark  - insert
typedef void (*insertObject_atIndex_IMP)(id self, SEL _cmd ,id anObject ,NSUInteger index);
static insertObject_atIndex_IMP origin_insertObject_atIndex = nil;
static void replace_insertObject_atIndex(id self, SEL _cmd ,id anObject ,NSUInteger index){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate) ]&& [array.delegate respondsToSelector:@selector(mutableArray:didAddObjects:atIndexes:)]) || listeners) {
        
        NSInteger number = increaseCount();
        origin_insertObject_atIndex(self,_cmd,anObject,index);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didAddObjects:@[anObject] atIndexes:[NSIndexSet indexSetWithIndex:index]];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didAddObjects) {
                        observer.didAddObjects(self, @[anObject], [NSIndexSet indexSetWithIndex:index]);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_insertObject_atIndex(self,_cmd,anObject,index);
    }
    freeListeners(listeners);
}

typedef void (*addObjectsFromArray_IMP)(id self,SEL _cmd,NSArray * otherArray );
static addObjectsFromArray_IMP  origin_addObjectsFromArray =nil;
static void replace_addObjectsFromArray (id self,SEL _cmd ,NSArray * otherArray){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didAddObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_addObjectsFromArray(self,_cmd,otherArray);
        
        NSIndexSet * indexSet = [array indexesOfObjectsPassingTest:^BOOL(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([otherArray containsObject:obj]) {
                return YES;
            }else{
                return NO;
            }
        }];
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didAddObjects:otherArray atIndexes:indexSet];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didAddObjects) {
                        observer.didAddObjects(self, otherArray, indexSet);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_addObjectsFromArray(self,_cmd,otherArray);
    }
    freeListeners(listeners);
}

typedef void (*insertObjects_atIndexes_IMP)(id self,SEL _cmd,NSArray * objects,NSIndexSet* indexes);
static insertObjects_atIndexes_IMP origin_insertObjects_atIndexes_IMP =nil;
static void replace_insertObjects_atIndexes_IMP(id self,SEL _cmd,NSArray * objects,NSIndexSet* indexes){
    NSMutableArray * array = self;
    __strong MutableArrayListener **listeners = getListeners(self);
    if (([array.delegate conformsToProtocol:@protocol(NSMutableArrayListenerDelegate)]&&[array.delegate respondsToSelector:@selector(mutableArray:didAddObjects:atIndexes:)]) || listeners) {
        NSInteger number = increaseCount();
        origin_insertObjects_atIndexes_IMP(self,_cmd,objects,indexes);
        decreaseCount();
        if (number==1) {
            [array.delegate mutableArray:self didAddObjects:objects atIndexes:indexes];
            if (listeners) {
                __strong MutableArrayListener **tmp = listeners;
                __unsafe_unretained MutableArrayListener *observer = nil;
                while ((observer = *tmp)) {
                    if (observer.didAddObjects) {
                        observer.didAddObjects(self, objects, indexes);
                    }
                    tmp++;
                }
            }
        }
    }else{
        origin_insertObjects_atIndexes_IMP(self,_cmd,objects,indexes);
    }
    freeListeners(listeners);
}

@implementation NSMutableArray (Listener)

@dynamic delegate;
-(void)addListener:(MutableArrayListener *)observer{
    if (observer) {
        addObserver(self, observer);

        NSAssert(observer.didChanged, @"can not be nil");
        NSAssert(observer.didAddObjects, @"can not be nil");
        NSAssert(observer.didDeleteObjects, @"can not be nil");
        NSAssert(observer.didExchangeIndex, @"can not be nil");
        NSAssert(observer.didReplaceObject, @"can not be nil");

        NSAssert(!checkCircleReference(observer.didAddObjects, self), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didDeleteObjects, self), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didChanged, self), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didExchangeIndex, self), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didReplaceObject, self), @"raise a block circle reference");
        
        
        NSAssert(!checkCircleReference(observer.didAddObjects, observer), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didDeleteObjects, observer), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didChanged, observer), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didExchangeIndex, observer), @"raise a block circle reference");
        NSAssert(!checkCircleReference(observer.didReplaceObject, observer), @"raise a block circle reference");
    }
}
-(void)removeListener:(MutableArrayListener *)observer{
    removeObserver(self, observer);
}

+(void)load{
    Method method;
    Class  class = NSClassFromString(@"__NSArrayM");
#pragma mark - insert
    method = class_getInstanceMethod(class, @selector(insertObject:atIndex:));
    origin_insertObject_atIndex = (insertObject_atIndex_IMP)method_setImplementation(method, (IMP)replace_insertObject_atIndex);
        
    method = class_getInstanceMethod(class, @selector(addObjectsFromArray:));
    origin_addObjectsFromArray = (addObjectsFromArray_IMP)method_setImplementation(method, (IMP)replace_addObjectsFromArray);
    
    method  = class_getInstanceMethod(class, @selector(insertObjects:atIndexes:));
    origin_insertObjects_atIndexes_IMP =(insertObjects_atIndexes_IMP)method_setImplementation(method, (IMP)replace_insertObjects_atIndexes_IMP);
    
#pragma mark - remove
    method  = class_getInstanceMethod(class, @selector(removeObjectAtIndex:));
    origin_removeObjectAtIndex_IMP = (removeObjectAtIndex_IMP)method_setImplementation(method, (IMP)replace_removeObjectAtIndex_IMP);
    
#pragma mark  - bath remove
    method = class_getInstanceMethod(class, @selector(removeObject:));
    origin_removeObject_IMP = (removeObject_IMP)method_setImplementation(method, (IMP)replace_removeObject_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeAllObjects));
    origin_removeAllObjects_IMP =(removeAllObjects_IMP)method_setImplementation(method, (IMP)replace_removeAllObjects_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeObject:inRange:));
    origin_removeObject_inRange_IMP =(removeObject_inRange_IMP)method_setImplementation(method, (IMP)replace_removeObject_inRange_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeObjectIdenticalTo:inRange:));
    origin_removeObjectIdenticalTo_inRange_IMP =(removeObjectIdenticalTo_inRange_IMP)method_setImplementation(method, (IMP)replace_removeObjectIdenticalTo_inRange_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeObjectIdenticalTo:));
    origin_removeObjectIdenticalTo_IMP =(removeObjectIdenticalTo_IMP)method_setImplementation(method, (IMP)replace_removeObjectIdenticalTo_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeObjectsInArray:));
    origin_removeObjectsInArray_IMP =(removeObjectsInArray_IMP)method_setImplementation(method, (IMP)replace_removeObjectsInArray_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeObjectsInRange:));
    origin_removeObjectsInRange_IMP =(removeObjectsInRange_IMP)method_setImplementation(method, (IMP)replace_removeObjectsInRange_IMP);
    
    method = class_getInstanceMethod(class, @selector(removeObjectsAtIndexes:));
    origin_removeObjectsAtIndexes_IMP =(removeObjectsAtIndexes_IMP)method_setImplementation(method, (IMP)replace_removeObjectsAtIndexes_IMP);
    
#pragma mark - replace
    method = class_getInstanceMethod(class, @selector(replaceObjectAtIndex:withObject:));
    origin_replaceObjectAtIndex_withObject_IMP =(replaceObjectAtIndex_withObject_IMP)method_setImplementation(method, (IMP)replace_replaceObjectAtIndex_withObject_IMP);
    
    method = class_getInstanceMethod(class, @selector(setObject:atIndexedSubscript:));
    origin_setObject_atIndexedSubscript_IMP =(setObject_atIndexedSubscript_IMP)method_setImplementation(method, (IMP)replace_setObject_atIndexedSubscript_IMP);

#pragma mark  - bath replace
    method = class_getInstanceMethod(class, @selector(replaceObjectsAtIndexes:withObjects:));
    origin_replaceObjectsAtIndexes_withObjects_IMP =(replaceObjectsAtIndexes_withObjects_IMP)method_setImplementation(method, (IMP)replace_replaceObjectsAtIndexes_withObjects_IMP);
    
    method = class_getInstanceMethod(class, @selector(replaceObjectsInRange:withObjectsFromArray:));
    origin_replaceObjectsInRange_withObjectsFromArray_IMP =(replaceObjectsInRange_withObjectsFromArray_IMP)method_setImplementation(method, (IMP)replace_replaceObjectsInRange_withObjectsFromArray_IMP);
    
    method = class_getInstanceMethod(class, @selector(replaceObjectsInRange:withObjectsFromArray:range:));
    origin_replaceObjectsInRange_withObjectsFromArray_range_IMP =(replaceObjectsInRange_withObjectsFromArray_range_IMP)method_setImplementation(method, (IMP)replace_replaceObjectsInRange_withObjectsFromArray_range_IMP);
    
#pragma mark - sort
    method = class_getInstanceMethod(class, @selector(sortUsingComparator:));
    origin_sortUsingComparator_IMP =(sortUsingComparator_IMP)method_setImplementation(method, (IMP)replace_sortUsingComparator_IMP);
    
    method = class_getInstanceMethod(class, @selector(sortUsingSelector:));
    origin_sortUsingSelector_IMP =(sortUsingSelector_IMP)method_setImplementation(method, (IMP)replace_sortUsingSelector_IMP);
    
    method = class_getInstanceMethod(class, @selector(sortUsingDescriptors:));
    origin_sortUsingDescriptors_IMP =(sortUsingDescriptors_IMP)method_setImplementation(method, (IMP)replace_sortUsingDescriptors_IMP);
    
    method = class_getInstanceMethod(class, @selector(sortUsingFunction:context:));
    origin_sortUsingFunction_context_IMP =(sortUsingFunction_context_IMP)method_setImplementation(method, (IMP)replace_sortUsingFunction_context_IMP);
    
    method = class_getInstanceMethod(class, @selector(sortWithOptions:usingComparator:));
    origin_sortWithOptions_usingComparator_IMP =(sortWithOptions_usingComparator_IMP)method_setImplementation(method, (IMP)replace_sortWithOptions_usingComparator_IMP);
    
    method = class_getInstanceMethod(class, @selector(setArray:));
    origin_setArray_IMP =(setArray_IMP)method_setImplementation(method, (IMP)replace_setArray_IMP);
#pragma mark  -  exchange
    method = class_getInstanceMethod(class, @selector(exchangeObjectAtIndex:withObjectAtIndex:));
    origin_exchangeObjectAtIndex_withObjectAtIndex_IMP =(exchangeObjectAtIndex_withObjectAtIndex_IMP)method_setImplementation(method, (IMP)replace_exchangeObjectAtIndex_withObjectAtIndex_IMP);
    
#pragma mark - filter   
    method = class_getInstanceMethod(class, @selector(filterUsingPredicate:));
    origin_filterUsingPredicate_IMP =(filterUsingPredicate_IMP)method_setImplementation(method, (IMP)replace_filterUsingPredicate_IMP);
    
    __semaphore = dispatch_semaphore_create(1);
}

#pragma mark - property
typedef id(^weakBlock)(void);
-(void)setDelegate:(id)delegate{
    __weak id weakObject = delegate;
    weakBlock block = weakObject?^(void){
        return weakObject;
    }:nil;
    objc_setAssociatedObject(self, @selector(delegate), block, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

-(id)delegate{
    weakBlock block = objc_getAssociatedObject(self, @selector(delegate));
    if (block) return block();
    return nil;
}

@end


static void* keyObserver;
static void* keyOperation;

typedef void(^operationBlock)(void);
static void addOperation(id obj, operationBlock block) {
    if (obj) {
        dispatch_semaphore_wait(__semaphore, DISPATCH_TIME_FOREVER);
        NSMutableArray *arr = objc_getAssociatedObject(obj, &keyOperation);
        if (arr == nil) {
            arr = [[NSMutableArray alloc] init];
            objc_setAssociatedObject(obj, &keyOperation, arr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [arr addObject:block];
        dispatch_semaphore_signal(__semaphore);
    }
}
static void doOperaion(id obj) {
    dispatch_semaphore_wait(__semaphore, DISPATCH_TIME_FOREVER);
    NSMutableArray *arr = objc_getAssociatedObject(obj, &keyOperation);
    NSArray *temp = [arr copy];
    [arr removeAllObjects];
    for (operationBlock block in temp) {
        block();
    }
    dispatch_semaphore_signal(__semaphore);
}

/**
 create a copy array mirror to the array, make all change operation in main thread
 
 @param array the array which to be copy
 @return the array which copied
 */
NSArray * MakeMainThreadCopyOfArray(NSArray * array) {
    if ([array isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *copy = [[NSMutableArray alloc] initWithArray:array];
        __weak typeof(copy) ws = copy;
        
        MutableArrayListener *observer = [[MutableArrayListener alloc] init];
        observer.didAddObjects = ^(NSMutableArray *array, NSArray *objects, NSIndexSet *indexes) {
            if (pthread_main_np()) {
                addOperation(ws, ^(){
                    NSUInteger currentIndex = [indexes firstIndex];
                    NSUInteger i, count = [indexes count];
                    
                    for (i = 0; i < count; i++)
                    {
                        [ws insertObject:[objects objectAtIndex:i] atIndex:currentIndex];
                        currentIndex = [indexes indexGreaterThanIndex:currentIndex];
                    }
                });
                doOperaion(ws);
            } else {
                if ([objects isKindOfClass:[NSMutableArray class]]) {
                    objects = [objects copy];
                }
                addOperation(ws, ^(){
                    NSUInteger currentIndex = [indexes firstIndex];
                    NSUInteger i, count = [indexes count];
                    
                    for (i = 0; i < count; i++)
                    {
                        [ws insertObject:[objects objectAtIndex:i] atIndex:currentIndex];
                        currentIndex = [indexes indexGreaterThanIndex:currentIndex];
                    }
                });
                dispatch_async(dispatch_get_main_queue(), ^{
                    doOperaion(ws);
                });
            }
        };
        observer.didDeleteObjects = ^(NSMutableArray *array, NSArray *objects, NSIndexSet *indexes) {
            addOperation(ws, ^(){
                NSUInteger currentIndex = [indexes lastIndex];
                NSUInteger i, count = [indexes count];
                
                for (i = 0; i < count; i++)
                {
                    [ws removeObjectAtIndex:currentIndex];
                    currentIndex = [indexes indexLessThanIndex:currentIndex];
                }
            });
            if (pthread_main_np()) {
                doOperaion(ws);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    doOperaion(ws);
                });
            }
        };
        observer.didExchangeIndex = ^(NSMutableArray *array, NSUInteger index1, NSUInteger index2) {
            addOperation(ws, ^(){
                [ws exchangeObjectAtIndex:index1 withObjectAtIndex:index2];
            });
            if (pthread_main_np()) {
                doOperaion(ws);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    doOperaion(ws);
                });
            }
        };
        observer.didReplaceObject = ^(NSMutableArray *array, id anObject, id withObject, NSUInteger index) {
            addOperation(ws, ^(){
                [ws replaceObjectAtIndex:index withObject:withObject];
            });
            if (pthread_main_np()) {
                doOperaion(ws);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    doOperaion(ws);
                });
            }
        };
        observer.didChanged = ^(NSMutableArray *array) {
            addOperation(ws, ^(){
                [ws setArray:array];;
            });
            if (pthread_main_np()) {
                doOperaion(ws);
            } else {
                array = [array copy];
                addOperation(ws, ^(){
                    [ws setArray:array];;
                });
                dispatch_async(dispatch_get_main_queue(), ^{
                    doOperaion(ws);
                });
            }
        };
        [(NSMutableArray*)array addListener:observer];
        objc_setAssociatedObject(copy, &keyObserver, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        return copy;
    } else {
        return array;
    }
}
