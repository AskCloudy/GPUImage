#import "GPUImageMovieWithAudio.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageAudioPlayer.h"

@interface GPUImageMovieWithAudio ()
{
    BOOL audioEncodingIsFinished, videoEncodingIsFinished;
    GPUImageMovieWriter *synchronizedMovieWriter;
    CVOpenGLESTextureCacheRef coreVideoTextureCache;
    AVAssetReader *reader;
    BOOL keepLooping;
    BOOL processedFirstFrame;
    BOOL shouldStopProcessing;
    BOOL processingStopped;
    
    GPUImageAudioPlayer *audioPlayer;
    CFAbsoluteTime assetStartTime;
    dispatch_queue_t audio_queue;
}

- (void)processAsset;

@end

@implementation GPUImageMovieWithAudio

@synthesize url = _url;
@synthesize asset = _asset;
@synthesize runBenchmark = _runBenchmark;
@synthesize playAtActualSpeed = _playAtActualSpeed;
@synthesize delegate = _delegate;
@synthesize shouldRepeat = _shouldRepeat;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithURL:(NSURL *)url;
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    [self textureCacheSetup];
    
    self.url = url;
    self.asset = nil;
    
    return self;
}

- (id)initWithAsset:(AVAsset *)asset;
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    [self textureCacheSetup];
    
    self.url = nil;
    self.asset = asset;
    
    return self;
}

- (void)textureCacheSetup;
{
    if ([GPUImageContext supportsFastTextureUpload])
    {
        runSynchronouslyOnVideoProcessingQueue(^{
            [GPUImageContext useImageProcessingContext];
#if defined(__IPHONE_6_0)
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [[GPUImageContext sharedImageProcessingContext] context], NULL, &coreVideoTextureCache);
#else
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)[[GPUImageContext sharedImageProcessingContext] context], NULL, &coreVideoTextureCache);
#endif
            if (err)
            {
                NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d", err);
            }
            
            // Need to remove the initially created texture
            [self deleteOutputTexture];
        });
    }
}

- (void)dealloc
{
    if (audio_queue != nil){
        dispatch_release(audio_queue);
    }
    
    if ([GPUImageContext supportsFastTextureUpload])
    {
        CFRelease(coreVideoTextureCache);
    }
}

#pragma mark -
#pragma mark Movie processing

- (void)enableSynchronizedEncodingUsingMovieWriter:(GPUImageMovieWriter *)movieWriter;
{
    synchronizedMovieWriter = movieWriter;
    movieWriter.encodingLiveVideo = NO;
}

- (void)startProcessing
{
    processingStopped = NO;
    
    if(self.url == nil)
    {
        [self processAsset];
        return;
    }
    
    if (_shouldRepeat) keepLooping = YES;
    
    NSDictionary *inputOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
    AVURLAsset *inputAsset = [[AVURLAsset alloc] initWithURL:self.url options:inputOptions];
    
    GPUImageMovieWithAudio __block *blockSelf = self;
    
    [inputAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler: ^{
        runSynchronouslyOnVideoProcessingQueue(^{
            NSError *error = nil;
            AVKeyValueStatus tracksStatus = [inputAsset statusOfValueForKey:@"tracks" error:&error];
            if (!tracksStatus == AVKeyValueStatusLoaded)
            {
                return;
            }
            blockSelf.asset = inputAsset;
            [blockSelf processAsset];
            blockSelf = nil;
        });
    }];
}

- (void)processAsset
{
    __unsafe_unretained GPUImageMovieWithAudio *weakSelf = self;
    AVAssetReaderTrackOutput *readerAudioTrackOutput = nil;
    AVAssetReaderTrackOutput *readerVideoTrackOutput = nil;
    BOOL hasAudioTraks = NO;
    BOOL shouldPlayAudio = NO;
    BOOL shouldRecordAudioTrack = NO;
    
    @synchronized(self) {
        NSError *error = nil;
        reader = [AVAssetReader assetReaderWithAsset:self.asset error:&error];
        
        NSMutableDictionary *outputSettings = [NSMutableDictionary dictionary];
        [outputSettings setObject: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]  forKey: (NSString*)kCVPixelBufferPixelFormatTypeKey];
        // Maybe set alwaysCopiesSampleData to NO on iOS 5.0 for faster video decoding
        readerVideoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:[[self.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0] outputSettings:outputSettings];
        [reader addOutput:readerVideoTrackOutput];
        
        NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
        hasAudioTraks = [audioTracks count] > 0;
        shouldPlayAudio = hasAudioTraks && self.playSound;
        shouldRecordAudioTrack = (hasAudioTraks && (weakSelf.audioEncodingTarget != nil));
        
        if (shouldRecordAudioTrack || shouldPlayAudio){
            audioEncodingIsFinished = NO;
            
            // This might need to be extended to handle movies with more than one audio track
            AVAssetTrack* audioTrack = [audioTracks objectAtIndex:0];
            NSDictionary *audioReadSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                               [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
                                               [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                                               [NSNumber numberWithInt:16], AVLinearPCMBitDepthKey,
                                               [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
                                               [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
                                               [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
                                               nil];
            
            readerAudioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:audioReadSettings];
            [reader addOutput:readerAudioTrackOutput];
            
            if (shouldPlayAudio){
                if (audio_queue == nil){
                    audio_queue = dispatch_queue_create("GPUAudioQueue", nil);
                }
                
                if (audioPlayer == nil){
                    audioPlayer = [[GPUImageAudioPlayer alloc] init];
                    [audioPlayer initAudio];
                    [audioPlayer startPlaying];
                }
            }
        }
        
        if (shouldRecordAudioTrack) {
            [self.audioEncodingTarget setShouldInvalidateAudioSampleWhenDone:YES];
        }
        
        if ([reader startReading] == NO)
        {
            NSLog(@"Error reading from file at URL: %@", weakSelf.url);
            return;
        }
    }
    
    if (synchronizedMovieWriter != nil)
    {
        [synchronizedMovieWriter setVideoInputReadyCallback:^BOOL{
            return [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];
        }];
        
        [synchronizedMovieWriter setAudioInputReadyCallback:^BOOL{
            return [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
        }];
        
        [synchronizedMovieWriter enableSynchronizationCallbacks];
    }
    else
    {
        assetStartTime = 0.0;
        while (!shouldStopProcessing && reader.status == AVAssetReaderStatusReading && (!_shouldRepeat || keepLooping))
        {
            [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];
            
            if (shouldPlayAudio && (!audioEncodingIsFinished)){
                
                if (audioPlayer.readyForMoreBytes) {
                    //process next audio sample if the player is ready to receive it
                    [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
                }
                
            } else if (shouldRecordAudioTrack && (!audioEncodingIsFinished)) {
                [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
            }
            
        }
        
        shouldStopProcessing = NO;
        
        if (reader.status == AVAssetWriterStatusCompleted) {
            
            @synchronized(self) {
                [reader cancelReading];
            }
            
            if (keepLooping) {
                reader = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self startProcessing];
                });
            } else {
                [weakSelf endProcessing];
                if ([self.delegate respondsToSelector:@selector(didCompletePlayingMovie)]) {
                    [self.delegate didCompletePlayingMovie];
                }
            }
            
        }
    }
}

- (BOOL)readNextVideoFrameFromOutput:(AVAssetReaderTrackOutput *)readerVideoTrackOutput;
{
    CMSampleBufferRef sampleBufferRef;
    AVAssetReaderStatus readerStatus;
    @synchronized(self) {
        readerStatus = reader.status;
        if (readerStatus == AVAssetReaderStatusReading) {
            sampleBufferRef = [readerVideoTrackOutput copyNextSampleBuffer];
        }
    }
    
    if (readerStatus == AVAssetReaderStatusReading)
    {
        if (sampleBufferRef)
        {
            BOOL renderVideoFrame = YES;
            
            if (_playAtActualSpeed)
            {
                // Do this outside of the video processing queue to not slow that down while waiting
                CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef);
                CFAbsoluteTime currentActualTime = CFAbsoluteTimeGetCurrent();
                if (assetStartTime == 0){
                    assetStartTime = currentActualTime;
                }
                
                CGFloat delay = (currentSampleTime.value/(float)currentSampleTime.timescale) - (currentActualTime-assetStartTime);
                //                NSLog(@"currentSampleTime: %f, currentTime: %f, delay: %f, sleep: %f", currentSampleTime.value/(float)currentSampleTime.timescale, (currentActualTime-assetStartTime), delay, 1000000.0 * fabs(delay));
                
                if (delay > 0.0){
                    usleep(1000000.0 * fabs(delay));
                }else if (delay < 0){
                    renderVideoFrame = NO;
                }
            }
            
            if (renderVideoFrame){
                __unsafe_unretained GPUImageMovieWithAudio *weakSelf = self;
                runSynchronouslyOnVideoProcessingQueue(^{
                    [weakSelf processMovieFrame:sampleBufferRef];
                });
            }
            
            CMSampleBufferInvalidate(sampleBufferRef);
            CFRelease(sampleBufferRef);
            
            return YES;
        }
        else
        {
            if (!keepLooping) {
                videoEncodingIsFinished = YES;
                [self endProcessing];
            }
        }
    }
    else if (synchronizedMovieWriter != nil)
    {
        if (reader.status == AVAssetWriterStatusCompleted)
        {
            [self endProcessing];
        }
    }
    
    return NO;
}

- (BOOL)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput {
    if (audioEncodingIsFinished && !self.playSound) {
        return NO;
    }
    
    if (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef audioSampleBufferRef;
        @synchronized(self) {
            audioSampleBufferRef = [readerAudioTrackOutput copyNextSampleBuffer];
        }
        
        if (audioSampleBufferRef) {
            
            if (self.playSound){
                CFRetain(audioSampleBufferRef);
                dispatch_async(audio_queue, ^{
                    [audioPlayer copyBuffer:audioSampleBufferRef];
                    
                    CFRelease(audioSampleBufferRef);
                });
                
            } else if (self.audioEncodingTarget != nil && !audioEncodingIsFinished){
                [self.audioEncodingTarget processAudioBuffer:audioSampleBufferRef];
            }
            
            CFRelease(audioSampleBufferRef);
            
            return YES;
        } else {
            audioEncodingIsFinished = YES;
        }
    }
    
    return NO;
}

- (void)processMovieFrame:(CMSampleBufferRef)movieSampleBuffer;
{
    CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(movieSampleBuffer);
    CVImageBufferRef movieFrame = CMSampleBufferGetImageBuffer(movieSampleBuffer);
    
    int bufferHeight = CVPixelBufferGetHeight(movieFrame);
#if TARGET_IPHONE_SIMULATOR
    int bufferWidth = CVPixelBufferGetBytesPerRow(movieFrame) / 4; // This works around certain movie frame types on the Simulator (see https://github.com/BradLarson/GPUImage/issues/424)
#else
    int bufferWidth = CVPixelBufferGetWidth(movieFrame);
#endif
    
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    
    if ([GPUImageContext supportsFastTextureUpload])
    {
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        [GPUImageContext useImageProcessingContext];
        CVOpenGLESTextureRef texture = NULL;
        CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                    coreVideoTextureCache,
                                                                    movieFrame,
                                                                    NULL,
                                                                    GL_TEXTURE_2D,
                                                                    self.outputTextureOptions.internalFormat,
                                                                    bufferWidth,
                                                                    bufferHeight,
                                                                    self.outputTextureOptions.format,
                                                                    self.outputTextureOptions.type,
                                                                    0,
                                                                    &texture);
        
        if (!texture || err) {
            NSLog(@"Movie CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
            return;
        }
        
        outputTexture = CVOpenGLESTextureGetName(texture);
        //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, self.outputTextureOptions.minFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, self.outputTextureOptions.magFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, self.outputTextureOptions.wrapS);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, self.outputTextureOptions.wrapT);
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:targetTextureIndex];
            [currentTarget setInputTexture:outputTexture atIndex:targetTextureIndex];
            [currentTarget setTextureDelegate:self atIndex:targetTextureIndex];
            
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
        
        // Flush the CVOpenGLESTexture cache and release the texture
        CVOpenGLESTextureCacheFlush(coreVideoTextureCache, 0);
        CFRelease(texture);
        outputTexture = 0;
    }
    else
    {
        // Upload to texture
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        // Using BGRA extension to pull in video frame data directly
        glTexImage2D(GL_TEXTURE_2D,
                     0,
                     self.outputTextureOptions.internalFormat,
                     bufferWidth,
                     bufferHeight,
                     0,
                     self.outputTextureOptions.format,
                     self.outputTextureOptions.type,
                     CVPixelBufferGetBaseAddress(movieFrame));
        
        CGSize currentSize = CGSizeMake(bufferWidth, bufferHeight);
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            [currentTarget setInputSize:currentSize atIndex:targetTextureIndex];
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
    }
    
    if (_runBenchmark)
    {
        CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
        NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
    }
    
    if (!processedFirstFrame && !processingStopped && self.delegate && [self.delegate respondsToSelector:@selector(didProcessFirstFrame)]) {
        processedFirstFrame = YES;
        [self.delegate didProcessFirstFrame];
    }
}

- (void)endProcessing;
{
    processingStopped = YES;
    
    processedFirstFrame = NO;
    
    keepLooping = NO;
    
    for (id<GPUImageInput> currentTarget in targets)
    {
        [currentTarget endProcessing];
    }
    
    if (synchronizedMovieWriter != nil)
    {
        [synchronizedMovieWriter setVideoInputReadyCallback:^BOOL{
            return NO;
        }];
        [synchronizedMovieWriter setAudioInputReadyCallback:^BOOL{
            return NO;
        }];
    }
    
    if (audioPlayer != nil){
        [audioPlayer stopPlaying];
        audioPlayer = nil;
    }
    
    shouldStopProcessing = YES;
}

- (void)cancelProcessing
{
    @synchronized(self) {
        if (reader) {
            [reader cancelReading];
        }
        [self endProcessing];
    }
}

@end
