#!/usr/bin/env python3
"""从 docs/*.md 生成统一中文格式的可编辑 Word 文档。"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from docx import Document
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor


ROOT = Path(__file__).resolve().parents[1]
DOCS_DIR = ROOT / "docs"
BLACK = RGBColor(0, 0, 0)

DOCUMENTS = {
    "项目设计方案": "基于 GPU 的服务资源卸载技术探索——项目设计方案",
    "实验结果报告": "GPUC 实验结果报告",
    "实验复现指南": "GPUC 实验复现指南",
}


def find_style(doc: Document, name: str):
    return next((style for style in doc.styles if style.name == name), None)


def ensure_paragraph_style(doc: Document, name: str):
    style = find_style(doc, name)
    if style is None:
        style = doc.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
    return style


def set_east_asia_font(run_or_style, name: str) -> None:
    run_or_style.font.name = name
    rpr = run_or_style._element.get_or_add_rPr()
    fonts = rpr.get_or_add_rFonts()
    fonts.set(qn("w:ascii"), name)
    fonts.set(qn("w:hAnsi"), name)
    fonts.set(qn("w:eastAsia"), name)
    fonts.set(qn("w:cs"), name)


def set_style(doc: Document, name: str, font: str, size: float, *, bold=False,
              line_spacing=1.5, before=0, after=6, first_indent=None,
              alignment=None) -> None:
    style = find_style(doc, name)
    if style is None:
        return
    set_east_asia_font(style, font)
    style.font.size = Pt(size)
    style.font.bold = bold
    style.font.color.rgb = BLACK
    pf = style.paragraph_format
    pf.line_spacing = line_spacing
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    if first_indent is not None:
        pf.first_line_indent = Cm(first_indent)
    if alignment is not None:
        pf.alignment = alignment


def set_run_font(run, name: str, size: float | None = None) -> None:
    set_east_asia_font(run, name)
    if size is not None:
        run.font.size = Pt(size)
    run.font.color.rgb = BLACK


def set_cell_shading(cell, fill: str) -> None:
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), fill)


def repeat_table_header(row) -> None:
    tr_pr = row._tr.get_or_add_trPr()
    marker = OxmlElement("w:tblHeader")
    marker.set(qn("w:val"), "true")
    tr_pr.append(marker)


def set_table_borders(table) -> None:
    tbl_pr = table._tbl.tblPr
    borders = tbl_pr.find(qn("w:tblBorders"))
    if borders is None:
        borders = OxmlElement("w:tblBorders")
        tbl_pr.append(borders)
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        element = borders.find(qn(f"w:{edge}"))
        if element is None:
            element = OxmlElement(f"w:{edge}")
            borders.append(element)
        element.set(qn("w:val"), "single")
        element.set(qn("w:sz"), "4")
        element.set(qn("w:space"), "0")
        element.set(qn("w:color"), "808080")


def set_table_autofit(table) -> None:
    tbl_pr = table._tbl.tblPr
    width = tbl_pr.find(qn("w:tblW"))
    if width is None:
        width = OxmlElement("w:tblW")
        tbl_pr.append(width)
    width.set(qn("w:type"), "pct")
    width.set(qn("w:w"), "5000")

    layout = tbl_pr.find(qn("w:tblLayout"))
    if layout is None:
        layout = OxmlElement("w:tblLayout")
        tbl_pr.append(layout)
    layout.set(qn("w:type"), "autofit")

    for cell_width in table._tbl.xpath('.//*[local-name()="tcW"]'):
        cell_width.set(qn("w:type"), "auto")
        cell_width.set(qn("w:w"), "0")


def add_page_number(paragraph) -> None:
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = paragraph.add_run()
    begin = OxmlElement("w:fldChar")
    begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = " PAGE "
    separate = OxmlElement("w:fldChar")
    separate.set(qn("w:fldCharType"), "separate")
    text = OxmlElement("w:t")
    text.text = "1"
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    for node in (begin, instr, separate, text, end):
        run._r.append(node)
    set_run_font(run, "宋体", 9)


def enable_field_updates(doc: Document) -> None:
    settings = doc.settings._element
    current = settings.find(qn("w:updateFields"))
    if current is None:
        current = OxmlElement("w:updateFields")
        settings.append(current)
    current.set(qn("w:val"), "true")


def format_paragraph(paragraph) -> None:
    style_name = paragraph.style.name if paragraph.style else ""
    if style_name == "Title":
        font, size = "黑体", 22
        paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    elif style_name in {"Subtitle", "Author", "Date"}:
        font, size = "宋体", 12
        paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    elif style_name.startswith("Heading") or style_name == "TOC Heading":
        font = "黑体"
        size = {"Heading 1": 16, "Heading 2": 14, "Heading 3": 12}.get(style_name, 12)
    elif style_name in {"Source Code", "Verbatim Char"}:
        font, size = "Consolas", 9.5
    else:
        font, size = "宋体", 12
    for run in paragraph.runs:
        set_run_font(run, font, size)


def style_document(path: Path) -> None:
    doc = Document(path)

    for name in ("TOC 1", "TOC 2", "TOC 3"):
        ensure_paragraph_style(doc, name)

    for section in doc.sections:
        section.page_width = Cm(21.0)
        section.page_height = Cm(29.7)
        section.top_margin = Cm(2.54)
        section.bottom_margin = Cm(2.54)
        section.left_margin = Cm(3.0)
        section.right_margin = Cm(2.5)
        section.header_distance = Cm(1.5)
        section.footer_distance = Cm(1.5)
        section.different_first_page_header_footer = True

    for name in ("Normal", "Body Text", "First Paragraph"):
        set_style(doc, name, "宋体", 12, line_spacing=1.5, after=6,
                  first_indent=0.74)
    for name in ("Compact", "List Paragraph", "Block Text"):
        set_style(doc, name, "宋体", 12, line_spacing=1.5, after=3,
                  first_indent=0)
    set_style(doc, "Title", "黑体", 22, bold=True, line_spacing=1.0,
              before=160, after=18, alignment=WD_ALIGN_PARAGRAPH.CENTER)
    for name in ("Subtitle", "Author", "Date"):
        set_style(doc, name, "宋体", 12, line_spacing=1.5, after=6,
                  alignment=WD_ALIGN_PARAGRAPH.CENTER)
    set_style(doc, "Heading 1", "黑体", 16, bold=True, line_spacing=1.0,
              before=18, after=8)
    set_style(doc, "Heading 2", "黑体", 14, bold=True, line_spacing=1.0,
              before=14, after=6)
    set_style(doc, "Heading 3", "黑体", 12, bold=True, line_spacing=1.0,
              before=10, after=5)
    set_style(doc, "TOC Heading", "黑体", 16, bold=True, line_spacing=1.0,
              after=12, alignment=WD_ALIGN_PARAGRAPH.CENTER)
    for name, size in (("TOC 1", 12), ("TOC 2", 11), ("TOC 3", 10.5)):
        set_style(doc, name, "宋体", size, line_spacing=1.5, after=0)
    set_style(doc, "Source Code", "Consolas", 9.5, line_spacing=1.0,
              before=3, after=6, first_indent=0)
    set_style(doc, "Caption", "宋体", 10.5, line_spacing=1.0, after=6,
              alignment=WD_ALIGN_PARAGRAPH.CENTER)

    link_style = find_style(doc, "Hyperlink")
    if link_style is not None:
        set_east_asia_font(link_style, "宋体")
        link_style.font.color.rgb = BLACK
        link_style.font.underline = False

    for paragraph in doc.paragraphs:
        format_paragraph(paragraph)
        if paragraph.style.name.startswith("Heading"):
            paragraph.paragraph_format.keep_with_next = True
        if paragraph.style.name == "Source Code":
            p_pr = paragraph._p.get_or_add_pPr()
            shd = OxmlElement("w:shd")
            shd.set(qn("w:fill"), "F2F2F2")
            p_pr.append(shd)

    date_paragraph = next((p for p in doc.paragraphs
                           if p.style.name == "Date"), None)
    has_page_break = bool(date_paragraph is not None and
                          date_paragraph._p.xpath('.//*[local-name()="br" and @*[local-name()="type"]="page"]'))
    if date_paragraph is not None and not has_page_break:
        date_paragraph.add_run().add_break(WD_BREAK.PAGE)

    for table in doc.tables:
        table_grid = find_style(doc, "Table Grid")
        table.style = table_grid if table_grid is not None else find_style(doc, "Table")
        set_table_borders(table)
        table.autofit = True
        set_table_autofit(table)
        if table.rows:
            repeat_table_header(table.rows[0])
        for row_index, row in enumerate(table.rows):
            for cell in row.cells:
                if row_index == 0:
                    set_cell_shading(cell, "E7E6E6")
                for paragraph in cell.paragraphs:
                    paragraph.paragraph_format.first_line_indent = Cm(0)
                    paragraph.paragraph_format.line_spacing = 1.5
                    paragraph.paragraph_format.space_after = Pt(0)
                    for run in paragraph.runs:
                        set_run_font(run, "宋体", 12)
                        run.font.color.rgb = BLACK
                        if row_index == 0:
                            run.font.bold = True

    # Pandoc 的目录位于标题页之后；正文从第一个一级标题另起一页。
    first_heading = next((p for p in doc.paragraphs
                          if p.style.name == "Heading 1"), None)
    if first_heading is not None:
        first_heading.paragraph_format.page_break_before = True

    # 所有超链接与目录字段均保持黑色。
    for run_el in doc.element.xpath('.//*[local-name()="hyperlink"]//*[local-name()="r"]'):
        r_pr = run_el.find(qn("w:rPr"))
        if r_pr is None:
            r_pr = OxmlElement("w:rPr")
            run_el.insert(0, r_pr)
        color = r_pr.find(qn("w:color"))
        if color is None:
            color = OxmlElement("w:color")
            r_pr.append(color)
        color.set(qn("w:val"), "000000")
    for run_el in doc.element.xpath('.//*[local-name()="sdt"]//*[local-name()="r"]'):
        r_pr = run_el.find(qn("w:rPr"))
        if r_pr is None:
            r_pr = OxmlElement("w:rPr")
            run_el.insert(0, r_pr)
        color = r_pr.find(qn("w:color"))
        if color is None:
            color = OxmlElement("w:color")
            r_pr.append(color)
        color.set(qn("w:val"), "000000")

    for section in doc.sections:
        footer = section.footer
        paragraph = footer.paragraphs[0]
        paragraph.clear()
        add_page_number(paragraph)

    enable_field_updates(doc)
    doc.core_properties.title = DOCUMENTS[path.stem]
    doc.core_properties.author = "西安交通大学 404notfound"
    doc.core_properties.subject = "基于 GPU 的服务资源卸载技术探索"
    doc.save(path)


def build_document(stem: str, title: str) -> Path:
    source = DOCS_DIR / f"{stem}.md"
    output = DOCS_DIR / f"{stem}.docx"
    lines = source.read_text(encoding="utf-8").splitlines(keepends=True)
    if not lines or not lines[0].startswith("# "):
        raise RuntimeError(f"{source} 缺少一级文档标题")

    # Word 使用 Pandoc 元数据生成独立标题页，正文标题整体上移一级。
    body_lines = lines[1:]
    while body_lines and not body_lines[0].strip():
        body_lines.pop(0)
    # Markdown 顶部引用块只保存版本和阅读提示；Word 已有独立封面，目录页不重复显示。
    while body_lines and body_lines[0].startswith(">"):
        body_lines.pop(0)
    while body_lines and not body_lines[0].strip():
        body_lines.pop(0)
    body = "".join(body_lines)

    with tempfile.TemporaryDirectory(prefix="gpuc_word_") as temp_dir:
        temp_md = Path(temp_dir) / source.name
        temp_md.write_text(body, encoding="utf-8")
        command = [
            "pandoc", str(temp_md), "--from=gfm", "--to=docx", "--standalone",
            "--toc", "--toc-depth=3", "--shift-heading-level-by=-1",
            f"--metadata=title:{title}",
            "--metadata=author:西安交通大学 404notfound",
            "--metadata=date:2026-08-09",
            "--metadata=lang:zh-CN", "--metadata=toc-title:目录",
            f"--resource-path={DOCS_DIR}:{ROOT}", f"--output={output}",
        ]
        subprocess.run(command, cwd=ROOT, check=True)

    style_document(output)
    return output


def main() -> None:
    for stem, title in DOCUMENTS.items():
        path = build_document(stem, title)
        print(path.relative_to(ROOT))


if __name__ == "__main__":
    main()
