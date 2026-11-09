// LongmaoPlus.m —— 龙猫工具大师 v6.2.0 免广告加积分 dylib（自己注入原版 IPA 使用）
// 编译：theos（macOS / GitHub Actions），详见仓库 .github/workflows/build-dylib.yml
// 功能：悬浮球 → 面板 → 一键加积分 / 自动执行开关 / 实时状态
// 说明：dylib 仅在本机进程内运行，所有请求由 App 自身发出，不修改服务端数据格式。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import <string.h>
#import <stdlib.h>

#define LM_LOG(fmt, ...) NSLog(@"[Longmao+] " fmt, ##__VA_ARGS__)

static NSString *const kBaseURL    = @"https://api-tool.xiaoxiaobite.com";
static const char *const kEncKey   = "hr*Ld4@CX4eA2*sk@TM";
static const char *const kDecKey   = "V#4@CX4TcG^EZvsklsz3r";
static NSString *const kBundleID   = @"com.appdream.douyina";
static NSString *const kPackage    = @"longmao";
static NSString *const kChan       = @"AppStore";
static NSString *const kVersion    = @"6.2.0";
static NSString *const kDefIdfa    = @"D091CDAF-0CF3-43C5-83A6-9224E5A6DE87";
static NSString *const kDefUdid    = @"746b827a-a0cb-402c-8054-fefe5f2fd8b7";
static NSString *const kDefChannel = @"mob_65l24zulph4qtj4";

#pragma mark - XXTEA

static uint32_t lm_mx(uint32_t sum, uint32_t y, uint32_t z, uint32_t p, uint32_t e, const uint32_t *k) {
    return ((((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4))) ^ ((sum ^ y) + (k[(p & 3) ^ e] ^ z)));
}

static void lm_xxtea_encrypt(uint32_t *v, int n, const uint32_t *k) {
    if (n < 2) return;
    uint32_t z = v[n - 1], y, sum = 0, e;
    int q = 6 + 52 / n, p;
    while (q-- > 0) {
        sum += 0x9E3779B9u;
        e = (sum >> 2) & 3;
        for (p = 0; p < n; p++) {
            y = v[(p + 1) % n];
            z = v[p] = (v[p] + lm_mx(sum, y, z, p, e, k));
        }
    }
}

static void lm_xxtea_decrypt(uint32_t *v, int n, const uint32_t *k) {
    if (n < 2) return;
    uint32_t y = v[0], z, sum, e;
    int q = 6 + 52 / n, p;
    sum = (uint32_t)q * 0x9E3779B9u;
    while (sum != 0) {
        e = (sum >> 2) & 3;
        for (p = n - 1; p >= 0; p--) {
            z = v[p > 0 ? p - 1 : n - 1];
            y = v[p] = (v[p] - lm_mx(sum, y, z, p, e, k));
        }
        sum -= 0x9E3779B9u;
    }
}

static void lm_key_words(const char *key, uint32_t *k) {
    uint8_t buf[16] = {0};
    size_t len = strlen(key);
    memcpy(buf, key, len < 16 ? len : 16);
    memcpy(k, buf, 16); // 小端设备直接用
}

// 输入长度必须是 4 的倍数
static NSData *lm_encrypt(NSData *data, const char *key) {
    NSUInteger n = data.length;
    if (n == 0 || (n % 4) != 0) return data;
    NSMutableData *out = [NSMutableData dataWithData:data];
    uint32_t k[4];
    lm_key_words(key, k);
    lm_xxtea_encrypt((uint32_t *)out.mutableBytes, (int)(n / 4), k);
    return out;
}

static NSData *lm_decrypt(NSData *data, const char *key) {
    NSUInteger n = data.length;
    if (n == 0 || (n % 4) != 0) return data;
    NSMutableData *out = [NSMutableData dataWithData:data];
    uint32_t k[4];
    lm_key_words(key, k);
    lm_xxtea_decrypt((uint32_t *)out.mutableBytes, (int)(n / 4), k);
    return out;
}

#pragma mark - msgpack 编码

static void mp_u8(NSMutableData *d, uint8_t v) { [d appendBytes:&v length:1]; }

static void mp_be16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v >> 8), (uint8_t)(v & 0xFF)};
    [d appendBytes:b length:2];
}

static void mp_be32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:4];
}

static void mp_be64(NSMutableData *d, uint64_t v) {
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)((v >> (56 - 8 * i)) & 0xFF);
    [d appendBytes:b length:8];
}

static void mp_int(NSMutableData *d, long long v) {
    if (v >= 0 && v <= 127) {
        mp_u8(d, (uint8_t)v);
    } else if (v < 0 && v >= -32) {
        mp_u8(d, (uint8_t)(0xE0 | (v & 0x1F)));
    } else if (v >= -128 && v <= 127) {
        mp_u8(d, 0xD0);
        mp_u8(d, (uint8_t)(int8_t)v);
    } else if (v >= -32768 && v <= 32767) {
        mp_u8(d, 0xD1);
        mp_be16(d, (uint16_t)(int16_t)v);
    } else if (v >= -2147483648LL && v <= 2147483647LL) {
        mp_u8(d, 0xD2);
        mp_be32(d, (uint32_t)(int32_t)v);
    } else {
        mp_u8(d, 0xD3);
        mp_be64(d, (uint64_t)v);
    }
}

static void mp_str(NSMutableData *d, NSString *s) {
    NSData *b = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSUInteger n = b.length;
    if (n < 32) {
        mp_u8(d, (uint8_t)(0xA0 | n));
    } else if (n < 256) {
        mp_u8(d, 0xD9);
        mp_u8(d, (uint8_t)n);
    } else {
        mp_u8(d, 0xDA);
        mp_be16(d, (uint16_t)n);
    }
    if (n) [d appendBytes:b.bytes length:n];
}

static void mp_map(NSMutableData *d, NSUInteger n) {
    if (n < 16) {
        mp_u8(d, (uint8_t)(0x80 | n));
    } else {
        mp_u8(d, 0xDE);
        mp_be16(d, (uint16_t)n);
    }
}

static void mp_arr(NSMutableData *d, NSUInteger n) {
    if (n < 16) {
        mp_u8(d, (uint8_t)(0x90 | n));
    } else {
        mp_u8(d, 0xDC);
        mp_be16(d, (uint16_t)n);
    }
}

static void mp_value(NSMutableData *d, id v) {
    if (!v || v == [NSNull null]) {
        mp_u8(d, 0xC0);
    } else if ([v isKindOfClass:[NSString class]]) {
        mp_str(d, v);
    } else if ([v isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) {
            mp_u8(d, [(NSNumber *)v boolValue] ? 0xC3 : 0xC2);   // 必须编码成 msgpack bool
        } else {
            mp_int(d, [(NSNumber *)v longLongValue]);
        }
    } else if ([v isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = v;
        mp_map(d, dict.count);
        for (id key in dict.allKeys) {   // 顺序无影响
            mp_str(d, [key description]);
            mp_value(d, dict[key]);
        }
    } else if ([v isKindOfClass:[NSArray class]]) {
        NSArray *arr = v;
        mp_arr(d, arr.count);
        for (id o in arr) mp_value(d, o);
    } else {
        mp_str(d, [v description]);
    }
}

#pragma mark - msgpack 解码

static uint16_t rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t rd32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint64_t rd64(const uint8_t *p) { uint64_t v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | p[i]; return v; }

static id mp_decode(const uint8_t **pp, const uint8_t *end) {
    const uint8_t *p = *pp;
    if (p >= end) return nil;
    uint8_t t = *p++;
    if (t <= 0x7F) { *pp = p; return @(t); }
    if (t >= 0xE0) { *pp = p; return @((int8_t)t); }
    if ((t & 0xF0) == 0x80) {
        uint8_t n = t & 0x0F;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (uint8_t i = 0; i < n; i++) {
            id key = mp_decode(&p, end);
            id val = mp_decode(&p, end);
            if (key) d[[key description]] = val ?: [NSNull null];
        }
        *pp = p;
        return d;
    }
    if ((t & 0xF0) == 0x90) {
        uint8_t n = t & 0x0F;
        NSMutableArray *a = [NSMutableArray array];
        for (uint8_t i = 0; i < n; i++) {
            id v = mp_decode(&p, end);
            [a addObject:v ?: [NSNull null]];
        }
        *pp = p;
        return a;
    }
    if ((t & 0xE0) == 0xA0) {
        uint8_t n = t & 0x1F;
        NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding] ?: @"";
        *pp = p + n;
        return s;
    }
    switch (t) {
        case 0xC0: *pp = p; return [NSNull null];
        case 0xC2: *pp = p; return @NO;
        case 0xC3: *pp = p; return @YES;
        case 0xCA: { uint32_t u = rd32(p); float f; memcpy(&f, &u, 4); *pp = p + 4; return @(f); }
        case 0xCB: { uint64_t u = rd64(p); double dv; memcpy(&dv, &u, 8); *pp = p + 8; return @(dv); }
        case 0xCC: { uint8_t v = *p; *pp = p + 1; return @(v); }
        case 0xCD: { uint16_t v = rd16(p); *pp = p + 2; return @(v); }
        case 0xCE: { uint32_t v = rd32(p); *pp = p + 4; return @(v); }
        case 0xCF: { uint64_t v = rd64(p); *pp = p + 8; return @(v); }
        case 0xD0: { int8_t v = (int8_t)*p; *pp = p + 1; return @(v); }
        case 0xD1: { int16_t v = (int16_t)rd16(p); *pp = p + 2; return @(v); }
        case 0xD2: { int32_t v = (int32_t)rd32(p); *pp = p + 4; return @(v); }
        case 0xD3: { int64_t v = (int64_t)rd64(p); *pp = p + 8; return @(v); }
        case 0xD9: { uint8_t n = *p; p += 1; NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding] ?: @""; *pp = p + n; return s; }
        case 0xDA: { uint16_t n = rd16(p); p += 2; NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding] ?: @""; *pp = p + n; return s; }
        case 0xDB: { uint32_t n = rd32(p); p += 4; NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding] ?: @""; *pp = p + n; return s; }
        case 0xC4: { uint8_t n = *p; p += 1; NSData *d = [NSData dataWithBytes:p length:n]; *pp = p + n; return d; }
        case 0xC5: { uint16_t n = rd16(p); p += 2; NSData *d = [NSData dataWithBytes:p length:n]; *pp = p + n; return d; }
        case 0xC6: { uint32_t n = rd32(p); p += 4; NSData *d = [NSData dataWithBytes:p length:n]; *pp = p + n; return d; }
        case 0xDC: { uint16_t n = rd16(p); p += 2; NSMutableArray *a = [NSMutableArray array]; for (uint16_t i = 0; i < n; i++) { id v = mp_decode(&p, end); [a addObject:v ?: [NSNull null]]; } *pp = p; return a; }
        case 0xDD: { uint32_t n = rd32(p); p += 4; NSMutableArray *a = [NSMutableArray array]; for (uint32_t i = 0; i < n; i++) { id v = mp_decode(&p, end); [a addObject:v ?: [NSNull null]]; } *pp = p; return a; }
        case 0xDE: { uint16_t n = rd16(p); p += 2; NSMutableDictionary *d = [NSMutableDictionary dictionary]; for (uint16_t i = 0; i < n; i++) { id key = mp_decode(&p, end); id val = mp_decode(&p, end); if (key) d[[key description]] = val ?: [NSNull null]; } *pp = p; return d; }
        case 0xDF: { uint32_t n = rd32(p); p += 4; NSMutableDictionary *d = [NSMutableDictionary dictionary]; for (uint32_t i = 0; i < n; i++) { id key = mp_decode(&p, end); id val = mp_decode(&p, end); if (key) d[[key description]] = val ?: [NSNull null]; } *pp = p; return d; }
        default: break;
    }
    *pp = end;
    return nil;
}

#pragma mark - 设备信息

static NSString *lm_machine(void) {
    struct utsname u;
    if (uname(&u) == 0) return [NSString stringWithUTF8String:u.machine];
    return @"iPhone";
}

static NSString *lm_norm_token(NSString *tok) {
    tok = [(tok ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    tok = [tok stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    if (tok.length == 0 || [tok containsString:@"%"]) return tok;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    return [tok stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: tok;
}

static NSMutableDictionary *lm_base_params(NSString *token) {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"lan"] = @"zh_Hans";
    p[@"platform"] = @"ios";
    p[@"package"] = kPackage;
    p[@"chn"] = kChan;
    p[@"nonce"] = [NSString stringWithFormat:@"0.%08u", arc4random_uniform(100000000)];
    p[@"time_zone"] = @28800;
    p[@"time_stamp"] = @((long long)[[NSDate date] timeIntervalSince1970]);
    p[@"binary_version"] = kVersion;
    p[@"bundle_id"] = kBundleID;
    p[@"idfa"] = kDefIdfa;
    p[@"udid"] = kDefUdid;
    p[@"channel_id"] = kDefChannel;
    p[@"system_version"] = [[UIDevice currentDevice] systemVersion] ?: @"18.0";
    p[@"first_open_time"] = @0;
    p[@"device_info"] = @{@"model": lm_machine(), @"localized_model": lm_machine()};
    p[@"logined"] = @(token.length > 0);
    p[@"token"] = lm_norm_token(token);
    p[@"debug"] = @NO;
    return p;
}

static NSData *lm_pack_body(NSString *token, NSDictionary *extra) {
    NSMutableDictionary *p = lm_base_params(token);
    if (extra) [p addEntriesFromDictionary:extra];
    NSMutableData *buf = [NSMutableData data];
    mp_value(buf, p);
    NSMutableData *out = [NSMutableData dataWithData:buf];
    NSUInteger pad = (4 - (buf.length % 4)) % 4;
    uint8_t zero[4] = {0, 0, 0, 0};
    if (pad) [out appendBytes:zero length:pad];
    uint32_t rawLen = (uint32_t)buf.length;
    uint8_t lb[4] = {(uint8_t)(rawLen & 0xFF), (uint8_t)((rawLen >> 8) & 0xFF),
                     (uint8_t)((rawLen >> 16) & 0xFF), (uint8_t)((rawLen >> 24) & 0xFF)};
    [out appendBytes:lb length:4];                 // 末尾 4 字节小端明文长度
    return lm_encrypt(out, kEncKey);
}

#pragma mark - 网络

static NSDictionary *lm_call(NSString *path, NSString *token, NSDictionary *extra, NSError **errOut) {
    NSData *cipher = lm_pack_body(token, extra);
    NSString *b64 = [cipher base64EncodedStringWithOptions:0];
    NSURL *url = [NSURL URLWithString:[kBaseURL stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 25;
    [req setValue:@"text/plain;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"1" forHTTPHeaderField:@"X-LM-Internal"];   // 插件自身请求，hook 不再回捕
    req.HTTPBody = [b64 dataUsingEncoding:NSUTF8StringEncoding];

    __block NSData *respData = nil;
    __block NSError *respErr = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            respData = data;
            respErr = error;
            dispatch_semaphore_signal(sema);
        }];
    [task resume];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

    if (respErr) {
        if (errOut) *errOut = respErr;
        return nil;
    }
    if (respData.length == 0) return nil;

    NSString *txt = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
    txt = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *cipherResp = [[NSData alloc] initWithBase64EncodedString:(txt ?: @"") options:0];
    if (!cipherResp) return nil;
    NSData *plain = lm_decrypt(cipherResp, kDecKey);
    if (plain.length < 8) return nil;
    const uint8_t *bytes = plain.bytes;
    uint32_t len = (uint32_t)bytes[plain.length - 4]
                 | ((uint32_t)bytes[plain.length - 3] << 8)
                 | ((uint32_t)bytes[plain.length - 2] << 16)
                 | ((uint32_t)bytes[plain.length - 1] << 24);
    if (len == 0 || len > plain.length) len = (uint32_t)(plain.length - 4);
    const uint8_t *p = bytes;
    id obj = mp_decode(&p, bytes + len);
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

#pragma mark - 登录态抓取（hook App 自身请求/响应）

static NSString *lm_latest_hook_token = nil;
static NSLock *lm_hook_lock = nil;

static NSString *lm_find_token_in_obj(id obj, int depth) {
    if (!obj || depth > 5) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        id t = d[@"token"];
        if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] >= 20) return t;
        for (id k in d.allKeys) {
            NSString *r = lm_find_token_in_obj(d[k], depth + 1);
            if (r.length) return r;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)obj) {
            NSString *r = lm_find_token_in_obj(v, depth + 1);
            if (r.length) return r;
        }
    }
    return nil;
}

// base64 → XXTEA → msgpack（也兼容裸密文）；只接受 map 头，避免误解析明文
static id lm_decode_payload(NSData *raw, const char *key) {
    if (raw.length < 16) return nil;
    NSData *cipher = nil;
    NSString *txt = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (txt.length) {
        NSString *t = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length >= 16) cipher = [[NSData alloc] initWithBase64EncodedString:t options:NSDataBase64DecodingIgnoreUnknownCharacters];
    }
    if (!cipher || cipher.length < 16) cipher = raw;
    if (cipher.length < 16 || (cipher.length % 4) != 0) return nil;
    NSData *plain = lm_decrypt(cipher, key);
    if (plain.length < 8) return nil;
    const uint8_t *bytes = plain.bytes;
    uint8_t head = bytes[0];
    BOOL isMap = (head >= 0x80 && head <= 0x8f) || head == 0xDE || head == 0xDF;
    if (!isMap) return nil;
    uint32_t len = (uint32_t)bytes[plain.length - 4]
                 | ((uint32_t)bytes[plain.length - 3] << 8)
                 | ((uint32_t)bytes[plain.length - 2] << 16)
                 | ((uint32_t)bytes[plain.length - 1] << 24);
    if (len < 2 || len > plain.length) len = (uint32_t)(plain.length - 4);
    const uint8_t *p = bytes;
    return mp_decode(&p, bytes + len);
}

static void lm_note_hook_token(NSString *token) {
    if (token.length < 20) return;
    NSString *norm = lm_norm_token(token);
    if (norm.length < 20) norm = token;
    if (!lm_hook_lock) lm_hook_lock = [NSLock new];
    [lm_hook_lock lock];
    BOOL changed = ![norm isEqualToString:lm_latest_hook_token];
    lm_latest_hook_token = [norm copy];
    [lm_hook_lock unlock];
    if (changed) {
        [[NSUserDefaults standardUserDefaults] setObject:norm forKey:@"lm_plus_token"];
        LM_LOG(@"捕获到 App 登录态：%@… (%lu 字符)", [norm substringToIndex:MIN(10u, norm.length)], (unsigned long)norm.length);
    }
}

// 插件自己发出的请求带内部标记，避免回捕
static BOOL lm_is_internal_request(NSURLRequest *req) {
    return req.allHTTPHeaderFields[@"X-LM-Internal"] != nil;
}

static void lm_capture_from_request(NSURLRequest *req) {
    if (!req || lm_is_internal_request(req)) return;
    @try {
        NSData *body = req.HTTPBody;
        if (body.length < 16) return;
        NSString *t = lm_find_token_in_obj(lm_decode_payload(body, kEncKey), 0);
        if (t.length) lm_note_hook_token(t);
    } @catch (NSException *e) {
        LM_LOG(@"解析请求失败：%@", e);
    }
}

static void lm_capture_from_response(NSData *data) {
    if (data.length < 16) return;
    @try {
        NSString *t = lm_find_token_in_obj(lm_decode_payload(data, kDecKey), 0);
        if (t.length) lm_note_hook_token(t);
    } @catch (NSException *e) {
    }
}

typedef NSURLSessionDataTask *(*LMDataTaskCH)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*LMDataTask)(id, SEL, NSURLRequest *);

static NSMutableDictionary *lm_imp_map = nil;

static NSString *lm_imp_key(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static IMP lm_imp_lookup(id self, SEL cmd) {
    Class cls = object_getClass(self);
    while (cls) {
        id v = lm_imp_map[lm_imp_key(cls, cmd)];
        if (v) return (IMP)[v pointerValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static NSURLSessionDataTask *lm_new_dt_ch(id self, SEL _cmd, NSURLRequest *req,
                                          void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    IMP orig = lm_imp_lookup(self, _cmd);
    lm_capture_from_request(req);
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = handler;
    if (handler && !lm_is_internal_request(req)) {
        wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
            lm_capture_from_response(data);
            handler(data, resp, err);
        };
    }
    return orig ? ((LMDataTaskCH)orig)(self, _cmd, req, wrapped) : nil;
}

static NSURLSessionDataTask *lm_new_dt(id self, SEL _cmd, NSURLRequest *req) {
    IMP orig = lm_imp_lookup(self, _cmd);
    lm_capture_from_request(req);
    return orig ? ((LMDataTask)orig)(self, _cmd, req) : nil;
}

static void lm_hook_install(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    if (!lm_imp_map) lm_imp_map = [NSMutableDictionary dictionary];
    NSArray *classes = @[[NSURLSession class], NSClassFromString(@"__NSCFURLSession") ?: [NSNull null]];
    SEL sels[2] = {@selector(dataTaskWithRequest:completionHandler:), @selector(dataTaskWithRequest:)};
    IMP imps[2] = {(IMP)lm_new_dt_ch, (IMP)lm_new_dt};
    for (id c in classes) {
        Class cls = [c isKindOfClass:[NSNull class]] ? Nil : (Class)c;
        if (!cls) continue;
        for (int i = 0; i < 2; i++) {
            Method m = class_getInstanceMethod(cls, sels[i]);
            if (!m) continue;
            IMP cur = method_getImplementation(m);
            if (cur == imps[i]) continue;
            lm_imp_map[lm_imp_key(cls, sels[i])] = [NSValue valueWithPointer:cur];
            method_setImplementation(m, imps[i]);
        }
    }
    LM_LOG(@"网络登录态 hook 已安装");
}

#pragma mark - token 获取兜底（文件 / UserDefaults / Keychain）

static BOOL lm_key_tokenish(NSString *k) {
    NSString *l = [k lowercaseString];
    return [l containsString:@"token"] || [l containsString:@"auth"] || [l containsString:@"jwt"]
        || [l containsString:@"session"] || [l containsString:@"login"] || [l containsString:@"user"];
}

static NSArray<NSString *> *lm_scan_user_defaults(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"[A-Za-z0-9%_\\-\\.\\+\\/=]{40,400}" options:0 error:nil];
    for (NSString *k in dict) {
        if (!lm_key_tokenish(k)) continue;
        id v = dict[k];
        NSString *s = nil;
        if ([v isKindOfClass:[NSString class]]) s = v;
        else if ([v isKindOfClass:[NSData class]]) s = [[NSString alloc] initWithData:v encoding:NSISOLatin1StringEncoding];
        else if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
            NSData *j = [NSJSONSerialization isValidJSONObject:v] ? [NSJSONSerialization dataWithJSONObject:v options:0 error:nil] : nil;
            if (j) s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
        }
        if (!s.length) continue;
        for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
            NSString *cand = [s substringWithRange:m.range];
            if (![out containsObject:cand]) [out addObject:cand];
        }
    }
    return out;
}

static NSArray<NSString *> *lm_scan_keychain(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (st != errSecSuccess || !result) return out;
    NSArray *items = (__bridge_transfer NSArray *)result;
    if (![items isKindOfClass:[NSArray class]]) return out;
    for (id it in items) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)it;
        NSString *acc = d[(__bridge id)kSecAttrAccount] ?: @"";
        NSString *svc = d[(__bridge id)kSecAttrService] ?: @"";
        id raw = d[(__bridge id)kSecValueData];
        NSString *val = nil;
        if ([raw isKindOfClass:[NSData class]] && [(NSData *)raw length]) {
            val = [[NSString alloc] initWithData:(NSData *)raw encoding:NSUTF8StringEncoding];
            if (!val) val = [[NSString alloc] initWithData:(NSData *)raw encoding:NSISOLatin1StringEncoding];
        } else if ([raw isKindOfClass:[NSString class]]) {
            val = (NSString *)raw;
        }
        val = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!val.length) continue;
        BOOL keyHit = lm_key_tokenish(acc) || lm_key_tokenish(svc);
        BOOL lenHit = val.length >= 40 && val.length <= 400;
        if (val.length >= 20 && val.length <= 400 && ![val containsString:@" "] && (lenHit || keyHit)) {
            if (![out containsObject:val]) [out addObject:val];
        }
    }
    return out;
}

static NSString *lm_read_token_from_files(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    for (NSString *sub in @[@"Library", @"Documents", @"tmp"]) {
        NSString *p = [home stringByAppendingPathComponent:sub];
        if ([fm fileExistsAtPath:p]) [roots addObject:p];
    }
    NSArray<NSRegularExpression *> *patterns = @[
        [NSRegularExpression regularExpressionWithPattern:
            @"[Tt][Oo][Kk][Ee][Nn][\"']?\\s*[:=]\\s*[\\\\\"']*([A-Za-z0-9%_\\-\\.\\+\\/=]{40,400})"
            options:0 error:nil],
        // MMKV / NSUserDefaults 二进制里键名与值是长度字节分隔，不是冒号或等号
        [NSRegularExpression regularExpressionWithPattern:
            @"[Tt][Oo][Kk][Ee][Nn][\\x00-\\x20]{0,6}[\"'=:]{0,2}([A-Za-z0-9%_\\-\\.\\+\\/=]{40,400})"
            options:0 error:nil],
        // JWT 形态
        [NSRegularExpression regularExpressionWithPattern:
            @"(eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,})"
            options:0 error:nil],
    ];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSInteger scanned = 0;

    NSMutableArray<NSString *> *queue = [roots mutableCopy];
    while (queue.count && scanned < 600) {
        NSString *dir = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        for (NSString *name in items) {
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) { if (queue.count + scanned < 700) [queue addObject:full]; continue; }
            if (++scanned > 600) break;
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if ([attrs[NSFileSize] unsignedLongLongValue] > 4 * 1024 * 1024) continue;
            NSString *ext = name.pathExtension.lowercaseString;
            if (![@[@"json", @"plist", @"txt", @"db", @"sqlite", @"dat", @"", @"storage", @"mmkv"] containsObject:ext]) continue;
            NSData *d = [NSData dataWithContentsOfFile:full];
            if (!d || d.length == 0) continue;
            NSString *s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
            if (!s) continue;
            for (NSRegularExpression *re in patterns) {
                NSArray *ms = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
                for (NSTextCheckingResult *m in ms) {
                    NSString *v = [s substringWithRange:[m rangeAtIndex:1]];
                    if (v.length >= 40 && v.length <= 400 && ![cands containsObject:v]) [cands addObject:v];
                }
            }
        }
    }
    // 追加 UserDefaults / Keychain 里的候选（App 换账号常写这里）
    [cands addObjectsFromArray:lm_scan_user_defaults()];
    [cands addObjectsFromArray:lm_scan_keychain()];
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *c in cands) {
        if (![ordered containsObject:c]) [ordered addObject:c];
    }
    cands = ordered;

    // 候选逐个验活（限量，避免长尾请求拖慢）
    NSInteger tried = 0;
    for (NSString *cand in cands) {
        if (++tried > 12) break;
        NSDictionary *r = lm_call(@"/api/user/info", cand, nil, nil);
        NSDictionary *ui = r[@"data"][@"user_info"];
        if ([r[@"code"] intValue] == 200 && [ui isKindOfClass:[NSDictionary class]] && ui[@"user_code"]) {
            LM_LOG(@"token 命中：%@... (%lu 字符)", [cand substringToIndex:MIN(12u, cand.length)], (unsigned long)cand.length);
            return cand;
        }
    }
    return nil;
}

#pragma mark - 任务

static NSString *lm_status_text = @"";

static NSDictionary *lm_user_info(NSString *token) {
    NSDictionary *r = lm_call(@"/api/user/info", token, nil, nil);
    return r[@"data"][@"user_info"];
}

static NSInteger lm_credits(NSString *token) {
    NSDictionary *ui = lm_user_info(token);
    return [ui[@"credits"] integerValue];
}

// 单类任务补齐；progress 回调次数
static NSInteger lm_run_task(NSString *token, NSString *infoPath, NSString *activePath,
                             NSString *name, void (^progress)(NSString *)) {
    NSDictionary *r = lm_call(infoPath, token, nil, nil);
    NSDictionary *ti = r[@"data"][@"task_info"];
    NSInteger done = [ti[@"user_count"] integerValue];
    NSInteger total = [ti[@"total_count"] integerValue];
    if (total <= 0) total = 10;
    if (progress) progress([NSString stringWithFormat:@"%@ %ld/%ld", name, (long)done, (long)total]);

    NSInteger ok = 0;
    for (NSInteger i = done; i < total; i++) {
        NSDictionary *rr = lm_call(activePath, token, nil, nil);
        NSInteger code = [rr[@"code"] integerValue];
        if (code == 200) {
            ok++;
            if (progress) progress([NSString stringWithFormat:@"%@ %ld/%ld", name, (long)(i + 1), (long)total]);
        } else {
            LM_LOG(@"%@ 中断：%@", name, rr[@"msg"] ?: rr);
            if (code == 100 || code == 1001 || code == 1020) break;
        }
        [NSThread sleepForTimeInterval:1.2];
    }
    return ok;
}

static void lm_run_all(void (^status)(NSString *), void (^done)(BOOL, NSString *)) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^update)(NSString *) = ^(NSString *s) {
            lm_status_text = s ?: @"";
            if (status) dispatch_async(dispatch_get_main_queue(), ^{ status(s); });
        };
        if (!lm_hook_lock) lm_hook_lock = [NSLock new];
        NSString *token = nil;

        // 1) 优先用 hook 抓到的登录态（App 每个请求都带 token，换账号后会立即刷新）
        [lm_hook_lock lock];
        NSString *hooked = [lm_latest_hook_token copy];
        [lm_hook_lock unlock];
        if (hooked.length >= 20 && [lm_user_info(hooked) isKindOfClass:[NSDictionary class]]) token = hooked;

        // 2) 上次缓存
        if (token.length < 20) {
            NSString *cached = [[NSUserDefaults standardUserDefaults] stringForKey:@"lm_plus_token"];
            if (cached.length >= 20 && [lm_user_info(cached) isKindOfClass:[NSDictionary class]]) token = cached;
        }

        // 3) 扫沙盒文件 / UserDefaults / Keychain 兜底
        if (token.length < 20) {
            update(@"正在定位登录态（可在 App 内点开任意页面再试）…");
            token = lm_read_token_from_files();
        }

        if (token.length >= 20) {
            [[NSUserDefaults standardUserDefaults] setObject:token forKey:@"lm_plus_token"];
        } else {
            if (done) dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"未找到登录态：请先在 App 内退出重登并刷新页面，再点一键加积分");
            });
            return;
        }

        NSInteger before = lm_credits(token);
        update([NSString stringWithFormat:@"当前积分 %ld，签到中…", (long)before]);
        NSDictionary *sign = lm_call(@"/api/task/sign/daily/active", token, nil, nil);
        LM_LOG(@"签到：%@", sign[@"msg"] ?: @( [sign[@"code"] integerValue] ));

        lm_run_task(token, @"/api/task/watchvideo/info", @"/api/task/watchvideo/active", @"看视频", update);
        lm_run_task(token, @"/api/task/watchbanner/info", @"/api/task/watchbanner/active", @"看Banner", update);

        NSInteger after = lm_credits(token);
        NSString *msg = [NSString stringWithFormat:@"完成：%ld → %ld（+%ld）", (long)before, (long)after, (long)(after - before)];
        update(msg);
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(YES, msg); });
    });
}

#pragma mark - 界面

// 点击穿透窗口：只放行悬浮球与面板区域的触摸，其余一律交给下层 App 窗口
@interface LMPassthroughWindow : UIWindow
@property (nonatomic, weak) UIView *hitBall;
@property (nonatomic, weak) UIView *hitPanel;
@end

@implementation LMPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *ball = self.hitBall;
    UIView *panel = self.hitPanel;
    if (ball && !ball.hidden && ball.alpha > 0.01 && CGRectContainsPoint(ball.frame, point)) {
        return [ball hitTest:[ball convertPoint:point fromView:self] withEvent:event] ?: ball;
    }
    if (panel && !panel.hidden && panel.alpha > 0.01 && CGRectContainsPoint(panel.frame, point)) {
        UIView *v = [super hitTest:point withEvent:event];
        // 命中面板或其子视图才消费，否则穿透
        if (v && (v == panel || [v isDescendantOfView:panel])) return v;
    }
    return nil;   // 透明区域不吃事件，App 正常响应
}

@end

@interface LMOverlay : NSObject
@property (nonatomic, strong) LMPassthroughWindow *window;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UISwitch *autoSwitch;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL running;
@end

static LMOverlay *gOverlay = nil;

@implementation LMOverlay

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gOverlay = [LMOverlay new]; });
    return gOverlay;
}

- (LMPassthroughWindow *)makeWindow {
    LMPassthroughWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                w = [[LMPassthroughWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                break;
            }
        }
    }
    if (!w) w = [[LMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = UIWindowLevelAlert + 20;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [[UIViewController alloc] init];
    w.rootViewController.view.frame = w.bounds;
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    // 关键：根视图本身不吃点击，命中判定全部交给 hitTest
    w.rootViewController.view.userInteractionEnabled = YES;
    w.hidden = NO;
    return w;
}

- (void)setup {
    if (self.window) return;
    self.window = [self makeWindow];

    CGFloat w = 56;
    self.ball = [UIButton buttonWithType:UIButtonTypeCustom];
    self.ball.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - w - 12, 160, w, w);
    self.ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    self.ball.layer.cornerRadius = w / 2;
    self.ball.layer.borderWidth = 1;
    self.ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    [self.ball setTitle:@"积分" forState:UIControlStateNormal];
    self.ball.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)]];
    [self.window.rootViewController.view addSubview:self.ball];
    self.window.hitBall = self.ball;

    [self buildPanel];
    self.window.hitPanel = self.panel;

    BOOL autoOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"lm_plus_auto"];
    self.autoSwitch.on = autoOn;
    if (autoOn) [self scheduleTimer];
}

- (void)buildPanel {
    CGFloat pw = 250, ph = 196;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    self.panel.hidden = YES;

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, pw - 28, 20)];
    self.titleLabel.text = @"龙猫助手 · 免广告加积分";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.titleLabel.textColor = [UIColor whiteColor];
    [self.panel addSubview:self.titleLabel];

    UILabel *autoLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 40, 90, 28)];
    autoLabel.text = @"自动执行";
    autoLabel.font = [UIFont systemFontOfSize:13];
    autoLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    [self.panel addSubview:autoLabel];

    self.autoSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 14 - 51, 38, 51, 31)];
    self.autoSwitch.transform = CGAffineTransformMakeScale(0.85, 0.85);
    [self.autoSwitch addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.autoSwitch];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 76, pw - 28, 46)];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    self.statusLabel.text = @"点下方按钮开始";
    [self.panel addSubview:self.statusLabel];

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.frame = CGRectMake(14, ph - 62, pw - 28, 44);
    [self.runButton setTitle:@"一键加积分" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.runButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.runButton.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.98 alpha:1];
    self.runButton.layer.cornerRadius = 10;
    [self.runButton addTarget:self action:@selector(runNow) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.runButton];

    [self.window.rootViewController.view addSubview:self.panel];
}

- (void)dragBall:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    if (g.state == UIGestureRecognizerStateEnded) {
        // 贴边
        CGRect bounds = v.superview.bounds;
        CGFloat margin = 10;
        CGFloat x = v.center.x < bounds.size.width / 2 ? margin + v.bounds.size.width / 2
                                                     : bounds.size.width - margin - v.bounds.size.width / 2;
        [UIView animateWithDuration:0.2 animations:^{ v.center = CGPointMake(x, v.center.y); }];
    }
    if (self.panel.isHidden == NO) [self layoutPanel];
}

- (void)layoutPanel {
    if (!self.panel || self.panel.hidden) return;
    CGRect r = self.ball.frame;
    CGSize screen = self.window.bounds.size;
    CGFloat pw = self.panel.bounds.size.width, ph = self.panel.bounds.size.height;
    CGFloat x = r.origin.x + r.size.width / 2 - pw / 2;
    x = MAX(8, MIN(x, screen.width - pw - 8));
    CGFloat y = r.origin.y + r.size.height + 8;
    if (y + ph > screen.height - 40) y = r.origin.y - ph - 8;
    self.panel.frame = CGRectMake(x, y, pw, ph);
}

- (void)togglePanel {
    self.panel.hidden = !self.panel.isHidden;
    [self layoutPanel];
    [self.window.rootViewController.view bringSubviewToFront:self.panel];
    [self.window.rootViewController.view bringSubviewToFront:self.ball];
}

- (void)autoChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn forKey:@"lm_plus_auto"];
    if (sw.isOn) {
        [self scheduleTimer];
        [self runNow];
    } else {
        [self.timer invalidate];
        self.timer = nil;
        self.statusLabel.text = @"自动执行已关闭";
    }
}

- (void)scheduleTimer {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:900 repeats:YES block:^(NSTimer *t) {
        if (!self.running) [self runNow];
    }];
}

- (void)runNow {
    if (self.running) return;
    self.running = YES;
    self.runButton.enabled = NO;
    self.statusLabel.text = @"准备中…";
    __weak typeof(self) weakSelf = self;
    lm_run_all(^(NSString *s) {
        weakSelf.statusLabel.text = s;
    }, ^(BOOL ok, NSString *msg) {
        __strong typeof(weakSelf) self2 = weakSelf;
        self2.running = NO;
        self2.runButton.enabled = YES;
        self2.statusLabel.text = msg ?: (ok ? @"完成" : @"失败");
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:ok ? @"加积分完成" : @"加积分未完成"
                                                                  message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self2.window.rootViewController presentViewController:ac animated:YES completion:nil];
    });
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void lm_plus_init(void) {
    LM_LOG(@"loaded in %@", [[NSBundle mainBundle] bundleIdentifier]);
    lm_hook_install();   // 必须在 App 发出首个请求前挂上，第一时间拿到登录态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[LMOverlay shared] setup];
        } @catch (NSException *e) {
            LM_LOG(@"setup 失败：%@", e);
        }
    });
}
