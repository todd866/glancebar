#import "nowplaying.h"
#import <MediaPlayer/MediaPlayer.h>

void GlanceNowPlayingSet(NSString *title, NSString *artist, double rate, double elapsed) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (title.length) info[MPMediaItemPropertyTitle] = title;
    if (artist.length) info[MPMediaItemPropertyArtist] = artist;
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(rate);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

void GlanceNowPlayingClear(void) {
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
}

void GlanceRemoteCommandsEnable(id target) {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    center.playCommand.enabled = YES;
    center.pauseCommand.enabled = YES;
    center.togglePlayPauseCommand.enabled = YES;
    center.nextTrackCommand.enabled = YES;
    center.previousTrackCommand.enabled = YES;
    [center.playCommand addTarget:target action:@selector(remotePlay:)];
    [center.pauseCommand addTarget:target action:@selector(remotePause:)];
    [center.togglePlayPauseCommand addTarget:target action:@selector(remoteToggle:)];
    [center.nextTrackCommand addTarget:target action:@selector(remoteNext:)];
    [center.previousTrackCommand addTarget:target action:@selector(remotePrevious:)];
}

void GlanceRemoteCommandsDisable(id target) {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    [center.playCommand removeTarget:target];
    [center.pauseCommand removeTarget:target];
    [center.togglePlayPauseCommand removeTarget:target];
    [center.nextTrackCommand removeTarget:target];
    [center.previousTrackCommand removeTarget:target];
    GlanceNowPlayingClear();
}
