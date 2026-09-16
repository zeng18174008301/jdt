#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "promo_exports" / "app-faithful"
APP_ICON = ROOT / "BlueStoneIM" / "Assets.xcassets" / "AppIcon.appiconset" / "Icon-1024.png"

W, H = 1242, 2688

FONT_CN_BOLD = "/System/Library/Fonts/STHeiti Medium.ttc"
FONT_CN_REG = "/System/Library/Fonts/STHeiti Light.ttc"
FONT_EN = "/System/Library/Fonts/HelveticaNeue.ttc"

BRAND = (93, 107, 255)
PEER_NAME = (79, 111, 159)
VIOLET = (124, 107, 255)
CYAN = (80, 210, 255)
INK = (23, 32, 51)
MUTED = (122, 131, 151)
PAGE = (243, 246, 252)
CARD = (255, 255, 255)
LINE = (232, 236, 245)
DANGER = (255, 93, 115)
SUCCESS = (35, 196, 142)
WARNING = (255, 178, 70)
WHITE = (255, 255, 255)


@dataclass(frozen=True)
class PromoLocale:
    lang: str
    brand: str
    badge: str
    titles: list[str]
    subtitles: list[str]


ZH = PromoLocale(
    lang="zh",
    brand="X01",
    badge="企业即时协作",
    titles=[
        "企业会话\n集中处理",
        "通讯录与组织\n一屏掌握",
        "收藏资料\n随时回看",
        "语音视频\n快速发起",
    ],
    subtitles=[
        "会话、群聊、系统通知和未读提醒，按真实工作流统一收拢。",
        "联系人、群列表、黑名单和组织架构，沿用 App 内的清爽卡片布局。",
        "图片、PDF、表格、文档按分类沉淀，资料列表支持刷新和预览。",
        "一对一语音/视频入口、最近通话记录和状态同步都在沟通页。",
    ],
)

EN = PromoLocale(
    lang="en",
    brand="BlueStone IM",
    badge="Enterprise Messaging",
    titles=[
        "Focused\nWork Chats",
        "Contacts & Org\nIn One View",
        "Saved Files\nAlways Ready",
        "Voice & Video\nOne Tap Away",
    ],
    subtitles=[
        "Chats, groups, system notices, and unread alerts stay in one calm workspace.",
        "Contacts, groups, blocked accounts, and org structure follow the real app layout.",
        "Images, PDFs, spreadsheets, and documents are organized for quick preview.",
        "Start one-to-one calls and review recent call history from the Communication tab.",
    ],
)


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size=size, index=index)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", size=size)


def promo_font(locale: PromoLocale, size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    if locale.lang == "zh":
        return load_font(FONT_CN_BOLD if bold else FONT_CN_REG, size)
    return load_font(FONT_EN, size, index=1 if bold else 0)


def cn_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return load_font(FONT_CN_BOLD if bold else FONT_CN_REG, size)


def en_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return load_font(FONT_EN, size, index=1 if bold else 0)


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(lerp(a[i], b[i], t) for i in range(3))


def vertical_gradient(size: tuple[int, int], stops: list[tuple[float, tuple[int, int, int]]]) -> Image.Image:
    width, height = size
    img = Image.new("RGB", size)
    draw = ImageDraw.Draw(img)
    for y in range(height):
        t = y / max(1, height - 1)
        left, right = stops[0], stops[-1]
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                left, right = stops[i], stops[i + 1]
                break
        span = max(0.001, right[0] - left[0])
        color = mix(left[1], right[1], (t - left[0]) / span)
        draw.line((0, y, width, y), fill=color)
    return img


def aurora(size: tuple[int, int]) -> Image.Image:
    img = vertical_gradient(
        size,
        [
            (0.0, PAGE),
            (0.42, (238, 241, 255)),
            (1.0, (234, 248, 255)),
        ],
    ).convert("RGBA")
    overlay = Image.new("RGBA", size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    w, h = size
    od.polygon([(w, 0), (w, h * 0.30), (w * 0.66, h * 0.24), (w * 0.78, 0)], fill=(*BRAND, 22))
    od.polygon([(0, h * 0.72), (w * 0.34, h * 0.78), (0, h)], fill=(*CYAN, 18))
    img.alpha_composite(overlay)
    return img


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def paste_rounded(base: Image.Image, img: Image.Image, xy: tuple[int, int], radius: int) -> None:
    base.paste(img, xy, rounded_mask(img.size, radius))


def shadow(base: Image.Image, box: tuple[int, int, int, int], radius: int, alpha: int = 30, blur: int = 28, y: int = 14) -> None:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x1, y1, x2, y2 = box
    d.rounded_rectangle((x1, y1 + y, x2, y2 + y), radius=radius, fill=(36, 48, 88, alpha))
    base.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def text_bbox(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, spacing: int = 8) -> tuple[int, int]:
    box = draw.multiline_textbbox((0, 0), text, font=font, spacing=spacing)
    return box[2] - box[0], box[3] - box[1]


def wrap_text(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, max_width: int) -> str:
    if "\n" in text:
        return "\n".join(wrap_text(draw, line, font, max_width) for line in text.split("\n"))
    if " " in text:
        lines: list[str] = []
        current = ""
        for word in text.split(" "):
            test = word if not current else f"{current} {word}"
            if text_bbox(draw, test, font)[0] <= max_width:
                current = test
            else:
                if current:
                    lines.append(current)
                current = word
        if current:
            lines.append(current)
        return "\n".join(lines)
    lines: list[str] = []
    current = ""
    for ch in text:
        test = current + ch
        if text_bbox(draw, test, font)[0] <= max_width:
            current = test
        else:
            if current:
                lines.append(current)
            current = ch
    if current:
        lines.append(current)
    return "\n".join(lines)


def draw_multiline(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int] = INK,
    spacing: int = 8,
    anchor: str | None = None,
) -> None:
    draw.multiline_text(xy, text, font=font, fill=fill, spacing=spacing, anchor=anchor)


def card(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    radius: int = 22,
    fill: tuple[int, int, int, int] = (255, 255, 255, 228),
    outline: tuple[int, int, int, int] = (255, 255, 255, 185),
) -> None:
    x1, y1, x2, y2 = box
    draw.rounded_rectangle((x1, y1 + 5, x2, y2 + 5), radius=radius, fill=(93, 107, 255, 14))
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=2)


def pill(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], text: str, color: tuple[int, int, int], selected: bool = False) -> None:
    fill = color if selected else (*CARD, 235)
    outline = color if selected else LINE
    draw.rounded_rectangle(box, radius=(box[3] - box[1]) // 2, fill=fill, outline=outline, width=2)
    draw.text(
        ((box[0] + box[2]) // 2, (box[1] + box[3]) // 2 + 1),
        text,
        font=cn_font(25, True),
        fill=WHITE if selected else INK,
        anchor="mm",
    )


def avatar(draw: ImageDraw.ImageDraw, xy: tuple[int, int], size: int, color: tuple[int, int, int], text: str) -> None:
    x, y = xy
    draw.ellipse((x, y, x + size, y + size), fill=color)
    draw.text((x + size / 2, y + size / 2 + 1), text[:1], font=cn_font(max(16, int(size * 0.42)), True), fill=WHITE, anchor="mm")


def small_cert(draw: ImageDraw.ImageDraw, x: int, y: int) -> None:
    draw.rounded_rectangle((x, y, x + 118, y + 34), radius=17, fill=(93, 107, 255, 22))
    draw.ellipse((x + 12, y + 10, x + 24, y + 22), fill=BRAND)
    draw.text((x + 32, y + 7), "企业认证", font=cn_font(18, True), fill=BRAND)


def status_bar(draw: ImageDraw.ImageDraw, width: int) -> None:
    draw.text((44, 35), "9:41", font=en_font(22, True), fill=INK)
    draw.rounded_rectangle((width - 116, 37, width - 70, 57), radius=7, outline=INK, width=2)
    draw.rounded_rectangle((width - 110, 42, width - 82, 52), radius=4, fill=INK)
    draw.rectangle((width - 66, 44, width - 61, 51), fill=INK)


def search_box(draw: ImageDraw.ImageDraw, x: int, y: int, width: int, text: str) -> None:
    draw.rounded_rectangle((x, y, x + width, y + 58), radius=18, fill=(255, 255, 255, 218), outline=LINE, width=2)
    draw.ellipse((x + 24, y + 20, x + 42, y + 38), outline=MUTED, width=3)
    draw.line((x + 39, y + 37, x + 50, y + 48), fill=MUTED, width=3)
    draw.text((x + 66, y + 17), text, font=cn_font(22), fill=MUTED)
    draw.rounded_rectangle((x + width - 92, y + 14, x + width - 24, y + 44), radius=15, fill=(93, 107, 255, 24))
    draw.text((x + width - 58, y + 29), "搜索", font=cn_font(18, True), fill=BRAND, anchor="mm")


def bottom_icon(draw: ImageDraw.ImageDraw, cx: int, cy: int, kind: str, color: tuple[int, int, int]) -> None:
    if kind == "chats":
        draw.rounded_rectangle((cx - 14, cy - 11, cx + 14, cy + 9), radius=8, outline=color, width=3)
        draw.polygon([(cx - 4, cy + 9), (cx + 4, cy + 9), (cx - 2, cy + 16)], fill=color)
    elif kind == "contacts":
        draw.ellipse((cx - 10, cy - 15, cx + 4, cy - 1), outline=color, width=3)
        draw.ellipse((cx + 4, cy - 12, cx + 16, cy), outline=color, width=3)
        draw.arc((cx - 20, cy - 2, cx + 10, cy + 24), 205, 335, fill=color, width=3)
        draw.arc((cx - 4, cy, cx + 24, cy + 22), 205, 335, fill=color, width=3)
    elif kind == "files":
        draw.rounded_rectangle((cx - 18, cy - 7, cx + 18, cy + 16), radius=5, outline=color, width=3)
        draw.line((cx - 15, cy - 8, cx - 4, cy - 16, cx + 5, cy - 16), fill=color, width=3)
    elif kind == "calls":
        draw.arc((cx - 20, cy - 18, cx + 18, cy + 20), 125, 315, fill=color, width=4)
        draw.line((cx - 13, cy + 6, cx - 21, cy + 14), fill=color, width=5)
        draw.line((cx + 10, cy - 13, cx + 18, cy - 21), fill=color, width=5)
    else:
        draw.ellipse((cx - 9, cy - 16, cx + 9, cy + 2), outline=color, width=3)
        draw.arc((cx - 22, cy - 1, cx + 22, cy + 30), 205, 335, fill=color, width=3)


def bottom_tabs(draw: ImageDraw.ImageDraw, width: int, height: int, active: str) -> None:
    labels = [
        ("会话", "chats"),
        ("通讯录", "contacts"),
        ("资料", "files"),
        ("沟通", "calls"),
        ("我的", "me"),
    ]
    y = height - 136
    draw.rounded_rectangle((0, y - 18, width, height + 8), radius=0, fill=(255, 255, 255, 246))
    draw.line((0, y - 18, width, y - 18), fill=LINE, width=2)
    step = width / 5
    for idx, (label, ident) in enumerate(labels):
        cx = int(step * idx + step / 2)
        color = INK if ident == active else MUTED
        bottom_icon(draw, cx, y + 20, ident, color)
        draw.text((cx, y + 56), label, font=cn_font(19, True), fill=color, anchor="ma")
        if ident == "chats" and active != "chats":
            draw.ellipse((cx + 17, y + 4, cx + 31, y + 18), fill=DANGER)


def app_shell(base: Image.Image, active: str, draw_screen) -> None:
    x, y, w, h = 80, 604, 1082, 1946
    shadow(base, (x, y, x + w, y + h), 58, alpha=34, blur=34, y=18)
    screen = aurora((w, h))
    draw = ImageDraw.Draw(screen)
    status_bar(draw, w)
    draw_screen(draw, w, h)
    bottom_tabs(draw, w, h, active)
    shell = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shell.alpha_composite(screen)
    outline = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    od = ImageDraw.Draw(outline)
    od.rounded_rectangle((0, 0, w - 1, h - 1), radius=58, outline=(255, 255, 255, 225), width=3)
    shell.alpha_composite(outline)
    paste_rounded(base, shell, (x, y), 58)


def conversation_row(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    width: int,
    title: str,
    subtitle: str,
    time: str,
    color: tuple[int, int, int],
    badge: str = "",
    muted: bool = False,
) -> None:
    card(draw, (x, y, x + width, y + 128), 24)
    avatar(draw, (x + 28, y + 34), 60, color, title)
    draw.text((x + 108, y + 30), title, font=cn_font(29, True), fill=INK)
    draw.text((x + 108, y + 73), subtitle, font=cn_font(22), fill=MUTED)
    draw.text((x + width - 32, y + 32), time, font=cn_font(18), fill=MUTED, anchor="ra")
    if muted:
        draw.text((x + width - 78, y + 75), "免打扰", font=cn_font(17, True), fill=MUTED, anchor="ra")
    if badge:
        draw.ellipse((x + width - 54, y + 70, x + width - 18, y + 106), fill=DANGER)
        draw.text((x + width - 36, y + 89), badge, font=en_font(18, True), fill=WHITE, anchor="mm")


def screen_chats(draw: ImageDraw.ImageDraw, w: int, h: int) -> None:
    x = 54
    card(draw, (x, 104, w - x, 252), 26)
    draw.rounded_rectangle((x + 26, 132, x + 88, 194), radius=20, fill=BRAND)
    draw.text((x + 57, 164), "简", font=cn_font(30, True), fill=WHITE, anchor="mm")
    draw.text((x + 110, 130), "蓝石科技", font=cn_font(30, True), fill=INK)
    draw.text((x + 110, 174), "企业码 JHT2026", font=cn_font(20, True), fill=MUTED)
    draw.ellipse((w - 132, 143, w - 82, 193), fill=(93, 107, 255, 22))
    draw.line((w - 118, 168, w - 96, 168), fill=BRAND, width=4)
    draw.line((w - 107, 157, w - 107, 179), fill=BRAND, width=4)
    search_box(draw, x, 282, w - x * 2, "搜索联系人、群聊、聊天记录、文件")
    pill(draw, (x, 366, x + 110, 410), "全部", BRAND, True)
    pill(draw, (x + 128, 366, x + 238, 410), "未读", BRAND)
    pill(draw, (x + 256, 366, x + 356, 410), "@我", DANGER)
    rows = [
        ("产品研发群", "版本发布清单已同步", "09:42", BRAND, "3", False),
        ("运营协同", "活动素材已更新", "09:18", SUCCESS, "1", False),
        ("栀野", "收到，会后更新纪要", "08:55", WARNING, "", False),
        ("系统通知", "管理员更新了企业策略", "昨日", DANGER, "", True),
    ]
    y = 438
    for row in rows:
        conversation_row(draw, x, y, w - x * 2, *row)
        y += 146
    card(draw, (x, y + 6, w - x, y + 106), 22, fill=(255, 255, 255, 210))
    draw.text((x + 28, y + 34), "公告", font=cn_font(22, True), fill=BRAND)
    draw.text((x + 92, y + 34), "企业维护窗口已确认，相关群聊已通知。", font=cn_font(22), fill=INK)


def screen_contacts(draw: ImageDraw.ImageDraw, w: int, h: int) -> None:
    x = 54
    search_box(draw, x, 104, w - x * 2, "搜索联系人、用户ID或拼音")
    draw.rounded_rectangle((x, 188, w - x, 250), radius=18, fill=(255, 255, 255, 214), outline=(255, 255, 255, 180), width=2)
    draw.rounded_rectangle((x + 8, 196, w // 2 - 8, 242), radius=14, fill=BRAND)
    draw.text((w // 4, 219), "联系人", font=cn_font(22, True), fill=WHITE, anchor="mm")
    draw.text((w * 3 // 4, 219), "组织架构", font=cn_font(22, True), fill=MUTED, anchor="mm")
    entries = [
        ("新朋友", "3 个待处理", BRAND, "新"),
        ("群列表", "18 个群聊", VIOLET, "群"),
        ("黑名单", "0 个账号", DANGER, "禁"),
    ]
    gap = 18
    ew = (w - x * 2 - gap * 2) // 3
    for idx, (title, subtitle, color, mark) in enumerate(entries):
        ex = x + idx * (ew + gap)
        card(draw, (ex, 282, ex + ew, 418), 24)
        avatar(draw, (ex + ew // 2 - 24, 308), 48, color, mark)
        draw.text((ex + ew // 2, 368), title, font=cn_font(22, True), fill=INK, anchor="mm")
        draw.text((ex + ew // 2, 397), subtitle, font=cn_font(16, True), fill=MUTED, anchor="mm")
        if idx == 0:
            draw.ellipse((ex + ew - 43, 296, ex + ew - 17, 322), fill=DANGER, outline=WHITE, width=2)
            draw.text((ex + ew - 30, 309), "3", font=en_font(14, True), fill=WHITE, anchor="mm")
    draw.text((x, 472), "联系人", font=cn_font(30, True), fill=INK)
    groups = [
        ("C", [("陈屿", "iOS 工程师", SUCCESS), ("程澈", "后端工程师", BRAND)]),
        ("L", [("林夏", "产品经理", VIOLET), ("蓝石设计组", "团队群聊", WARNING)]),
        ("Z", [("栀野", "设计协作", WARNING)]),
    ]
    y = 520
    for letter, users in groups:
        draw.text((x + 8, y), letter, font=cn_font(22, True), fill=MUTED)
        y += 30
        card(draw, (x, y, w - x, y + 104 * len(users)), 24)
        for idx, (name, role, color) in enumerate(users):
            row_y = y + idx * 104
            avatar(draw, (x + 28, row_y + 24), 56, color, name)
            draw.text((x + 104, row_y + 24), name, font=cn_font(27, True), fill=INK)
            draw.text((x + 104, row_y + 63), role, font=cn_font(20), fill=MUTED)
            if role != "团队群聊":
                small_cert(draw, w - x - 152, row_y + 36)
            if idx < len(users) - 1:
                draw.line((x + 104, row_y + 103, w - x - 24, row_y + 103), fill=LINE, width=2)
        y += 104 * len(users) + 38


def file_row(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    width: int,
    name: str,
    meta: str,
    source: str,
    ext: str,
    color: tuple[int, int, int],
) -> None:
    card(draw, (x, y, x + width, y + 130), 24)
    draw.rounded_rectangle((x + 28, y + 32, x + 84, y + 92), radius=14, fill=color)
    draw.text((x + 56, y + 62), ext, font=en_font(14, True), fill=WHITE, anchor="mm")
    draw.text((x + 108, y + 28), name, font=cn_font(27, True), fill=INK)
    draw.text((x + 108, y + 66), meta, font=cn_font(20), fill=MUTED)
    draw.text((x + 108, y + 96), source, font=cn_font(18), fill=MUTED)
    draw.ellipse((x + width - 62, y + 48, x + width - 26, y + 84), fill=(255, 178, 70, 22))
    draw.text((x + width - 44, y + 66), "★", font=cn_font(18, True), fill=WARNING, anchor="mm")


def screen_files(draw: ImageDraw.ImageDraw, w: int, h: int) -> None:
    x = 54
    search_box(draw, x, 104, w - x * 2, "搜索文件、来源、发送人")
    chips = [("全部", True), ("PDF", False), ("图片", False), ("视频", False), ("表格", False), ("文档", False)]
    cx = x
    for label, selected in chips:
        tw = text_bbox(draw, label, cn_font(21, True))[0] + 44
        pill(draw, (cx, 188, cx + tw, 232), label, BRAND, selected)
        cx += tw + 12
    card(draw, (x, 264, w - x, 326), 16, fill=(255, 255, 255, 190))
    draw.text((x + 28, 286), "↓", font=cn_font(22, True), fill=BRAND)
    draw.text((x + 62, 286), "资料列表已刷新 21:12", font=cn_font(20, True), fill=MUTED)
    rows = [
        ("需求评审.pdf", "PDF · 8.1 MB · 林夏", "产品研发群 · 09:30", "PDF", DANGER),
        ("项目排期.xlsx", "表格 · 2.4 MB · 陈屿", "运营协同 · 昨日", "XLS", SUCCESS),
        ("发布素材.zip", "压缩包 · 35 MB · 栀野", "蓝石设计组 · 周二", "ZIP", WARNING),
        ("会议纪要.docx", "文档 · 486 KB · 周宁", "产品研发群 · 周一", "DOC", BRAND),
    ]
    y = 364
    for row in rows:
        file_row(draw, x, y, w - x * 2, *row)
        y += 148
    card(draw, (x, y + 14, w - x, y + 156), 24, fill=(255, 255, 255, 205))
    draw.text((x + 28, y + 50), "继续下滑显示更多资料", font=cn_font(23, True), fill=INK)
    draw.text((x + 28, y + 90), "图片、视频、音频与压缩包会按分类保留。", font=cn_font(20), fill=MUTED)


def call_row(
    draw: ImageDraw.ImageDraw,
    x: int,
    y: int,
    width: int,
    name: str,
    direction: str,
    detail: str,
    status: str,
    color: tuple[int, int, int],
) -> None:
    card(draw, (x, y, x + width, y + 130), 22)
    avatar(draw, (x + 28, y + 34), 56, color, name)
    draw.ellipse((x + 68, y + 72, x + 92, y + 96), fill=color, outline=WHITE, width=2)
    draw.text((x + 80, y + 83), "☎", font=cn_font(14, True), fill=WHITE, anchor="mm")
    draw.text((x + 108, y + 25), name, font=cn_font(27, True), fill=INK)
    draw.rounded_rectangle((x + 108, y + 63, x + 184, y + 94), radius=15, fill=(*color, 22))
    draw.text((x + 146, y + 78), direction, font=cn_font(16, True), fill=color, anchor="mm")
    draw.text((x + 198, y + 67), detail, font=cn_font(20), fill=MUTED)
    draw.text((x + width - 28, y + 32), "今天", font=cn_font(19, True), fill=MUTED, anchor="ra")
    status_color = SUCCESS if status.startswith("已") else DANGER
    draw.rounded_rectangle((x + width - 120, y + 70, x + width - 28, y + 102), radius=16, fill=(*status_color, 24))
    draw.text((x + width - 74, y + 86), status, font=cn_font(16, True), fill=status_color, anchor="mm")


def screen_calls(draw: ImageDraw.ImageDraw, w: int, h: int) -> None:
    x = 54
    card(draw, (x, 104, w - x, 338), 28)
    draw.rounded_rectangle((x + 26, 138, x + 92, 204), radius=22, fill=BRAND)
    draw.text((x + 59, 172), "☎", font=cn_font(30, True), fill=WHITE, anchor="mm")
    draw.text((x + 116, 138), "1对1沟通", font=cn_font(34, True), fill=INK)
    draw.text((x + 116, 188), "好友来电通知、接听和最近通话记录", font=cn_font(21, True), fill=MUTED)
    draw.rounded_rectangle((x + 26, 250, x + 474, 306), radius=18, fill=(93, 107, 255, 22))
    draw.text((x + 250, 278), "语音通话", font=cn_font(24, True), fill=BRAND, anchor="mm")
    draw.rounded_rectangle((x + 496, 250, w - x - 26, 306), radius=18, fill=(124, 107, 255, 22))
    draw.text(((x + 496 + w - x - 26) // 2, 278), "视频通话", font=cn_font(24, True), fill=VIOLET, anchor="mm")
    card(draw, (x, 378, w - x, 520), 24, fill=(255, 255, 255, 210))
    avatar(draw, (x + 28, 420), 58, SUCCESS, "林夏")
    draw.text((x + 108, 418), "林夏 · 语音通话", font=cn_font(28, True), fill=INK)
    draw.text((x + 108, 459), "来电中，等待接听", font=cn_font(21), fill=MUTED)
    draw.ellipse((w - x - 132, 424, w - x - 82, 474), fill=SUCCESS)
    draw.text((w - x - 107, 449), "接", font=cn_font(20, True), fill=WHITE, anchor="mm")
    draw.ellipse((w - x - 68, 424, w - x - 18, 474), fill=DANGER)
    draw.text((w - x - 43, 449), "拒", font=cn_font(20, True), fill=WHITE, anchor="mm")
    draw.text((x, 578), "最近通话", font=cn_font(30, True), fill=INK)
    rows = [
        ("陈屿", "我呼出", "语音通话 · 08:42", "已接", BRAND),
        ("栀野", "对方来电", "视频通话 · 12:18", "未接", WARNING),
        ("蓝石支持", "系统", "通话连接恢复", "已结束", VIOLET),
    ]
    y = 626
    for row in rows:
        call_row(draw, x, y, w - x * 2, *row)
        y += 148


SCREENS = [
    ("conversations", "chats", screen_chats),
    ("contacts", "contacts", screen_contacts),
    ("files", "files", screen_files),
    ("calls", "calls", screen_calls),
]


def draw_brand_header(base: Image.Image, locale: PromoLocale) -> None:
    draw = ImageDraw.Draw(base)
    icon = Image.open(APP_ICON).convert("RGBA")
    icon = ImageOps.fit(icon, (76, 76))
    shadow(base, (86, 86, 162, 162), 22, alpha=24, blur=18, y=8)
    paste_rounded(base, icon, (86, 86), 22)
    draw.text((180, 91), locale.brand, font=promo_font(locale, 34, True), fill=INK)
    badge_w = 218 if locale.lang == "zh" else 302
    draw.rounded_rectangle((180, 134, 180 + badge_w, 172), radius=19, fill=(255, 255, 255, 180))
    draw.text((202, 141), locale.badge, font=promo_font(locale, 20, True), fill=BRAND)


def render(locale: PromoLocale, index: int) -> Image.Image:
    base = aurora((W, H))
    draw = ImageDraw.Draw(base)
    draw_brand_header(base, locale)
    title_font = promo_font(locale, 78 if locale.lang == "zh" else 72, True)
    subtitle_font = promo_font(locale, 31 if locale.lang == "zh" else 29)
    draw_multiline(draw, (86, 218), locale.titles[index], title_font, fill=INK, spacing=8)
    subtitle_y = 410 if "\n" in locale.titles[index] else 334
    subtitle = wrap_text(draw, locale.subtitles[index], subtitle_font, 920)
    draw_multiline(draw, (88, subtitle_y), subtitle, subtitle_font, fill=MUTED, spacing=10)

    _, active, screen = SCREENS[index]
    app_shell(base, active, screen)
    footer = "BlueStoneIM" if locale.lang == "en" else "BlueStoneIM · X01"
    draw.text((W // 2, H - 58), footer, font=promo_font(locale, 22, True), fill=(92, 104, 132), anchor="mm")
    return base.convert("RGB")


def make_contact_sheet(paths: Iterable[Path]) -> Path:
    paths = list(paths)
    sheet_path = OUT_DIR / "contact-sheet-app-faithful.jpg"
    thumbs = []
    label_font = en_font(18)
    for path in paths:
        with Image.open(path) as src:
            thumb = src.convert("RGB")
            thumb.thumbnail((220, 476))
            canvas = Image.new("RGB", (260, 540), WHITE)
            canvas.paste(thumb, ((260 - thumb.width) // 2, 18))
            ImageDraw.Draw(canvas).text((10, 505), path.name, font=label_font, fill=INK)
            thumbs.append(canvas)
    sheet = Image.new("RGB", (1040, 1080), (245, 247, 252))
    for index, thumb in enumerate(thumbs):
        sheet.paste(thumb, ((index % 4) * 260, (index // 4) * 540))
    sheet.save(sheet_path, quality=92)
    return sheet_path


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for locale in (ZH, EN):
        for index, (name, _, _) in enumerate(SCREENS):
            image = render(locale, index)
            out = OUT_DIR / f"{locale.lang}-{index + 1:02d}-{name}-app-faithful-1242x2688.png"
            image.save(out, "PNG", optimize=True)
            written.append(out)
            print(out)
    print(make_contact_sheet(written))


if __name__ == "__main__":
    main()
