#import "music_loudness.h"
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdatomic.h>
#import <objc/runtime.h>

static double PeakDBFSFromLinear(double pk) {
    if (pk <= 0) return -INFINITY;
    return 20.0 * log10(pk);
}

BOOL GBMeasureLoudnessAtURL(NSURL *url, double *lufsOut, double *peakDBFSOut, NSError **errorOut) {
    if (!url.isFileURL) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"GBLoudness" code:1 userInfo:@{NSLocalizedDescriptionKey: @"not a file URL"}];
        return NO;
    }
    NSDictionary *opts = @{AVURLAssetPreferPreciseDurationAndTimingKey: @NO};
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:opts];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!tracks.count) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"GBLoudness" code:2 userInfo:@{NSLocalizedDescriptionKey: @"no audio track"}];
        return NO;
    }
    AVAssetTrack *track = tracks.firstObject;
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        if (errorOut) *errorOut = err;
        return NO;
    }
    AudioStreamBasicDescription asbd = {0};
    CMFormatDescriptionRef fmt = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    if (fmt) asbd = *CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    double sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000;
    NSDictionary *out = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
        AVSampleRateKey: @(sampleRate),
        AVNumberOfChannelsKey: @2,
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:out];
  output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"GBLoudness" code:3 userInfo:@{NSLocalizedDescriptionKey: @"cannot add output"}];
        return NO;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        if (errorOut) *errorOut = reader.error;
        return NO;
    }
    GBLoudnessMeter meter;
    GBLoudnessMeterInit(&meter, sampleRate);
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef buf = [output copyNextSampleBuffer];
        if (!buf) break;
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buf);
        size_t contiguous = 0, length = 0;
        char *data = NULL;
        if (block && CMBlockBufferGetDataPointer(block, 0, &contiguous, &length, &data) == kCMBlockBufferNoErr && data) {
            if (contiguous < length) {   // a buffer in several pieces: copy it whole, don't measure the first piece only
                NSMutableData *whole = [NSMutableData dataWithLength:length];
                if (CMBlockBufferCopyDataBytes(block, 0, length, whole.mutableBytes) == kCMBlockBufferNoErr)
                    GBLoudnessMeterFeed(&meter, (const float *)whole.bytes, (UInt32)(length / (sizeof(float) * 2)));
            } else {
                GBLoudnessMeterFeed(&meter, (const float *)data, (UInt32)(length / (sizeof(float) * 2)));
            }
        }
        CFRelease(buf);
    }
    BOOL saw = meter.sawSignal;
    double lufs = GBLoudnessMeterFinish(&meter);
    double peak = PeakDBFSFromLinear(meter.peakLinear);
    GBLoudnessMeterFree(&meter);
    if (lufsOut) *lufsOut = lufs;
    if (peakDBFSOut) *peakDBFSOut = peak;
    if (reader.status == AVAssetReaderStatusFailed && errorOut) *errorOut = reader.error;
    return saw;
}

typedef struct {
    _Atomic int refs;
    _Atomic float targetLinear;
    float currentLinear;
    double sampleRate;
    GBLoudnessLimiter limiter;
} GBLoudnessTapState;

static void TapStateRelease(GBLoudnessTapState *st) {
    if (st && atomic_fetch_sub(&st->refs, 1) == 1) free(st);
}

@implementation GBLoudnessHandle {
@public
    GBLoudnessTapState *_state;
}
- (void)setTargetLinear:(float)gainLinear {
    if (_state) atomic_store(&_state->targetLinear, gainLinear > 0 ? gainLinear : 1.f);
}
- (void)dealloc { TapStateRelease(_state); }
@end

static void LoudnessTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    (void)tap;
    *tapStorageOut = clientInfo;   // the reference taken for the tap in GBLoudnessAttachToPlayerItem
}

static void LoudnessTapFinalize(MTAudioProcessingTapRef tap) {
    TapStateRelease((GBLoudnessTapState *)MTAudioProcessingTapGetStorage(tap));
}

static void LoudnessTapPrepare(MTAudioProcessingTapRef tap, CMItemCount __unused maxFrames,
                               const AudioStreamBasicDescription *processingFormat) {
    GBLoudnessTapState *st = (GBLoudnessTapState *)MTAudioProcessingTapGetStorage(tap);
    if (!st) return;
    st->sampleRate = processingFormat->mSampleRate > 0 ? processingFormat->mSampleRate : 48000;
    GBLoudnessLimiterInit(&st->limiter, st->sampleRate, -1.0, 150.0);
    st->currentLinear = atomic_load(&st->targetLinear);
}

static void LoudnessTapUnprepare(MTAudioProcessingTapRef tap) { (void)tap; }

// Real-time: no Objective-C, no locks, no allocation.
static void LoudnessTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                               MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                               CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    OSStatus err = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (err != noErr) return;
    GBLoudnessTapState *st = (GBLoudnessTapState *)MTAudioProcessingTapGetStorage(tap);
    if (!st || !bufferListInOut->mNumberBuffers) return;
    UInt32 frames = (UInt32)(*numberFramesOut);
    float target = atomic_load(&st->targetLinear);
    if (target == 1.f && st->currentLinear == 1.f && st->limiter.env >= 1.f) return;   // unity: untouched
    AudioBuffer *b0 = &bufferListInOut->mBuffers[0];
    if (!b0->mData) return;
    if (bufferListInOut->mNumberBuffers >= 2) {
        AudioBuffer *b1 = &bufferListInOut->mBuffers[1];
        if (!b1->mData) return;
        GBLoudnessProcess((float *)b0->mData, (float *)b1->mData, 1, frames, &st->currentLinear,
                          target, 2.0, st->sampleRate, &st->limiter);
    } else if (b0->mNumberChannels >= 2) {
        float *pcm = (float *)b0->mData;
        GBLoudnessProcess(pcm, pcm + 1, b0->mNumberChannels, frames, &st->currentLinear,
                          target, 2.0, st->sampleRate, &st->limiter);
    } else {
        float *pcm = (float *)b0->mData;
        GBLoudnessProcess(pcm, pcm, 1, frames, &st->currentLinear, target, 2.0, st->sampleRate, &st->limiter);
    }
}

static char kLoudnessHandleKey;

GBLoudnessHandle *GBLoudnessHandleForItem(AVPlayerItem *item) {
    return item ? objc_getAssociatedObject(item, &kLoudnessHandleKey) : nil;
}

GBLoudnessHandle *GBLoudnessAttachToPlayerItem(AVPlayerItem *item, float gainLinear) {
    if (!item) return nil;
    AVAssetTrack *track = [item.asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return nil;
    GBLoudnessTapState *st = calloc(1, sizeof(GBLoudnessTapState));
    if (!st) return nil;
    float g = gainLinear > 0 ? gainLinear : 1.f;
    atomic_store(&st->refs, 2);   // one for the tap, one for the handle
    atomic_store(&st->targetLinear, g);
    st->currentLinear = g;
    GBLoudnessLimiterInit(&st->limiter, 44100, -1.0, 150.0);
    GBLoudnessHandle *handle = [GBLoudnessHandle new];
    handle->_state = st;
    MTAudioProcessingTapCallbacks cb = {
        .version = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = st,
        .init = LoudnessTapInit,
        .finalize = LoudnessTapFinalize,
        .prepare = LoudnessTapPrepare,
        .unprepare = LoudnessTapUnprepare,
        .process = LoudnessTapProcess,
    };
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) != noErr || !tap) {
        TapStateRelease(st);   // the tap's reference; the handle's goes with the handle
        return nil;
    }
    AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    params.audioTapProcessor = tap;
    CFRelease(tap);
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;
    objc_setAssociatedObject(item, &kLoudnessHandleKey, handle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return handle;
}
