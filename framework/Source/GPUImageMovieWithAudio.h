#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "GPUImageContext.h"
#import "GPUImageOutput.h"

/** Protocol for getting Movie played callback.
 */
@protocol GPUImageMovieWithAudioDelegate <NSObject>

- (void)didCompletePlayingMovie;
- (void)didProcessFirstFrame;
@end

/** Source object for filtering movies
 */
@interface GPUImageMovieWithAudio : GPUImageOutput

@property (readwrite, retain) AVAsset *asset;
@property(readwrite, retain) NSURL *url;

/** This enables the benchmarking mode, which logs out instantaneous and average frame times to the console
 */
@property(readwrite, nonatomic) BOOL runBenchmark;

/** This determines whether to play back a movie as fast as the frames can be processed, or if the original speed of the movie should be respected. Defaults to NO.
 */
@property(readwrite, nonatomic) BOOL playAtActualSpeed;

/** This determines whether the video should repeat (loop) at the end and restart from the beginning. Defaults to NO.
 */
@property(readwrite, nonatomic) BOOL shouldRepeat;


/** This determines whether audio should be played. Cann't be set to work with video writing. Defaults to NO.
 */
@property(readwrite, nonatomic) BOOL playSound;


/** This is used to send the delete Movie did complete playing alert
 */
@property (readwrite, nonatomic, assign) id <GPUImageMovieWithAudioDelegate>delegate;

/// @name Initialization and teardown
- (id)initWithAsset:(AVAsset *)asset;
- (id)initWithURL:(NSURL *)url;
- (void)textureCacheSetup;

/// @name Movie processing
- (void)enableSynchronizedEncodingUsingMovieWriter:(GPUImageMovieWriter *)movieWriter;
- (BOOL)readNextVideoFrameFromOutput:(AVAssetReaderTrackOutput *)readerVideoTrackOutput;
- (BOOL)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput;
- (void)startProcessing;
- (void)endProcessing;
- (void)cancelProcessing;
- (void)processMovieFrame:(CMSampleBufferRef)movieSampleBuffer;

- (void)releaseResources;

@end