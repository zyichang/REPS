# 怎样写 REPS 牌组(REPS Card YAML v1)

[English](yaml-guide.en.md)

一个牌组就是一个 `.yaml` 文本文件。写好后在 App 里「导入」选中它即可。
本文的每个 ```` ```yaml ```` 例子都是能直接导入的完整文件,桌面测试 `devtest/guide_test.ts` 会逐个解析,
格式变了而文档没跟上时测试会失败。

完整示例文件:[`testdata/examples/example.zh.yaml`](../testdata/examples/example.zh.yaml)
(交给 AI 当模板最方便)。字段的完整定义见 [`data-model.md`](data-model.md) 第 1 节。

## 1. 最小的牌组

```yaml
reps: 1
deck: 经济学基础
cards:
  - type: qa
    front: "什么是机会成本?"
    back: "为了得到某样东西而必须放弃的、价值最高的那个选择。"
```

- `reps: 1`:格式版本,固定写 1。
- `deck`:牌组名。
- `cards`:卡片列表,每张以 `- ` 开头,下面的字段缩进对齐。

## 2. 牌组信息与卡片 id

```yaml
reps: 1
meta:
  version: 1
  author: "张三"
  language: zh-CN
  license: CC-BY-4.0
  description: "《经济学原理》第 1 章的核心概念"
  source: "曼昆《经济学原理》第 1 章"
  generated_by: ai
deck: 经济学原理 · 第1章
tags: [经济学, 第1章]
cards:
  - id: ch1-001
    type: qa
    title: "机会成本"
    front: "什么是机会成本?"
    back: "为了得到某样东西而必须放弃的东西。"
    tags: [概念]
```

- `meta` 整块可选。`generated_by` 写 `manual`(手写)、`ai` 或 `ai+manual`。
- `meta.id` 不用自己写,第一次导出时 App 会生成。
- **卡片 `id` 强烈建议写**:只用字母、数字、`-`,文件内不重复(如 `ch1-001`)。
  以后改了内容重新导入,App 按 `id` 认出是同一张卡,**学习进度保留**。
  没写 `id` 时按标题(没有标题就按正面第一行)认卡,改了它就会被当成一张新卡。
- `title` 可选,显示在浏览列表里;没写就用正面第一行。

## 3. 问答题(qa)

多行内容用 `|`,下面的正文统一多缩进 2 格:

```yaml
reps: 1
deck: 示例 · 问答
cards:
  - id: qa-1
    type: qa
    front: "TCP 三次握手的三步分别是什么?"
    back: |
      1. 客户端发 **SYN**
      2. 服务器回 **SYN + ACK**
      3. 客户端再发 **ACK**

      > [!TIP]
      > 两次握手不够:服务器无法确认客户端收到了自己的 SYN。
```

## 4. 单选题

`options` 只写选项内容,App 自动编成 A、B、C…;`answer` 写一个字母:

```yaml
reps: 1
deck: 示例 · 单选
cards:
  - id: choice-1
    type: choice
    front: "下列哪种排序算法是稳定的?"
    options: ["快速排序", "堆排序", "归并排序", "选择排序"]
    answer: C
    back: "归并排序合并时相等元素保持原有先后顺序。"
```

`back` 在选择题里是可选的解析。

## 5. 多选题

`answer` 写成列表就是多选,**全选对才算对**。选项多或较长时可以一行一个:

```yaml
reps: 1
deck: 示例 · 多选
cards:
  - id: multi-1
    type: choice
    front: "下列哪些是线性结构?"
    options:
      - "栈"
      - "二叉树"
      - "队列"
      - "图"
    answer: [A, C]
    back: "栈和队列的元素一个接一个排成一条线;树和图不是。"
```

## 6. 挖空题(cloze)

用 `{{ }}` 包住要挖掉的内容。一张卡里的所有空**同时**考、同时揭开:

```yaml
reps: 1
deck: 示例 · 挖空
cards:
  - id: cloze-1
    type: cloze
    front: "中国的首都是 {{北京}}。"

  - id: cloze-2
    type: cloze
    front: "程序的三种基本结构是 {{顺序}}、{{选择}} 和 {{循环}}。"
    back: "任何单入口单出口的程序都能用这三种结构表达。"
```

想分开考的空,就拆成几张卡。

## 7. 公式、代码与格式

```yaml
reps: 1
deck: 示例 · 格式
cards:
  - id: fmt-math
    type: qa
    front: "一元二次方程 $ax^2+bx+c=0$ 的求根公式是什么?"
    back: |
      $$x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$$

      其中 $\Delta = b^2-4ac$ 叫 **判别式**。

  - id: fmt-code
    type: qa
    front: "Python 里怎样反转一个列表?"
    back: |
      ```python
      nums = [1, 2, 3]
      nums.reverse()      # 原地反转
      print(nums[::-1])   # 返回新列表
      ```

  - id: fmt-style
    type: qa
    front: "REPS 支持哪些文字格式?"
    back: |
      **粗体**、*斜体*、==高亮==、`行内代码`、上标 x^2^、下标 H~2~O。

      > [!NOTE]
      > 说明(蓝)

      > [!WARNING] 自定义标题
      > 注意(橙)。另外还有 TIP(绿)、IMPORTANT(紫)、CAUTION(红)。
```

| 写法 | 效果 |
|---|---|
| `$…$` / `$$…$$` | 行内公式 / 独立成行的公式(KaTeX) |
| ```` ``` ```` 代码块 | 等宽、原样显示,里面的符号不解析 |
| `**粗体**`、`*斜体*`、`==高亮==` | 斜体的星号要紧贴文字,`a * b` 不算斜体 |
| `` `代码` ``、`x^2^`、`H~2~O` | 行内代码、上标、下标 |
| `> [!NOTE]` 等五种 | 提示框;可在后面写自定义标题 |

不支持图片、音频、视频。

## 8. 写法规则(容易出错的地方)

- **文字一律加引号或用 `|`**:`front`、`back`、`title`、每个选项。
  不加引号时,冒号会截断内容、`no` 会变成布尔值、`#` 会被当成注释,所以 REPS 直接拒绝。
- 缩进用 **2 个空格**,不能用 Tab。
- 双引号里要写 `"` 或 `\` 时,改用 `|` 块更省事。
- `#` 注释只能单独占一行。
- 选项里**不要**自己写 `A.`,App 会加。
- 选择题必须有 `options`(至少 2 项)和 `answer`;别的题型不要写 `options`。

错误示例(导入时会报错并给出行号):

```text
  - front: 什么是 TCP: 一种协议        ← 没加引号,冒号会截断
    options: [A. 栈, B. 队列]          ← 没加引号,而且不该自己写 A. B.
    answer: E                           ← 只有两个选项,没有 E
```

## 9. 让 AI 生成牌组

把下面这段提示词连同资料(书的章节、讲义、笔记)一起发给 AI。
最好再附上完整示例文件 `testdata/examples/example.zh.yaml`。

```text
请阅读我提供的资料,把其中值得记住的知识点做成 REPS 牌组,只输出一个 YAML 文件,不要别的解释。

格式要求(REPS Card YAML v1):
1. 第一行 reps: 1;然后 deck: 牌组名;可选 tags: [标签1, 标签2];然后 cards: 列表。
2. 每张卡写 id(字母数字和 -,如 ch1-001,不重复)、type、front,按题型补充:
   - type: qa   问答题,必须有 back。
   - type: choice 选择题,options 只写选项内容(不要写 A. B.),每项加双引号;
     answer 单选写一个字母(如 C),多选写列表(如 [A, C])。back 写解析。
   - type: cloze 挖空题,在 front 里用 {{答案}} 挖空,一张卡的空会同时考。
3. 所有文字(front、back、title、每个选项)必须用双引号,或者用 | 写多行块(正文多缩进 2 格)。
4. 缩进用 2 个空格,不用 Tab。
5. 可以用 Markdown:**粗体**、*斜体*、==高亮==、`代码`、``` 代码块;
   公式用 $…$ 和 $$…$$(LaTeX);提示框用 > [!NOTE] / [!TIP] / [!IMPORTANT] / [!WARNING] / [!CAUTION]。
6. 一张卡只考一个知识点;正面是清楚的问题,背面先给简短答案,再给必要的解释。
7. 不要放图片和链接。
```

生成后直接导入。导入失败时,App 会告诉你第几行出错,把报错发回给 AI 让它改就行。
