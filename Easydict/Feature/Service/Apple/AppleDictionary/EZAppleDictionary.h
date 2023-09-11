//
//  EZAppleDictionary.h
//  Easydict
//
//  Created by tisfeng on 2023/7/29.
//  Copyright © 2023 izual. All rights reserved.
//

#import "EZQueryService.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *EZAppleDictionaryHTMLDirectory = @"Dict HTML";
static NSString *EZAppleDictionaryHTMLDictFilePath = @"dict.html";

@interface EZAppleDictionary : EZQueryService

@property (nonatomic, copy) NSString *htmlFilePath;

@end

NS_ASSUME_NONNULL_END
