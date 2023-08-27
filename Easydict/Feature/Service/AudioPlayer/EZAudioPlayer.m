//
//  EZAudioPlayer.m
//  Easydict
//
//  Created by tisfeng on 2022/12/13.
//  Copyright © 2022 izual. All rights reserved.
//

#import "EZAudioPlayer.h"
#import "EZAppleService.h"
#import <AVFoundation/AVFoundation.h>
#import "EZQueryService.h"
#import "EZEnumTypes.h"
#import "EZBaiduTranslate.h"
#import "EZGoogleTranslate.h"
#import "EZTextWordUtils.h"
#import "EZServiceTypes.h"
#import "EZConfiguration.h"
#import <sys/xattr.h>


static NSString *const kFileExtendedAttributes = @"NSFileExtendedAttributes";

// kMDItemWhereFroms
static NSString *const kItemWhereFroms = @"com.apple.metadata:kMDItemWhereFroms";

@interface EZAudioPlayer () <NSSpeechSynthesizerDelegate>

@property (nonatomic, strong) EZAppleService *appleService;
@property (nonatomic, strong) NSSpeechSynthesizer *synthesizer;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *playerItem;

@property (nonatomic, assign) BOOL isPlaying;

@property (nonatomic, strong) EZQueryService *defaultTTSService;

@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) EZLanguage language;
@property (nonatomic, copy) NSString *audioURL;
@property (nonatomic, copy, nullable) NSString *accent;
@property (nonatomic, copy, nonnull) EZServiceType serviceType;

@end

@implementation EZAudioPlayer

@synthesize isPlaying = _isPlaying;

+ (instancetype)shared {
    static EZAudioPlayer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[EZAudioPlayer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.useSystemTTSWhenPlayFailed = YES;
    
    // KVO timeControlStatus is not a good choice
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFinishPlaying:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFinishPlaying:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFinishPlaying:)
                                                 name:AVPlayerItemPlaybackStalledNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFinishPlaying:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:nil];
}

- (void)didFinishPlaying:(NSNotification *)notification {
    AVPlayerItem *playerItem = notification.object;
    if (self.player.currentItem == playerItem) {
        self.isPlaying = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark - Getter

- (EZAppleService *)appleService {
    if (!_appleService) {
        _appleService = [[EZAppleService alloc] init];
    }
    return _appleService;
}

- (AVPlayer *)player {
    if (!_player) {
        _player = [[AVPlayer alloc] init];
    }
    return _player;
}

- (void)setIsPlaying:(BOOL)playing {
    _isPlaying = playing;
    
    if (self.playingBlock) {
        self.playingBlock(playing);
    }
}

// Note that user may change it when using, so we need to read it every time.
- (EZQueryService *)defaultTTSService {
    EZServiceType defaultTTSServiceType = EZConfiguration.shared.defaultTTSServiceType;;
    EZQueryService *ttsService = [EZServiceTypes.shared serviceWithType:defaultTTSServiceType];
    _defaultTTSService = ttsService;
    _defaultTTSService.audioPlayer = self;
    
    if (defaultTTSServiceType == EZServiceTypeApple) {
        self.appleService = (EZAppleService *)ttsService;
    }
    
    return _defaultTTSService;
}

- (EZQueryService *)service {
    if (!_service) {
        _service = self.defaultTTSService;
    }
    return _service;
}


#pragma mark - Public Mehods

- (void)playWordPhonetic:(EZWordPhonetic *)wordPhonetic serviceType:(nullable EZServiceType)serviceType {
    [self playTextAudio:wordPhonetic.word
               language:wordPhonetic.language
                 accent:wordPhonetic.accent
               audioURL:wordPhonetic.speakURL
      designatedService:nil];
}

// TODO: need to optimize
- (void)playTextAudio:(NSString *)text textLanguage:(EZLanguage)language {
    [self playTextAudio:text
               language:language
                 accent:nil
               audioURL:nil
      designatedService:nil];
}

/// Play text audio.
- (void)playTextAudio:(NSString *)text
             language:(EZLanguage)language
               accent:(nullable NSString *)accent
             audioURL:(nullable NSString *)audioURL
    designatedService:(nullable EZQueryService *)designatedService {
    if (!text.length) {
        NSLog(@"play text is empty");
        return;
    }
    
    self.isPlaying = YES;
    self.serviceType = designatedService.serviceType ?: self.service.serviceType;
    
    self.text = text;
    self.language = language;
    self.audioURL = audioURL;
    self.accent = accent;
    
    BOOL isEnglishWord = [language isEqualToString:EZLanguageEnglish] && ([EZTextWordUtils isEnglishWord:text]);
    self.enableDownload = isEnglishWord;
    
    // 1. if has audio url, play audio url directly.
    if (audioURL.length) {
        [self playAudioURL:audioURL
                      text:text
                  language:language
                    accent:accent
               serviceType:self.serviceType];
        return;
    }
    
    // 2. if service type is Apple, use system speech.
    if (self.serviceType == EZServiceTypeApple) {
        [self playSystemTextAudio:text language:language];
        return;
    }
    
    EZQueryService *service = designatedService ?: self.service;
    
    // 3. get service text audio URL, and play.
    [service textToAudio:text fromLanguage:language completion:^(NSString *_Nullable url, NSError *_Nullable error) {
        if (!error && url.length) {
            [self playTextAudio:text
                       language:language
                         accent:nil
                       audioURL:url
              designatedService:nil];
        } else {
            NSLog(@"get audio url error: %@", error);
            
            // e.g. if Baidu get audio url failed, try to use default tts, such as Google.
            [self playWithDefaultTTSService];
        }
    }];
}


- (void)stop {
//    NSLog(@"stop play");
    
    // !!!: This method won't post play end notification.
    [_player pause];
    
    // It wiil call delegate.
    [_synthesizer stopSpeaking];
    
    self.isPlaying = NO;
}


#pragma mark - NSSpeechSynthesizerDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking {
    self.isPlaying = NO;
}


#pragma mark -

/// Play system text audio.
- (void)playSystemTextAudio:(NSString *)text language:(EZLanguage)language {
    NSSpeechSynthesizer *synthesizer = [self.appleService playTextAudio:text fromLanguage:language];
    synthesizer.delegate = self;
    self.synthesizer = synthesizer;
    self.isPlaying = YES;
}

/// Play audio URL.
- (void)playAudioURL:(NSString *)audioURLString
                text:(NSString *)text
            language:(EZLanguage)language
              accent:(nullable NSString *)accent
         serviceType:(EZServiceType)serviceType {
    if (audioURLString.length == 0) {
        NSLog(@"play audio url is empty");
        return;
    }
    
    [self.player pause];
        
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // For English words, Youdao TTS is better than other services, so we try to play Youdao local audio first.
    
    // Currently, only enable to download English word audio.
    BOOL isEnglishWord = self.enableDownload;
    if (isEnglishWord) {
        NSString *youdaoAudioFilePath = [self getWordAudioFilePath:text
                                                          language:language
                                                            accent:accent
                                                       serviceType:EZServiceTypeYoudao];
        
        if ([fileManager fileExistsAtPath:youdaoAudioFilePath]) {
            [self playLocalAudioFile:youdaoAudioFilePath];
            return;
        }
    }
    

    // If audio url is a local file url
    if ([fileManager fileExistsAtPath:audioURLString]) {
        [self playLocalAudioFile:audioURLString];
        return;
    }
    
    NSString *audioFilePath = [self getWordAudioFilePath:text
                                           language:language
                                             accent:accent
                                        serviceType:serviceType];
    
    // If audio file exist, play it.
    if ([fileManager fileExistsAtPath:audioFilePath]) {
        [self playLocalAudioFile:audioFilePath];
        return;
    }
    
    NSLog(@"play remote audio url: %@", audioURLString);

    // Since some of Youdao's audio cannot be played directly, it needs to be downloaded first, such as 'set'.
    BOOL download = self.enableDownload;
    
    if (download) {
        NSURL *URL = [NSURL URLWithString:audioURLString];
        [self downloadWordAudio:text
                       audioURL:URL
                       autoPlay:YES
                       language:language
                         accent:accent
                    serviceType:serviceType];
    } else {
        [self playRemoteAudio:audioURLString];
    }
}

/// Download word audio file.
- (void)downloadWordAudio:(NSString *)word
                 audioURL:(NSURL *)URL
                 autoPlay:(BOOL)autoPlay
                 language:(EZLanguage)language
                   accent:(nullable NSString *)accent
              serviceType:(EZServiceType)serviceType {
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        NSString *filePath = [self getWordAudioFilePath:word
                                               language:language
                                                 accent:accent
                                            serviceType:serviceType];
        return [NSURL fileURLWithPath:filePath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        NSLog(@"Download file to: %@", filePath);
        if (autoPlay) {
            [self playLocalAudioFile:filePath.path];
        }
//        [self testFileInfo:filePath.path];
    }];
    [downloadTask resume];
}

- (void)testFileInfo:(NSString *)filePath {
    NSURL *fileURL = [NSURL fileURLWithPath:@"/Users/tisfeng/Downloads/reader-ios-master.zip"];
    NSArray *URLs = [self getDownloadSourcesForFilePath:fileURL.path];
    
    NSArray *urls = @[
        @"https://github.com/yuenov/reader-ios",
        @"https://codeload.github.com/yuenov/reader-ios/zip/refs/heads/master",
    ];

    [self setDownloadSourceForFilePath:filePath sourceURLs:urls];
    URLs = [self getDownloadSourcesForFilePath:filePath];
    NSLog(@"URLs: %@", URLs);

}

/// Play local audio file
- (void)playLocalAudioFile:(NSString *)filePath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        self.isPlaying = NO;
        NSLog(@"playLocalAudioFile not exist: %@", filePath);
        return;
    }
    NSLog(@"play local audio file: %@", filePath);
    
    NSURL *URL = [NSURL fileURLWithPath:filePath];
    [self playAudioURL:URL];
}

/// Play audio with remote url string.
- (void)playRemoteAudio:(NSString *)urlString {
    if (!urlString.length) {
        return;
    }
    
    // TODO: maybe we need to pre-load audio url, then play when user click.
    
    NSURL *URL = [NSURL URLWithString:urlString];
    [self loadAudioURL:URL completion:^(AVAsset *_Nullable asset) {
        if (asset) {
            AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
            [self playWithPlayerItem:playerItem];
        } else {
            [self playWithDefaultTTSService];
        }
    }];
}


/// Play audio with NSURL
- (void)playAudioURL:(NSURL *)URL {
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:URL];
    [self playWithPlayerItem:playerItem];
}

- (void)playWithPlayerItem:(AVPlayerItem *)playerItem {
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:playerItem];
    [self.player play];
}

- (void)play {
    NSURL *URL = [NSURL URLWithString:self.audioURL];
    [self playAudioURL:URL];
}

- (void)playWithDefaultTTSService {
    NSLog(@"playWithDefaultTTSService");
    
    EZAudioPlayer *audioPlayer = self.service.audioPlayer;
    if (![audioPlayer.service.class isEqual:audioPlayer.defaultTTSService.class]) {
        EZAudioPlayer *defaultTTSAudioPlayer = audioPlayer.defaultTTSService.audioPlayer;
        [defaultTTSAudioPlayer playTextAudio:self.text
                                    language:self.language
                                      accent:self.accent
                                    audioURL:nil
                           designatedService:defaultTTSAudioPlayer.defaultTTSService];
    } else {
        if (self.useSystemTTSWhenPlayFailed) {
            [self playSystemTextAudio:self.text language:self.language];
        }
    }
}

- (void)loadAudioURL:(NSURL *)URL completion:(void (^)(AVAsset *_Nullable asset))completion {
    if ([URL isFileURL]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:URL.path]) {
            AVAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
            completion(asset);
        } else {
            completion(nil);
        }
        return;
    }
    
    // Check URL is valid
    if (!URL || !URL.scheme || !URL.host) {
        NSLog(@"audio url is invalid: %@", URL);
        completion(nil);
        return;
    }
    
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
    NSArray *resourceKeys = @[ @"playable" ];
    [asset loadValuesAsynchronouslyForKeys:resourceKeys completionHandler:^{
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:@"playable" error:&error];
        
        BOOL isPlayable = NO;
        if (status == AVKeyValueStatusLoaded) {
            if (asset.isPlayable) {
                isPlayable = YES;
            }
        } else {
            NSLog(@"load playable failed: %@", [error localizedDescription]);
        }
        NSLog(@"audio url isPlayable: %d", isPlayable);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (isPlayable) {
                completion(asset);
            } else {
                completion(nil);
            }
        });
    }];
}


#pragma mark -

// Get app cache directory
- (NSString *)getCacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths objectAtIndex:0];
}

// Get audio file directory, if not exist, create it.
- (NSString *)getAudioDirectory {
    NSString *cachesDirectory = [self getCacheDirectory];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSString *audioDirectory = [cachesDirectory stringByAppendingPathComponent:bundleID];
    audioDirectory = [audioDirectory stringByAppendingPathComponent:@"audio"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:audioDirectory]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:audioDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return audioDirectory;
}

// Get word audio file path
- (NSString *)getWordAudioFilePath:(NSString *)word
                          language:(EZLanguage)language
                            accent:(nullable NSString *)accent
                       serviceType:(EZServiceType)serviceType {
    NSString *audioDirectory = [self getAudioDirectory];
    
    // Avoid special characters in file name.
    word = [word md5];
    NSString *textLanguage = language;
    if ([language isEqualToString:EZLanguageEnglish] && !accent) {
        accent = @"us";
    }
    
    if (accent.length) {
        textLanguage = [textLanguage stringByAppendingFormat:@"-%@", accent];
    }
    
    NSString *audioFileName = [NSString stringWithFormat:@"%@_%@_%@", serviceType, textLanguage, word];
    
    /**
     TODO: maybe we should check the downloaded audio file type, some of them are not mp3, though the suggested extension is mp3, also can be played, but the file will 10x larger than m4a if we save it as mp3.
     
     e.g. 'set' from Youdao.
     */
    
    // m4a
    NSString *m4aFilePath = [audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", audioFileName]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:m4aFilePath]) {
        return m4aFilePath;
    }
    
    // mp3
    NSString *mp3FilePath = [audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp3", audioFileName]];
    return mp3FilePath;
}

- (BOOL)isAudioFilePlayable:(NSURL *)filePathURL {
    OSStatus status;
    AudioFileID audioFile;
    AudioFileTypeID fileType;
    
    NSLog(@"kAudioFileWAVEType: %d", kAudioFileWAVEType);
    
    status = AudioFileOpenURL((__bridge CFURLRef)filePathURL, kAudioFileReadPermission, 0, &audioFile);
    if (status == noErr) {
        UInt32 size = sizeof(fileType);
        status = AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &fileType);
        if (status == noErr) {
            if (fileType == kAudioFileAAC_ADTSType) {
                NSLog(@"Audio file is of type: AAC ADTS");
            } else if (fileType == kAudioFileAIFFType) {
                NSLog(@"Audio file is of type: AIFF");
            } else if (fileType == kAudioFileCAFType) {
                NSLog(@"Audio file is of type: CAF");
            } else if (fileType == kAudioFileMP3Type) {
                NSLog(@"Audio file is of type: MP3");
            } else if (fileType == kAudioFileMPEG4Type) {
                NSLog(@"Audio file is of type: MP4");
            } else if (fileType == kAudioFileWAVEType) {
                NSLog(@"Audio file is of type: WAVE");
            } else {
                NSLog(@"Audio file is of an unknown type");
            }
        } else {
            NSLog(@"Error getting audio file property: %d", (int)status);
            return NO;
        }
    } else {
        NSLog(@"Error opening audio file type: %d", (int)status);
        return NO;
    }
    return YES;
}

#pragma mark - Get file download sources

- (nullable NSArray<NSString *> *)getDownloadSourcesForFilePath:(NSString *)filePath {
    NSError *error = nil;
    
    // Ref: https://stackoverflow.com/questions/61778159/swift-how-to-get-an-image-where-from-metadata-field
    
    // 获取文件属性
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
    if (error) {
        NSLog(@"Error getting file attributes: %@", error);
        return nil;
    }
    
    // 从文件属性中获取扩展属性
    NSDictionary *fileExtendedAttributes = attrs[kFileExtendedAttributes];
    NSData *itemWhereFroms = fileExtendedAttributes[kItemWhereFroms];
    
    if (!itemWhereFroms) {
        return nil;
    }
    
    NSString *itemWhereFromsString = [[NSString alloc] initWithData:itemWhereFroms encoding:NSASCIIStringEncoding];
    // bplist00¢_Chttps://codeload.github.com/yuenov/reader-ios/zip/refs/heads/master_$https://github.com/yuenov/reader-iosQ
    NSLog(@"itemWhereFromsString: %@", itemWhereFromsString);
    
    // 解析属性列表数据
    NSError *plistError = nil;
    NSPropertyListFormat format;
    id plistData = [NSPropertyListSerialization propertyListWithData:itemWhereFroms options:NSPropertyListImmutable format:&format error:&plistError];
    
    if (plistError) {
        NSLog(@"Error decoding property list: %@", plistError);
        return nil;
    }
    
    NSMutableArray *urls = [NSMutableArray array];
    
    if ([plistData isKindOfClass:[NSArray class]]) {
        for (NSString *urlString in (NSArray *)plistData) {
            [urls addObject:urlString];
        }
    }
    
    return [urls copy];
}

// ???: Why does not it work?
- (void)setDownloadSourceForFilePath:(NSString *)filePath sourceURLs:(NSArray<NSString *> *)URLStrings {
    NSError *error;
    NSData *URLsData = [NSPropertyListSerialization dataWithPropertyList:URLStrings format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];

    if (URLsData) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSMutableDictionary *attrs = [[fileManager attributesOfItemAtPath:filePath error:nil] mutableCopy];
        if (!attrs) {
            attrs = [NSMutableDictionary dictionary];
        }
        
        NSMutableDictionary *extendedAttributes = [attrs[kFileExtendedAttributes] mutableCopy];
        if (!extendedAttributes) {
            extendedAttributes = [NSMutableDictionary dictionary];
        }
        extendedAttributes[kItemWhereFroms] = URLsData;
        attrs[kFileExtendedAttributes] = @{kItemWhereFroms: URLsData};
        
        if (![fileManager setAttributes:attrs ofItemAtPath:filePath error:&error]) {
            NSLog(@"Error setting download source: %@", error);
        }
        
        // Set the extended attribute using setxattr
        int result = setxattr(filePath.UTF8String, kItemWhereFroms.UTF8String, [URLsData bytes], [URLsData length], 0, 0);
        
        if (result == 0) {
            NSLog(@"Download source set successfully.");
        } else {
            NSLog(@"Error setting download source: %s", strerror(errno));
        }
    }
}

@end
