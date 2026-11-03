// 生成设置面板入口用的图标（icon.png / @2x / @3x）。
// 只用 CoreGraphics + ImageIO，不需要 GPU 或媒体加速框架。
// 用法：clang -arch arm64e tools/makeicon.c -o <项目内路径> \
//           -framework CoreGraphics -framework ImageIO -framework CoreFoundation
//       ldid -S <项目内路径> && <项目内路径> Resources/Bundle/icon.png 29
// 第二个参数是像素边长（29 / 58 / 87），图形按比例缩放。
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 设计稿按 90x90 画，实际输出时整体缩放
static const CGFloat kDesignSide = 90;

static void fillRoundedRect(CGContextRef ctx, CGRect rect, CGFloat radius,
                            CGFloat r, CGFloat g, CGFloat b) {
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
    CGContextAddPath(ctx, path);
    CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
    CGContextFillPath(ctx);
    CGPathRelease(path);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: makeicon <out.png> <side-pixels>\n");
        return 2;
    }
    const size_t side = (size_t)atoi(argv[2]);
    if (side < 8 || side > 1024) {
        fprintf(stderr, "makeicon: side out of range\n");
        return 2;
    }

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (ctx == NULL) {
        fprintf(stderr, "makeicon: cannot create bitmap context\n");
        return 1;
    }
    CGContextScaleCTM(ctx, (CGFloat)side / kDesignSide, (CGFloat)side / kDesignSide);

    // 背景：圆角方块，蓝
    fillRoundedRect(ctx, CGRectMake(0, 0, kDesignSide, kDesignSide), 20, 0.04, 0.48, 0.96);

    // 禁止符号：白色圆环 + 斜杠
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
    CGContextSetLineWidth(ctx, 7);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(19, 19, 52, 52));
    CGContextMoveToPoint(ctx, 27.5, 62.5);
    CGContextAddLineToPoint(ctx, 62.5, 27.5);
    CGContextStrokePath(ctx);

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (image == NULL) {
        fprintf(stderr, "makeicon: cannot create image\n");
        return 1;
    }

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), false);
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CFRelease(url);
    if (destination == NULL) {
        fprintf(stderr, "makeicon: cannot open output\n");
        CGImageRelease(image);
        return 1;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    bool ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    if (!ok) {
        fprintf(stderr, "makeicon: write failed\n");
        return 1;
    }
    printf("wrote %s (%zux%zu)\n", argv[1], side, side);
    return 0;
}
