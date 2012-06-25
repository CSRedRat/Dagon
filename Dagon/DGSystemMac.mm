////////////////////////////////////////////////////////////
//
// DAGON - An Adventure Game Engine
// Copyright (c) 2011 Senscape s.r.l.
// All rights reserved.
//
// NOTICE: Senscape permits you to use, modify, and
// distribute this file in accordance with the terms of the
// license agreement accompanying it.
//
////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////
// Headers
////////////////////////////////////////////////////////////

#import "DGAudioManager.h"
#import "DGConfig.h"
#import "DGControl.h"
#import "DGLog.h"
#import "DGSystem.h"
#import "DGTimerManager.h"
#import "DGViewDelegate.h"
#import "DGVideoManager.h"

////////////////////////////////////////////////////////////
// Definitions
////////////////////////////////////////////////////////////

// These are static private in order to keep a clean and
// portable header

NSWindow* window;
DGViewDelegate* view;

dispatch_semaphore_t _semaphores[DGNumberOfThreads];

dispatch_source_t _mainLoop;
dispatch_source_t _audioThread;
dispatch_source_t _timerThread;
dispatch_source_t _profilerThread;
dispatch_source_t _videoThread;
dispatch_source_t CreateDispatchTimer(uint64_t interval,
                                      uint64_t leeway,
                                      dispatch_queue_t queue,
                                      dispatch_block_t block);

////////////////////////////////////////////////////////////
// Implementation - Constructor
////////////////////////////////////////////////////////////

// TODO: At this point the system module should copy the config file
// into the user folder
DGSystem::DGSystem() {  
    audioManager = &DGAudioManager::getInstance();
    log = &DGLog::getInstance();
    config = &DGConfig::getInstance();
    timerManager = &DGTimerManager::getInstance();  
    videoManager = &DGVideoManager::getInstance();
    
    _areThreadsActive = false;
    _isInitialized = false;
    _isRunning = false;
}

////////////////////////////////////////////////////////////
// Implementation - Destructor
////////////////////////////////////////////////////////////

DGSystem::~DGSystem() {
    // The shutdown sequence is performed in the terminate() method
}

////////////////////////////////////////////////////////////
// Implementation
////////////////////////////////////////////////////////////

void DGSystem::createThreads() {
    // Create the semaphores
    _semaphores[DGAudioThread] = dispatch_semaphore_create(0);
    _semaphores[DGTimerThread] = dispatch_semaphore_create(0);
    _semaphores[DGVideoThread] = dispatch_semaphore_create(0);
    
    // Send the first signal
    dispatch_semaphore_signal(_semaphores[DGAudioThread]);
    dispatch_semaphore_signal(_semaphores[DGTimerThread]); 
    dispatch_semaphore_signal(_semaphores[DGVideoThread]);
    
    _audioThread = CreateDispatchTimer(0.01f * NSEC_PER_SEC, 0,
                                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                                       ^{ dispatch_semaphore_wait(_semaphores[DGAudioThread], DISPATCH_TIME_FOREVER);
                                           audioManager->update();
                                           dispatch_semaphore_signal(_semaphores[DGAudioThread]); });    
    
    _timerThread = CreateDispatchTimer(0.01f * NSEC_PER_SEC, 0,
                                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                                       ^{ dispatch_semaphore_wait(_semaphores[DGTimerThread], DISPATCH_TIME_FOREVER);
                                           timerManager->update(); 
                                           dispatch_semaphore_signal(_semaphores[DGTimerThread]); });
    
    _videoThread = CreateDispatchTimer(0.01f * NSEC_PER_SEC, 0,
                                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                                       ^{ dispatch_semaphore_wait(_semaphores[DGVideoThread], DISPATCH_TIME_FOREVER);
                                           videoManager->update();
                                           dispatch_semaphore_signal(_semaphores[DGVideoThread]); });
    
    if (config->debugMode) {
        _profilerThread = CreateDispatchTimer(1.0f * NSEC_PER_SEC, 0,
                                              dispatch_get_main_queue(),
                                              ^{ control->profiler(); });
    }
    
    _areThreadsActive = true;
}

void DGSystem::destroyThreads() {    
    // Suspend and release all threads
    this->suspendThread(DGAudioThread);
    this->suspendThread(DGTimerThread);
    this->suspendThread(DGVideoThread);
    
    dispatch_source_cancel(_audioThread);
    dispatch_source_cancel(_timerThread);
    dispatch_source_cancel(_videoThread);
    
    dispatch_release(_semaphores[DGAudioThread]);
    dispatch_release(_semaphores[DGTimerThread]);
    dispatch_release(_semaphores[DGVideoThread]);
    
    // If in debug mode, release the profiler
    if (config->debugMode) {
        dispatch_source_cancel(_profilerThread);
        dispatch_release(_profilerThread);
    }
    
    _areThreadsActive = false;
}

void DGSystem::findPaths(int argc, char* argv[]) {
    // Check if launched by Finder (non-standard but safe)
    if (argc >= 2 && strncmp (argv[1], "-psn", 4) == 0 ) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        
        if (config->debugMode) {
            // Set working directory to parent of bundle
            NSString *bundleDirectory = [[NSBundle mainBundle] bundlePath];
            NSString *parentDirectory = [bundleDirectory stringByDeletingLastPathComponent];
            chdir([parentDirectory UTF8String]);
        }
        else {
            // Get Application Support folder
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
            NSString *appSupportDirectory = [paths objectAtIndex:0];
            
            appSupportDirectory = [appSupportDirectory stringByAppendingString:@"/Dagon/"];
            
            // Create if it doesn't exist
            if (![[NSFileManager defaultManager] fileExistsAtPath:appSupportDirectory]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:appSupportDirectory withIntermediateDirectories:YES attributes:nil error:nil];
            }
            
            config->setPath(DGPathUser, [appSupportDirectory UTF8String]);
            
            NSString *appDirectory = [[NSBundle mainBundle] resourcePath];
            appDirectory = [appDirectory stringByAppendingString:@"/"];
            config->setPath(DGPathApp, [appDirectory UTF8String]);
            
            // Get resource folder in bundle path
            NSString *resDirectory = [[NSBundle mainBundle] resourcePath];
            resDirectory = [[resDirectory stringByAppendingString:@"/"] stringByAppendingString:@DGDefCatalogPath];
            config->setPath(DGPathRes, [resDirectory UTF8String]);
        }   
        
        [pool release];
    }
}

void DGSystem::init() {
    if (!_isInitialized) {
        log->trace(DGModSystem, "========================================");
        log->trace(DGModSystem, "%s", DGMsg040000);
        
        // We manually create our NSApplication instance
        [NSApplication sharedApplication];
        
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        
        // Programmatically create a window
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(50, 100, config->displayWidth, config->displayHeight) 
                                                     styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
                                                       backing:NSBackingStoreBuffered defer:TRUE];
        
        // Programmatically create our NSView delegate
        NSRect mainDisplayRect, viewRect;
        mainDisplayRect = NSMakeRect(0, 0, config->displayWidth, config->displayHeight);
        
        viewRect = NSMakeRect(0.0, 0.0, mainDisplayRect.size.width, mainDisplayRect.size.height);
        view = [[DGViewDelegate alloc] initWithFrame:viewRect];
        
        // Now we're ready to init the controller instance
        control = &DGControl::getInstance();
        control->init();
        
        [window setAcceptsMouseMovedEvents:YES];
        [window setContentView:view];
        [window makeFirstResponder:view];
        [window setCollectionBehavior: NSWindowCollectionBehaviorFullScreenPrimary];
        [window setTitle:[NSString stringWithUTF8String:config->script()]];
        [window makeKeyAndOrderFront:window];
        
        if (config->fullScreen) {
            [window toggleFullScreen:nil];
            [NSCursor hide];
        }
        
        [NSBundle loadNibNamed:@"MainMenu" owner:NSApp];
        [pool release];
        
        _isInitialized = true;
        log->trace(DGModSystem, "%s", DGMsg040001);
    }
    else log->warning(DGModSystem, "%s", DGMsg140002);
}

void DGSystem::resumeThread(int threadID) {
    if (_areThreadsActive) {
        switch (threadID) {
            case DGAudioThread:
                dispatch_resume(_audioThread);
                break;
            case DGTimerThread:
                dispatch_resume(_timerThread);
                break;
            case DGVideoThread:
                dispatch_resume(_videoThread);
                break;                
        }
    }
}

// TODO: Note this isn't quite multithreaded yet.
// The timer is running in the main process and thus the OpenGL context doesn't
// have to be shared.
void DGSystem::run() {
    _mainLoop = CreateDispatchTimer((1.0f / config->framerate) * NSEC_PER_SEC, 0,
                                    dispatch_get_main_queue(),
                                    ^{ control->update(); });
    
    _isRunning = true;
    
    [NSApp run];
}

void DGSystem::setTitle(const char* title) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSString* aux = [NSString stringWithUTF8String:title];
    
    [window setTitle:aux];

    [pool release];
}

void DGSystem::suspendThread(int threadID) {
    if (_areThreadsActive) {
        dispatch_semaphore_wait(_semaphores[threadID], DISPATCH_TIME_FOREVER);
        
        switch (threadID) {
            case DGAudioThread:
                dispatch_suspend(_audioThread);
                break;
            case DGTimerThread:
                dispatch_suspend(_timerThread);
                break;
            case DGVideoThread:
                dispatch_suspend(_videoThread);
                break;                
        }
        
        dispatch_semaphore_signal(_semaphores[threadID]);
    }
}

void DGSystem::terminate() {
    static bool isTerminating = false;
    
    if (!isTerminating) {
        // This is crappy, yes, but the only way to peacefully
        // coexist with our delegate in some situations
        isTerminating = true;
        int r = arc4random() % 8; // Double the replies, so that the default one appears often
        
        if (_isRunning) {
            // Release the main loop
            dispatch_source_cancel(_mainLoop);
            
            if (_areThreadsActive)
                destroyThreads();
        }    
        
        if (_isInitialized) {
            [view release];
            [window release];
        }
        
        switch (r) {
            default:
            case 0: log->trace(DGModSystem, "%s", DGMsg040100); break;
            case 1: log->trace(DGModSystem, "%s", DGMsg040101); break;
            case 2: log->trace(DGModSystem, "%s", DGMsg040102); break;
            case 3: log->trace(DGModSystem, "%s", DGMsg040103); break;
        }
        
        [NSApp terminate:nil];
    }
}

void DGSystem::toggleFullScreen() {
    config->fullScreen = !config->fullScreen;
    if (_isRunning) {
        // TODO: Suspend the timer to avoid multiple redraws
        [window toggleFullScreen:nil];
    }
    else [window toggleFullScreen:nil];
}

void DGSystem::update() {
    [view update];
}

time_t DGSystem::wallTime() {
    dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, NULL);
    return (now / 1000);
}

////////////////////////////////////////////////////////////
// Implementation - Private methods
////////////////////////////////////////////////////////////

dispatch_source_t CreateDispatchTimer(uint64_t interval,
                                      uint64_t leeway,
                                      dispatch_queue_t queue,
                                      dispatch_block_t block) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0, 0, queue);
    if (timer) {
        dispatch_source_set_timer(timer, dispatch_time(NULL, 0), interval, leeway);
        dispatch_source_set_event_handler(timer, block);
        dispatch_resume(timer);
    }
    
    return timer;
}
