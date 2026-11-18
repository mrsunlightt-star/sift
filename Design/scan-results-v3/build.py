#!/usr/bin/env python3
"""Scan-results redesign mockups (light appearance).

Every colour, size and radius below is an existing token from
Shared/DesignSystem/SiftTheme.swift, so this is implementable without a second
visual language: action green #007E46, main #202722, secondary #5F6962,
quiet #68716B, divider #E5EAE6, wall #F6F8F6, safe #286D41, review #8A5A00.
"""

from pathlib import Path

OUT = Path(__file__).resolve().parent

ACTION = "#007E46"
MAIN = "#202722"
SECONDARY = "#5F6962"
QUIET = "#68716B"
DIVIDER = "#E5EAE6"
WELL = "#F6F8F6"
HOVER = "#F4F7F5"
SAFE = "#286D41"
REVIEW = "#8A5A00"
DANGER = "#B23A3A"
BORDER = "#DFE3E0"
CB_OFF = "#C4CFC8"


def icon(paths, size=18):
    return (
        f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" '
        f'stroke="currentColor" stroke-width="1.7" stroke-linecap="round" '
        f'stroke-linejoin="round">{paths}</svg>'
    )


I = {
    "overview": '<rect x="4" y="4" width="7" height="7" rx="1.6"/><rect x="13" y="4" width="7" height="7" rx="1.6"/><rect x="4" y="13" width="7" height="7" rx="1.6"/><rect x="13" y="13" width="7" height="7" rx="1.6"/>',
    "scan": '<path d="M4 9V6a2 2 0 0 1 2-2h3"/><path d="M15 4h3a2 2 0 0 1 2 2v3"/><path d="M20 15v3a2 2 0 0 1-2 2h-3"/><path d="M9 20H6a2 2 0 0 1-2-2v-3"/><path d="M4 12h16"/>',
    "apps": '<rect x="3.5" y="3.5" width="9" height="9" rx="2"/><rect x="11.5" y="11.5" width="9" height="9" rx="2"/>',
    "storage": '<path d="M5 20V11"/><path d="M12 20V4"/><path d="M19 20v-5"/>',
    "settings": '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2M12 18.5v2M20.5 12h-2M5.5 12h-2M18 6l-1.4 1.4M7.4 16.6L6 18M18 18l-1.4-1.4M7.4 7.4L6 6"/>',
    "account": '<circle cx="12" cy="9" r="3.4"/><path d="M5.5 20a6.5 6.5 0 0 1 13 0"/>',
    "appearance": '<circle cx="12" cy="12" r="8"/><path d="M12 4a8 8 0 0 1 0 16z" fill="currentColor" stroke="none"/>',
    "globe": '<circle cx="12" cy="12" r="8"/><path d="M4 12h16"/><path d="M12 4c2.4 2.3 3.6 5 3.6 8s-1.2 5.7-3.6 8c-2.4-2.3-3.6-5-3.6-8S9.6 6.3 12 4z"/>',
    "check": '<path d="M4.8 12.4l4.4 4.4L19.2 6.6"/>',
    "chevron": '<path d="M6 9.5l6 6 6-6"/>',
    "lock": '<rect x="5" y="10.2" width="14" height="9.8" rx="2.2"/><path d="M8.4 10.2V7.8a3.6 3.6 0 0 1 7.2 0v2.4"/>',
    "trash": '<path d="M4.5 7h15"/><path d="M9.5 7V5.2a1.2 1.2 0 0 1 1.2-1.2h2.6a1.2 1.2 0 0 1 1.2 1.2V7"/><path d="M6.5 7l.9 12.1a1.6 1.6 0 0 0 1.6 1.4h6a1.6 1.6 0 0 0 1.6-1.4L17.5 7"/>',
    "refresh": '<path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20 4.5V10h-5.2"/>',
    "warning": '<path d="M12 4.6l8.3 14.3H3.7z"/><path d="M12 10v4"/><path d="M12 16.7v.1"/>',
    "duplicate": '<rect x="8.5" y="8.5" width="11" height="11" rx="2"/><path d="M15.5 8.5V6.6a2.1 2.1 0 0 0-2.1-2.1H6.6a2.1 2.1 0 0 0-2.1 2.1v6.8a2.1 2.1 0 0 0 2.1 2.1h1.9"/>',
    "folder": '<path d="M3.9 7.4a1.9 1.9 0 0 1 1.9-1.9h3.3l1.9 2.3h7.2a1.9 1.9 0 0 1 1.9 1.9v7.9a1.9 1.9 0 0 1-1.9 1.9H5.8a1.9 1.9 0 0 1-1.9-1.9z"/>',
}

CSS = f"""
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ background: #fff; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
        color: {MAIN}; -webkit-font-smoothing: antialiased; }}
.window {{ width: 1440px; height: 900px; background: #fff; display: flex; overflow: hidden; }}

.sidebar {{ width: 190px; flex: 0 0 190px; border-right: 1px solid {DIVIDER};
           display: flex; flex-direction: column; padding: 0 10px 10px; }}
.traffic {{ height: 50px; display: flex; align-items: center; gap: 8px; padding-left: 8px; }}
.dot {{ width: 12px; height: 12px; border-radius: 50%; }}
.brand {{ display: flex; align-items: center; gap: 9px; padding: 4px 8px 16px; }}
.brand-mark {{ width: 26px; height: 26px; border-radius: 7px; background: #00BF63;
               display: grid; place-items: center; color: #fff; }}
.brand-name {{ font-size: 14px; font-weight: 600; }}
.nav {{ display: flex; flex-direction: column; gap: 2px; }}
.nav-item {{ display: flex; align-items: center; gap: 10px; height: 42px; padding: 0 12px;
             border-radius: 8px; font-size: 14px; font-weight: 500; color: {SECONDARY}; }}
.nav-item.on {{ background: #E8F7EF; color: {ACTION}; font-weight: 600; }}
.nav-foot {{ margin-top: auto; display: flex; flex-direction: column; gap: 1px; padding-top: 9px;
             border-top: 1px solid {DIVIDER}; }}
.nav-foot .nav-item {{ height: 36px; font-size: 13px; font-weight: 400; }}

.page {{ flex: 1 1 auto; display: flex; flex-direction: column; min-width: 0; }}
.col {{ max-width: 1120px; }}

.header {{ padding: 20px 28px 0; display: flex; align-items: flex-start; }}
.h-title {{ font-size: 26px; font-weight: 600; letter-spacing: -.2px; line-height: 1.2; }}
.h-sub {{ margin-top: 5px; font-size: 12.5px; color: {SECONDARY}; }}
.h-sub .sep {{ color: #BAC4BC; margin: 0 7px; }}
.h-sub .strong {{ color: {MAIN}; font-weight: 500; }}
.btn-ghost {{ margin-left: auto; display: inline-flex; align-items: center; gap: 6px; height: 30px;
              padding: 0 11px; border: 1px solid {BORDER}; border-radius: 7px; background: #fff;
              font-size: 12.5px; font-weight: 500; color: {MAIN}; }}
.rule {{ height: 1px; background: {DIVIDER}; margin-top: 12px; }}

.tabs {{ display: flex; align-items: flex-end; gap: 26px; padding: 0 28px; }}
.tab {{ position: relative; display: inline-flex; align-items: baseline; gap: 7px; height: 44px;
        padding-top: 14px; font-size: 13px; font-weight: 500; color: {SECONDARY}; }}
.tab .n {{ font-size: 11.5px; color: {QUIET}; font-variant-numeric: tabular-nums; }}
.tab.on {{ color: {ACTION}; font-weight: 600; }}
.tab.on .n {{ color: {ACTION}; }}
.tab.on::after {{ content: ""; position: absolute; left: 0; right: 0; bottom: 0; height: 2px;
                  background: {ACTION}; border-radius: 1px 1px 0 0; }}
.tabs .grow {{ flex: 1; }}
.sort {{ display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: {SECONDARY};
         padding-bottom: 14px; }}

.ledger {{ flex: 1 1 auto; padding: 2px 28px 0; overflow: hidden; }}
.grp {{ display: flex; align-items: center; gap: 8px; height: 38px; margin-top: 12px; }}
.grp .gt {{ font-size: 13px; font-weight: 600; }}
.grp .gc {{ font-size: 11.5px; color: {SECONDARY}; font-variant-numeric: tabular-nums; }}
.grp .gb {{ font-size: 11.5px; color: {SECONDARY}; font-variant-numeric: tabular-nums; }}
.grp .grow {{ flex: 1; }}
.link {{ font-size: 11.5px; font-weight: 500; color: {ACTION}; }}
.chev {{ color: {QUIET}; display: grid; place-items: center; }}
.hint {{ font-size: 11.5px; color: {QUIET}; margin: -4px 0 6px 25px; }}

.row {{ display: flex; align-items: center; gap: 12px; height: 50px; padding: 0 10px 0 4px; border-radius: 7px; }}
.row.hov {{ background: {HOVER}; }}
.cbx {{ width: 17px; flex: 0 0 17px; height: 17px; border-radius: 4.5px; border: 1.5px solid {CB_OFF};
        background: #fff; display: grid; place-items: center; color: #fff; }}
.cbx.on {{ background: {ACTION}; border-color: {ACTION}; }}
.cbx.lock {{ border: none; background: transparent; color: {QUIET}; }}
.rn {{ flex: 1 1 auto; min-width: 0; }}
.name {{ font-size: 13.5px; font-weight: 500; line-height: 1.35; white-space: nowrap;
         overflow: hidden; text-overflow: ellipsis; }}
.sub {{ margin-top: 1px; font-size: 11.5px; color: {SECONDARY}; line-height: 1.35; white-space: nowrap;
        overflow: hidden; text-overflow: ellipsis; }}
.sz {{ flex: 0 0 92px; text-align: right; font-size: 13px; font-weight: 500;
       font-variant-numeric: tabular-nums; font-family: "SF Mono", ui-monospace, monospace; }}
.row.muted .name {{ font-weight: 400; color: {SECONDARY}; }}
.row.muted .sz {{ color: {SECONDARY}; }}

.more {{ display: flex; align-items: center; gap: 8px; height: 32px; padding-left: 33px; }}
.more .t {{ font-size: 11.5px; color: {QUIET}; }}
.more .grow {{ flex: 1; }}

.note {{ display: flex; align-items: center; gap: 9px; margin-top: 12px; padding: 9px 12px;
         background: {WELL}; border-radius: 7px; font-size: 11.5px; color: {SECONDARY}; }}
.note .grow {{ flex: 1; }}
.note .chev {{ margin-left: 2px; }}

.bar {{ border-top: 1px solid {DIVIDER}; padding: 12px 28px; }}
.bar-in {{ max-width: 1120px; display: flex; align-items: center; gap: 16px; }}
.num {{ font-size: 27px; font-weight: 600; letter-spacing: -.5px; line-height: 1.05;
        font-variant-numeric: tabular-nums; }}
.meta {{ display: flex; flex-direction: column; gap: 2px; padding-top: 2px; }}
.meta .a {{ font-size: 12.5px; color: {MAIN}; }}
.meta .b {{ font-size: 11.5px; color: {QUIET}; }}
.bar .grow {{ flex: 1; }}
.btn {{ display: inline-flex; align-items: center; gap: 7px; height: 36px; padding: 0 15px;
        border-radius: 7px; background: {ACTION}; color: #fff; font-size: 13px; font-weight: 600; }}
"""


def sidebar():
    def item(label, key, on=False):
        return f'<div class="nav-item{" on" if on else ""}">{icon(I[key],17)}<span>{label}</span></div>'
    return f"""
  <aside class="sidebar">
    <div class="traffic"><span class="dot" style="background:#FF5F57"></span>
      <span class="dot" style="background:#FEBC2E"></span>
      <span class="dot" style="background:#28C840"></span></div>
    <div class="brand"><div class="brand-mark">{icon(I['check'],15)}</div><span class="brand-name">Sift</span></div>
    <nav class="nav">{item("总览","overview")}{item("扫描","scan",True)}{item("应用","apps")}{item("存储","storage")}</nav>
    <div class="nav-foot">{item("设置","settings")}{item("账户","account")}{item("跟随系统","appearance")}{item("简体中文","globe")}</div>
  </aside>"""


def header():
    return f"""
  <header class="header">
    <div>
      <div class="h-title">扫描</div>
      <div class="h-sub">刚刚扫描<span class="sep">·</span>151 个项目<span class="sep">·</span>可清理 14.74 GB</div>
    </div>
    <div class="btn-ghost">{icon(I['refresh'],13)}<span>重新扫描</span></div>
  </header>
  <div class="rule"></div>"""


def tabs(active="全部"):
    cells = [(t, n, t == active) for t, n in [
        ("全部","151 项"),("垃圾","10.03 GB"),("大文件","4.38 GB"),
        ("旧文件","326.7 MB"),("重复","2.7 GB")]]
    html = "".join(
        f'<div class="tab{" on" if on else ""}"><span>{t}</span><span class="n">{n}</span></div>'
        for t, n, on in cells)
    return f"""
  <div class="tabs">{html}<div class="grow"></div>
    <div class="sort"><span>按大小</span>{icon(I['chevron'],11)}</div>
  </div>"""


def cb(state="on"):
    if state == "lock":
        return f'<span class="cbx lock">{icon(I["lock"],14)}</span>'
    if state == "on":
        return f'<span class="cbx on">{icon(I["check"],11)}</span>'
    return '<span class="cbx"></span>'


def row(name, path, size, state="on", muted=False, hov=False):
    cls = "row" + (" hov" if hov else "") + (" muted" if muted else "")
    return f"""
  <div class="{cls}">{cb(state)}
    <div class="rn"><div class="name">{name}</div><div class="sub">{path}</div></div>
    <div class="sz">{size}</div>
  </div>"""


def grp(title, count, size, glyph=None, color=QUIET, action=None, chevron=True, open_=False):
    g = f'<span style="color:{color};display:grid;place-items:center">{icon(I[glyph],14)}</span>' if glyph else ""
    act = f'<span class="link">{action}</span>' if action else ""
    ch = f'<span class="chev" style="transform:rotate(180deg)">{icon(I["chevron"],12)}</span>' if open_ else (
        f'<span class="chev">{icon(I["chevron"],12)}</span>' if chevron else '<span style="width:12px"></span>')
    return f"""
  <div class="grp">{g}<span class="gt">{title}</span><span class="gc">{count}</span>
    <span class="gb">{size}</span><span class="grow"></span>{act}{ch}
  </div>"""


def more(text, action="展开全部"):
    return f'<div class="more"><span class="t">{text}</span><span class="grow"></span><span class="link">{action}</span></div>'


def note(text, action=None):
    a = f'<span class="link">{action}</span>' if action else ""
    return f"""
  <div class="note">{icon(I['warning'],13)}<span>{text}</span><span class="grow"></span>{a}<span class="chev">{icon(I['chevron'],11)}</span></div>"""


def ledger_all():
    return f"""
  <div class="ledger col">
    {grp("可安全清理","37 项","4.6 GB","check",SAFE,open_=True)}
    {row("Google","~/Library/Caches/Google","1.47 GB")}
    {row("DerivedData","~/Library/Developer/Xcode/DerivedData","980.6 MB")}
    {row("@deepseek-aidsh-desktop-updater","~/Library/Caches/@deepseek-aidsh-desktop-updater","726.4 MB")}
    {row("qoder-updater","~/Library/Caches/qoder-updater","684.3 MB")}
    {more("还有 33 项较小内容，共 734.4 MB")}

    {grp("需要你确认","114 项","10.14 GB","warning",REVIEW,open_=True)}
    <div class="hint">这些项目不会默认勾选，逐项确认后才会清理。</div>
    {row("系统日志","~/Library/Logs · 超过 30 天未修改","1.9 GB",state="off",muted=True)}
    {row("崩溃报告","~/Library/Logs/DiagnosticReports · 超过 30 天","612.4 MB",state="off",muted=True)}
    {row("隐私痕迹","~/Library/Safari · 浏览与搜索记录","486.2 MB",state="off",muted=True)}
    {more("还有 111 项，共 7.14 GB")}

    {grp("重复文件","136 组","2.7 GB","duplicate",QUIET,action="查看")}
    {grp("受保护","8 项","不参与清理","lock",QUIET,chevron=True)}

    {note("13 个位置无法读取，需要完全磁盘访问权限","打开系统设置")}
  </div>"""


def ledger_duplicates():
    def member(path, size, keep=False):
        if keep:
            return f"""
  <div class="row" style="height:42px;padding-left:22px;background:{WELL}">
    <span style="flex:0 0 17px;width:17px;height:17px;border-radius:50%;background:{SAFE};
                 display:grid;place-items:center;color:#fff">{icon(I['check'],10)}</span>
    <div class="rn"><div class="name" style="font-weight:400;color:{SECONDARY}">{path}</div></div>
    <div class="sz" style="color:{SECONDARY}">{size}</div>
    <span style="flex:0 0 56px;text-align:right;font-size:11.5px;color:{SAFE}">已保留</span>
  </div>"""
        return f"""
  <div class="row" style="height:42px;padding-left:22px">
    {cb('on')}
    <div class="rn"><div class="name">{path}</div></div>
    <div class="sz">{size}</div>
    <span class="link" style="flex:0 0 56px;text-align:right;color:{QUIET}">保留此项</span>
  </div>"""

    def group(title, meta, members):
        rows = "".join(member(*m) for m in members)
        return f"""
  <div style="padding-left:14px;margin:6px 0 4px">
    <div style="display:flex;align-items:baseline;gap:8px;height:28px">
      <span style="font-size:12.5px;font-weight:600">{title}</span>
      <span style="font-size:11.5px;color:{SECONDARY}">{meta}</span>
    </div>{rows}
  </div>"""

    return f"""
  <div class="ledger col">
    {grp("重复文件","136 组","2.7 GB","duplicate",QUIET,chevron=False)}
    <div class="hint" style="margin-left:23px">
      每组保留最早的一份，其余副本移入废纸篓；点任一副本的“保留此项”即可改为保留它。
    </div>
    {group("证据目录-0928.pdf","4 份 · 可释放 61.8 MB",[
        ("~/Documents/案件/证据目录-0928.pdf","20.6 MB",True),
        ("~/Downloads/证据目录-0928 (1).pdf","20.6 MB",False),
        ("~/Desktop/备份/证据目录-0928.pdf","20.6 MB",False),
        ("~/Downloads/旧/证据目录-0928.pdf","20.6 MB",False)])}
    {group("会议录屏 2026-09.mov","3 份 · 可释放 275.2 MB",[
        ("~/Movies/会议录屏 2026-09.mov","137.6 MB",True),
        ("~/Downloads/会议录屏 2026-09.mov","137.6 MB",False),
        ("~/Desktop/未命名文件夹/会议录屏 2026-09.mov","137.6 MB",False)])}
    {more("已显示 2 组，共 136 组","加载更多")}
    {grp("受保护","8 项","不参与清理","lock",QUIET,chevron=True)}
  </div>"""


def bar(big="4.6 GB", a="已选 37 项，共 151 项", b="其中 3 项需要确认 · 移入废纸篓后可恢复"):
    return f"""
  <div class="bar"><div class="bar-in">
    <div class="num">{big}</div>
    <div class="meta"><span class="a">{a}</span><span class="b">{b}</span></div>
    <div class="grow"></div>
    <span class="link">全选可清理项</span>
    <span class="link" style="color:{QUIET}">取消全选</span>
    <div class="btn">{icon(I['trash'],14)}<span>移入废纸篓</span></div>
  </div></div>"""


def page(body, active="全部"):
    return f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><style>{CSS}</style></head>
<body><div class="window">{sidebar()}<main class="page">{header()}{tabs(active)}{body}</main></div></body></html>"""


def write(name, html):
    (OUT / name).write_text(html, encoding="utf-8")
    print("wrote", name)


write("01-scan-results.html", page(ledger_all() + bar()))
write("02-scan-duplicates.html",
      page(ledger_duplicates() + bar(big="105.4 MB",
                                     a="已选 5 个副本，共 136 组",
                                     b="每组保留 1 份 · 移入废纸篓后可恢复"),
           active="重复"))
