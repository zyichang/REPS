# How to write a REPS deck (REPS Card YAML v1 / v2)

[中文](yaml-guide.zh.md)

A deck is a single `.yaml` text file. Once it's written, tap Import in the app and pick the file.
Every ```` ```yaml ```` example here is a complete file you can import as-is. The desktop test
`devtest/guide_test.ts` parses each one, so if the format changes and this guide doesn't, the test fails.

Full example file: [`testdata/examples/example.en.yaml`](../testdata/examples/example.en.yaml)
(the easiest template to give an AI). The complete field reference is in section 1 of
[`data-model.md`](data-model.md) (Chinese).

## 1. The smallest deck

```yaml
reps: 1
deck: Economics Basics
cards:
  - type: qa
    front: "What is opportunity cost?"
    back: "The value of the best alternative you give up to get something."
```

- `reps: 1`: the format version. Always 1.
- `deck`: the deck name.
- `cards`: the list of cards. Each starts with `- `, and its fields line up under it.

## 2. Deck info and card ids

```yaml
reps: 1
meta:
  version: 1
  author: "Jane Doe"
  language: en
  license: CC-BY-4.0
  description: "Key ideas from chapter 1 of Principles of Economics"
  source: "Mankiw, Principles of Economics, ch. 1"
  generated_by: ai
deck: Principles of Economics · Ch 1
tags: [economics, ch1]
cards:
  - id: ch1-001
    type: qa
    title: "Opportunity cost"
    front: "What is opportunity cost?"
    back: "Whatever must be given up to obtain some item."
    tags: [concept]
```

- The whole `meta` block is optional. `generated_by` is `manual`, `ai`, or `ai+manual`.
- Leave out `meta.id`. The app generates it the first time the deck is exported.
- **Card `id`s are strongly recommended.** Use only letters, digits, and `-`, unique within the file
  (e.g. `ch1-001`). When you edit a card and re-import, the app matches it by `id` and **keeps your
  study progress**. Without an `id`, the app matches by title (or the front's first line if there's no
  title), so changing that makes it a new card.
- `title` is optional and shows in the Browse list. Without it, the front's first line is used.

## 3. Q&A (qa)

For multi-line text, use `|` and indent the body 2 more spaces:

```yaml
reps: 1
deck: Example · Q&A
cards:
  - id: qa-1
    type: qa
    front: "What are the three steps of the TCP handshake?"
    back: |
      1. The client sends **SYN**
      2. The server replies **SYN + ACK**
      3. The client sends **ACK**

      > [!TIP]
      > Two steps aren't enough: the server couldn't be sure the client got its SYN.
```

## 4. Single choice

`options` holds only the option text; the app labels them A, B, C… `answer` is one letter:

```yaml
reps: 1
deck: Example · Single choice
cards:
  - id: choice-1
    type: choice
    front: "Which sorting algorithm is stable?"
    options: ["Quicksort", "Heapsort", "Merge sort", "Selection sort"]
    answer: C
    back: "Merge sort keeps equal elements in their original order when merging."
```

For choice cards, `back` is an optional explanation.

## 5. Multiple choice

Make `answer` a list for multiple choice. **All correct options must be picked.** For long or many
options, put one per line:

```yaml
reps: 1
deck: Example · Multiple choice
cards:
  - id: multi-1
    type: choice
    front: "Which of these are linear data structures?"
    options:
      - "Stack"
      - "Binary tree"
      - "Queue"
      - "Graph"
    answer: [A, C]
    back: "Stacks and queues keep elements in a single line; trees and graphs don't."
```

## 6. Cloze

Wrap what should be hidden in `{{ }}`. All blanks on one card are tested **together** and revealed
together:

```yaml
reps: 1
deck: Example · Cloze
cards:
  - id: cloze-1
    type: cloze
    front: "The capital of France is {{Paris}}."

  - id: cloze-2
    type: cloze
    front: "The three basic control structures are {{sequence}}, {{selection}}, and {{iteration}}."
    back: "Any single-entry, single-exit program can be written with these three."
```

To test blanks separately, split them into several cards.

## 7. Math, code, and formatting

```yaml
reps: 1
deck: Example · Formatting
cards:
  - id: fmt-math
    type: qa
    front: "What is the quadratic formula for $ax^2+bx+c=0$?"
    back: |
      $$x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$$

      Here $\Delta = b^2-4ac$ is the **discriminant**.

  - id: fmt-code
    type: qa
    front: "How do you reverse a list in Python?"
    back: |
      ```python
      nums = [1, 2, 3]
      nums.reverse()      # in place
      print(nums[::-1])   # returns a new list
      ```

  - id: fmt-style
    type: qa
    front: "Which text formats does REPS support?"
    back: |
      **Bold**, *italic*, ==highlight==, `inline code`, superscript x^2^, subscript H~2~O.

      > [!NOTE]
      > Note (blue)

      > [!WARNING] A custom title
      > Warning (orange). There are also TIP (green), IMPORTANT (purple), and CAUTION (red).
```

| Syntax | Result |
|---|---|
| `$…$` / `$$…$$` | Inline math / display math (KaTeX) |
| ```` ``` ```` code block | Monospace, shown as-is; nothing inside is parsed |
| `**bold**`, `*italic*`, `==highlight==` | Italic asterisks must touch the text; `a * b` is not italic |
| `` `code` ``, `x^2^`, `H~2~O` | Inline code, superscript, subscript |
| `> [!NOTE]` and four others | Callout box; a custom title may follow |

Images, audio, and video are not supported.

## 8. Question kinds and answer time limits (reps: 2)

Exam questions need pacing practice. Each question kind has an answer time limit; when time runs
out, the card flips over automatically and counts as Again. The default limits suit memorization;
exam decks set their own limits in the file, based on the real exam. If you use either field below,
the first line must be `reps: 2`.

**A card's `kind` (question kind).** It is not the same as `type`: `type` is how you answer,
`kind` is which kind of exam question it is.

| `kind` | Question kind | Default limit | Without `kind` |
|---|---|---|---|
| `choice` | Multiple choice | 60 s | cards with `type: choice` |
| `blank` | Fill-in-the-blank | 60 s | cards with `type: cloze` |
| `short` | Short answer | 60 s | cards with `type: qa` |
| `long` | Long answer (worked problems) | 5 min | must be written out |
| `essay` | Essay | 25 min | must be written out |

An exam fill-in-the-blank question (work out the result, then fill it in) is written as `type: qa`
plus `kind: blank`. Long-answer and essay cards that count as Again don't come back the same day;
they return the next day.

**The deck-level `time_limits`.** It sits at the same level as `deck`. Each line is
`kind: minutes`; decimals are allowed, and the value must be more than 0 and at most 180.
List only the kinds you want to change; the rest keep their default limits.

```yaml
reps: 2
deck: Example · Kinds and limits
time_limits:
  choice: 2.5
  essay: 30
cards:
  - id: exam-choice-1
    type: choice
    front: "A price rises 20%, then falls 20%. The new price is what share of the original?"
    options: ["96%", "100%", "104%", "80%", "120%"]
    answer: A
    back: "1.2 × 0.8 = 0.96."

  - id: exam-long-1
    type: qa
    kind: long
    front: |
      Find $\lim_{x \to 0} \dfrac{\sin x}{x}$.
    back: |
      **1.** By the squeeze theorem: $\cos x < \dfrac{\sin x}{x} < 1$.

  - id: exam-essay-1
    type: qa
    kind: essay
    front: |
      Essay: write about 700 words on the topic of "persistence". Choose your own title.
    back: |
      **Reading the prompt:** persistence is a means, not an end; say what is worth persisting in, and why.

      **Structure:** thesis → supporting argument → counterargument → conclusion.
```

In this deck, multiple choice gets 2.5 minutes and essays get 30. Long answers aren't listed, so
they keep the default 5 minutes. A complete exam deck example:
[`testdata/examples/example-exam.en.yaml`](../testdata/examples/example-exam.en.yaml).

## 9. Rules (common mistakes)

- **Always quote text or use `|`**: `front`, `back`, `title`, and every option. Unquoted, a colon
  cuts the text short, `no` turns into a boolean, and `#` starts a comment, so REPS rejects it outright.
- Indent with **2 spaces**, never tabs.
- If the text contains `"` or `\`, a `|` block is easier than escaping.
- A `#` comment must be on its own line.
- **Don't** write `A.` in options; the app adds the letters.
- Choice cards need `options` (at least 2) and `answer`. Other types must not have `options`.
- If you use `kind` or `time_limits`, the first line must be `reps: 2`. A `reps: 1` file that
  contains them fails to import.

Wrong (the import fails and reports the line number):

```text
  - front: What is TCP: a protocol      ← not quoted; the colon cuts it short
    options: [A. Stack, B. Queue]       ← not quoted, and don't write A. B. yourself
    answer: E                           ← only two options, so there's no E
```

## 10. Generating a deck with AI

Send this prompt to the AI together with your material (book chapters, lecture notes, your own
notes). Attaching the full example file `testdata/examples/example.en.yaml` helps too; for an exam
deck, attach `example-exam.en.yaml` as well.

```text
Read the material I provide and turn the facts worth remembering into a REPS deck.
Output only one YAML file, with no other explanation.

Format (REPS Card YAML):
1. First line: reps: 1 (reps: 2 if you use kind or time_limits from rule 3). Then deck: <deck name>,
   optionally tags: [tag1, tag2], then a cards: list.
2. Every card has an id (letters, digits, and -, e.g. ch1-001, unique), a type, and a front, plus:
   - type: qa      Q&A. Must have a back.
   - type: choice  Multiple choice. options holds only the option text (no "A." or "B."),
     each in double quotes. answer is one letter for single choice (e.g. C) or a list for
     multiple choice (e.g. [A, C]). Put the explanation in back.
   - type: cloze   Cloze. Mark blanks in front with {{answer}}; all blanks on a card are tested together.
3. For exam questions, also write kind (the question kind): kind: essay for essays, kind: long for
   long-answer and worked problems, kind: blank for exam fill-in-the-blank questions (written as
   type: qa). Multiple choice, cloze, and short answers need no kind. If the deck uses kind, add
   time_limits under deck with an answer time limit in minutes for each kind, based on the real exam,
   e.g. time_limits: followed by indented lines choice: 2.5 and essay: 30.
4. All text (front, back, title, every option) must be in double quotes, or be a | block
   (body indented 2 more spaces).
5. Indent with 2 spaces, never tabs.
6. Markdown is allowed: **bold**, *italic*, ==highlight==, `code`, ``` code blocks.
   Math uses $…$ and $$…$$ (LaTeX). Callouts: > [!NOTE] / [!TIP] / [!IMPORTANT] / [!WARNING] / [!CAUTION].
7. One fact per card. The front is a clear question; the back gives the short answer first,
   then any needed explanation.
8. No images or links.
```

Import the result directly. If the import fails, the app tells you which line is wrong; send that
error back to the AI and ask it to fix the file.
