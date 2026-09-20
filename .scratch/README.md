# .scratch — 本仓库的议题追踪器

这个目录**是版本管理的一部分**,不是临时草稿。名字里的 "scratch" 有点误导,
但它是 `docs/agents/issue-tracker.md` 约定的位置:议题与 PRD 以 markdown 文件形式
存在这里,而不是放在 GitHub Issues 上。

提交它的理由:议题如果被 gitignore 掉,换一台机器 clone 之后就全没了,
协作者也看不到。

## 约定

```
.scratch/<feature-slug>/
├── PRD.md                      该特性的需求文档
└── issues/
    ├── 01-<slug>.md
    └── 02-<slug>.md            从 01 开始编号
```

每个议题文件顶部带一行 `Status:`,取值只能是这五个之一
(定义见 `docs/agents/triage-labels.md`):

```markdown
# 03 — 把 Markdown 标题层级切成知识点

Status: ready-for-agent
```

| 取值 | 含义 |
|---|---|
| `needs-triage` | 还需要评估 |
| `needs-info` | 等提出者补充信息 |
| `ready-for-agent` | 已写清楚,agent 可以无人值守地实现 |
| `ready-for-human` | 需要人来做 |
| `wontfix` | 不做 |

对话记录追加在文件末尾的 `## Comments` 之下。
