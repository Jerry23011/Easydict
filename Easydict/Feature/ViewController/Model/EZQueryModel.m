//
//  EZQueryModel.m
//  Easydict
//
//  Created by tisfeng on 2022/11/21.
//  Copyright © 2022 izual. All rights reserved.
//

#import "EZQueryModel.h"
#import "EZConfiguration.h"
#import <KVOController/NSObject+FBKVOController.h>
#import "NSString+EZUtils.h"
#import "NSString+EZSplit.h"
#import "EZAppleDictionary.h"
#import "NSString+EZHandleInputText.h"

@interface EZQueryModel ()

@property (nonatomic, copy) NSString *queryText;

@property (nonatomic, strong) NSMutableDictionary *stopBlockDictionary; // <serviceType : block>

@end

@implementation EZQueryModel

@synthesize needDetectLanguage = _needDetectLanguage;
@synthesize detectedLanguage = _detectedLanguage;

- (instancetype)init {
    if (self = [super init]) {
        [self.KVOController observe:EZConfiguration.shared keyPath:@"from" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew block:^(EZQueryModel *queryModel, EZConfiguration *config, NSDictionary<NSString *, id> *_Nonnull change) {
            queryModel.userSourceLanguage = change[NSKeyValueChangeNewKey];
        }];
        [self.KVOController observe:EZConfiguration.shared keyPath:@"to" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew block:^(EZQueryModel *queryModel, EZConfiguration *config, NSDictionary<NSString *, id> *_Nonnull change) {
            queryModel.userTargetLanguage = change[NSKeyValueChangeNewKey];
        }];
        
        self.detectedLanguage = EZLanguageAuto;
        self.actionType = EZActionTypeInputQuery;
        self.stopBlockDictionary = [NSMutableDictionary dictionary];
        self.needDetectLanguage = YES;
        self.showAutoLanguage = NO;
        self.specifiedTextLanguageDict = [NSMutableDictionary dictionary];
        self.autoQuery = YES;
    }
    return self;
}

- (instancetype)copyWithZone:(NSZone *)zone {
    EZQueryModel *model = [[EZQueryModel allocWithZone:zone] init];
    model.actionType = _actionType;
    model.inputText = _inputText;
    model.userSourceLanguage = _userSourceLanguage;
    model.userTargetLanguage = _userTargetLanguage;
    model.detectedLanguage = _detectedLanguage;
    model.OCRImage = _OCRImage;
    model.queryViewHeight = _queryViewHeight;
    model.audioURL = _audioURL;
    model.needDetectLanguage = _needDetectLanguage;
    model.showAutoLanguage = _showAutoLanguage;
    model.specifiedTextLanguageDict = [_specifiedTextLanguageDict mutableCopy];
    model.autoQuery = _autoQuery;
    
    return model;
}

- (void)setInputText:(NSString *)inputText {
    if (![inputText isEqualToString:_inputText]) {
        // TODO: need to optimize, like needDetectLanguage.
        self.audioURL = nil;
        self.needDetectLanguage = YES;
    }
    
    _inputText = [inputText copy];

    if (_inputText.trim.length == 0) {
        _detectedLanguage = EZLanguageAuto;
        _showAutoLanguage = NO;
    }
}

- (void)setActionType:(EZActionType)actionType {
    _actionType = actionType;
    
    if (actionType != EZActionTypeOCRQuery && actionType != EZActionTypeScreenshotOCR) {
        _OCRImage = nil;
    }
}

- (void)setOCRImage:(NSImage *)ocrImage {
    _OCRImage = ocrImage;
    
    if (ocrImage) {
        _actionType = EZActionTypeOCRQuery;
    }
}

- (void)setDetectedLanguage:(EZLanguage)detectedLanguage {
    _detectedLanguage = detectedLanguage;
    
    [self.specifiedTextLanguageDict enumerateKeysAndObjectsUsingBlock:^(NSString *key, EZLanguage language, BOOL *stop) {
        if ([key isEqualToString:self.queryText]) {
            _detectedLanguage = language;
            _needDetectLanguage = NO;
            *stop = YES;
        }
    }];
}

- (void)setNeedDetectLanguage:(BOOL)needDetectLanguage {
    _needDetectLanguage = needDetectLanguage;
    
    if (needDetectLanguage) {
        _showAutoLanguage = NO;
    }
    
    [self setDetectedLanguage:self.detectedLanguage];
}


- (EZLanguage)queryFromLanguage {
    EZLanguage fromLanguage = self.hasUserSourceLanguage ? self.userSourceLanguage : self.detectedLanguage;
    return fromLanguage;
}

- (EZLanguage)queryTargetLanguage {
    EZLanguage fromLanguage = self.queryFromLanguage;
    EZLanguage targetLanguage = self.userTargetLanguage;
    if (!self.hasUserTargetLanguage) {
        targetLanguage = [EZLanguageManager.shared userTargetLanguageWithSourceLanguage:fromLanguage];
    }
    return targetLanguage;
}

- (BOOL)hasQueryFromLanguage {
    return ![self.queryFromLanguage isEqualToString:EZLanguageAuto];
}

- (BOOL)hasUserSourceLanguage {
    BOOL hasUserSourceLanguage = ![self.userSourceLanguage isEqualToString:EZLanguageAuto];
    return hasUserSourceLanguage;
}

- (BOOL)hasUserTargetLanguage {
    BOOL hasUserTargetLanguage = ![self.userTargetLanguage isEqualToString:EZLanguageAuto];
    return hasUserTargetLanguage;
}


#pragma mark - Stop Block

- (void)setStopBlock:(void (^)(void))stopBlock serviceType:(NSString *)type {
    self.stopBlockDictionary[type] = stopBlock;
}

- (void)stopServiceRequest:(NSString *)serviceType {
    void (^stopBlock)(void) = self.stopBlockDictionary[serviceType];
    if (stopBlock) {
        stopBlock();
        [self.stopBlockDictionary removeObjectForKey:serviceType];
    }
}

- (BOOL)isServiceStopped:(NSString *)serviceType {
    return self.stopBlockDictionary[serviceType] == nil;
}

- (void)stopAllService {
    for (NSString *key in self.stopBlockDictionary.allKeys) {
        [self stopServiceRequest:key];
    }
}


#pragma mark - Handle Input text

- (NSString *)handleInputText:(NSString *)inputText {
    NSString *queryText = [inputText trim];
    
    /**
     Split camel and snake case text
     https://github.com/tisfeng/Easydict/issues/135#issuecomment-1750498120
     
     _anchoredDraggable_State --> anchored Draggable State
     */
    if ([queryText isSingleWord]) {
        // If text is an English word, like LaTeX, we don't split it.
        BOOL isEnglishWord = [EZAppleDictionary.shared queryDictionaryForText:queryText language:EZLanguageEnglish];
        if (!isEnglishWord) {
            // If text has quotes, like 'UIKit', we don't split it.
            if ([queryText hasQuotesPair]) {
                queryText = [queryText tryToRemoveQuotes];
            } else {
                queryText = [self splitText:queryText];
            }
        }
    }
    
    if (EZConfiguration.shared.isBeta) {
        queryText = [queryText removeCommentSymbolPrefixAndJoinTexts];
        queryText = [self removeCommentSymbols:queryText];
    }

    return [queryText trim];
}

- (NSString *)queryText {
    NSString *queryText = [self handleInputText:self.inputText];
    return queryText;
}

- (NSString *)splitText:(NSString *)text {
    NSString *queryText = [text splitSnakeCaseText];
    queryText = [queryText splitCamelCaseText];
    
    // Filter empty text
    NSArray *texts = [queryText componentsSeparatedByString:@" "];
    NSMutableArray *newTexts = [NSMutableArray array];
    for (NSString *text in texts) {
        if (text.length) {
            [newTexts addObject:text];
        }
    }
    
    queryText = [newTexts componentsJoinedByString:@" "];
    
    return queryText;
}

/**
 Remove comment symbols
 */
- (NSString *)removeCommentSymbols:(NSString *)text {
    // good # girl /*** boy */ --> good  girl  boy
    
    // match /*
    NSString *pattern1 = @"/\\*+";
    
    // match */
    NSString *pattern2 = @"[/*]+";
    
    // match // and  #
    NSString *pattern3 = @"//|#";
    
    NSString *combinedPattern = [NSString stringWithFormat:@"%@|%@|%@", pattern1, pattern2, pattern3];
    
    NSString *cleanedText = [text stringByReplacingOccurrencesOfString:combinedPattern
                                                            withString:@""
                                                               options:NSRegularExpressionSearch
                                                                 range:NSMakeRange(0, text.length)];
    
    return cleanedText;
}

/**
 Remove //, and
 
 // These values will persist after the process is killed by the system
 // and remain available via the same object.
 */
- (NSString *)removeCommentAndJoinText:(NSString *)text {
    // 分割文本为行数组
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
        
    NSMutableString *resultText = [NSMutableString string];
    BOOL previousLineIsComment = NO;
    
    for (NSString *line in lines) {
        // 去除行首和行尾的空格和换行符
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        if (previousLineIsComment) {
            // 如果前一行是注释，拼接当前行
            [resultText appendFormat:@" %@", trimmedLine];
        } else if ([trimmedLine hasPrefix:@"//"]) {
            // 当前行以 "//" 开头，标记为注释
            previousLineIsComment = YES;
            
            
            
            [resultText appendString:trimmedLine];
        } else {
            // 不是注释行，追加原始行
            previousLineIsComment = NO;
            [resultText appendString:line];
        }
        
        // 添加换行符分隔行
        [resultText appendString:@"\n"];
    }
    
    return resultText;
}

// Remove comment symbol prefix, // and #
- (NSString *)removeCommentSymbolPrefix:(NSString *)text {
    NSString *pattern = @"^\\s*(//|#)";
    NSString *cleanedText = [text stringByReplacingOccurrencesOfString:pattern
                                                            withString:@""
                                                               options:NSRegularExpressionSearch
                                                                 range:NSMakeRange(0, text.length)];
    return cleanedText;
}

// Is start with comment symbol prefix, // and #
- (BOOL)isStartWithCommentSymbolPrefix:(NSString *)text {
    NSString *pattern = @"^\\s*(//|#)";
    NSRange range = [text rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location != NSNotFound;
}

@end
