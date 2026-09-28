#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 PKB 的 Math_1000 合并成一本可导入的书,并输出等价的 YAML 版本。

为什么 YAML 只做文本搬运、不重新推导题型:
REPS 的 YAML 导入器本身就是「读出 front / back,拼回 Quizify Markdown,
再交给 parseQuizify」。所以只要把每张卡按 `***` 切成 front / back 原样搬过去,
两条路径解析出来的题型、选项、标识键必然一致 —— 不需要(也不应该)在这里
另写一套题型判定,否则两边会慢慢说出不同的话。

输出:
  C:\\temp\\math1000\\math1000.md
  C:\\temp\\math1000\\math1000.yml
"""
import io
import os
import re
import sys

SRC = '/mnt/c/Users/yicha/Development/PKB/DocforAnki/Math_1000_Markdown'
OUT = '/mnt/c/temp/math1000'
DECK = 'Math_1000'

# 篇的顺序由目录名前缀决定(01_ 在 02_ 前),章的顺序由 ChNN 决定
def sort_key(path: str):
    part = os.path.basename(os.path.dirname(path))
    m = re.search(r'Ch(\d+)', os.path.basename(path))
    return (part, int(m.group(1)) if m else 0)


def collect_files():
    out = []
    for root, _dirs, files in os.walk(SRC):
        for f in files:
            if f.endswith('.md'):
                out.append(os.path.join(root, f))
    return sorted(out, key=sort_key)


FM = re.compile(r'^---\s*\n.*?\n---\s*\n', re.S)


def body_of(text: str) -> str:
    """去掉 front matter,只留卡片正文"""
    return FM.sub('', text, count=1)


def cards_of(body: str):
    """按独占一行的 +++ 切出卡片。空块丢掉 —— 文件首尾各有一个 +++"""
    parts = re.split(r'(?m)^\+\+\+\s*$', body)
    return [p.strip('\n') for p in parts if p.strip()]


def split_front_back(card: str):
    """按独占一行的 *** 切成正反面"""
    halves = re.split(r'(?m)^\*\*\*\s*$', card)
    if len(halves) != 2:
        return None
    return halves[0].strip('\n'), halves[1].strip('\n')


def block_scalar(text: str, indent: int) -> str:
    """
    输出 YAML 的 `|` 块标量。
    每一行都缩进 indent 个空格;空行输出成真正的空行(不留尾随空格),
    否则 YAML 里会变成含空格的行,块标量的缩进判定会跟着漂。
    """
    pad = ' ' * indent
    out = []
    for line in text.split('\n'):
        out.append(pad + line if line.strip() else '')
    return '\n'.join(out)


def main() -> int:
    files = collect_files()
    if not files:
        print(f'没找到源文件: {SRC}')
        return 2
    os.makedirs(OUT, exist_ok=True)

    all_cards = []
    per_file = []
    tags = set()
    for path in files:
        text = io.open(path, encoding='utf-8').read()
        mt = re.search(r'tags:\s*\[([^\]]*)\]', text)
        if mt:
            for t in mt.group(1).split(','):
                t = t.strip()
                if t:
                    tags.add(t)
        cs = cards_of(body_of(text))
        per_file.append((os.path.basename(path), len(cs)))
        all_cards.extend(cs)

    # 源文件每章都带一堆知识点 tag,合并成一本书之后那 44 个 tag 毫无检索价值。
    # 只留书级别的几个;章节信息本来就在每张卡的 #### 标题里。
    KEEP = ('Math', '1000题', '数一', '高等数学', '基础篇', '强化篇')
    keep = [t for t in KEEP if t in tags]

    # ---------- Markdown ----------
    md = io.StringIO()
    md.write('---\n')
    md.write('quizify:\n')
    md.write('  format: 1\n')
    md.write(f'  deck: {DECK}\n')
    md.write('  tags: [' + ', '.join(keep) + ']\n')
    md.write('---\n\n')
    # `+++` 是**每张卡前面的分隔标记,文件末尾不再补一个**。
    # 源文件就是这个约定:Ch01 有 20 张卡、正好 20 个 +++。
    # 多写一个尾部 +++ 会凭空造出一张空卡,解析直接报「这张卡的正面是空的」。
    for c in all_cards:
        md.write('+++\n\n')
        md.write(c)
        md.write('\n\n')
    md_path = os.path.join(OUT, 'math1000.md')
    io.open(md_path, 'w', encoding='utf-8', newline='\n').write(md.getvalue())

    # ---------- YAML ----------
    ya = io.StringIO()
    ya.write(f'deck: {DECK}\n')
    ya.write('tags: [' + ', '.join(keep) + ']\n')
    ya.write('cards:\n')
    bad = 0
    for c in all_cards:
        fb = split_front_back(c)
        if fb is None:
            bad += 1
            continue
        front, back = fb
        ya.write('  - front: |\n')
        ya.write(block_scalar(front, 6) + '\n')
        ya.write('    back: |\n')
        ya.write(block_scalar(back, 6) + '\n')
    yml_path = os.path.join(OUT, 'math1000.yml')
    io.open(yml_path, 'w', encoding='utf-8', newline='\n').write(ya.getvalue())

    print(f'源文件 {len(files)} 个')
    for name, n in per_file:
        print(f'  {n:3d} 张  {name}')
    print(f'\n合计 {len(all_cards)} 张卡')
    if bad:
        print(f'**{bad} 张缺少 *** 分隔,已跳过(YAML 需要 back)**')
    print(f'tags: {keep}')
    print(f'\n{md_path}  {os.path.getsize(md_path) // 1024} KB')
    print(f'{yml_path}  {os.path.getsize(yml_path) // 1024} KB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
